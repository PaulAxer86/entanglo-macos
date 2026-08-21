//
// filename: InputCaptureService.swift
// path: Entanglo/Entanglo/Services/InputCaptureService.swift
// purpose: Captures local keyboard and mouse events on the Controller
//          via CGEventTap, normalizes them into InputEventMessage, and
//          contains the *pure* edge-switching logic that decides when
//          to hand control to a remote target. Keystroke content is
//          never logged.
//

import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Pure-logic helper used by the controller loop AND by the
/// EdgeSwitchingTests. No CGEvent, no AppKit — just maths.
public struct EdgeSwitchConfig: Codable, Equatable, Sendable {
    public var leftEdgeTargetId: String?
    public var rightEdgeTargetId: String?
    public var topEdgeTargetId: String?
    public var bottomEdgeTargetId: String?
    public var edgeThicknessPoints: CGFloat
    public var enabled: Bool

    public init(
        leftEdgeTargetId: String? = nil,
        rightEdgeTargetId: String? = nil,
        topEdgeTargetId: String? = nil,
        bottomEdgeTargetId: String? = nil,
        edgeThicknessPoints: CGFloat = 2,
        enabled: Bool = true
    ) {
        self.leftEdgeTargetId = leftEdgeTargetId
        self.rightEdgeTargetId = rightEdgeTargetId
        self.topEdgeTargetId = topEdgeTargetId
        self.bottomEdgeTargetId = bottomEdgeTargetId
        self.edgeThicknessPoints = edgeThicknessPoints
        self.enabled = enabled
    }
}

public enum EdgeSwitchDecision: Equatable, Sendable {
    case stayLocal
    case switchTo(deviceId: String)
}

public enum EdgeSwitchingLogic {
    /// Given the current mouse position (in screen points), the local
    /// screen bounds, the configuration, and whether control is already
    /// remote, returns whether to remain local or switch to a particular
    /// remote device.
    public static func decide(
        mouseX: CGFloat,
        mouseY: CGFloat,
        screenMinX: CGFloat,
        screenMaxX: CGFloat,
        screenMinY: CGFloat,
        screenMaxY: CGFloat,
        currentlyRemote: Bool,
        config: EdgeSwitchConfig
    ) -> EdgeSwitchDecision {
        guard config.enabled, !currentlyRemote else { return .stayLocal }

        if mouseX <= screenMinX + config.edgeThicknessPoints,
           let left = config.leftEdgeTargetId {
            return .switchTo(deviceId: left)
        }

        if mouseX >= screenMaxX - config.edgeThicknessPoints,
           let right = config.rightEdgeTargetId {
            return .switchTo(deviceId: right)
        }

        if mouseY <= screenMinY + config.edgeThicknessPoints,
           let top = config.topEdgeTargetId {
            return .switchTo(deviceId: top)
        }

        if mouseY >= screenMaxY - config.edgeThicknessPoints,
           let bottom = config.bottomEdgeTargetId {
            return .switchTo(deviceId: bottom)
        }

        return .stayLocal
    }
}

/// Pure-logic helper for the triple-Escape emergency stop.
public struct EmergencyStopState: Equatable, Sendable {
    public var pressTimes: [Date] = []
    public let requiredPresses: Int
    public let windowSeconds: TimeInterval

    public init(requiredPresses: Int = 3, windowSeconds: TimeInterval = 0.6) {
        self.requiredPresses = requiredPresses
        self.windowSeconds = windowSeconds
    }

    /// Records a fresh Escape press. Returns true if the press completed
    /// the triple-tap sequence.
    public mutating func record(at moment: Date = Date()) -> Bool {
        pressTimes.append(moment)
        // Drop any presses older than the window.
        pressTimes = pressTimes.filter { moment.timeIntervalSince($0) <= windowSeconds }
        if pressTimes.count >= requiredPresses {
            pressTimes.removeAll()
            return true
        }
        return false
    }
}

public protocol InputCaptureDelegate: AnyObject {
    func inputCapture(_ service: InputCaptureService, didProduce event: InputEventMessage)
    func inputCapture(_ service: InputCaptureService, requestsSwitchTo deviceId: String)
    func inputCaptureRequestsLocalReturn(_ service: InputCaptureService)
}

public final class InputCaptureService {
    public weak var delegate: InputCaptureDelegate?
    public var edgeConfig: EdgeSwitchConfig = .init()
    public var currentTargetDeviceId: String? {
        didSet {
            let wasRemote = oldValue != nil
            let nowRemote = currentTargetDeviceId != nil
            if wasRemote != nowRemote { applyRemoteCursorLock(nowRemote) }
            if !nowRemote {
                virtualCursor = nil
                parkPosition = nil
                remoteEntryEdge = nil
            }
        }
    }

    /// Side of the remote screen the cursor entered through. The same
    /// edge is the only valid exit back to local — the opposite edge
    /// becomes an impassable wall so the cursor doesn't tunnel out the
    /// far side and immediately re-trigger an edge switch (the "loop"
    /// the user observed on a two-Mac layout).
    private enum RemoteEntryEdge { case left, right, top, bottom }
    private var remoteEntryEdge: RemoteEntryEdge?

    /// Notional bounds we assume for the remote screen — used both as
    /// the coordinate space sent to the receiver and as the exit-edge
    /// trigger. iMac 2011 27" panels are 2560×1440. v0.2 will replace
    /// this with the actual size advertised in a Hello message.
    public static let remoteScreenSize = CGSize(width: 2560, height: 1440)

    /// Cursor position we virtually maintain on the receiver's screen
    /// while in remote mode. Updated from raw mouseEventDeltaX/Y and
    /// shipped as absolute (x, y) in every InputEventMessage.
    private var virtualCursor: CGPoint?

    /// Local park position — where we keep the OS cursor frozen while
    /// we are in remote mode. CGAssociateMouseAndMouseCursorPosition(0)
    /// alone is not enough on Sequoia: the WindowServer occasionally
    /// still moves the cursor, so we also warp it back on every event.
    private var parkPosition: CGPoint?

    /// Throttle for mouseMove sends. 60+ FPS of JSON-encoded events
    /// over LAN can starve the heartbeat timer on the same runloop;
    /// 8 ms (~120 Hz) is more than enough for smooth cursor motion.
    private var lastMouseMoveSentAt: CFTimeInterval = 0
    private static let mouseMoveMinInterval: CFTimeInterval = 0.008

    /// Throttle for CGWarpMouseCursorPosition. Calling warp on every
    /// event races the WindowServer and on Sequoia has been observed
    /// to cause input freezes. ~60 Hz is plenty to keep the cursor
    /// pinned at the park position.
    private var lastWarpAt: CFTimeInterval = 0
    private static let warpMinInterval: CFTimeInterval = 0.016

    /// Sender-side mouse-button state. We need this because the
    /// receiver has to distinguish hover-moves (.mouseMoved) from
    /// drag-moves (.leftMouseDragged/.rightMouseDragged); without it
    /// drag-to-select is impossible across the link.
    private var leftButtonDown = false
    private var rightButtonDown = false

    private let log: AppLogService
    private var emergencyStop = EmergencyStopState()

    #if canImport(CoreGraphics)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    #endif

    public init(log: AppLogService = .shared) {
        self.log = log
    }

    public func start() {
        #if canImport(CoreGraphics)
        // Guard against double-start. The previous behaviour leaked a
        // second tap which both received every event AND survived
        // stop(): a stale tap on the runloop is one of the suspected
        // causes of system input freezes.
        if tap != nil {
            log.log(.input, "Input capture already running — skipping start()")
            return
        }

        // Build the event mask in steps; Swift's type checker chokes on
        // a single 10-way `|` expression of CGEventMask literals.
        var mask: CGEventMask = 0
        mask |= (1 << CGEventType.mouseMoved.rawValue)
        mask |= (1 << CGEventType.leftMouseDown.rawValue)
        mask |= (1 << CGEventType.leftMouseUp.rawValue)
        mask |= (1 << CGEventType.leftMouseDragged.rawValue)
        mask |= (1 << CGEventType.rightMouseDown.rawValue)
        mask |= (1 << CGEventType.rightMouseUp.rawValue)
        mask |= (1 << CGEventType.rightMouseDragged.rawValue)
        mask |= (1 << CGEventType.scrollWheel.rawValue)
        mask |= (1 << CGEventType.keyDown.rawValue)
        mask |= (1 << CGEventType.keyUp.rawValue)
        // Capture modifier press/release so Cmd+C, Cmd+V, Shift-click,
        // Option-drag etc. actually fire on the receiver. Without this,
        // we only ship the modifier as a flag on the next key/mouse
        // event, which is enough for plain typing but NOT enough for
        // shortcuts — many apps require the modifier to be physically
        // held when the action key is dispatched.
        mask |= (1 << CGEventType.flagsChanged.rawValue)
        // CGEventType.systemDefined (raw value 14) carries Apple media
        // keys (volume up/down, mute, brightness, play/pause, …). The
        // enum doesn't expose a case for it, so we use the raw value.
        mask |= (1 << 14)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                let me = Unmanaged<InputCaptureService>.fromOpaque(ctx!).takeUnretainedValue()
                // Re-enable the tap if the kernel disabled it because a
                // previous callback took too long — without this, all
                // input on the Mac silently stops after the first miss.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handle(type: type, event: event)
            },
            userInfo: opaqueSelf
        ) else {
            log.log(.error, "Failed to create CGEventTap — Accessibility/Input Monitoring required")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Always attach to the *main* runloop, not whatever runloop
        // happened to be current when start() was called. The previous
        // behaviour would silently break if start() was invoked from
        // any non-main context.
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = src
        log.log(.input, "Input capture started")
        #endif
    }

    public func stop() {
        #if canImport(CoreGraphics)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        applyRemoteCursorLock(false)
        log.log(.input, "Input capture stopped")
        #endif
    }

    #if canImport(CoreGraphics)
    /// While we are forwarding to a remote target we want the local
    /// cursor frozen — otherwise the WindowServer keeps moving it
    /// underneath us (because the session-level tap sees mouseMoved
    /// only after the cursor has already been rendered). Decoupling
    /// mouse-from-cursor via the public CG API keeps the cursor parked
    /// at the edge while we keep reading raw deltas.
    private func applyRemoteCursorLock(_ locked: Bool) {
        if locked {
            CGAssociateMouseAndMouseCursorPosition(0)
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
    #endif

    #if canImport(CoreGraphics)
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Ignore events that *we* injected (via InputInjectionService). They
        // carry our magic userData tag. Without this filter, two Macs sharing
        // both ways echo each other's events into an infinite loop and the
        // CGEventTap eventually gets disabled by the kernel.
        if event.getIntegerValueField(.eventSourceUserData) == InputInjectionService.injectedSourceUserData {
            return Unmanaged.passUnretained(event)
        }

        // Diagnostic: trace every keyboard-class event reaching the tap.
        // Helps debug "Cmd+letter dropped" issues — we can confirm whether
        // the letter ever arrives at our tap when a modifier is held.
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let f = event.flags.rawValue
            log.log(.input, "Tap saw type=\(type.rawValue) kc=\(String(format: "0x%X", kc)) flags=\(String(format: "0x%X", f))")
        }

        // Emergency stop: three Escapes in a 600 ms window.
        if type == .keyDown {
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if kc == 0x35 /* kVK_Escape */ {
                if emergencyStop.record() {
                    log.log(.input, "Emergency stop activated")
                    delegate?.inputCaptureRequestsLocalReturn(self)
                }
            }
        }

        // Track button state so we can tell the receiver "this move is a
        // drag, not a hover" — required for click-and-drag text selection.
        switch type {
        case .leftMouseDown:  leftButtonDown = true
        case .leftMouseUp:    leftButtonDown = false
        case .rightMouseDown: rightButtonDown = true
        case .rightMouseUp:   rightButtonDown = false
        default: break
        }

        // Edge switching: only mouseMove triggers this.
        if type == .mouseMoved,
           let screen = CGEvent.currentScreenBounds() {
            let loc = event.location
            let decision = EdgeSwitchingLogic.decide(
                mouseX: loc.x,
                mouseY: loc.y,
                screenMinX: screen.minX,
                screenMaxX: screen.maxX,
                screenMinY: screen.minY,
                screenMaxY: screen.maxY,
                currentlyRemote: currentTargetDeviceId != nil,
                config: edgeConfig
            )
            if case .switchTo(let id) = decision {
                let thickness = edgeConfig.edgeThicknessPoints
                let fromLeft   = loc.x <= screen.minX + thickness
                let fromRight  = loc.x >= screen.maxX - thickness
                let fromTop    = loc.y <= screen.minY + thickness
                let fromBottom = loc.y >= screen.maxY - thickness
                // Seed the virtual cursor on the receiver: come in from
                // the opposite edge of the one we crossed locally. The
                // entry edge is the only valid exit back to local.
                // L/R take priority over T/B (matches decide()'s order).
                if fromLeft {
                    virtualCursor = CGPoint(
                        x: Self.remoteScreenSize.width - 1,
                        y: Self.remoteScreenSize.height / 2
                    )
                    remoteEntryEdge = .right
                    parkPosition = CGPoint(x: screen.minX + 4, y: loc.y)
                } else if fromRight {
                    virtualCursor = CGPoint(
                        x: 0,
                        y: Self.remoteScreenSize.height / 2
                    )
                    remoteEntryEdge = .left
                    parkPosition = CGPoint(x: screen.maxX - 4, y: loc.y)
                } else if fromTop {
                    virtualCursor = CGPoint(
                        x: Self.remoteScreenSize.width / 2,
                        y: Self.remoteScreenSize.height - 1
                    )
                    remoteEntryEdge = .bottom
                    parkPosition = CGPoint(x: loc.x, y: screen.minY + 4)
                } else if fromBottom {
                    virtualCursor = CGPoint(
                        x: Self.remoteScreenSize.width / 2,
                        y: 0
                    )
                    remoteEntryEdge = .top
                    parkPosition = CGPoint(x: loc.x, y: screen.maxY - 4)
                }
                delegate?.inputCapture(self, requestsSwitchTo: id)
            }
        }

        // Forward as a normalized event when remote control is active.
        if currentTargetDeviceId != nil {
            // Park the local cursor periodically: belt-and-suspenders
            // with CGAssociateMouseAndMouseCursorPosition(0). Calling
            // warp on every event has been observed to race the
            // WindowServer and lock up input on macOS Sequoia, so we
            // throttle to ~60 Hz and only warp on mouse-related events.
            if let park = parkPosition,
               type == .mouseMoved
                || type == .leftMouseDragged || type == .rightMouseDragged
                || type == .leftMouseDown || type == .leftMouseUp
                || type == .rightMouseDown || type == .rightMouseUp
                || type == .scrollWheel {
                let now = CACurrentMediaTime()
                if now - lastWarpAt >= Self.warpMinInterval {
                    CGWarpMouseCursorPosition(park)
                    lastWarpAt = now
                }
            }

            // Special-case mouseMove + drag: maintain the virtual cursor
            // and check whether the user just dragged off the receiver
            // edge (→ hand control back to local). Drags must forward
            // too, otherwise text selection on the remote Mac is broken.
            if (type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged),
               var vc = virtualCursor {
                let dx = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
                vc.x += dx
                vc.y += dy
                // Only the entry edge can exit. The opposite edge is an
                // impassable wall; otherwise the cursor would tunnel out
                // the far side and immediately re-enter from the local
                // edge, looping infinitely between the two Macs.
                let buttonsHeld = leftButtonDown || rightButtonDown
                if !buttonsHeld {
                    switch remoteEntryEdge {
                    case .right where vc.x >= Self.remoteScreenSize.width:
                        log.log(.input, "Virtual cursor exited via entry edge (right) — returning to local")
                        delegate?.inputCaptureRequestsLocalReturn(self)
                        return nil
                    case .left where vc.x < 0:
                        log.log(.input, "Virtual cursor exited via entry edge (left) — returning to local")
                        delegate?.inputCaptureRequestsLocalReturn(self)
                        return nil
                    case .bottom where vc.y >= Self.remoteScreenSize.height:
                        log.log(.input, "Virtual cursor exited via entry edge (bottom) — returning to local")
                        delegate?.inputCaptureRequestsLocalReturn(self)
                        return nil
                    case .top where vc.y < 0:
                        log.log(.input, "Virtual cursor exited via entry edge (top) — returning to local")
                        delegate?.inputCaptureRequestsLocalReturn(self)
                        return nil
                    default:
                        break
                    }
                }
                vc.x = min(max(vc.x, 0), Self.remoteScreenSize.width - 1)
                vc.y = min(max(vc.y, 0), Self.remoteScreenSize.height - 1)
                virtualCursor = vc

                // Throttle: don't send more than ~120 mouseMove/sec.
                let now = CACurrentMediaTime()
                if now - lastMouseMoveSentAt < Self.mouseMoveMinInterval {
                    return nil
                }
                lastMouseMoveSentAt = now

                let activeButton: Int? = leftButtonDown ? 0 : (rightButtonDown ? 1 : nil)
                let msg = InputEventMessage(
                    kind: .mouseMove,
                    x: Double(vc.x),
                    y: Double(vc.y),
                    button: activeButton,
                    modifierFlags: event.flags.rawValue,
                    pressed: activeButton != nil ? true : nil
                )
                delegate?.inputCapture(self, didProduce: msg)
                return nil
            }
            if let msg = normalize(type: type, event: event) {
                let label: String
                switch msg.kind {
                case .keyDown, .keyUp:
                    let kc = msg.keyCode.map { String(format: "0x%X", $0) } ?? "?"
                    label = "Keyboard event sent kc=\(kc) \(msg.kind == .keyDown ? "down" : "up")"
                case .mediaKey:
                    label = "Media key sent \(msg.mediaKey?.rawValue ?? "?") pressed=\(msg.pressed ?? false)"
                default:
                    label = "Pointer event sent"
                }
                log.log(.input, label)
                delegate?.inputCapture(self, didProduce: msg)
            }
            // flagsChanged must NOT be swallowed locally — otherwise the
            // local kernel never registers the modifier as held, and the
            // *next* keyDown (e.g. C in Cmd+C) is dispatched without the
            // modifier flag and shows up at the frontmost app as raw C
            // → system beep. Letting it through keeps the local kernel
            // modifier state in sync; we still forward it to the remote.
            if type == .flagsChanged {
                return Unmanaged.passUnretained(event)
            }
            // Swallow the event locally while remote.
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func normalize(type: CGEventType, event: CGEvent) -> InputEventMessage? {
        let mods = event.flags.rawValue
        switch type {
        case .mouseMoved:
            // We always send deltas while in remote mode: with the local
            // cursor decoupled the `location` field stays frozen at the
            // park position, but `mouseEventDeltaX/Y` still report the
            // physical motion.
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            return InputEventMessage(kind: .mouseMove, deltaX: dx, deltaY: dy, modifierFlags: mods)
        case .leftMouseDown:
            let cs = Int(event.getIntegerValueField(.mouseEventClickState))
            return InputEventMessage(kind: .mouseDown, button: 0, modifierFlags: mods, pressed: true, clickState: cs)
        case .leftMouseUp:
            let cs = Int(event.getIntegerValueField(.mouseEventClickState))
            return InputEventMessage(kind: .mouseUp, button: 0, modifierFlags: mods, pressed: false, clickState: cs)
        case .rightMouseDown:
            let cs = Int(event.getIntegerValueField(.mouseEventClickState))
            return InputEventMessage(kind: .mouseDown, button: 1, modifierFlags: mods, pressed: true, clickState: cs)
        case .rightMouseUp:
            let cs = Int(event.getIntegerValueField(.mouseEventClickState))
            return InputEventMessage(kind: .mouseUp, button: 1, modifierFlags: mods, pressed: false, clickState: cs)
        case .scrollWheel:
            let dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            return InputEventMessage(kind: .scroll, deltaX: dx, deltaY: dy, modifierFlags: mods)
        case .keyDown:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return InputEventMessage(kind: .keyDown, keyCode: kc, modifierFlags: mods, pressed: true)
        case .keyUp:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return InputEventMessage(kind: .keyUp, keyCode: kc, modifierFlags: mods, pressed: false)
        case .flagsChanged:
            // The toggled modifier's keyCode comes through the same
            // field as for regular keys. Whether it's now down or up
            // is derived from whether its flag bit is still set in
            // the post-event flag word.
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let pressed = Self.modifierIsPressed(keyCode: kc, flags: mods)
            return InputEventMessage(
                kind: pressed ? .keyDown : .keyUp,
                keyCode: kc,
                modifierFlags: mods,
                pressed: pressed
            )
        default:
            // CGEventType.systemDefined carries Apple media keys. The
            // enum doesn't expose a case for it, so we compare against
            // the raw value (14) and decode via NSEvent.
            if type.rawValue == 14 {
                return decodeSystemDefined(event: event, mods: mods)
            }
            return nil
        }
    }

    #if canImport(AppKit)
    /// Decode an NX_SYSDEFINED event (subtype 8 = AUX_CONTROL_BUTTONS)
    /// into a portable MediaKey + pressed flag. Returns nil for any
    /// system-defined event we don't recognise (e.g. screen change).
    private func decodeSystemDefined(event: CGEvent, mods: UInt64) -> InputEventMessage? {
        guard let ns = NSEvent(cgEvent: event) else { return nil }
        // NSEvent.EventSubtype rawValue 8 == NX_SUBTYPE_AUX_CONTROL_BUTTONS.
        guard ns.subtype.rawValue == 8 else { return nil }
        let data1 = ns.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        // data1 lower 16 bits: (state << 8) | repeat.
        //   state 0xA == NX_KEYDOWN, 0xB == NX_KEYUP.
        let stateNibble = (keyFlags & 0xFF00) >> 8
        let pressed: Bool
        switch stateNibble {
        case 0xA: pressed = true
        case 0xB: pressed = false
        default: return nil
        }
        guard let mk = Self.mediaKey(forNXKeyType: keyCode) else { return nil }
        return InputEventMessage(
            kind: .mediaKey,
            mediaKey: mk,
            modifierFlags: mods,
            pressed: pressed
        )
    }
    #endif

    /// Map IOKit NX_KEYTYPE_* constants (from `IOKit/hidsystem/ev_keymap.h`)
    /// to our portable MediaKey enum. Unknown codes return nil.
    static func mediaKey(forNXKeyType code: Int32) -> MediaKey? {
        switch code {
        case 0:  return .volumeUp           // NX_KEYTYPE_SOUND_UP
        case 1:  return .volumeDown         // NX_KEYTYPE_SOUND_DOWN
        case 2:  return .brightnessUp       // NX_KEYTYPE_BRIGHTNESS_UP
        case 3:  return .brightnessDown     // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7:  return .mute               // NX_KEYTYPE_MUTE
        case 14: return .eject              // NX_KEYTYPE_EJECT
        case 16: return .playPause          // NX_KEYTYPE_PLAY
        case 17: return .next               // NX_KEYTYPE_NEXT
        case 18: return .previous           // NX_KEYTYPE_PREVIOUS
        case 19: return .fastForward        // NX_KEYTYPE_FAST
        case 20: return .rewind             // NX_KEYTYPE_REWIND
        default: return nil
        }
    }

    /// True if the modifier identified by `keyCode` is still held down
    /// after this flagsChanged event. macOS doesn't tell us directly —
    /// we infer it from whether the modifier's flag bit is set in the
    /// event's post-state flag word.
    static func modifierIsPressed(keyCode: UInt16, flags: UInt64) -> Bool {
        let bit: UInt64
        switch keyCode {
        case 0x37, 0x36:               // kVK_Command, kVK_RightCommand
            bit = UInt64(CGEventFlags.maskCommand.rawValue)
        case 0x38, 0x3C:               // kVK_Shift, kVK_RightShift
            bit = UInt64(CGEventFlags.maskShift.rawValue)
        case 0x3A, 0x3D:               // kVK_Option, kVK_RightOption
            bit = UInt64(CGEventFlags.maskAlternate.rawValue)
        case 0x3B, 0x3E:               // kVK_Control, kVK_RightControl
            bit = UInt64(CGEventFlags.maskControl.rawValue)
        case 0x39:                     // kVK_CapsLock
            bit = UInt64(CGEventFlags.maskAlphaShift.rawValue)
        case 0x3F:                     // kVK_Function (fn key)
            bit = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
        default:
            return false
        }
        return (flags & bit) != 0
    }

    /// Inverse of `mediaKey(forNXKeyType:)`. Used by InputInjectionService.
    static func nxKeyType(for media: MediaKey) -> Int32 {
        switch media {
        case .volumeUp:        return 0
        case .volumeDown:      return 1
        case .brightnessUp:    return 2
        case .brightnessDown:  return 3
        case .mute:            return 7
        case .eject:           return 14
        case .playPause:       return 16
        case .next:            return 17
        case .previous:        return 18
        case .fastForward:     return 19
        case .rewind:          return 20
        }
    }
    #endif
}

#if canImport(CoreGraphics)
extension CGEvent {
    /// Returns the bounds of the screen the cursor is currently on, if
    /// we can derive them. v0.1 uses the primary display via CG since
    /// we're not yet pulling AppKit screens here.
    static func currentScreenBounds() -> CGRect? {
        let displayId = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayId)
        return bounds.isEmpty ? nil : bounds
    }
}
#endif
