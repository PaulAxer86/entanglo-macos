//
// filename: EntangloRole.swift
// path: Entanglo/Entanglo/Models/EntangloRole.swift
// purpose: Enumerates the roles a single Entanglo instance can hold.
//          A device may carry several roles at once (e.g., Controller
//          and AI Worker on the same Mac).
//

import Foundation

public enum EntangloRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case controller
    case receiver

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .controller: return "Controller"
        case .receiver:   return "Receiver"
        }
    }

    public var shortLabel: String {
        switch self {
        case .controller: return "Ctrl"
        case .receiver:   return "Recv"
        }
    }
}
