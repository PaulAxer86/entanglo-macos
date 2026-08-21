//
// filename: PrinterBridgeService.swift
// path: Entanglo/Entanglo/Services/PrinterBridgeService.swift
// purpose: Receives a PDF print job from a trusted peer, switches this
//          Mac's Wi-Fi from the current network onto the printer's
//          SoftAP (the HP-style "direct" Wi-Fi), runs `lpr -P queue file`
//          via the local CUPS queue, then power-cycles Wi-Fi so macOS
//          auto-rejoins its preferred network — no home password stored.
//
//          Designed for the common HP "Wi-Fi Direct only" scenario:
//          paired Mac on Ethernet/Wi-Fi forwards a PDF over Entanglo's
//          trusted-peer transport, the bridge Mac sacrifices ~30 s of
//          its own Wi-Fi to print, then comes back online.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

/// Status of an active or completed print bridge job, surfaced to the UI
/// so the user knows their Wi-Fi is being borrowed.
public struct PrinterBridgeJobStatus: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case received
        case savingCurrentNetwork
        case joiningPrinterNetwork
        case waitingForPrinter
        case submittingJob
        case waitingForJobCompletion
        case restoringNetwork
        case done
        case failed
    }
    public var jobId: String
    public var fromPeerName: String
    public var fileName: String
    public var phase: Phase
    public var message: String
    public var startedAt: Date
    public var finishedAt: Date?
}

@MainActor
public final class PrinterBridgeService: ObservableObject {

    @Published public private(set) var currentJob: PrinterBridgeJobStatus?
    @Published public private(set) var recentJobs: [PrinterBridgeJobStatus] = []

    /// User-configurable bridge state — flipped by SettingsView and
    /// mirrored from AppState so persistence happens in one place.
    public var bridgeEnabled: Bool = false
    public var printerSSID: String = ""
    public var printerPassword: String = ""
    public var printerQueue: String = ""

    private let log: AppLogService
    private let wifiInterface: String

    public init(log: AppLogService = .shared, wifiInterface: String = "en0") {
        self.log = log
        self.wifiInterface = wifiInterface
    }

    // MARK: - Public entry

    /// Called by AppState when an incoming file transfer marked
    /// `kind: "printJob"` finishes. If the bridge is enabled and a queue
    /// is configured, runs the full network-switch + lpr sequence on a
    /// background task; otherwise just logs and leaves the PDF in
    /// ~/Downloads/Entanglo for the user to handle manually.
    public func submitIncomingPrintJob(fileURL: URL, fromPeerName: String) {
        guard bridgeEnabled else {
            log.log(.app, "Print job from \(fromPeerName) ignored — bridge disabled. PDF saved at \(fileURL.path)")
            return
        }
        guard !printerSSID.isEmpty else {
            log.log(.error, "Print job from \(fromPeerName) rejected — printer SSID not configured")
            return
        }
        guard !printerQueue.isEmpty else {
            log.log(.error, "Print job from \(fromPeerName) rejected — printer queue not configured")
            return
        }
        let status = PrinterBridgeJobStatus(
            jobId: UUID().uuidString,
            fromPeerName: fromPeerName,
            fileName: fileURL.lastPathComponent,
            phase: .received,
            message: "Print job received from \(fromPeerName)",
            startedAt: Date(),
            finishedAt: nil
        )
        currentJob = status
        log.log(.app, "Print bridge: starting job \(fileURL.lastPathComponent) from \(fromPeerName)")

        let ssid = printerSSID
        let password = printerPassword
        let queue = printerQueue
        let iface = wifiInterface
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runJob(
                status: status,
                fileURL: fileURL,
                printerSSID: ssid,
                printerPassword: password,
                printerQueue: queue,
                interface: iface
            )
        }
    }

    /// Lists CUPS queues installed on this Mac. Backs the queue picker in
    /// SettingsView so the user doesn't have to type a name.
    public static func availableCUPSQueues() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        proc.arguments = ["-e"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Job orchestration

    private nonisolated func runJob(
        status initialStatus: PrinterBridgeJobStatus,
        fileURL: URL,
        printerSSID: String,
        printerPassword: String,
        printerQueue: String,
        interface: String
    ) async {
        var status = initialStatus

        await self.advance(&status, phase: .savingCurrentNetwork,
                           message: "Recording current Wi-Fi network")
        let savedSSID = Self.currentSSID(interface: interface)
        if let savedSSID {
            await self.appendLog("Print bridge: current SSID = \(savedSSID)")
        }

        await self.advance(&status, phase: .joiningPrinterNetwork,
                           message: "Joining printer network \(printerSSID)")
        let switched = Self.setAirportNetwork(interface: interface, ssid: printerSSID, password: printerPassword)
        if !switched {
            await self.fail(&status, reason: "Could not join printer Wi-Fi \(printerSSID)")
            Self.powerCycleWiFi(interface: interface)
            return
        }

        await self.advance(&status, phase: .waitingForPrinter,
                           message: "Waiting for printer Wi-Fi to be ready")
        let printerReady = await Self.waitForSSID(printerSSID, interface: interface, timeoutSeconds: 15)
        if !printerReady {
            await self.fail(&status, reason: "Printer Wi-Fi \(printerSSID) didn't come up within 15 s")
            Self.powerCycleWiFi(interface: interface)
            return
        }

        await self.advance(&status, phase: .submittingJob,
                           message: "Submitting to CUPS queue \(printerQueue)")
        let lprJob = Self.runLPR(queue: printerQueue, file: fileURL)
        if let lprJob {
            await self.appendLog("Print bridge: lpr accepted job \(lprJob)")
        } else {
            await self.fail(&status, reason: "lpr -P \(printerQueue) failed")
            Self.powerCycleWiFi(interface: interface)
            return
        }

        await self.advance(&status, phase: .waitingForJobCompletion,
                           message: "Printing on \(printerQueue)")
        // Some HP printers need ~30 s to render a page. Cap at 60 s to
        // bound how long we hold the user's Wi-Fi hostage.
        let printed = await Self.waitForQueueIdle(queue: printerQueue, timeoutSeconds: 60)
        if !printed {
            await self.appendLog("Print bridge: queue \(printerQueue) still busy after 60 s — restoring network anyway")
        }

        await self.advance(&status, phase: .restoringNetwork,
                           message: "Reconnecting to your usual network")
        // Power-cycle is more reliable than re-running setairportnetwork
        // with a remembered SSID: macOS handles the auto-join (with the
        // password already stored in the system keychain) so we never
        // have to store the user's home Wi-Fi password.
        Self.powerCycleWiFi(interface: interface)

        // Best-effort wait until we're back on a non-printer network.
        _ = await Self.waitForNetworkOtherThan(printerSSID, interface: interface, timeoutSeconds: 20)

        await self.finish(&status, message: "Print job done")
    }

    // MARK: - State transitions (main actor)

    private func advance(_ status: inout PrinterBridgeJobStatus, phase: PrinterBridgeJobStatus.Phase, message: String) async {
        status.phase = phase
        status.message = message
        let snapshot = status
        await MainActor.run {
            self.currentJob = snapshot
            self.log.log(.app, "Print bridge: \(phase.rawValue) — \(message)")
        }
    }

    private func fail(_ status: inout PrinterBridgeJobStatus, reason: String) async {
        status.phase = .failed
        status.message = reason
        status.finishedAt = Date()
        let snapshot = status
        await MainActor.run {
            self.currentJob = nil
            self.recentJobs.insert(snapshot, at: 0)
            self.log.log(.error, "Print bridge failed: \(reason)")
        }
    }

    private func finish(_ status: inout PrinterBridgeJobStatus, message: String) async {
        status.phase = .done
        status.message = message
        status.finishedAt = Date()
        let snapshot = status
        await MainActor.run {
            self.currentJob = nil
            self.recentJobs.insert(snapshot, at: 0)
            if self.recentJobs.count > 10 {
                self.recentJobs.removeLast(self.recentJobs.count - 10)
            }
            self.log.log(.app, "Print bridge done: \(snapshot.fileName)")
        }
    }

    private func appendLog(_ msg: String) async {
        await MainActor.run { self.log.log(.app, msg) }
    }

    // MARK: - Shell helpers (pure, nonisolated)

    private nonisolated static func currentSSID(interface: String) -> String? {
        let out = run("/usr/sbin/networksetup", ["-getairportnetwork", interface])
        // Format: "Current Wi-Fi Network: <SSID>"
        guard let out, let range = out.range(of: ": ") else { return nil }
        let trimmed = out[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("not associated") { return nil }
        return trimmed
    }

    @discardableResult
    private nonisolated static func setAirportNetwork(interface: String, ssid: String, password: String) -> Bool {
        let args: [String]
        if password.isEmpty {
            args = ["-setairportnetwork", interface, ssid]
        } else {
            args = ["-setairportnetwork", interface, ssid, password]
        }
        let out = run("/usr/sbin/networksetup", args) ?? ""
        // networksetup prints "Failed to join network <ssid>" on failure.
        if out.lowercased().contains("failed") { return false }
        return true
    }

    private nonisolated static func waitForSSID(_ expected: String, interface: String, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if currentSSID(interface: interface) == expected { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private nonisolated static func waitForNetworkOtherThan(_ ssid: String, interface: String, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let cur = currentSSID(interface: interface), cur != ssid { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Returns the CUPS job ID stamped by `lpr -V` if the job was queued,
    /// or nil on failure. Example output: "request id is HP_Color-42 (1 file(s))".
    private nonisolated static func runLPR(queue: String, file: URL) -> String? {
        let out = run("/usr/bin/lpr", ["-P", queue, "-V", file.path]) ?? ""
        // Heuristic: lpr exits 0 silently on success. Treat empty output
        // as success unless we got an explicit error keyword.
        if out.lowercased().contains("error") { return nil }
        if let range = out.range(of: "request id is ") {
            let tail = out[range.upperBound...]
            if let space = tail.firstIndex(of: " ") {
                return String(tail[..<space])
            }
        }
        return "queued"
    }

    private nonisolated static func waitForQueueIdle(queue: String, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let out = run("/usr/bin/lpstat", ["-o", queue]) ?? ""
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return false
    }

    private nonisolated static func powerCycleWiFi(interface: String) {
        _ = run("/usr/sbin/networksetup", ["-setairportpower", interface, "off"])
        Thread.sleep(forTimeInterval: 1.5)
        _ = run("/usr/sbin/networksetup", ["-setairportpower", interface, "on"])
    }

    /// Runs `tool args…` synchronously and returns combined stdout, or
    /// nil if the process couldn't be launched at all.
    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
