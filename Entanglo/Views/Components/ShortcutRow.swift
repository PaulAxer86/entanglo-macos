//
// filename: ShortcutRow.swift
// path: Entanglo/Entanglo/Views/Components/ShortcutRow.swift
// purpose: One row showing a labelled global shortcut on the Dashboard.
//

import SwiftUI

struct ShortcutRow: View {
    let label: String
    let combo: String
    let hint: String?

    init(label: String, combo: String, hint: String? = nil) {
        self.label = label
        self.combo = combo
        self.hint = hint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.weight(.semibold))
                if let hint = hint {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(combo)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
