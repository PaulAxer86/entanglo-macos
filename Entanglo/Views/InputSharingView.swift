//
// filename: InputSharingView.swift
// path: Entanglo/Entanglo/Views/InputSharingView.swift
// purpose: Configure edge switching, hotkey, emergency stop, and shows
//          whether input is currently local or remote.
//

import SwiftUI

struct InputSharingView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Sharing") {
                Toggle("Share my keyboard & mouse", isOn: Binding(
                    get: { state.sharingEnabled },
                    set: { $0 ? state.startSharing() : state.stopSharing() }
                ))
                Toggle("Receive remote keyboard & mouse", isOn: Binding(
                    get: { state.enabledRoles.contains(.receiver) },
                    set: { on in
                        if on { state.enabledRoles.insert(.receiver) }
                        else  { state.enabledRoles.remove(.receiver) }
                    }
                ))
            }

            Section("Status") {
                HStack {
                    Text("Active Target")
                    Spacer()
                    Text(state.inputCapture.currentTargetDeviceId ?? "Local")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Heartbeat")
                    Spacer()
                    StatusPill(
                        text: state.receiverHeartbeatAlive ? "Alive" : "No link",
                        tone: state.receiverHeartbeatAlive ? .ok : .neutral
                    )
                }
                HStack {
                    Text("Emergency Stop")
                    Spacer()
                    StatusPill(
                        text: state.emergencyStopActive ? "ACTIVE" : "Armed",
                        tone: state.emergencyStopActive ? .bad : .info
                    )
                }
                ForEach(state.trustedDevices.filter { $0.pairing == .trusted }) { d in
                    HStack {
                        Text(d.name)
                        Spacer()
                        Text(state.connectionStates[d.id]?.displayName ?? "Idle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Edge Switching") {
                Toggle("Enabled", isOn: edgeEnabledBinding)
                Picker("Left edge → device", selection: leftBinding) {
                    Text("None").tag(String?.none)
                    ForEach(state.trustedDevices.filter { $0.pairing == .trusted }) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
                Picker("Right edge → device", selection: rightBinding) {
                    Text("None").tag(String?.none)
                    ForEach(state.trustedDevices.filter { $0.pairing == .trusted }) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
                Picker("Top edge → device", selection: topBinding) {
                    Text("None").tag(String?.none)
                    ForEach(state.trustedDevices.filter { $0.pairing == .trusted }) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
                Picker("Bottom edge → device", selection: bottomBinding) {
                    Text("None").tag(String?.none)
                    ForEach(state.trustedDevices.filter { $0.pairing == .trusted }) { d in
                        Text(d.name).tag(Optional(d.id))
                    }
                }
            }

            Section("Shortcuts") {
                HStack {
                    Text("Toggle hotkey")
                    Spacer()
                    Text(state.hotkey).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Emergency stop")
                    Spacer()
                    Text("Escape × 3").foregroundStyle(.secondary)
                }
            }

            Section("Safety") {
                Text("Input injection is blocked unless: the receiver is trusted, the receiver role is enabled, Accessibility + Input Monitoring are granted, the heartbeat is alive, and the emergency stop is not active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var edgeEnabledBinding: Binding<Bool> {
        Binding(get: { state.edgeConfig.enabled }, set: { state.edgeConfig.enabled = $0; state.inputCapture.edgeConfig = state.edgeConfig })
    }
    private var leftBinding: Binding<String?> {
        Binding(get: { state.edgeConfig.leftEdgeTargetId }, set: { state.edgeConfig.leftEdgeTargetId = $0; state.inputCapture.edgeConfig = state.edgeConfig })
    }
    private var rightBinding: Binding<String?> {
        Binding(get: { state.edgeConfig.rightEdgeTargetId }, set: { state.edgeConfig.rightEdgeTargetId = $0; state.inputCapture.edgeConfig = state.edgeConfig })
    }
    private var topBinding: Binding<String?> {
        Binding(get: { state.edgeConfig.topEdgeTargetId }, set: { state.edgeConfig.topEdgeTargetId = $0; state.inputCapture.edgeConfig = state.edgeConfig })
    }
    private var bottomBinding: Binding<String?> {
        Binding(get: { state.edgeConfig.bottomEdgeTargetId }, set: { state.edgeConfig.bottomEdgeTargetId = $0; state.inputCapture.edgeConfig = state.edgeConfig })
    }
}
