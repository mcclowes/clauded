import SwiftUI

struct InstancePanelView: View {
    @Environment(InstanceRegistry.self) private var registry

    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if registry.instances.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("Clauded")
                .font(.headline)
            Spacer()
            if registry.needsAttentionCount > 0 {
                Label(
                    "\(registry.needsAttentionCount) waiting",
                    systemImage: "bell.badge.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Claude Code sessions")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Start `claude` in a terminal to see it here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(registry.sortedInstances) { instance in
                    InstanceRow(instance: instance) {
                        TerminalFocuser.focus(pid: instance.pid)
                        onClose()
                    }
                }
            }
            .padding(8)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Spacer()

            Button("Quit Clauded") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
