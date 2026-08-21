//
// filename: UpdatesView.swift
// path: Entanglo/Entanglo/Views/UpdatesView.swift
// purpose: News & Updates tab. Top card shows an actionable banner when
//          a newer DMG is detected by UpdateService; below, the embedded
//          release-notes feed acts as the changelog.
//

import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                autoInstallBanner
                availableUpdateCard
                whatsNewCard
                changelogList
            }
            .padding(16)
        }
        .sheet(item: Binding(
            get: { state.installInFlight.map { InstallSheetItem(progress: $0) } },
            set: { _ in /* sheet auto-dismisses when state.installInFlight becomes nil */ }
        )) { item in
            installProgressSheet(item.progress)
        }
    }

    private struct InstallSheetItem: Identifiable {
        let progress: AppState.InstallProgress
        var id: String { "\(progress.version)-\(progress.startedAt.timeIntervalSince1970)" }
    }

    @ViewBuilder
    private func installProgressSheet(_ progress: AppState.InstallProgress) -> some View {
        let done = progress.completedPeers + progress.failedPeers
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Sending update \(progress.version) to peers…")
                    .font(.headline)
            }
            Text("\(done) of \(progress.totalPeers) peer(s) done — will open the installer and quit when finished.")
                .font(.caption).foregroundStyle(.secondary)
            if progress.failedPeers > 0 {
                Text("\(progress.failedPeers) push(es) failed — they won't get the update automatically.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Skip — install here only") {
                    state.cancelInstallAndOpenLocal()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    // MARK: - Auto-install countdown banner (receiver side)

    @ViewBuilder private var autoInstallBanner: some View {
        if let auto = state.autoInstallCountdown {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update from \(auto.peerName) — installing in \(auto.secondsLeft)s")
                            .font(.headline)
                        Text("Entanglo will replace itself with \(auto.version) and relaunch automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { state.cancelAutoInstall() }
                        .buttonStyle(.bordered)
                    Button("Install now") { state.commitAutoInstallNow() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.orange.opacity(0.35))
            )
        }
    }

    // MARK: - Available update banner

    @ViewBuilder private var availableUpdateCard: some View {
        if let update = state.updates.availableUpdate {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available — \(update.version)")
                            .font(.headline)
                        Text("You're on \(state.updates.currentVersion). \(update.url.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install…") { state.beginInstall() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.installInFlight != nil)
                }
                if let note = update.note {
                    Divider()
                    highlightsList(note.highlights)
                }
                Text("Click Install to push this build to every connected peer, then open the DMG locally and quit. Drag Entanglo into Applications, replace the existing copy, then relaunch on both Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.blue.opacity(0.3))
            )
        }
    }

    // MARK: - What's new in the running version

    @ViewBuilder private var whatsNewCard: some View {
        if let note = state.updates.currentVersionNote {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                    Text("What's new in \(note.version)")
                        .font(.headline)
                    Text(note.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(note.title)
                    .font(.subheadline.weight(.medium))
                highlightsList(note.highlights)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Full changelog

    @ViewBuilder private var changelogList: some View {
        let older = state.updates.releaseNotes.filter { $0.version != state.updates.currentVersion }
        if !older.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Previous releases")
                    .font(.headline)
                ForEach(older) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(note.version).font(.subheadline.weight(.semibold))
                            Text(note.date).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text(note.title).font(.caption.weight(.medium))
                        highlightsList(note.highlights)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder private func highlightsList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).font(.callout)
                }
            }
        }
    }
}
