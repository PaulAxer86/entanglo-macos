//
// filename: InputInjectionService.swift
// path: Entanglo/Entanglo/Services/InputInjectionService.swift
// purpose: Synthesizes mouse / keyboard events on the Receiver from
//          InputEventMessage payloads. Every injection passes through a
//          safety-gate that requires: pairing, permissions, heartbeat
//          alive, and emergency-stop not active.
//

import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct InjectionSafetyGate: Sendable {
    public var isPaired: Bool
    public var receiverRoleEnabled: Bool
    public var accessibilityGranted: Bool
    public var heartbeatAlive: Bool
    public var emergencyStopActive: Bool

    public init(
        isPaired: Bool = false,
        receiverRoleEnabled: Bool = false,
        accessibilityGranted: Bool = false,
        heartbeatAlive: Bool = false,
        emergencyStopActive: Bool = false
    ) {
        self.isPaired = isPaired
        self.receiverRoleEnabled = receiverRoleEnabled
        self.accessibilityGranted = accessibilityGranted
        self.heartbeatAlive = heartbeatAlive
        self.emergencyStopActive = emergencyStopActive
    }

    public var allowsInjection: Bool {
        isPaired && receiverRoleEnabled && accessibilityGranted && heartbeatAlive && !emergencyStopActive
    }
}

public final class InputInjectionService {
    public var gate = InjectionSafetyGate()

    /// Magic value stamped on every CGEvent we synthesise. The capture
    /// side inspects `.eventSourceUserData` and lets these pass through
    /// untouched, which prevents the local tap from re-forwarding events
    /// that were originally sent by a peer (echo loop → freeze).
    public static let injectedSourceUserData: Int64 = 0xE17A_E17A

    private let log: AppLogService
    public init(log: AppLogService = .shared) { self.log = log }

    #if canImport(CoreGraphics)
    private lazy var taggedSource: CGEventSource? = {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return nil }
        src.userData = Self.injectedSourceUserData
        return src
    }()
    #endif

    public func inject(_ event: InputEventMessage) {
        guard gate.allowsInjection else {
            log.log(.input, "Injection blocked by safety gate")
            return
        }
        guard event.isValid else {
            log.log(.error, "Invalid input event payload — dropping")
            return
        }
        #if canImport(CoreGraphics)
        switch event.kind {
        case .mouseMove:
            // If a button is held during this move, this is a drag and we
            // must post the corresponding *Dragged event — otherwise
            // text selection across the link doesn't work.
            let dragging = event.pressed == true && event.button != nil
            let moveType: CGEventType
            let moveButton: CGMouseButton
            if dragging, let b = event.button {
                moveType = b == 1 ? .rightMouseDragged : .leftMouseDragged
                moveButton = b == 1 ? .right : .left
            } else {
                moveType = .mouseMoved
                moveButton = .left
            }
            if let x = event.x, let y = event.y {
                postMouseEvent(moveType, button: moveButton, at: clampToMainScreen(CGPoint(x: x, y: y)), pressed: false, flags: event.modifierFlags)
            } else if event.deltaX != nil || event.deltaY != nil {
                if lastKnownLocation == .zero {
                    let b = CGDisplayBounds(CGMainDisplayID())
                    lastKnownLocation = CGPoint(x: b.midX, y: b.midY)
                }
                let dx = event.deltaX ?? 0
                let dy = event.deltaY ?? 0
                let next = CGPoint(x: lastKnownLocation.x + dx, y: lastKnownLocation.y + dy)
                postMouseEvent(moveType, button: moveButton, at: clampToMainScreen(next), pressed: false, flags: event.modifierFlags)
            }
        case .mouseDown:
            if let button = event.button {
                postMouseEvent(buttonDown(button), button: cgButton(button), at: lastKnownLocation, pressed: true, flags: event.modifierFlags, clickState: event.clickState)
            }
        case .mouseUp:
            if let button = event.button {
                postMouseEvent(buttonUp(button), button: cgButton(button), at: lastKnownLocation, pressed: false, flags: event.modifierFlags, clickState: event.clickState)
            }
        case .scroll:
            let dy = Int32(event.deltaY ?? 0)
            let dx = Int32(event.deltaX ?? 0)
            if let s = CGEvent(scrollWheelEvent2Source: taggedSource, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                s.flags = CGEventFlags(rawValue: event.modifierFlags)
                s.post(tap: .cghidEventTap)
            }
        case .keyDown:
            if let kc = event.keyCode {
                postKey(kc, down: true, flags: event.modifierFlags)
            }
        case .keyUp:
            if let kc = event.keyCode {
                postKey(kc, down: false, flags: event.modifierFlags)
            }
        case .mediaKey:
            if let mk = event.mediaKey, let pressed = event.pressed {
                postMediaKey(mk, pressed: pressed, flags: event.modifierFlags)
            }
        }
        #endif
    }

    #if canImport(CoreGraphics)
    private var lastKnownLocation: CGPoint = .zero

    private func clampToMainScreen(_ p: CGPoint) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = min(max(p.x, bounds.minX), bounds.maxX - 1)
        let y = min(max(p.y, bounds.minY), bounds.maxY - 1)
        return CGPoint(x: x, y: y)
    }

    private func cgButton(_ b: Int) -> CGMouseButton {
        switch b {
        case 0: return .left
        case 1: return .right
        default: return .center
        }
    }
    private func buttonDown(_ b: Int) -> CGEventType {
        switch b {
        case 0: return .leftMouseDown
        case 1: return .rightMouseDown
        default: return .otherMouseDown
        }
    }
    private func buttonUp(_ b: Int) -> CGEventType {
        switch b {
        case 0: return .leftMouseUp
        case 1: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    private func postMouseEvent(
        _ type: CGEventType,
        button: CGMouseButton,
        at point: CGPoint,
        pressed: Bool,
        flags: UInt64,
        clickState: Int? = nil
    ) {
        if let e = CGEvent(mouseEventSource: taggedSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) {
            e.flags = CGEventFlags(rawValue: flags)
            // Set the click-state field on every mouseDown/mouseUp so the
            // WindowServer can treat sequences as double or triple click.
            // Without this, AppKit always sees clickState=1 → no dblclick.
            switch type {
            case .leftMouseDown, .leftMouseUp,
                 .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp:
                e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickState ?? 1)))
            default:
                break
            }
            e.post(tap: .cghidEventTap)
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                lastKnownLocation = point
            default:
                break
            }
        }
    }

    private func postKey(_ keyCode: UInt16, down: Bool, flags: UInt64) {
        if Self.isModifierKeyCode(keyCode) {
            postModifier(keyCode: keyCode, flags: flags)
            log.log(.input, "Modifier injected kc=\(String(format: "0x%X", keyCode)) flags=\(String(format: "0x%X", flags))")
            return
        }
        guard let e = CGEvent(keyboardEventSource: taggedSource, virtualKey: CGKeyCode(keyCode), keyDown: down) else {
            return
        }
        e.flags = CGEventFlags(rawValue: flags)
        e.post(tap: .cghidEventTap)
        log.log(.input, "Key injected kc=\(String(format: "0x%X", keyCode)) down=\(down) flags=\(String(format: "0x%X", flags))")
    }

    /// Modifier keys (Cmd, Shift, Option, Control, Fn, CapsLock) must be
    /// posted as `.flagsChanged` events whose `flags` field reflects the
    /// CURRENT cumulative modifier state of the system after the press
    /// or release. Building from a keyboardEvent + mutating .type after
    /// the fact silently fails on macOS — the kernel keeps the event's
    /// internal class as keyDown and the modifier state never flips.
    private func postModifier(keyCode: UInt16, flags: UInt64) {
        guard let e = CGEvent(source: taggedSource) else { return }
        e.type = .flagsChanged
        e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        e.flags = CGEventFlags(rawValue: flags)
        e.post(tap: .cghidEventTap)
    }

    static func isModifierKeyCode(_ kc: UInt16) -> Bool {
        switch kc {
        case 0x36, 0x37,            // Right/Left Command
             0x38, 0x3C,            // Left/Right Shift
             0x39,                  // CapsLock
             0x3A, 0x3D,            // Left/Right Option
             0x3B, 0x3E,            // Left/Right Control
             0x3F:                  // Fn
            return true
        default:
            return false
        }
    }

    #if canImport(AppKit)
    /// Synthesise an Apple media key event (NX_SYSDEFINED, subtype 8).
    /// Tags the underlying CGEvent so the local CGEventTap recognises
    /// it as ours and doesn't echo it back to the controller.
    private func postMediaKey(_ media: MediaKey, pressed: Bool, flags: UInt64) {
        let nxCode = Int(InputCaptureService.nxKeyType(for: media))
        let state = pressed ? 0xA : 0xB
        let data1 = (nxCode << 16) | (state << 8)
        guard let ns = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ), let cg = ns.cgEvent else {
            log.log(.error, "Failed to build media key event for \(media.rawValue)")
            return
        }
        cg.setIntegerValueField(.eventSourceUserData, value: Self.injectedSourceUserData)
        cg.post(tap: .cghidEventTap)
    }
    #endif
    #endif
}
