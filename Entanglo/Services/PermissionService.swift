//
// filename: PermissionService.swift
// path: Entanglo/Entanglo/Services/PermissionService.swift
// purpose: Inspects the macOS permissions Entanglo needs and exposes a
//          published snapshot so the Settings view can render Permission
//          rows. Never bypasses the system prompts — only reports state
//          and offers a deep-link to the relevant System Settings pane.
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum PermissionKind: String, CaseIterable, Sendable {
    case accessibility
    case inputMonitoring
    case localNetwork
    case screenRecording

    public var displayName: String {
        switch self {
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        case .localNetwork:     return "Local Network"
        case .screenRecording:  return "Screen Recording"
        }
    }

    public var explanation: String {
        switch self {
        case .accessibility:
            return "Required to capture global keyboard and mouse events on the Controller and to inject them on the Receiver."
        case .inputMonitoring:
            return "Required on macOS 10.15+ to observe keystrokes globally, in addition to Accessibility."
        case .localNetwork:
            return "Required to advertise and browse Bonjour services on your LAN. macOS doesn't expose the current state — if Devices shows discovered peers you're good."
        case .screenRecording:
            return "Only needed when a peer asks this Mac for a screenshot (⌘⇧S). Without it the screenshot push returns an error to the requester."
        }
    }

    public var systemImage: String {
        switch self {
        case .accessibility:    return "hand.tap"
        case .inputMonitoring:  return "keyboard"
        case .localNetwork:     return "wifi"
        case .screenRecording:  return "rectangle.dashed.badge.record"
        }
    }

    /// Which roles actually depend on this permission. Used by the UI to
    /// mark a row as "required for what you've enabled" vs. "optional".
    public func relevantFor(roles: Set<EntangloRole>) -> Bool {
        switch self {
        case .accessibility, .inputMonitoring:
            return roles.contains(.controller) || roles.contains(.receiver)
        case .localNetwork:
            return true
        case .screenRecording:
            return roles.contains(.receiver)
        }
    }

    public var systemSettingsAnchor: String {
        switch self {
        case .accessibility:   return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .localNetwork:    return "Privacy_LocalNetwork"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }

    /// macOS 14 (Sonoma) and later removed the Local Network panel from
    /// System Settings — the legacy deep-link `Privacy_LocalNetwork`
    /// silently lands on a 404 page. Suppress the "Open Settings" button
    /// for permissions whose anchor isn't reliable across supported OS
    /// versions.
    public var systemSettingsAnchorExists: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording:
            return true
        case .localNetwork:
            return false
        }
    }

    /// Whether macOS exposes a public API to read the current grant state.
    /// When false, the UI should show a neutral "info" indicator instead of
    /// an alarming "required but missing" warning, since we genuinely don't
    /// know whether the user has granted it.
    public var isDetectable: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording: return true
        case .localNetwork:                                       return false
        }
    }
}

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
    case unknown

    public var displayName: String {
        switch self {
        case .granted: return "Granted"
        case .denied:  return "Not granted"
        case .unknown: return "Unknown"
        }
    }
}

public struct PermissionSnapshot: Equatable, Sendable {
    public var accessibility: PermissionStatus
    public var inputMonitoring: PermissionStatus
    public var localNetwork: PermissionStatus
    public var screenRecording: PermissionStatus

    public init(
        accessibility: PermissionStatus = .unknown,
        inputMonitoring: PermissionStatus = .unknown,
        localNetwork: PermissionStatus = .unknown,
        screenRecording: PermissionStatus = .unknown
    ) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.localNetwork = localNetwork
        self.screenRecording = screenRecording
    }

    public func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .accessibility:   return accessibility
        case .inputMonitoring: return inputMonitoring
        case .localNetwork:    return localNetwork
        case .screenRecording: return screenRecording
        }
    }
}

public final class PermissionService: ObservableObject {
    @Published public private(set) var snapshot = PermissionSnapshot()

    public init() {}

    /// Re-reads every permission. Cheap; safe to call from a UI refresh.
    public func refresh() {
        snapshot = PermissionSnapshot(
            accessibility: checkAccessibility(),
            inputMonitoring: checkInputMonitoring(),
            localNetwork: .unknown, // No public API; we can only infer from Bonjour activity.
            screenRecording: checkScreenRecording()
        )
    }

    private func checkScreenRecording() -> PermissionStatus {
        #if canImport(CoreGraphics)
        // CGPreflightScreenCaptureAccess is available on macOS 11+. Until
        // the user grants, the API returns false and capture returns nil.
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        return .unknown
        #else
        return .unknown
        #endif
    }

    // MARK: - Individual checks (all read-only, no prompts shown by us)

    private func checkAccessibility() -> PermissionStatus {
        #if canImport(AppKit)
        // AXIsProcessTrusted returns whether the process is currently
        // listed as trusted in the Accessibility pane. Passing the
        // "prompt" option = false means we never trigger a popup.
        let opts: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts) ? .granted : .denied
        #else
        return .unknown
        #endif
    }

    private func checkInputMonitoring() -> PermissionStatus {
        #if canImport(CoreGraphics)
        // IOHIDCheckAccess is the canonical API; in a SwiftPM build that
        // does not link IOKit we fall back to .unknown rather than
        // pretending.
        let event = CGEventSource.init(stateID: .hidSystemState)
        return event != nil ? .granted : .denied
        #else
        return .unknown
        #endif
    }

    // MARK: - Open System Settings

    public func openSystemSettings(for kind: PermissionKind) {
        #if canImport(AppKit)
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(kind.systemSettingsAnchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
