//
// filename: DashboardView.swift
// path: Entanglo/Entanglo/Views/DashboardView.swift
// purpose: One-glance status of the local device + active link, trusted
//          peers with per-device connection state, and sharing toggles
//          summary.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                linkBanner
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    thisDeviceCard
                    networkQualityCard
                    pairingCard
                    recentTransfersCard
                    quickActionsCard
                }
            }
            .padding(12)
        }
    }

    // MARK: - Top banner

    private var linkBanner: some View {
        let alive = state.receiverHeartbeatAlive
        let trusted = state.trustedDevices.filter { $0.pairing == .trusted }
        let connectedIds = state.connectionStates
            .filter { $0.value == .connected }
            .map(\.key)
        let connected = trusted.filter { connectedIds.contains($0.id) }

        return HStack(spacing: 14) {
            Image(systemName: alive ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .font(.system(size: 32))
                .foregroundStyle(alive ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(alive ? "Linked" : "Not linked")
                    .font(.title3.bold())
                Text(bannerSubtitle(trustedCount: trusted.count,
                                    connectedNames: connected.map(\.name)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(systemImage: alive ? "waveform.path.ecg" : "bolt.slash.fill",
                       tone: alive ? .ok : .neutral,
                       help: alive ? "Heartbeat OK" : "No heartbeat")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((alive ? Color.green : Color.primary).opacity(0.18),
                              lineWidth: 1)
        )
    }

    private func bannerSubtitle(trustedCount: Int, connectedNames: [String]) -> String {
        if trustedCount == 0 { return "No trusted devices yet — pair one in Devices." }
        if connectedNames.isEmpty { return "\(trustedCount) trusted • waiting for a peer to come online" }
        return "Connected to " + connectedNames.joined(separator: ", ")
    }

    // MARK: - Cards

    private var thisDeviceCard: some View {
        CompactCard("This Device", subtitle: state.localDeviceId) {
            VStack(spacing: 6) {
                MetricRow(label: "Name", value: state.localDeviceName)
                MetricRow(label: "Roles", value: rolesLabel)
                MetricRow(label: "Sharing",
                          value: state.sharingEnabled ? "On" : "Off",
                          tone: state.sharingEnabled ? .ok : .neutral,
                          systemImage: state.sharingEnabled ? "checkmark.circle.fill" : "circle")
                MetricRow(label: "Clipboard sync",
                          value: state.clipboardSyncEnabled ? "On" : "Off",
                          tone: state.clipboardSyncEnabled ? .ok : .neutral,
                          systemImage: state.clipboardSyncEnabled ? "checkmark.circle.fill" : "circle")
            }
        }
    }

    private var networkQualityCard: some View {
        CompactCard("Network Quality", subtitle: "Live transport snapshot") {
            VStack(spacing: 6) {
                if let q = state.qualitySnapshot {
                    MetricRow(label: "Interface",
                              value: q.iface.kind.displayName,
                              tone: .info,
                              systemImage: interfaceIcon(q.iface.kind))
                    MetricRow(label: "Latency",
                              value: q.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—")
                    MetricRow(label: "Suggested", value: q.suggested.displayName,
                              tone: tone(for: q.suggested))
                } else {
                    Text("Detecting…")
                        .foregroundStyle(.secondary).font(.subheadline)
                }
            }
        }
    }

    private var pairingCard: some View {
        let connected = state.trustedDevices.filter { state.connectionStates[$0.id] == .connected }
        return CompactCard("Pairing", subtitle: "Connected peers") {
            if connected.isEmpty {
                Text(state.trustedDevices.isEmpty
                     ? "No paired devices yet."
                     : "No peers currently connected.")
                    .foregroundStyle(.secondary).font(.subheadline)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(connected) { d in
                        HStack {
                            Text(d.name).font(.subheadline)
                            Spacer()
                            StatusPill(systemImage: linkIcon(for: d.id),
                                       tone: linkTone(for: d.id),
                                       help: linkLabel(for: d.id))
                        }
                    }
                }
            }
        }
    }

    private var recentTransfersCard: some View {
        CompactCard("Recent Transfers", subtitle: "Last 3 file transfers") {
            VStack(alignment: .leading, spacing: 6) {
                let last3 = Array(state.fileTransfers.transfers.sorted(by: { $0.startedAt > $1.startedAt }).prefix(3))
                if last3.isEmpty {
                    Text("No transfers yet.")
                        .foregroundStyle(.secondary).font(.subheadline)
                } else {
                    ForEach(last3) { t in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: transferIcon(t))
                                .foregroundStyle(transferTint(t))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.fileName).font(.caption.weight(.semibold)).lineLimit(1)
                                Text("\(t.peerName) • \(humanBytes(t.sizeBytes)) • \(t.startedAt, style: .relative) ago")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private var quickActionsCard: some View {
        CompactCard("Quick Actions", subtitle: "Click or use the shortcut") {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    state.pushCurrentURLToPeers()
                } label: {
                    Label("Push URL to peer", systemImage: "link.badge.plus")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(firstAvailablePeer == nil)
                .help("Clipboard URL or active browser tab — also ⌘⇧U globally")

                screenshotControl

                if state.coordinator.screenshotInProgress != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Capturing peer screen…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let msg = state.coordinator.lastQuickActionMessage {
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if let err = state.coordinator.lastScreenshotError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                }
                if firstAvailablePeer == nil {
                    Text(state.trustedDevices.isEmpty
                         ? "Pair a device first (Devices tab)."
                         : "Waiting for a peer to come online…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Picker for the Screenshot Quick Action. Renders three ways:
    ///   • 0 peers online  → disabled Button (the "no peer" caption below
    ///                       already explains why).
    ///   • 1 peer online   → plain Button that targets that one peer, so
    ///                       the common single-Mac case stays one click.
    ///   • ≥2 peers online → Menu with one item per peer, so multi-peer
    ///                       setups pick unambiguously which Mac to shoot.
    @ViewBuilder
    private var screenshotControl: some View {
        let peers = availableScreenshotPeers
        if peers.count <= 1 {
            Button {
                if let only = peers.first {
                    state.requestScreenshot(fromPeerId: only.id)
                } else {
                    state.requestPeerScreenshot()
                }
            } label: {
                Label(peers.count == 1
                      ? "Screenshot \(peers[0].name)"
                      : "Screenshot peer's screen",
                      systemImage: "camera.viewfinder")
                    .font(.caption)
            }
            .controlSize(.small)
            .disabled(peers.isEmpty)
            .help(peers.count == 1
                  ? "Capture \(peers[0].name)'s screen — also ⌘⇧S globally"
                  : "Connect a peer to capture their screen")
        } else {
            Menu {
                ForEach(peers) { d in
                    Button {
                        state.requestScreenshot(fromPeerId: d.id)
                    } label: {
                        Label(d.name, systemImage: "display")
                    }
                }
            } label: {
                Label("Screenshot peer's screen…", systemImage: "camera.viewfinder")
                    .font(.caption)
            }
            .controlSize(.small)
            .menuStyle(.borderlessButton)
            .help("Pick which peer to capture (⌘⇧S targets the first)")
        }
    }

    /// Trusted peers with a live outbound transport, ordered by name so
    /// the picker doesn't jitter as the dictionary rehashes.
    private var availableScreenshotPeers: [Device] {
        let outbound = state.coordinator.outbound
        return state.trustedDevices
            .filter { outbound[$0.id] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var firstConnectedPeer: Device? {
        let connectedIds = state.connectionStates.filter { $0.value == .connected }.map(\.key)
        return state.trustedDevices.first { connectedIds.contains($0.id) }
    }

    /// Like firstConnectedPeer, but also accepts peers whose outbound
    /// transport exists even if the state hasn't yet flipped to .connected
    /// (e.g. just dialed, heartbeat alive). Used to keep Quick Actions and
    /// Speed Test reachable as soon as a TCP session is up.
    private var firstAvailablePeer: Device? {
        let outbound = state.coordinator.outbound
        return state.trustedDevices.first { outbound[$0.id] != nil }
    }

    private func peerName(_ id: String) -> String {
        state.trustedDevices.first(where: { $0.id == id })?.name ?? id
    }

    private func humanBytes(_ b: Int) -> String {
        if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1_000_000.0) }
        if b >= 1_000     { return String(format: "%.1f KB", Double(b) / 1_000.0) }
        return "\(b) B"
    }

    private func transferIcon(_ t: FileTransferService.Transfer) -> String {
        switch t.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        case .active:    return "arrow.up.arrow.down.circle"
        case .offered:   return "envelope.circle"
        case .cancelled: return "minus.circle"
        }
    }

    private func transferTint(_ t: FileTransferService.Transfer) -> Color {
        switch t.status {
        case .completed: return .green
        case .failed:    return .red
        case .active:    return .blue
        case .offered:   return .orange
        case .cancelled: return .secondary
        }
    }

    // MARK: - Helpers

    private var rolesLabel: String {
        if state.enabledRoles.isEmpty { return "None" }
        return state.enabledRoles.map(\.shortLabel).sorted().joined(separator: ", ")
    }

    private func tone(for mode: SuggestedNetworkMode) -> StatusPill.Tone {
        switch mode {
        case .ethernetPreferred: return .ok
        case .wifiOK:            return .info
        case .unstable:          return .warn
        case .offline:           return .bad
        }
    }

    private func linkLabel(for deviceId: String) -> String {
        switch state.connectionStates[deviceId] {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .discovered:   return "Discovered"
        case .disconnected: return "Offline"
        case .errored:      return "Error"
        case .offline:      return "Offline"
        case .none:         return "Idle"
        }
    }

    private func linkTone(for deviceId: String) -> StatusPill.Tone {
        switch state.connectionStates[deviceId] {
        case .connected:    return .ok
        case .connecting:   return .info
        case .errored:      return .bad
        default:            return .neutral
        }
    }

    private func linkIcon(for deviceId: String) -> String {
        switch state.connectionStates[deviceId] {
        case .connected:    return "link"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .discovered:   return "dot.radiowaves.left.and.right"
        case .errored:      return "exclamationmark.triangle.fill"
        case .disconnected, .offline, .none: return "wifi.slash"
        }
    }

    private func interfaceIcon(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .ethernet: return "cable.connector"
        case .wifi:     return "wifi"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .unknown:  return "questionmark.circle"
        }
    }
}
