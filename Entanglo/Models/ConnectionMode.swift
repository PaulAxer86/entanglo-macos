//
// filename: ConnectionMode.swift
// path: Entanglo/Entanglo/Models/ConnectionMode.swift
// purpose: Possible connection states for a discovered Entanglo peer.
//

import Foundation

public enum ConnectionMode: String, Codable, Equatable, Sendable {
    case offline
    case discovered
    case connecting
    case connected
    case disconnected
    case errored

    public var displayName: String {
        switch self {
        case .offline:      return "Offline"
        case .discovered:   return "Discovered"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        case .errored:      return "Error"
        }
    }

    public var isUsable: Bool {
        self == .connected
    }
}
