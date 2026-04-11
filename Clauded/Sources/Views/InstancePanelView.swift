import AppKit
import SwiftUI

struct InstancePanelView: View {
    @Environment(InstanceRegistry.self) private var registry
    @Environment(HookInstallState.self) private var hookState
    @Environment(\.openSettings) private var openSettingsAction

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if hookState.status != .installed {
                Divider()
                hookWarningBanner
            }
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

    private var hookWarningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hooks not installed")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(hookWarningMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Reinstall") {
                hookState.reinstall()
            }
            .controlSize(.small)
            .disabled(hookState.isWorking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }

    private var hookWarningMessage: String {
        switch hookState.status {
        case .notInstalled:
            "Clauded isn't receiving session events. Reinstall to restore integration."
        case .partial:
            "Some hooks are missing or point at a stale path. Reinstall to repair."
        case .installed:
            ""
        }
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
                    InstanceRow(
                        instance: instance,
                        onTap: {
                            // Close the popover first so macOS's activation-restoration has
                            // already flushed by the time we bring the terminal to the front;
                            // otherwise the popover close fires after our activate and reverts
                            // focus to whichever app was frontmost before the popover opened.
                            onClose()
                            TerminalFocuser.focus(pid: instance.pid)
                        },
                        onToggleAutoYes: {
                            registry.setAutoYes(
                                sessionId: instance.id,
                                enabled: !instance.autoYesEnabled
                            )
                        }
                    )
                }
            }
            .padding(8)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                // Close the popover first so the Settings window can become key.
                // Then activate the app — accessory-policy apps don't take focus
                // on their own, and `openSettings` opens the window behind
                // whichever app was frontmost without an explicit activation.
                onClose()
                NSApp.activate(ignoringOtherApps: true)
                openSettingsAction()
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
