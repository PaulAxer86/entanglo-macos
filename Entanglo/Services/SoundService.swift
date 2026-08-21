//
// filename: SoundService.swift
// path: Entanglo/Entanglo/Services/SoundService.swift
// purpose: Plays short, gentle macOS system sounds for peer events
//          (file received, peer link lost / restored). Uses only built-in
//          /System/Library/Sounds/*.aiff so no resources ship with the app.
//          Respects a user-level enabled flag; UI binds via AppState.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class SoundService {
    /// macOS bundled system sounds — all live in /System/Library/Sounds.
    enum Cue {
        case fileReceived
        case peerLost
        case peerBack

        var soundName: String {
            switch self {
            case .fileReceived: return "Tink"   // short, soft click
            case .peerLost:     return "Funk"   // low, non-aggressive
            case .peerBack:     return "Glass"  // gentle positive chime
            }
        }
    }

    var enabled: Bool = true

    func play(_ cue: Cue) {
        guard enabled else { return }
        #if canImport(AppKit)
        NSSound(named: NSSound.Name(cue.soundName))?.play()
        #endif
    }
}
