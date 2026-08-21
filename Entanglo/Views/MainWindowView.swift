//
// filename: MainWindowView.swift
// path: Entanglo/Entanglo/Views/MainWindowView.swift
// purpose: Top-level NavigationSplitView with sidebar + detail. Compact
//          768×520 default size; follows system Light/Dark automatically.
//

import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView
                .overlay(alignment: .bottomTrailing) { versionBadge }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Entanglo")
        .toolbar(content: toolbar)
        .sheet(item: Binding(
            get: { state.pendingScreenshot },
            set: { newValue in
                if newValue == nil { state.coordinator.lastScreenshot = nil }
            }
        )) { shot in
            ScreenshotPreviewView(shot: shot)
        }
    }

    private var versionBadge: some View {
        Text("v\(Self.appVersion)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
            .help("Entanglo \(Self.appVersion)")
            .accessibilityLabel("Entanglo version \(Self.appVersion)")
    }

    private static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }()

    @ViewBuilder private var detailView: some View {
        switch state.sidebarSelection {
        case .dashboard:       DashboardView()
        case .devices:         DevicesView()
        case .inputSharing:    InputSharingView()
        case .files:           FilesView()
        case .print:           PrintView()
        case .network:         NetworkView()
        case .updates:         UpdatesView()
        case .settings:        SettingsView()
        case .logs:            LogsView()
        }
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Label(state.localDeviceName, systemImage: "macbook.gen2")
                .labelStyle(.titleAndIcon)
        }
        ToolbarItem(placement: .automatic) {
            Button(role: .destructive) {
                state.emergencyStopActive.toggle()
            } label: {
                Image(systemName: state.emergencyStopActive ? "play.circle.fill" : "stop.circle.fill")
                    .foregroundStyle(state.emergencyStopActive ? Color.orange : Color.red)
            }
            .help(state.emergencyStopActive
                  ? "Resume sharing (currently halted)"
                  : "Emergency Stop — halt input + clipboard sharing")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                state.refreshAll()
            } label: {
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(state.isRefreshing)
            .help("Refresh")
        }
    }
}
