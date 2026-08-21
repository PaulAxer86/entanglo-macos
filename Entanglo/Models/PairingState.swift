//
// filename: PairingState.swift
// path: Entanglo/Entanglo/Models/PairingState.swift
// purpose: Five-state pairing model used by PairingService and the UI.
//          Encodes the only legal transitions; everything else fails closed.
//

import Foundation

public enum PairingState: String, Codable, Equatable, Sendable {
    case notPaired
    case pairingRequested
    case pinRequired
    case trusted
    case blocked

    public var displayName: String {
        switch self {
        case .notPaired:        return "Not Paired"
        case .pairingRequested: return "Pairing Requested"
        case .pinRequired:      return "PIN Required"
        case .trusted:          return "Trusted"
        case .blocked:          return "Blocked"
        }
    }

    /// Returns true only if the transition self → next is permitted by the
    /// state machine. The PairingService relies on this; tests cover all
    /// pairs.
    public func canTransition(to next: PairingState) -> Bool {
        switch (self, next) {
        // Identity is always allowed (idempotent re-apply).
        case (let a, let b) where a == b: return true

        // From notPaired we can start a pairing or block.
        case (.notPaired, .pairingRequested),
             (.notPaired, .blocked):
            return true

        // From pairingRequested we may move to PIN entry, back to start,
        // be blocked, or jump straight to trusted (v0.1 autoaccept path:
        // the wire-side PIN ceremony lands in 0.2).
        case (.pairingRequested, .pinRequired),
             (.pairingRequested, .notPaired),
             (.pairingRequested, .blocked),
             (.pairingRequested, .trusted):
            return true

        // From pinRequired only success (→ trusted), cancel (→ notPaired)
        // or block are legal.
        case (.pinRequired, .trusted),
             (.pinRequired, .notPaired),
             (.pinRequired, .blocked):
            return true

        // Trusted devices can be revoked (→ notPaired) or blocked.
        case (.trusted, .notPaired),
             (.trusted, .blocked):
            return true

        // Blocked devices may only be reset back to notPaired manually.
        case (.blocked, .notPaired):
            return true

        default:
            return false
        }
    }
}
