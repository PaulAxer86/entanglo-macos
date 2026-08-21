//
// filename: InputEventMessage.swift
// path: Entanglo/Entanglo/Protocol/InputEventMessage.swift
// purpose: Normalized keyboard and mouse event payload. Carries low-level
//          codes only — never Unicode text — so logs and traffic do not
//          contain what the user typed.
//

import Foundation

public enum InputEventKind: String, Codable, Sendable {
    case mouseMove
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
    case mediaKey
}

/// Portable identifiers for the keys on a Mac keyboard's top row (F-keys
/// with the printed glyphs) and on third-party keyboards' media buttons.
/// Encoded as strings so receivers on other platforms can map to their
/// native equivalents without needing the macOS NX_KEYTYPE constants.
public enum MediaKey: String, Codable, Sendable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown
    case playPause
    case next
    case previous
    case fastForward
    case rewind
    case eject
}

public struct InputEventMessage: Codable, Equatable, Sendable {
    public let kind: InputEventKind

    // Mouse fields. (x, y) is the normalized cursor position in target
    // screen coordinates, in points.
    public let x: Double?
    public let y: Double?
    public let deltaX: Double?
    public let deltaY: Double?

    // Mouse button identifier (0 = primary, 1 = secondary, 2 = middle…).
    public let button: Int?

    // Keyboard fields. keyCode is the platform virtual key code.
    public let keyCode: UInt16?

    // Media key identifier (volume up/down, brightness, play/pause, …).
    // Only set when kind == .mediaKey.
    public let mediaKey: MediaKey?

    // Bitmask of modifier flags using CG event modifier flag values.
    public let modifierFlags: UInt64

    // True for *Down events, false for *Up events, nil otherwise.
    public let pressed: Bool?

    // CGEvent click state: 1 = single, 2 = double, 3 = triple, … Only
    // populated for mouseDown / mouseUp. Optional so older peers that
    // omit it decode cleanly; receiver falls back to 1.
    public let clickState: Int?

    public init(
        kind: InputEventKind,
        x: Double? = nil,
        y: Double? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        button: Int? = nil,
        keyCode: UInt16? = nil,
        mediaKey: MediaKey? = nil,
        modifierFlags: UInt64 = 0,
        pressed: Bool? = nil,
        clickState: Int? = nil
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.button = button
        self.keyCode = keyCode
        self.mediaKey = mediaKey
        self.modifierFlags = modifierFlags
        self.pressed = pressed
        self.clickState = clickState
    }

    private enum CodingKeys: String, CodingKey {
        case kind, x, y, deltaX, deltaY, button, keyCode, mediaKey, modifierFlags, pressed, clickState
    }

    /// Custom decoder so a `mediaKey` value introduced by a newer peer
    /// (e.g. a Windows client with extra keys) doesn't make the whole
    /// event undecodable. Unknown values fall back to nil; `isValid`
    /// then rejects the event for the .mediaKey case.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(InputEventKind.self, forKey: .kind)
        self.x = try c.decodeIfPresent(Double.self, forKey: .x)
        self.y = try c.decodeIfPresent(Double.self, forKey: .y)
        self.deltaX = try c.decodeIfPresent(Double.self, forKey: .deltaX)
        self.deltaY = try c.decodeIfPresent(Double.self, forKey: .deltaY)
        self.button = try c.decodeIfPresent(Int.self, forKey: .button)
        self.keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        self.mediaKey = (try? c.decodeIfPresent(MediaKey.self, forKey: .mediaKey)) ?? nil
        self.modifierFlags = try c.decodeIfPresent(UInt64.self, forKey: .modifierFlags) ?? 0
        self.pressed = try c.decodeIfPresent(Bool.self, forKey: .pressed)
        self.clickState = try c.decodeIfPresent(Int.self, forKey: .clickState)
    }

    /// Sanity check used by the Receiver before attempting injection.
    public var isValid: Bool {
        switch kind {
        case .mouseMove:
            return (x != nil && y != nil) || (deltaX != nil || deltaY != nil)
        case .mouseDown, .mouseUp:
            return button != nil
        case .scroll:
            return deltaX != nil || deltaY != nil
        case .keyDown, .keyUp:
            return keyCode != nil
        case .mediaKey:
            return mediaKey != nil && pressed != nil
        }
    }
}
