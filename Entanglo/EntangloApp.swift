//
// filename: EntangloApp.swift
// path: Entanglo/Entanglo/EntangloApp.swift
// purpose: Application entry point. Sets up the AppState environment
//          object, the main window, and a menu-bar status item so the
//          app can run in the background with quick access from the
//          menu bar.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct EntangloApp: App {
    @NSApplicationDelegateAdaptor(EntangloAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Entanglo") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { appDelegate.bind(state: appState) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {} // no New Document
        }

        MenuBarExtra("Entanglo", systemImage: "link.circle.fill") {
            MenuBarContent()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

#if canImport(AppKit)
@MainActor
final class EntangloAppDelegate: NSObject, NSApplicationDelegate {
    private weak var state: AppState?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        // Honor the user's persisted preference before any window appears
        // so the Dock icon doesn't briefly flash when launching as a
        // menu-bar app.
        let menuBarOnly = SettingsStore.shared.bool(.runAsMenuBarApp, default: false)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        }
    }

    func bind(state: AppState) {
        self.state = state
        applyActivationPolicy()
    }

    func applyActivationPolicy() {
        guard let state else { return }
        // `.accessory` hides the Dock icon (menu-bar-only app),
        // `.regular` is the normal full-citizen app with Dock + menu bar.
        NSApp.setActivationPolicy(state.runAsMenuBarApp ? .accessory : .regular)
    }
}
#else
final class EntangloAppDelegate: NSObject {
    func bind(state: AppState) {}
}
#endif
