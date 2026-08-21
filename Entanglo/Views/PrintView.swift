//
// filename: PrintView.swift
// path: Entanglo/Entanglo/Views/PrintView.swift
// purpose: Sender side of the Printer Bridge feature. Pick a PDF, pick
//          a paired Mac, hit Send — the file is shipped over the
//          existing trusted-peer transport with kind="printJob" so the
//          receiver's PrinterBridgeService handles the Wi-Fi swap + lpr.
//

import SwiftUI
import UniformTypeIdentifiers

struct PrintView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedFile: URL?
    @State private var selectedPeerId: String = ""
    @State private var isPicking = false
    @State private var lastSentSummary: String?

    var body: some View {
        Form {
            Section("Send a print job to a paired Mac") {
                fileRow
                peerPicker
                HStack {
                    Button("Send to print") { send() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSend)
                    if let lastSentSummary {
                        Text(lastSentSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("How it works") {
                Text("The selected PDF is sent over your trusted-peer link to the chosen Mac. That Mac switches its Wi-Fi to the printer's direct network, prints, then auto-reconnects to its usual network. Enable 'Printer Bridge' in Settings on the receiving Mac first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if state.printerBridgeEnabled {
                Section("This Mac as a Printer Bridge") {
                    bridgeStatus
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Print")
    }

    // MARK: - Subviews

    private var fileRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedFile?.lastPathComponent ?? "No file selected")
                    .lineLimit(1).truncationMode(.middle)
                if let url = selectedFile {
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button("Choose PDF…") { pickFile() }
        }
    }

    @ViewBuilder private var peerPicker: some View {
        let peers = availablePeers
        if peers.isEmpty {
            Text("No paired Macs are reachable right now.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Send to", selection: $selectedPeerId) {
                Text("Select a Mac…").tag("")
                ForEach(peers) { peer in
                    Text(peer.name).tag(peer.id)
                }
            }
        }
    }

    @ViewBuilder private var bridgeStatus: some View {
        if let job = state.printerBridge.currentJob {
            VStack(alignment: .leading, spacing: 4) {
                Text("Active job: \(job.fileName)").font(.subheadline.weight(.semibold))
                Text("From \(job.fromPeerName) — \(job.message)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Bridge is idle. Incoming print jobs will run automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Logic

    private var availablePeers: [Device] {
        let outbound = state.coordinator.outbound
        return state.trustedDevices.filter { outbound[$0.id] != nil }
    }

    private var canSend: Bool {
        selectedFile != nil && !selectedPeerId.isEmpty
    }

    private func pickFile() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose a PDF to print on a paired Mac"
        if panel.runModal() == .OK {
            selectedFile = panel.url
        }
        #endif
    }

    private func send() {
        guard let url = selectedFile,
              let peer = availablePeers.first(where: { $0.id == selectedPeerId }) else { return }
        let tid = state.fileTransfers.sendFile(
            at: url, to: peer.id, peerName: peer.name, kind: "printJob"
        )
        lastSentSummary = "Sent \(url.lastPathComponent) to \(peer.name) (transfer \(tid.prefix(8))…)"
    }
}
