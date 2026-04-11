import SwiftUI

struct InstanceRow: View {
    let instance: ClaudeInstance
    let onTap: () -> Void
    let onToggleAutoYes: () -> Void

    @State private var isHovered = false

    /// `RelativeDateTimeFormatter` is expensive to construct; share one across all rows
    /// rather than creating a fresh instance on every render.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                stateIndicator
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.projectName)
                        .font(.system(.callout, design: .default, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                autoYesToggle
                Text(relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var autoYesToggle: some View {
        Button {
            onToggleAutoYes()
        } label: {
            Image(systemName: instance.autoYesEnabled ? "bolt.fill" : "bolt.slash")
                .font(.caption)
                .foregroundStyle(instance.autoYesEnabled ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(instance.autoYesEnabled
            ? "Auto-yes is on for this session — Clauded will answer permission prompts automatically"
            : "Auto-yes is off — click to let Clauded answer permission prompts for this session")
    }

    private var stateIndicator: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(stateColor.opacity(0.4), lineWidth: instance.needsAttention ? 4 : 0)
            )
    }

    private var stateColor: Color {
        switch instance.state {
        case .idle: .gray
        case .working: .blue
        case .awaitingInput: .orange
        case .finished: .green
        }
    }

    private var subtitle: String {
        if let msg = instance.lastMessage, !msg.isEmpty { return msg }
        return stateLabel
    }

    private var stateLabel: String {
        switch instance.state {
        case .idle: "Idle"
        case .working: "Working…"
        case .awaitingInput: "Waiting for input"
        case .finished: "Finished"
        }
    }

    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: instance.lastActivity, relativeTo: Date())
    }
}
