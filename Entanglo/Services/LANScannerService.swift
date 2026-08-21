//
// filename: LANScannerService.swift
// path: Entanglo/Entanglo/Services/LANScannerService.swift
// purpose: Discover devices on the local LAN by parsing the ARP table and
//          enriching entries with Bonjour hostnames + vendor inferred from
//          the MAC OUI prefix. Persists seen MACs so a new device emits a
//          one-shot UNUserNotification.
//

import Foundation
import Combine

#if canImport(Network)
import Network
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

public struct LANDevice: Identifiable, Equatable, Sendable {
    public let id: String           // normalized MAC, lowercased, ":" separated
    public let macAddress: String
    public var ipAddress: String
    public var hostname: String?            // reverse DNS / mDNS
    public var vendor: String?              // from OUI prefix
    public var friendlyName: String?        // SSDP UPnP friendlyName
    public var modelName: String?           // SSDP UPnP modelName
    public var services: [String]           // e.g. ["AirPlay", "SMB"]
    public var openPorts: [Int]             // populated by user-triggered probe
    public var banners: [Int: String]       // port -> first-line banner
    public var firstSeen: Date
    public var lastSeen: Date

    public var displayName: String {
        friendlyName ?? hostname?.replacingOccurrences(of: ".local.", with: "")
            .replacingOccurrences(of: ".local", with: "")
            ?? modelName ?? vendor ?? macAddress
    }

    public var secondary: String? {
        var pieces: [String] = []
        if let m = modelName, m != friendlyName { pieces.append(m) }
        if let v = vendor, !pieces.contains(where: { $0.localizedCaseInsensitiveContains(v) }) {
            pieces.append(v)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " • ")
    }
}

@MainActor
public final class LANScannerService: ObservableObject {
    @Published public private(set) var devices: [LANDevice] = []
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var lastScanAt: Date?

    private let log: AppLogService
    private let ouiLookup: OUIVendorLookup
    private let seenStore: SeenDeviceStore

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 30

    #if canImport(Network)
    private var bonjourBrowsers: [NWBrowser] = []
    private var bonjourHostnames: [String: String] = [:]   // ipv4 -> hostname
    private var bonjourServices: [String: Set<String>] = [:] // ipv4 -> service labels
    #endif

    private var ssdpFriendly: [String: String] = [:]       // ipv4 -> SSDP friendlyName
    private var ssdpModel: [String: String] = [:]          // ipv4 -> SSDP modelName
    private let ssdp = SSDPDiscoverer()
    private let portProbe = PortProbeService()

    public init(
        log: AppLogService = .shared,
        ouiLookup: OUIVendorLookup = OUIVendorLookup(),
        seenStore: SeenDeviceStore = SeenDeviceStore()
    ) {
        self.log = log
        self.ouiLookup = ouiLookup
        self.seenStore = seenStore
    }

    public func start() {
        guard refreshTimer == nil else { return }
        log.log(.network, "LAN scanner started")
        startBonjourBrowsing()
        startSSDP()
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopBonjourBrowsing()
        ssdp.stop()
        log.log(.network, "LAN scanner stopped")
    }

    private func startSSDP() {
        ssdp.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if let n = result.friendlyName { self.ssdpFriendly[result.ip] = n }
                if let m = result.modelName    { self.ssdpModel[result.ip]    = m }
                if var idx = self.devices.firstIndex(where: { $0.ipAddress == result.ip }) {
                    if self.devices[idx].friendlyName == nil { self.devices[idx].friendlyName = result.friendlyName }
                    if self.devices[idx].modelName == nil    { self.devices[idx].modelName = result.modelName }
                    _ = idx
                }
            }
        }
        ssdp.start()
    }

    public func probe(deviceId: String) async {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        let ip = devices[idx].ipAddress
        log.log(.network, "Probing \(ip) (\(deviceId))")
        let result = await portProbe.probe(host: ip)
        if let i = devices.firstIndex(where: { $0.id == deviceId }) {
            devices[i].openPorts = result.openPorts
            devices[i].banners = result.banners
            if devices[i].hostname == nil, let host = result.reverseDNS {
                devices[i].hostname = host
            }
            log.log(.network, "Probe \(ip): \(result.openPorts.count) open ports")
        }
    }

    public func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) { [weak self] in
            let entries = ArpTableReader.read()
            await self?.merge(arpEntries: entries)
        }
    }

    private func merge(arpEntries: [ArpTableReader.Entry]) {
        let now = Date()
        var byMac: [String: LANDevice] = [:]
        for d in devices { byMac[d.id] = d }

        var newMacs: [LANDevice] = []
        for entry in arpEntries {
            let id = entry.mac
            let hostname = bonjourHostnames[entry.ip]
            let services = bonjourServices[entry.ip].map { Array($0).sorted() } ?? []
            if var existing = byMac[id] {
                existing.ipAddress = entry.ip
                existing.lastSeen = now
                if existing.hostname == nil { existing.hostname = hostname }
                if existing.friendlyName == nil { existing.friendlyName = ssdpFriendly[entry.ip] }
                if existing.modelName == nil { existing.modelName = ssdpModel[entry.ip] }
                if !services.isEmpty { existing.services = services }
                byMac[id] = existing
            } else {
                let vendor = ouiLookup.vendor(for: entry.mac)
                let device = LANDevice(
                    id: id,
                    macAddress: entry.mac,
                    ipAddress: entry.ip,
                    hostname: hostname,
                    vendor: vendor,
                    friendlyName: ssdpFriendly[entry.ip],
                    modelName: ssdpModel[entry.ip],
                    services: services,
                    openPorts: [],
                    banners: [:],
                    firstSeen: now,
                    lastSeen: now
                )
                byMac[id] = device
                if !seenStore.isKnown(mac: id) {
                    newMacs.append(device)
                    seenStore.markKnown(mac: id)
                }
            }
        }

        let merged = byMac.values.sorted { lhs, rhs in
            (lhs.hostname ?? lhs.ipAddress) < (rhs.hostname ?? rhs.ipAddress)
        }
        devices = merged
        lastScanAt = now
        isScanning = false

        for d in newMacs { postNewDeviceNotification(for: d) }
        if !newMacs.isEmpty {
            log.log(.network, "LAN scan: \(merged.count) devices (+\(newMacs.count) new)")
        }
    }

    private func postNewDeviceNotification(for device: LANDevice) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = "New device on your network"
        content.body = "\(device.displayName) — \(device.ipAddress)"
        content.sound = nil
        let request = UNNotificationRequest(identifier: "lan.new.\(device.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        #endif
    }

    #if canImport(Network)
    private func startBonjourBrowsing() {
        let types = ["_services._dns-sd._udp", "_airplay._tcp", "_raop._tcp", "_smb._tcp",
                     "_ipp._tcp", "_http._tcp", "_ssh._tcp", "_workstation._tcp"]
        for type in types {
            let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.handleBonjour(results: results, type: type) }
            }
            browser.start(queue: .global(qos: .utility))
            bonjourBrowsers.append(browser)
        }
    }

    private func stopBonjourBrowsing() {
        bonjourBrowsers.forEach { $0.cancel() }
        bonjourBrowsers.removeAll()
    }

    private func handleBonjour(results: Set<NWBrowser.Result>, type: String) {
        let label = serviceLabel(for: type)
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            let host = name.replacingOccurrences(of: "_", with: " ")
            // Resolve to IP via NWConnection probe; cheap enough.
            let conn = NWConnection(to: r.endpoint, using: .tcp)
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready, .preparing:
                    if let ipv4 = conn.currentPath?.remoteEndpoint.flatMap(Self.ipv4(from:)) {
                        Task { @MainActor in
                            self?.bonjourHostnames[ipv4] = host
                            var set = self?.bonjourServices[ipv4] ?? []
                            set.insert(label)
                            self?.bonjourServices[ipv4] = set
                        }
                        conn.cancel()
                    }
                case .failed, .cancelled:
                    conn.cancel()
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    nonisolated private static func ipv4(from endpoint: NWEndpoint) -> String? {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return String(describing: addr)
            default: return nil
            }
        }
        return nil
    }

    private func serviceLabel(for type: String) -> String {
        switch type {
        case "_airplay._tcp":     return "AirPlay"
        case "_raop._tcp":        return "AirPlay Audio"
        case "_smb._tcp":         return "SMB"
        case "_ipp._tcp":         return "Printer"
        case "_http._tcp":        return "HTTP"
        case "_ssh._tcp":         return "SSH"
        case "_workstation._tcp": return "Workstation"
        default:                  return type
        }
    }
    #else
    private func startBonjourBrowsing() {}
    private func stopBonjourBrowsing() {}
    #endif
}

enum ArpTableReader {
    struct Entry { let ip: String; let mac: String }

    static func read() -> [Entry] {
        let output = runArp()
        return parse(output)
    }

    private static func runArp() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Lines look like: "? (192.168.1.10) at a4:83:e7:12:34:56 on en0 ifscope [ethernet]"
    static func parse(_ raw: String) -> [Entry] {
        var out: [Entry] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 4 else { continue }
            let ipRaw = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let mac = String(parts[3]).lowercased()
            guard isValidMAC(mac), isValidIPv4(ipRaw) else { continue }
            out.append(Entry(ip: ipRaw, mac: normalize(mac: mac)))
        }
        return out
    }

    private static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }

    private static func isValidMAC(_ s: String) -> Bool {
        let parts = s.split(separator: ":")
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { $0.count >= 1 && $0.count <= 2 && Int($0, radix: 16) != nil }
    }

    private static func normalize(mac: String) -> String {
        mac.split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
    }
}

public final class SeenDeviceStore {
    private let defaults: UserDefaults
    private let key = "EntangloSeenLANDevices"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isKnown(mac: String) -> Bool {
        let set = (defaults.array(forKey: key) as? [String]) ?? []
        return set.contains(mac)
    }

    public func markKnown(mac: String) {
        var set = (defaults.array(forKey: key) as? [String]) ?? []
        if !set.contains(mac) {
            set.append(mac)
            defaults.set(set, forKey: key)
        }
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }
}
