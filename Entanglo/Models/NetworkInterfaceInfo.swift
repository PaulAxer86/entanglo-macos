//
// filename: NetworkInterfaceInfo.swift
// path: Entanglo/Entanglo/Models/NetworkInterfaceInfo.swift
// purpose: Describes the active network interface used to reach a peer
//          (Wi-Fi, Ethernet, or Unknown) and a coarse latency reading.
//

import Foundation

public enum NetworkInterfaceKind: String, Codable, Sendable {
    case wifi
    case ethernet
    case loopback
    case unknown

    public var displayName: String {
        switch self {
        case .wifi:     return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .loopback: return "Loopback"
        case .unknown:  return "Unknown"
        }
    }
}

public struct NetworkInterfaceInfo: Codable, Equatable, Sendable {
    public var kind: NetworkInterfaceKind
    public var name: String
    public var ipAddress: String?
    public var latencyMs: Double?
    public var lastHeartbeat: Date?

    public init(
        kind: NetworkInterfaceKind,
        name: String,
        ipAddress: String? = nil,
        latencyMs: Double? = nil,
        lastHeartbeat: Date? = nil
    ) {
        self.kind = kind
        self.name = name
        self.ipAddress = ipAddress
        self.latencyMs = latencyMs
        self.lastHeartbeat = lastHeartbeat
    }
}
