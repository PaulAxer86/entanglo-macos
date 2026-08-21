//
// filename: LogsView.swift
// path: Entanglo/Entanglo/Views/LogsView.swift
// purpose: Compact log panel with category filter pills. No keystroke
//          text is ever logged.
//

import SwiftUI

struct LogsView: View {
    @EnvironmentObject var state: AppState
    @State private var filter: LogCategory? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Logs").font(.title3.bold())
                Spacer()
                Button {
                    state.log.clear()
                } label: { Label("Clear", systemImage: "trash") }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    pill("All", filter == nil) { filter = nil }
                    ForEach(LogCategory.allCases, id: \.self) { cat in
                        pill(cat.displayName, filter == cat) { filter = cat }
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider()

            List(filtered) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(timeString(entry.timestamp))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    StatusPill(text: entry.category.displayName, tone: tone(for: entry.category))
                    Text(entry.message)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
        .padding(.top, 8)
    }

    private var filtered: [LogEntry] {
        guard let f = filter else { return state.log.entries.reversed() }
        return state.log.entries.filter { $0.category == f }.reversed()
    }

    private func pill(_ title: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(active ? Color.accentColor.opacity(0.20) : Color.gray.opacity(0.10))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tone(for c: LogCategory) -> StatusPill.Tone {
        switch c {
        case .error:   return .bad
        case .pairing: return .info
        case .network: return .info
        case .input:   return .neutral
        case .app:     return .neutral
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
