//
// filename: GlobalHotkeyManager.swift
// path: Entanglo/Entanglo/Services/GlobalHotkeyManager.swift
// purpose: Thin wrapper around Carbon RegisterEventHotKey so we can bind
//          global keyboard shortcuts (URL push, screenshot push) without
//          rolling a new CGEventTap. Carbon hotkeys are the standard macOS
//          mechanism — they require Accessibility (which we already have)
//          and survive sandbox/TCC quirks better than NSEvent monitors.
//

import Foundation
import Carbon.HIToolbox
import AppKit

public final class GlobalHotkeyManager {
    public struct Hotkey: Hashable {
        public let id: UInt32
        public let keyCode: UInt32
        public let modifiers: UInt32

        public init(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
            self.id = id
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        public static let urlPush = Hotkey(
            id: 0xE0_01,
            keyCode: UInt32(kVK_ANSI_U),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        public static let screenshotPush = Hotkey(
            id: 0xE0_02,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    public static let shared = GlobalHotkeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    private init() {}

    public func register(_ hotkey: Hotkey, action: @escaping () -> Void) {
        installCarbonHandlerIfNeeded()
        handlers[hotkey.id] = action
        let signature = OSType(0x454E5447)  // 'ENTG'
        let hkId = EventHotKeyID(signature: signature, id: hotkey.id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hkId,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs[hotkey.id] = ref
        } else {
            NSLog("Entanglo: RegisterEventHotKey failed for id=\(hotkey.id) status=\(status)")
        }
    }

    public func unregister(_ hotkey: Hotkey) {
        if let ref = refs[hotkey.id] {
            UnregisterEventHotKey(ref)
            refs.removeValue(forKey: hotkey.id)
        }
        handlers.removeValue(forKey: hotkey.id)
    }

    private func installCarbonHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData -> OSStatus in
            guard let eventRef = eventRef, let userData = userData else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkId = EventHotKeyID()
            let status = GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkId)
            if status == noErr {
                DispatchQueue.main.async {
                    manager.handlers[hkId.id]?()
                }
            }
            return noErr
        }, 1, &spec, context, nil)
    }
}
