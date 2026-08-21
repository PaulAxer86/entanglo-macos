//
// filename: DeviceRow.swift
// path: Entanglo/Entanglo/Views/Components/DeviceRow.swift
// purpose: One row in the Devices list.
//

import SwiftUI

struct DeviceRow: View {
    let device: Device
    /// Live transport state from ConnectionCoordinator. `device.connection`
    /// is a persisted legacy field that only reflects the last hello and
    /// lies after disconnects — always render this instead.
    let liveConnection: ConnectionMode
    let onPair: () -> Void
    let onTrust: () -> Void
    let onRevoke: () -> Void
    let onBlock: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "macbook.gen2")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.subheadline.weight(.semibold))
                    StatusPill(text: liveConnection.displayName, tone: tone(for: liveConnection))
                    StatusPill(text: device.pairing.displayName, tone: tone(for: device.pairing))
                    StatusPill(text: device.iface.kind.displayName, tone: .info)
                }
                HStack(spacing: 10) {
                    if let host = device.hostName ?? device.ipAddress {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                    if let lat = device.iface.latencyMs {
                        Text(String(format: "%.0f ms", lat))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch device.pairing {
            case .notPaired:
                Button("Pair", action: onPair).controlSize(.small)
                Button("Block", role: .destructive, action: onBlock).controlSize(.small)
            case .pairingRequested, .pinRequired:
                Button("Trust", action: onTrust).controlSize(.small)
                Button("Cancel", role: .destructive, action: onRevoke).controlSize(.small)
            case .trusted:
                Button("Remove Trust", role: .destructive, action: onRevoke).controlSize(.small)
            case .blocked:
                Button("Unblock", action: onRevoke).controlSize(.small)
            }
            Button {
                onForget()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Forget this device (removes it from the saved list)")
        }
    }

    private func tone(for s: ConnectionMode) -> StatusPill.Tone {
        switch s {
        case .connected:    return .ok
        case .connecting:   return .info
        case .discovered:   return .neutral
        case .disconnected: return .warn
        case .offline:      return .neutral
        case .errored:      return .bad
        }
    }
    private func tone(for s: PairingState) -> StatusPill.Tone {
        switch s {
        case .trusted: return .ok
        case .blocked: return .bad
        case .pinRequired, .pairingRequested: return .info
        case .notPaired: return .neutral
        }
    }
}
