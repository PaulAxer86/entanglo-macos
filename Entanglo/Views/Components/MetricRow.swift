//
// filename: MetricRow.swift
// path: Entanglo/Entanglo/Views/Components/MetricRow.swift
// purpose: Label + value pair used inside dashboard cards. The value can
//          render as plain monospaced text, a colored text pill, or an
//          icon-only pill (for compact on/off, link kind, etc).
//

import SwiftUI

struct MetricRow: View {
    let label: String
    let value: String
    var tone: StatusPill.Tone? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.subheadline)
            Spacer()
            if let systemImage, let tone {
                StatusPill(systemImage: systemImage, tone: tone, help: value)
            } else if let tone {
                StatusPill(text: value, tone: tone)
            } else {
                Text(value).font(.subheadline.monospacedDigit())
            }
        }
    }
}
