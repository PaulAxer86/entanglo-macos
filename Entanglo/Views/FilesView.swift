//
// filename: FilesView.swift
// path: Entanglo/Entanglo/Views/FilesView.swift
// purpose: Drop a file onto a peer to send it. Received files land in
//          ~/Downloads/Entanglo/. Shows in-flight + recent transfers
//          with progress bars and a "Reveal" button on completion.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct FilesView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedPeerId: String?
    @State private var isTargeted: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                sendCard
                transfersCard
            }
            .padding(12)
        }
        .onAppear { ensurePeerSelection() }
        .onChange(of: state.connectionStates) { _ in ensurePeerSelection() }
        .onChange(of: state.trustedDevices) { _ in ensurePeerSelection() }
    }

    // MARK: - Cards

    private var sendCard: some View {
        CompactCard("Send a file", subtitle: "Drag any file onto the zone below") {
            VStack(spacing: 10) {
                peerPicker
                dropZone
                HStack {
                    Spacer()
                    Button {
                        chooseFileWithPanel()
                    } label: {
                        Label("Choose file…", systemImage: "folder")
                    }
                    .disabled(selectedPeerId == nil)
                }
            }
        }
    }

    private var peerPicker: some View {
        HStack {
            Text("Send to").foregroundStyle(.secondary).font(.subheadline)
            Spacer()
            if connectablePeers.isEmpty {
                Text("No connected peers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { selectedPeerId ?? connectablePeers.first?.id ?? "" },
                    set: { selectedPeerId = $0 }
                )) {
                    ForEach(connectablePeers) { d in
                        Text(d.name).tag(d.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted
                          ? Color.accentColor.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title)
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    Text(isTargeted ? "Release to send" : "Drop a file here")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
            .opacity(connectablePeers.isEmpty ? 0.45 : 1)
            .allowsHitTesting(!connectablePeers.isEmpty)
    }

    private var transfersCard: some View {
        CompactCard("Transfers", subtitle: subtitleForTransfers) {
            transfersBody
        }
    }

    @ViewBuilder private var transfersBody: some View {
        let items = state.fileTransfers.transfers
        if items.isEmpty {
            Text("Nothing yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(items) { t in
                    TransferRow(transfer: t)
                }
                if hasFinished(items) {
                    HStack {
                        Spacer()
                        Button("Clear finished") {
                            state.fileTransfers.clearCompleted()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func hasFinished(_ items: [FileTransferService.Transfer]) -> Bool {
        items.contains { t in
            t.status == .completed || t.status == .failed || t.status == .cancelled
        }
    }

    private var subtitleForTransfers: String {
        let active = state.fileTransfers.transfers.filter { t in
            t.status == .active || t.status == .offered
        }.count
        if active == 0 { return "No active transfers" }
        return "\(active) active"
    }

    private func ensurePeerSelection() {
        let ids = connectablePeers.map(\.id)
        if let sel = selectedPeerId, !ids.contains(sel) { selectedPeerId = ids.first }
        if selectedPeerId == nil { selectedPeerId = ids.first }
    }

    // MARK: - Data

    private var connectablePeers: [Device] {
        state.trustedDevices.filter {
            $0.pairing == .trusted && state.connectionStates[$0.id] == .connected
        }
    }

    // MARK: - Drop / file choose

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let peerId = selectedPeerId,
              let peer = connectablePeers.first(where: { $0.id == peerId }) else { return false }
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.resolveFileURL(from: item) else { return }
                Task { @MainActor in
                    state.fileTransfers.sendFile(at: url, to: peer.id, peerName: peer.name)
                }
            }
        }
        return accepted
    }

    private static func resolveFileURL(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
        if let str = item as? String, let url = URL(string: str) { return url }
        return nil
    }

    private func chooseFileWithPanel() {
        #if canImport(AppKit)
        guard let peerId = selectedPeerId,
              let peer = connectablePeers.first(where: { $0.id == peerId }) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            state.fileTransfers.sendFile(at: url, to: peer.id, peerName: peer.name)
        }
        #endif
    }
}

private struct TransferRow: View {
    let transfer: FileTransferService.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: directionIcon)
                    .foregroundStyle(.secondary)
                Text(transfer.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(transfer.peerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StatusPill(systemImage: statusIcon, tone: statusTone, help: statusHelp)
            }
            ProgressView(value: transfer.progress)
                .progressViewStyle(.linear)
            HStack {
                Text(byteString(transfer.bytesTransferred) + " / " + byteString(transfer.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if transfer.status == .completed, transfer.direction == .incoming, let url = transfer.destinationURL {
                    Button("Reveal") {
                        #if canImport(AppKit)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    }
                    .controlSize(.mini)
                }
                if let err = transfer.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var directionIcon: String {
        transfer.direction == .outgoing ? "arrow.up.circle" : "arrow.down.circle"
    }

    private var statusIcon: String {
        switch transfer.status {
        case .offered:   return "hourglass"
        case .active:    return "arrow.up.arrow.down"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusTone: StatusPill.Tone {
        switch transfer.status {
        case .offered:   return .neutral
        case .active:    return .info
        case .completed: return .ok
        case .failed:    return .bad
        case .cancelled: return .neutral
        }
    }

    private var statusHelp: String {
        switch transfer.status {
        case .offered:   return "Waiting"
        case .active:    return "In progress"
        case .completed: return "Done"
        case .failed:    return transfer.errorMessage ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func byteString(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
