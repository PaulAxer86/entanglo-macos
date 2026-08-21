//
// filename: MenuBarContent.swift
// path: Entanglo/Entanglo/Views/MenuBarContent.swift
// purpose: Compact menu shown when the user clicks the Entanglo icon in
//          the menu bar. Lets the user toggle sharing, enable receiver
//          mode, open the main window, and quit.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(statusLine).disabled(true)
        Divider()

        Toggle("Share keyboard & mouse", isOn: Binding(
            get: { state.sharingEnabled },
            set: { $0 ? state.startSharing() : state.stopSharing() }
        ))
        Toggle("Receive remote input", isOn: Binding(
            get: { state.enabledRoles.contains(.receiver) },
            set: { on in
                if on { state.enabledRoles.insert(.receiver) }
                else  { state.enabledRoles.remove(.receiver) }
            }
        ))
        Toggle("Clipboard sync", isOn: $state.clipboardSyncEnabled)

        Divider()

        Button("Open Entanglo…") { openMainWindow() }
        Button("Refresh permissions") { state.refreshAll() }
            .disabled(state.isRefreshing)

        Divider()

        Button("Quit Entanglo") {
            #if canImport(AppKit)
            NSApp.terminate(nil)
            #endif
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        let trusted = state.trustedDevices.filter { $0.pairing == .trusted }.count
        let heart = state.receiverHeartbeatAlive ? "linked" : "idle"
        return "Entanglo — \(trusted) trusted • \(heart)"
    }

    private func openMainWindow() {
        #if canImport(AppKit)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Find the first content window and bring it to the front. If no
        // window exists (menu-bar-only mode), reopen via the standard
        // application reopen path.
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSApplication.unhide(_:)), to: nil, from: nil)
        }
        #endif
    }
}
