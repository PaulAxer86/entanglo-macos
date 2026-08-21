//
// filename: NetworkQualityMonitor.swift
// path: Entanglo/Entanglo/Services/NetworkQualityMonitor.swift
// purpose: Combines NWPathMonitor (interface kind + IP) with the
//          coordinator's heartbeat state, and publishes a single
//          NetworkQualitySnapshot the Dashboard can render.
//

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(Network)
import Network
#endif

@MainActor
public final class NetworkQualityMonitor: ObservableObject {

    @Published public private(set) var snapshot: NetworkQualitySnapshot?

    private var heartbeatAlive: Bool = false
    private var currentKind: NetworkInterfaceKind = .unknown
    private var currentIfaceName: String = "—"
    /// Set by the coordinator from the active NWConnection's path. When
    /// non-.unknown this wins over the default-route NWPath because it
    /// reflects the interface the peer link actually uses.
    private var transportKind: NetworkInterfaceKind = .unknown
    /// Last RTT in ms reported by the coordinator (via heartbeat echo).
    private var currentLatencyMs: Double?

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "entanglo.netquality")
    #endif

    public init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            let (kind, name) = Self.classify(path)
            Task { @MainActor [weak self] in
                self?.currentKind = kind
                self?.currentIfaceName = name
                self?.recompute()
            }
        }
        monitor.start(queue: queue)
        #endif
    }

    deinit {
        #if canImport(Network)
        monitor.cancel()
        #endif
    }

    public func updateHeartbeat(alive: Bool) {
        guard alive != heartbeatAlive else { return }
        heartbeatAlive = alive
        recompute()
    }

    public func updateTransportInterface(_ kind: NetworkInterfaceKind) {
        guard kind != transportKind else { return }
        transportKind = kind
        recompute()
    }

    public func updateLatency(_ ms: Double?) {
        guard ms != currentLatencyMs else { return }
        currentLatencyMs = ms
        recompute()
    }

    private func recompute() {
        // Transport-reported kind wins when set — it reflects the actual
        // peer connection. Otherwise fall back to the system default route.
        let effectiveKind = transportKind != .unknown ? transportKind : currentKind
        let effectiveName: String = {
            switch effectiveKind {
            case .ethernet: return currentKind == .ethernet ? currentIfaceName : "Ethernet"
            case .wifi:     return currentKind == .wifi ? currentIfaceName : "Wi-Fi"
            case .loopback: return "lo0"
            case .unknown:  return currentIfaceName
            }
        }()
        let iface = NetworkInterfaceInfo(
            kind: effectiveKind,
            name: effectiveName,
            ipAddress: nil,
            latencyMs: currentLatencyMs,
            lastHeartbeat: nil
        )
        // Real RTT comes from the heartbeat echo; age stays synthetic
        // until we wire per-message timing. Loss is treated as 0 for now.
        let age: TimeInterval? = heartbeatAlive ? 0 : nil
        snapshot = NetworkQualityService.evaluate(
            iface: iface,
            latencyMs: currentLatencyMs,
            lossRate: nil,
            lastHeartbeatAge: age
        )
    }

    #if canImport(Network)
    private nonisolated static func classify(_ path: NWPath) -> (NetworkInterfaceKind, String) {
        if path.usesInterfaceType(.wiredEthernet) {
            return (.ethernet, Self.firstName(in: path, of: .wiredEthernet) ?? "Ethernet")
        }
        if path.usesInterfaceType(.wifi) {
            return (.wifi, Self.firstName(in: path, of: .wifi) ?? "Wi-Fi")
        }
        if path.usesInterfaceType(.loopback) {
            return (.loopback, "lo0")
        }
        return (.unknown, "—")
    }

    private nonisolated static func firstName(in path: NWPath, of type: NWInterface.InterfaceType) -> String? {
        path.availableInterfaces.first(where: { $0.type == type })?.name
    }
    #endif
}
