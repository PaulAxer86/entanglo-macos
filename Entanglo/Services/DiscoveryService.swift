//
// filename: DiscoveryService.swift
// path: Entanglo/Entanglo/Services/DiscoveryService.swift
// purpose: Bonjour service advertise + browse for `_entanglo._tcp`.
//          Uses Network.framework (NWListener / NWBrowser).
//

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(Network)
import Network
#endif

public final class DiscoveryService: ObservableObject {
    public static let serviceType = "_entanglo._tcp"

    @Published public private(set) var discoveredDevices: [Device] = []
    @Published public private(set) var isAdvertising = false
    @Published public private(set) var isBrowsing = false

    /// Called by the listener whenever a peer dials in. The coordinator
    /// wraps the connection in a NetworkTransport.
    #if canImport(Network)
    public var onIncomingConnection: ((NWConnection) -> Void)?
    #endif

    private let log: AppLogService

    #if canImport(Network)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]    // deviceId/name -> endpoint
    /// Every interface *type* on which the peer's Bonjour advert was seen
    /// (typically both `.wiredEthernet` and `.wifi` when both machines
    /// share a subnet via cable and Wi-Fi at the same time). Used by the
    /// coordinator to pin dial-outs to Ethernet when it's available.
    private var interfaceTypes: [String: Set<NWInterface.InterfaceType>] = [:]
    #endif

    public init(log: AppLogService = .shared) {
        self.log = log
    }

    #if canImport(Network)
    public func endpoint(forDeviceId id: String) -> NWEndpoint? {
        endpoints[id]
    }

    public func interfaceTypes(forDeviceId id: String) -> Set<NWInterface.InterfaceType> {
        interfaceTypes[id] ?? []
    }
    #endif

    public func startAdvertising(name: String, port: UInt16) {
        #if canImport(Network)
        // pollPermissions retries startDiscovery whenever isAdvertising flips
        // false; without this guard a fresh NWListener stacks on top of the
        // previous one, leaving two sockets and two Bonjour registrations
        // (the second registers under " (2)" because the first never went
        // away), which then confuses Windows' name-based session dedup.
        self.listener?.cancel()
        self.listener = nil
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            listener.service = NWListener.Service(name: name, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                self?.log.log(.network, "Listener state: \(state)")
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.log.log(.network, "Incoming connection from \(connection.endpoint)")
                if let cb = self?.onIncomingConnection {
                    cb(connection)
                } else {
                    self?.log.log(.error, "No incoming handler installed — dropping")
                    connection.cancel()
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.isAdvertising = true
            log.log(.network, "Advertising as \(name) on port \(port)")
        } catch {
            log.log(.error, "Failed to start listener: \(error)")
        }
        #endif
    }

    public func stopAdvertising() {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        isAdvertising = false
        log.log(.network, "Stopped advertising")
        #endif
    }

    public func startBrowsing() {
        #if canImport(Network)
        self.browser?.cancel()
        self.browser = nil
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            self?.log.log(.network, "Browser state: \(state)")
        }
        browser.start(queue: .main)
        self.browser = browser
        self.isBrowsing = true
        log.log(.network, "Started browsing for \(Self.serviceType)")
        #endif
    }

    public func stopBrowsing() {
        #if canImport(Network)
        browser?.cancel()
        browser = nil
        isBrowsing = false
        log.log(.network, "Stopped browsing")
        #endif
    }

    #if canImport(Network)
    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var devices: [Device] = []
        var freshEndpoints: [String: NWEndpoint] = [:]
        var freshTypes: [String: Set<NWInterface.InterfaceType>] = [:]
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                let iface = Self.interfaceFor(result: result)
                // Drop self-discovery via lo0 — it surfaces the local
                // Entanglo instance under whatever LocalHostName Bonjour
                // currently advertises (often a stale "(2)" suffix from a
                // prior name collision) and pollutes the device list.
                if iface.kind == .loopback { continue }
                let device = Device(
                    id: name,
                    name: name,
                    iface: iface,
                    lastSeen: Date()
                )
                devices.append(device)
                freshEndpoints[name] = result.endpoint
                freshTypes[name] = Set(result.interfaces.map { $0.type })
            }
        }
        self.discoveredDevices = devices
        self.endpoints = freshEndpoints
        self.interfaceTypes = freshTypes
    }

    /// Return the "best" interface the peer is reachable on. Ethernet /
    /// Thunderbolt bridges beat Wi-Fi even when both are advertised —
    /// the coordinator uses this to display the effective transport and
    /// to pin the dial-out to the wired path.
    private static func interfaceFor(result: NWBrowser.Result) -> NetworkInterfaceInfo {
        var pick: (kind: NetworkInterfaceKind, name: String)?
        for iface in result.interfaces {
            switch iface.type {
            case .wiredEthernet:
                return NetworkInterfaceInfo(kind: .ethernet, name: iface.name)
            case .wifi where pick == nil:
                pick = (.wifi, iface.name)
            case .loopback where pick == nil:
                pick = (.loopback, iface.name)
            default: continue
            }
        }
        if let pick { return NetworkInterfaceInfo(kind: pick.kind, name: pick.name) }
        return NetworkInterfaceInfo(kind: .unknown, name: "unknown")
    }
    #endif
}
