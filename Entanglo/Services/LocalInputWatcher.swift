//
// filename: LocalInputWatcher.swift
// path: Entanglo/Entanglo/Services/LocalInputWatcher.swift
// purpose: Observes non-injected local mouse/keyboard activity on a
//          receiver Mac. Used by the ConnectionCoordinator to detect
//          "user touched the local mouse/keyboard" while a remote peer
//          is controlling us, so we can tell that peer to stop.
//
//          We use NSEvent's global monitor (passive — never modifies
//          events, never blocks the runloop) instead of CGEventTap to
//          minimise the chance of input-related lockups.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

final class LocalInputWatcher {
    var onLocalInput: (() -> Void)?

    #if canImport(AppKit)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    #endif

    /// Throttle the callback so a flurry of mouseMoved events triggers
    /// the handler at most ~10 Hz.
    private var lastFiredAt: TimeInterval = 0
    private let minInterval: TimeInterval = 0.1

    func start() {
        #if canImport(AppKit)
        stop()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown, .leftMouseDragged,
            .rightMouseDown, .rightMouseDragged,
            .keyDown
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        #endif
    }

    func stop() {
        #if canImport(AppKit)
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        #endif
    }

    #if canImport(AppKit)
    private func handle(_ event: NSEvent) {
        // Skip events Entanglo synthesised. CGEvent's userData survives
        // the bridge to NSEvent through `cgEvent`.
        if let cg = event.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == InputInjectionService.injectedSourceUserData {
            return
        }
        // Skip pure-zero deltas (some apps re-post events).
        if event.type == .mouseMoved,
           let cg = event.cgEvent {
            let dx = cg.getIntegerValueField(.mouseEventDeltaX)
            let dy = cg.getIntegerValueField(.mouseEventDeltaY)
            if dx == 0 && dy == 0 { return }
        }
        let now = Date().timeIntervalSince1970
        if now - lastFiredAt < minInterval { return }
        lastFiredAt = now
        onLocalInput?()
    }
    #endif
}
