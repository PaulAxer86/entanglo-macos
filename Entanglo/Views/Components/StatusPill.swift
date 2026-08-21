//
// filename: StatusPill.swift
// path: Entanglo/Entanglo/Views/Components/StatusPill.swift
// purpose: Compact rounded label that conveys a status with a tint color.
//          Supports text-only, icon-only, or icon+text variants. Use the
//          icon variants for short, recurring statuses (on/off, link
//          quality) to keep dashboards scannable.
//

import SwiftUI

struct StatusPill: View {
    enum Tone { case ok, warn, bad, neutral, info }

    let text: String?
    let systemImage: String?
    let tone: Tone
    var help: String?

    init(text: String, tone: Tone) {
        self.text = text
        self.systemImage = nil
        self.tone = tone
        self.help = nil
    }

    init(systemImage: String, tone: Tone, help: String? = nil) {
        self.text = nil
        self.systemImage = systemImage
        self.tone = tone
        self.help = help
    }

    init(systemImage: String, text: String, tone: Tone) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.help = nil
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(iconFont)
            }
            if let text {
                Text(text)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, text == nil ? 9 : 9)
        .padding(.vertical, text == nil ? 6 : 5)
        .background(background)
        .foregroundColor(foreground)
        .clipShape(Capsule())
        .help(help ?? text ?? "")
    }

    private var iconFont: Font {
        // Icon-only pills get a bit larger so they read at a glance.
        text == nil ? .body.weight(.semibold) : .caption.weight(.semibold)
    }

    private var background: some View {
        Group {
            switch tone {
            case .ok:      Color.green.opacity(0.18)
            case .warn:    Color.orange.opacity(0.20)
            case .bad:     Color.red.opacity(0.18)
            case .info:    Color.blue.opacity(0.18)
            case .neutral: Color.gray.opacity(0.18)
            }
        }
    }

    private var foreground: Color {
        switch tone {
        case .ok:      return .green
        case .warn:    return .orange
        case .bad:     return .red
        case .info:    return .blue
        case .neutral: return .secondary
        }
    }
}
