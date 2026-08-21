//
// filename: NetworkQualityService.swift
// path: Entanglo/Entanglo/Services/NetworkQualityService.swift
// purpose: Pure-logic scoring of an active link — given a transport kind,
//          latency, loss approximation, and heartbeat freshness, returns
//          a "suggested mode" that the UI can show.
//

import Foundation

public enum SuggestedNetworkMode: String, Equatable, Sendable {
    case ethernetPreferred
    case wifiOK
    case unstable
    case offline

    public var displayName: String {
        switch self {
        case .ethernetPreferred: return "Ethernet Preferred"
        case .wifiOK:            return "Wi-Fi OK"
        case .unstable:          return "Unstable"
        case .offline:           return "Offline"
        }
    }
}

public struct NetworkQualitySnapshot: Equatable, Sendable {
    public let iface: NetworkInterfaceInfo
    public let latencyMs: Double?
    public let lossRate: Double?            // 0…1
    public let lastHeartbeatAge: TimeInterval?
    public let suggested: SuggestedNetworkMode

    public init(
        iface: NetworkInterfaceInfo,
        latencyMs: Double?,
        lossRate: Double?,
        lastHeartbeatAge: TimeInterval?,
        suggested: SuggestedNetworkMode
    ) {
        self.iface = iface
        self.latencyMs = latencyMs
        self.lossRate = lossRate
        self.lastHeartbeatAge = lastHeartbeatAge
        self.suggested = suggested
    }
}

public enum NetworkQualityService {
    /// Decision boundaries (tunable later from Settings).
    public static let unstableLatencyMs: Double = 120
    public static let unstableLossRate: Double = 0.05
    public static let heartbeatStaleAfter: TimeInterval = 3.0

    public static func evaluate(
        iface: NetworkInterfaceInfo,
        latencyMs: Double?,
        lossRate: Double?,
        lastHeartbeatAge: TimeInterval?
    ) -> NetworkQualitySnapshot {
        let suggested = suggestion(
            kind: iface.kind,
            latencyMs: latencyMs,
            lossRate: lossRate,
            lastHeartbeatAge: lastHeartbeatAge
        )
        return NetworkQualitySnapshot(
            iface: iface,
            latencyMs: latencyMs,
            lossRate: lossRate,
            lastHeartbeatAge: lastHeartbeatAge,
            suggested: suggested
        )
    }

    /// Pure decision function used directly by NetworkQualityTests.
    public static func suggestion(
        kind: NetworkInterfaceKind,
        latencyMs: Double?,
        lossRate: Double?,
        lastHeartbeatAge: TimeInterval?
    ) -> SuggestedNetworkMode {
        // No heartbeat ever seen — treat as offline.
        guard let age = lastHeartbeatAge else { return .offline }
        // Heartbeat is stale — link is effectively dead.
        if age > heartbeatStaleAfter { return .offline }

        // If we haven't measured RTT yet, don't punish the link — the
        // heartbeat already proves it's reachable.
        let latency = latencyMs ?? 0
        let loss = lossRate ?? 0

        if latency >= unstableLatencyMs || loss >= unstableLossRate {
            return .unstable
        }

        switch kind {
        case .ethernet, .loopback: return .ethernetPreferred
        case .wifi:                return .wifiOK
        case .unknown:             return .wifiOK
        }
    }
}
