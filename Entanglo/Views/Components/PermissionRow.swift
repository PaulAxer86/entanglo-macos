//
// filename: PermissionRow.swift
// path: Entanglo/Entanglo/Views/Components/PermissionRow.swift
// purpose: One row in the Settings → Permissions list. Shows a glyph for
//          the permission kind, the current status as a pill, why it's
//          needed, and a deep-link to System Settings whenever an anchor
//          exists (even when already granted, so the user can verify).
//

import SwiftUI

struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let requiredForCurrentRoles: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .frame(width: 24, alignment: .center)
                .foregroundStyle(iconTone)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.displayName).font(.subheadline.weight(.semibold))
                    StatusPill(systemImage: statusIcon, tone: statusTone, help: status.displayName)
                    if requiredForCurrentRoles && status == .denied {
                        StatusPill(systemImage: "exclamationmark.circle.fill",
                                   tone: .warn,
                                   help: "Required for your current roles")
                    } else if requiredForCurrentRoles && status == .unknown && !kind.isDetectable {
                        StatusPill(systemImage: "info.circle",
                                   tone: .neutral,
                                   help: "macOS doesn't expose this permission's state")
                    }
                }
                Text(kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if kind.systemSettingsAnchorExists {
                Button(status == .granted ? "Open in Settings" : "Open Settings",
                       action: onOpen)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconTone: Color {
        switch status {
        case .granted: return .green
        case .denied:  return requiredForCurrentRoles ? .orange : .secondary
        case .unknown: return .secondary
        }
    }

    private var statusIcon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied:  return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusTone: StatusPill.Tone {
        switch status {
        case .granted: return .ok
        case .denied:  return requiredForCurrentRoles ? .bad : .neutral
        case .unknown: return .neutral
        }
    }
}
