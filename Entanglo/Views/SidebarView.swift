//
// filename: SidebarView.swift
// path: Entanglo/Entanglo/Views/SidebarView.swift
// purpose: Sections list on the left of the main window. Tools on top,
//          utilities (News & Updates, Settings, Logs) pinned at the bottom.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    private var tools: [SidebarSection] {
        SidebarSection.allCases.filter { $0.group == .tools }
    }
    private var utilities: [SidebarSection] {
        SidebarSection.allCases.filter { $0.group == .utilities }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.sidebarSelection) {
                Section("Entanglo") {
                    ForEach(tools) { section in
                        row(for: section)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            List(selection: $state.sidebarSelection) {
                Section {
                    ForEach(utilities) { section in
                        row(for: section)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(height: CGFloat(utilities.count) * 28 + 24)
            .scrollDisabled(true)
        }
        .frame(minWidth: 180, idealWidth: 200)
    }

    @ViewBuilder
    private func row(for section: SidebarSection) -> some View {
        HStack {
            Label(section.displayName, systemImage: section.systemImage)
            Spacer()
            if section == .updates, state.updates.availableUpdate != nil {
                Text("1")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.blue, in: Capsule())
            }
        }
        .tag(section)
    }
}
