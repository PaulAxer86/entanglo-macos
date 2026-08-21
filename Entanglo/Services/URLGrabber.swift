//
// filename: URLGrabber.swift
// path: Entanglo/Entanglo/Services/URLGrabber.swift
// purpose: Resolve "the URL the user probably wants to push" when the
//          URL-push hotkey fires. Order: 1) pasteboard (cheapest, works
//          for any browser), 2) AppleScript fall-backs for Safari/Chrome.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum URLGrabber {
    public static func grab() -> String? {
        if let pb = pasteboardURL() { return pb }
        if let active = activeBrowserURL() { return active }
        return nil
    }

    private static func pasteboardURL() -> String? {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        // Prefer typed URL pasteboard contents
        if let url = pb.string(forType: .URL), looksLikeURL(url) { return url }
        // Fall back to plain string
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           looksLikeURL(str) {
            return str
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        guard let comps = URLComponents(string: s) else { return false }
        guard let scheme = comps.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Try to read the front URL from the currently active browser via
    /// AppleScript. Each browser exposes its own dictionary; we ship the
    /// scripts for Safari and Chromium-based browsers (Chrome/Edge/Brave/
    /// Arc — all share the same `URL of active tab of front window`).
    private static func activeBrowserURL() -> String? {
        #if canImport(AppKit)
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier
        else { return nil }
        let script: String?
        switch bundleId {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return URL of current tab of front window"
        case "com.google.Chrome",
             "com.microsoft.edgemac",
             "com.brave.Browser",
             "company.thebrowser.Browser":
            let appName = frontApp.localizedName ?? "Google Chrome"
            script = "tell application \"\(appName)\" to return URL of active tab of front window"
        case "org.mozilla.firefox":
            // Firefox doesn't expose URL via AppleScript. Fall through.
            script = nil
        default:
            script = nil
        }
        guard let scriptText = script else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: scriptText)?.executeAndReturnError(&error).stringValue
        if let err = error { NSLog("Entanglo URLGrabber AppleScript error: \(err)") }
        return result
        #else
        return nil
        #endif
    }
}
