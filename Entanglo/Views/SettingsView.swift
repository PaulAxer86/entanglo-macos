//
// filename: SettingsView.swift
// path: Entanglo/Entanglo/Views/SettingsView.swift
// purpose: All app settings, grouped into four top-level sections:
//          Pairing (identity, roles, link behavior), Behavior (how the app
//          runs), Permissions (TCC status), About (version, links).
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            // MARK: Pairing
            Section("Pairing") {
                TextField("Device name", text: $state.localDeviceName)
                LabeledContent("Device ID", value: state.localDeviceId)
                    .font(.caption.monospaced())
            }

            Section("Roles on this Mac") {
                ForEach(EntangloRole.allCases) { role in
                    Toggle(role.displayName, isOn: roleBinding(role))
                }
            }

            Section("Input Sharing") {
                Toggle("Edge switching enabled", isOn: Binding(
                    get: { state.edgeConfig.enabled },
                    set: { state.edgeConfig.enabled = $0 }
                ))
                LabeledContent("Toggle hotkey", value: state.hotkey)
                LabeledContent("Emergency stop", value: "Escape × 3")
            }

            Section("Clipboard") {
                Toggle("Sync clipboard with trusted devices", isOn: $state.clipboardSyncEnabled)
                Text("Plain text only, between trusted devices. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Printer Bridge") {
                Toggle("Act as printer bridge on this Mac", isOn: $state.printerBridgeEnabled)
                if state.printerBridgeEnabled {
                    TextField("Printer Wi-Fi name (SSID)", text: $state.printerSSID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Printer Wi-Fi password (leave empty if open)", text: $state.printerPassword)
                        .textFieldStyle(.roundedBorder)
                    Picker("CUPS queue", selection: $state.printerQueue) {
                        Text("Select a queue…").tag("")
                        ForEach(PrinterBridgeService.availableCUPSQueues(), id: \.self) { q in
                            Text(q).tag(q)
                        }
                    }
                }
                Text("When a paired Mac sends a PDF as a print job, this Mac switches its Wi-Fi to the printer's network, runs lpr, then power-cycles Wi-Fi so macOS auto-reconnects to your home network. Your home Wi-Fi password isn't stored — only the printer's. The bridge Mac loses internet for ~30 s per job.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: Behavior
            Section("App Behavior") {
                Toggle("Run in menu bar (hide Dock icon)", isOn: $state.runAsMenuBarApp)
                Toggle("Launch at login", isOn: $state.launchAtLoginEnabled)
                Toggle("Keep this Mac awake while a peer is connected", isOn: $state.keepAwakeWhilePaired)
                Toggle("Play notification sounds for peer events", isOn: $state.soundsEnabled)
                Text("Menu-bar mode keeps Entanglo running in the background. Launch at login adds it to your Login Items. Keep-awake holds an IOPMAssertion (same mechanism as `caffeinate`) while a trusted peer is reachable. Sounds: gentle macOS system tones for file received (Tink), peer link lost (Funk) and peer link restored (Glass).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Network") {
                Toggle("Prefer Ethernet", isOn: $state.preferEthernet)
                Toggle("Allow Wi-Fi", isOn: $state.allowWiFi)
                TextField("Manual IP fallback", text: $state.manualIP)
            }

            // MARK: Permissions
            Section("Permissions") {
                permissionsHeader
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRow(
                        kind: kind,
                        status: state.permissions.snapshot.status(for: kind),
                        requiredForCurrentRoles: kind.relevantFor(roles: state.enabledRoles),
                        onOpen: { state.permissions.openSystemSettings(for: kind) }
                    )
                }
                HStack(spacing: 8) {
                    Button("Re-check permissions") { state.refreshAll() }
                        .controlSize(.small)
                        .disabled(state.isRefreshing)
                    if state.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            // MARK: About
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
                Text("Native macOS app for sharing keyboard, mouse, clipboard and files between trusted Macs on your LAN. No third-party services.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func roleBinding(_ role: EntangloRole) -> Binding<Bool> {
        Binding(
            get: { state.enabledRoles.contains(role) },
            set: { _ in state.toggleRole(role) }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    // MARK: - Permissions header

    @ViewBuilder private var permissionsHeader: some View {
        let snap = state.permissions.snapshot
        let required = PermissionKind.allCases.filter { $0.relevantFor(roles: state.enabledRoles) }
        let missing = required.filter { snap.status(for: $0) != .granted && $0.systemSettingsAnchorExists }
        let allGood = missing.isEmpty

        HStack(spacing: 10) {
            Image(systemName: allGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(allGood ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(allGood
                     ? "All required permissions granted"
                     : "Setup incomplete — \(missing.count) permission\(missing.count == 1 ? "" : "s") missing")
                    .font(.subheadline.weight(.semibold))
                Text(allGood
                     ? "Entanglo can capture and inject input as configured."
                     : "Grant the items marked below — Entanglo will still launch but the gated features will stay off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
