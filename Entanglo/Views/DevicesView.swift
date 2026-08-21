//
// filename: DevicesView.swift
// path: Entanglo/Entanglo/Views/DevicesView.swift
// purpose: Discovered + saved devices with pairing controls and a
//          manual-IP connect fallback.
//

import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var state: AppState
    @State private var manualHost = ""
    @State private var manualPort = "55555"
    @State private var confirmResetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Devices").font(.title3.bold())
                Spacer()
                Button {
                    state.discovery.startBrowsing()
                } label: { Label("Refresh", systemImage: "magnifyingglass") }
                .controlSize(.small)
                Button(role: .destructive) {
                    confirmResetAll = true
                } label: { Label("Reset", systemImage: "trash") }
                .controlSize(.small)
                .disabled(state.trustedDevices.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            List {
                Section("Discovered & Saved") {
                    if state.trustedDevices.isEmpty && state.discoveredDevices.isEmpty {
                        Text("No devices yet — make sure Entanglo is running on another Mac on the same LAN.")
                            .foregroundStyle(.secondary).font(.subheadline)
                    } else {
                        ForEach(combinedDevices) { device in
                            DeviceRow(
                                device: device,
                                liveConnection: state.connectionStates[device.id] ?? .discovered,
                                onPair: { pair(device) },
                                onTrust: { trust(device) },
                                onRevoke: { try? state.pairing.revokeTrust(deviceId: device.id) },
                                onBlock: { observeAndThen(device) { try? state.pairing.block(deviceId: device.id) } },
                                onForget: { forget(device) }
                            )
                        }
                    }
                }
                Section("Manual Connect") {
                    HStack {
                        TextField("Host", text: $manualHost)
                        TextField("Port", text: $manualPort).frame(width: 80)
                        Button("Connect") {
                            // NetworkTransport wiring happens in AppState in
                            // future revisions; for now we just log intent.
                            state.log.log(.network, "Manual connect requested: \(manualHost):\(manualPort)")
                        }
                        .disabled(manualHost.isEmpty)
                    }
                }
            }
        }
        .alert("Reset all saved devices?", isPresented: $confirmResetAll) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                let count = state.trustedDevices.count
                state.pairing.forgetAll()
                state.log.log(.pairing, "Reset all devices (\(count) removed)")
            }
        } message: {
            Text("This removes every paired and blocked device from the saved list. Discovery will repopulate them on the LAN if they are still active.")
        }
    }

    private var combinedDevices: [Device] {
        var byId: [String: Device] = [:]
        for d in state.trustedDevices { byId[d.id] = d }
        for d in state.discoveredDevices where byId[d.id] == nil {
            byId[d.id] = d
        }
        return byId.values
            .filter { $0.name != state.localDeviceName }
            .sorted(by: { $0.name < $1.name })
    }

    // v0.1 does not yet exchange pairing messages over the wire, so any
    // pairing action first needs to materialise the discovered peer in
    // PairingService (otherwise transitions throw unknownDevice). On both
    // Macs the user clicks Pair → Trust unilaterally; full peer-to-peer
    // PIN ceremony lands in 0.2.
    private func pair(_ device: Device) {
        state.pairing.observe(device)
        try? state.pairing.transition(deviceId: device.id, to: .pairingRequested)
        state.log.log(.pairing, "Pair requested for \(device.name)")
    }

    private func trust(_ device: Device) {
        observeAndThen(device) {
            try? state.pairing.transition(deviceId: device.id, to: .trusted)
            state.log.log(.pairing, "Device trusted: \(device.name)")
        }
    }

    private func forget(_ device: Device) {
        state.pairing.forget(deviceId: device.id)
        state.log.log(.pairing, "Device forgotten: \(device.name)")
    }

    private func observeAndThen(_ device: Device, _ action: () -> Void) {
        if state.pairing.device(id: device.id) == nil {
            state.pairing.observe(device)
        }
        action()
    }
}
