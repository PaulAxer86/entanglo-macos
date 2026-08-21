//
// filename: UpdateService.swift
// path: Entanglo/Entanglo/Services/UpdateService.swift
// purpose: Detects whether a newer Entanglo build is available, exposes
//          it to the UI as a published value, and loads embedded release
//          notes. Sources are abstracted behind UpdateSource so a future
//          RemoteHTTPSource (manifest JSON over LAN or internet) can drop
//          in without touching the view layer.
//

import Foundation
import Combine
import CryptoKit

#if canImport(AppKit)
import AppKit
#endif

public struct AvailableUpdate: Equatable {
    public let version: String
    public let url: URL
    public let note: ReleaseNote?
}

public protocol UpdateSource: AnyObject {
    /// Called when the source detects a candidate. The service compares
    /// against the running bundle version before exposing it.
    var onCandidate: ((_ version: String, _ url: URL) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
public final class UpdateService: ObservableObject {
    @Published public private(set) var availableUpdate: AvailableUpdate?
    @Published public private(set) var releaseNotes: [ReleaseNote] = []

    public let currentVersion: String
    private let sources: [UpdateSource]
    private let log: AppLogService

    public init(
        currentVersion: String = UpdateService.bundleVersion(),
        sources: [UpdateSource],
        log: AppLogService = .shared
    ) {
        self.currentVersion = currentVersion
        self.sources = sources
        self.log = log
        loadReleaseNotesFromBundle()
        Task { @MainActor in await self.refreshReleaseNotesFromRemote() }
        wireSources()
    }

    public func start() {
        cleanupOldDMGs()
        sources.forEach { $0.start() }
    }
    public func stop()  { sources.forEach { $0.stop() } }

    /// Deletes `Entanglo-X.Y.Z.dmg` files whose version is strictly older
    /// than the running build. Keeps `~/Downloads/Entanglo/` and the dev
    /// `dist/` folder from accumulating stale installers across releases.
    public func cleanupOldDMGs() {
        var dirs: [URL] = []
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dirs.append(downloads.appendingPathComponent("Entanglo"))
        }
        let devDist = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("entanglo/Entanglo/dist")
        dirs.append(devDist)
        let outbox = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Entanglo/Updates")
        dirs.append(outbox)
        for dir in dirs where FileManager.default.fileExists(atPath: dir.path) {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.pathExtension == "dmg" {
                guard let v = LocalDistFolderSource.parseVersion(from: url.lastPathComponent) else { continue }
                if SemverCompare.compare(v, currentVersion) < 0 {
                    do {
                        try FileManager.default.removeItem(at: url)
                        log.log(.app, "Removed obsolete DMG \(url.lastPathComponent)")
                    } catch {
                        log.log(.error, "Failed to remove old DMG \(url.path): \(error)")
                    }
                }
            }
        }
    }

    /// Opens the .dmg the user wants to install. We deliberately don't
    /// try to self-replace the running bundle — the user drags onto
    /// Applications and relaunches.
    public func openInstaller() {
        guard let update = availableUpdate else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(update.url)
        #endif
    }

    /// Opens the DMG, then quits the app after a short delay so the user
    /// can see the DMG mount before the window disappears.
    public func openInstallerAndQuit() {
        openInstaller()
        #if canImport(AppKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
        #endif
    }

    /// Spawns a detached shell helper that waits for this process to die,
    /// mounts the DMG, replaces Entanglo.app at its current install path,
    /// unmounts, deletes the DMG file, and relaunches the new bundle. If
    /// anything fails it falls back to opening the DMG so the user can
    /// install manually.
    public func performAutoReplaceAndQuit() {
        guard let update = availableUpdate else { return }
        #if canImport(AppKit)
        spawnReplaceHelper(dmgPath: update.url.path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
        #endif
    }

    #if canImport(AppKit)
    private func spawnReplaceHelper(dmgPath: String) {
        guard FileManager.default.fileExists(atPath: dmgPath) else {
            log.log(.error, "Auto-install: DMG missing at \(dmgPath) — falling back to open")
            openInstaller()
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = Bundle.main.bundleURL.path
        let bundleId = Bundle.main.bundleIdentifier ?? "com.paoloasara.entanglo"
        let scriptPath = "/tmp/entanglo-update-\(pid).sh"
        let script = """
        #!/bin/bash
        PID="$1"
        DMG="$2"
        APP="$3"
        BUNDLE_ID="$4"
        LOG="/tmp/entanglo-update.log"
        exec >>"$LOG" 2>&1
        echo "[$(date)] === Entanglo auto-update PID=$PID DMG=$DMG APP=$APP BUNDLE_ID=$BUNDLE_ID ==="
        for i in $(seq 1 60); do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            sleep 0.2
        done
        sleep 0.5
        MP="/tmp/entanglo-mount-$PID"
        mkdir -p "$MP"
        if ! hdiutil attach -nobrowse -mountpoint "$MP" "$DMG"; then
            echo "[$(date)] mount failed — opening DMG for manual install"
            open "$DMG"
            exit 1
        fi
        SRC="$MP/Entanglo.app"
        if [ ! -d "$SRC" ]; then
            echo "[$(date)] Entanglo.app not found in mounted DMG"
            hdiutil detach "$MP" 2>/dev/null || true
            open "$DMG"
            exit 1
        fi
        echo "[$(date)] replacing $APP"
        rm -rf "$APP"
        if ! cp -R "$SRC" "$APP"; then
            echo "[$(date)] copy failed — opening DMG for manual install"
            hdiutil detach "$MP" 2>/dev/null || true
            open "$DMG"
            exit 1
        fi
        hdiutil detach "$MP" 2>/dev/null || true
        rmdir "$MP" 2>/dev/null || true
        rm -f "$DMG"
        sleep 0.5
        echo "[$(date)] launching $APP"
        open "$APP"
        echo "[$(date)] done"
        """
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            log.log(.error, "Auto-install: cannot write helper script: \(error)")
            openInstaller()
            return
        }
        let cmd = "nohup /bin/bash \(shQuote(scriptPath)) \(pid) \(shQuote(dmgPath)) \(shQuote(appPath)) \(shQuote(bundleId)) </dev/null >/dev/null 2>&1 &"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", cmd]
        do {
            try proc.run()
            proc.waitUntilExit()
            log.log(.app, "Auto-install: helper spawned for \(dmgPath) → \(appPath)")
        } catch {
            log.log(.error, "Auto-install: cannot spawn helper: \(error) — falling back")
            openInstaller()
        }
    }

    private func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    #endif

    // MARK: - Peer push

    private weak var coordinator: ConnectionCoordinator?
    private weak var fileTransfers: FileTransferService?

    public func wirePeerPush(coordinator: ConnectionCoordinator, fileTransfers: FileTransferService) {
        self.coordinator = coordinator
        self.fileTransfers = fileTransfers
    }

    /// Send the currently-available DMG to every peer that has a live
    /// outbound transport. Returns the list of transfer IDs that were
    /// kicked off, so the caller can monitor completion.
    @discardableResult
    public func pushUpdateToPeers() -> [String] {
        guard let update = availableUpdate else { return [] }
        guard let coordinator, let fileTransfers else { return [] }
        guard FileManager.default.fileExists(atPath: update.url.path) else {
            log.log(.error, "Push update: DMG file not found at \(update.url.path)")
            return []
        }
        var ids: [String] = []
        for peerId in coordinator.outbound.keys {
            let name = coordinator.peerDisplayNamePublic(forDeviceId: peerId)
            let tid = fileTransfers.sendFile(at: update.url, to: peerId, peerName: name)
            ids.append(tid)
        }
        log.log(.network, "Pushing update \(update.version) to \(ids.count) peer(s)")
        return ids
    }

    /// Hooks an incoming completed transfer back into the update pipeline.
    /// If the file is `Entanglo-X.Y.Z.dmg` and newer than the running
    /// build, it surfaces as availableUpdate just like a local-dist find.
    public func evaluateIncomingFile(_ url: URL) {
        guard url.pathExtension == "dmg" else { return }
        guard let version = LocalDistFolderSource.parseVersion(from: url.lastPathComponent) else { return }
        evaluate(version: version, url: url)
    }

    /// Release note for the currently running version, if any.
    public var currentVersionNote: ReleaseNote? {
        releaseNotes.first(where: { $0.version == currentVersion })
    }

    // MARK: - Internals

    private func wireSources() {
        for src in sources {
            src.onCandidate = { [weak self] version, url in
                Task { @MainActor in self?.evaluate(version: version, url: url) }
            }
        }
    }

    private func evaluate(version: String, url: URL) {
        guard SemverCompare.isNewer(version, than: currentVersion) else {
            // If we previously announced an update that has since been
            // replaced by an older file (e.g. user moved files around),
            // clear it. Otherwise the badge would lie.
            if let current = availableUpdate, current.url == url {
                availableUpdate = nil
            }
            return
        }
        let note = releaseNotes.first(where: { $0.version == version })
        let update = AvailableUpdate(version: version, url: url, note: note)
        if availableUpdate != update {
            availableUpdate = update
            log.log(.network, "Update available: \(version) at \(url.lastPathComponent)")
        }
    }

    /// Loads the bundled snapshot synchronously so the UI has something to
    /// show before the network round-trip lands.
    private func loadReleaseNotesFromBundle() {
        guard let url = Bundle.main.url(forResource: "release-notes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            log.log(.error, "release-notes.json not found in bundle")
            return
        }
        decodeAndApply(data: data, source: "bundle")
    }

    /// Re-fetches release-notes.json from the public website so the News
    /// & Updates tab is the single source of truth across the fleet — a
    /// published release immediately shows everywhere without requiring
    /// every Mac to be on the same build.
    private func refreshReleaseNotesFromRemote() async {
        guard let url = URL(string: "https://entanglo.pages.dev/updates/release-notes.json") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.log(.error, "release-notes remote HTTP \(http.statusCode)")
                return
            }
            decodeAndApply(data: data, source: "remote")
        } catch {
            log.log(.error, "release-notes remote fetch failed: \(error.localizedDescription)")
        }
    }

    private func decodeAndApply(data: Data, source: String) {
        do {
            let decoded = try JSONDecoder().decode([ReleaseNote].self, from: data)
            // Newest first for UI consumption.
            releaseNotes = decoded.sorted { SemverCompare.compare($0.version, $1.version) > 0 }
            log.log(.app, "release-notes loaded from \(source) (\(releaseNotes.count) entries)")
        } catch {
            log.log(.error, "Failed to decode release-notes (\(source)): \(error)")
        }
    }

    public nonisolated static func bundleVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

// MARK: - Local dist/ folder source

/// Watches the project's `dist/` directory for files matching
/// `Entanglo-X.Y.Z.dmg`. Used during development — the dev runs
/// `make-dmg.sh`, the running app picks up the new artifact and shows
/// the update tile. No network involved.
public final class LocalDistFolderSource: UpdateSource {
    public var onCandidate: ((String, URL) -> Void)?
    private let folder: URL
    private var dirFD: Int32 = -1
    private var watcher: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "entanglo.update.localdist", qos: .utility)
    private let log: AppLogService

    public init(folder: URL, log: AppLogService = .shared) {
        self.folder = folder
        self.log = log
    }

    public func start() {
        scanOnce()
        installWatcher()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        if dirFD >= 0 { close(dirFD); dirFD = -1 }
    }

    private func installWatcher() {
        guard watcher == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            log.log(.error, "UpdateSource: cannot open \(folder.path)")
            return
        }
        dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scanOnce() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        src.resume()
        watcher = src
    }

    private func scanOnce() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return }

        // Pick the highest-versioned Entanglo-X.Y.Z.dmg in the folder.
        var best: (String, URL)?
        for url in entries where url.pathExtension == "dmg" {
            guard let version = Self.parseVersion(from: url.lastPathComponent) else { continue }
            if let current = best {
                if SemverCompare.compare(version, current.0) > 0 {
                    best = (version, url)
                }
            } else {
                best = (version, url)
            }
        }
        if let (version, url) = best {
            onCandidate?(version, url)
        }
    }

    /// Parses `Entanglo-0.1.21.dmg` → `0.1.21`. Returns nil for anything
    /// that doesn't fit the convention (other DMGs in the folder are
    /// ignored).
    static func parseVersion(from filename: String) -> String? {
        guard filename.hasPrefix("Entanglo-"), filename.hasSuffix(".dmg") else { return nil }
        let core = filename
            .dropFirst("Entanglo-".count)
            .dropLast(".dmg".count)
        let s = String(core)
        // Loose validation: must look like N.N.N (semver, three numeric parts).
        let parts = s.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return s
    }
}

// MARK: - Remote HTTP source

/// Polls the public website manifest (entanglo.pages.dev/updates/latest.json)
/// and, when it announces a build newer than the running one, downloads
/// the DMG into the local Updates outbox and verifies the SHA256. The
/// outbox LocalDistFolderSource watcher then picks it up and the
/// existing evaluate → availableUpdate pipeline lights the update badge.
/// From then on the user clicks Install (or the file just sits there
/// silently until they do).
public final class RemoteHTTPSource: UpdateSource {
    public struct Manifest: Decodable {
        public let version: String
        public let url: URL
        public let sha256: String
        public let size: Int?
    }

    public var onCandidate: ((String, URL) -> Void)?

    private let manifestURL: URL
    private let outbox: URL
    private let currentVersion: String
    private let pollSeconds: TimeInterval
    private let log: AppLogService
    private let queue = DispatchQueue(label: "entanglo.update.remote", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var inFlight = false

    public init(
        manifestURL: URL,
        outbox: URL,
        currentVersion: String,
        pollSeconds: TimeInterval = 3600,
        log: AppLogService = .shared
    ) {
        self.manifestURL = manifestURL
        self.outbox = outbox
        self.currentVersion = currentVersion
        self.pollSeconds = pollSeconds
        self.log = log
    }

    public func start() {
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        checkNow(reason: "start")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollSeconds, repeating: pollSeconds)
        t.setEventHandler { [weak self] in self?.checkNow(reason: "poll") }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func checkNow(reason: String) {
        queue.async { [weak self] in
            guard let self, !self.inFlight else { return }
            self.inFlight = true
            Task { [weak self] in
                await self?.performCheck(reason: reason)
                self?.queue.async { self?.inFlight = false }
            }
        }
    }

    private func performCheck(reason: String) async {
        do {
            var req = URLRequest(url: manifestURL)
            req.timeoutInterval = 15
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.log(.error, "RemoteHTTP: manifest HTTP \(http.statusCode) (\(reason))")
                return
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard SemverCompare.isNewer(manifest.version, than: currentVersion) else {
                log.log(.app, "RemoteHTTP: latest \(manifest.version) not newer than \(currentVersion) (\(reason))")
                return
            }
            let dest = outbox.appendingPathComponent("Entanglo-\(manifest.version).dmg")
            if FileManager.default.fileExists(atPath: dest.path),
               verifySha256(url: dest, expected: manifest.sha256) {
                log.log(.app, "RemoteHTTP: outbox already has verified \(manifest.version)")
                onCandidate?(manifest.version, dest)
                return
            }
            log.log(.network, "RemoteHTTP: downloading \(manifest.version) from \(manifest.url.absoluteString)")
            let (tmp, dlResponse) = try await URLSession.shared.download(from: manifest.url)
            if let http = dlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.log(.error, "RemoteHTTP: DMG HTTP \(http.statusCode)")
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            guard verifySha256(url: tmp, expected: manifest.sha256) else {
                log.log(.error, "RemoteHTTP: SHA256 mismatch for \(manifest.version), discarding")
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            log.log(.app, "RemoteHTTP: staged \(manifest.version) in outbox")
            onCandidate?(manifest.version, dest)
        } catch {
            log.log(.error, "RemoteHTTP: check failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func verifySha256(url: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hex.caseInsensitiveCompare(expected) == .orderedSame
    }
}
