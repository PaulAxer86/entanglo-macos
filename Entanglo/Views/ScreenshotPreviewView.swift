//
// filename: ScreenshotPreviewView.swift
// path: Entanglo/Entanglo/Views/ScreenshotPreviewView.swift
// purpose: Modal preview of the most-recent screenshot received from a
//          peer (⌘⇧S). Lets the user save it to disk or copy to the
//          clipboard. Dismiss clears state.lastScreenshot.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ScreenshotPreviewView: View {
    @EnvironmentObject var state: AppState
    let shot: ReceivedScreenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Screenshot from \(shot.peerName)")
                        .font(.headline)
                    Text("\(shot.receivedAt, style: .time) • \(humanSize(shot.pngData.count))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    state.coordinator.lastScreenshot = nil
                }
            }

            ScrollView([.horizontal, .vertical]) {
                if let img = nsImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200, maxHeight: 800)
                        .overlay(alignment: .topLeading) { sourceBadge }
                } else {
                    Text("Could not decode image")
                        .foregroundStyle(.secondary)
                        .padding(60)
                }
            }
            .frame(minHeight: 360)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button {
                    saveToFile()
                } label: { Label("Save…", systemImage: "square.and.arrow.down") }

                Button {
                    copyToClipboard()
                } label: { Label("Copy", systemImage: "doc.on.doc") }

                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 600, idealWidth: 900, minHeight: 480)
    }

    /// Small "from PeerName · HH:mm:ss" badge pinned to the top-left of
    /// the captured image itself. The header above the ScrollView already
    /// says the same thing, but when the user scrolls into a zoomed view
    /// (or exports the PNG via ⌘C then pastes into a doc) the header is
    /// out of frame — the overlay travels with the pixels so multi-peer
    /// sessions never lose track of which Mac produced which shot.
    private var sourceBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "display")
                .font(.caption2)
            Text(shot.peerName)
                .font(.caption.weight(.semibold))
            Text("·")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(shot.receivedAt, style: .time)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .padding(8)
        .accessibilityLabel("Screenshot from \(shot.peerName) at \(shot.receivedAt.formatted(date: .omitted, time: .standard))")
    }

    private var nsImage: NSImage? {
        #if canImport(AppKit)
        return NSImage(data: shot.pngData)
        #else
        return nil
        #endif
    }

    private func saveToFile() {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Entanglo-\(shot.peerName)-\(Int(shot.receivedAt.timeIntervalSince1970)).png"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? shot.pngData.write(to: url)
            }
        }
        #endif
    }

    private func copyToClipboard() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(shot.pngData, forType: .png)
        #endif
    }

    private func humanSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.2f MB", mb)
    }
}
