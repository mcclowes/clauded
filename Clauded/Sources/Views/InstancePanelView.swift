import AppKit
import SwiftUI

struct InstancePanelView: View {
    @Environment(InstanceRegistry.self) private var registry
    @Environment(HookInstallState.self) private var hookState
    @Environment(AccessibilityPermissionState.self) private var accessibilityState
    @Environment(KeyBindingsStore.self) private var keyBindings
    @Environment(QuickReplyController.self) private var quickReply
    @Environment(\.openSettings) private var openSettingsAction

    @State private var selectedId: String?
    @FocusState private var panelFocused: Bool

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if hookState.status != .installed {
                Divider()
                hookWarningBanner
            }
            if !accessibilityState.isTrusted {
                Divider()
                accessibilityWarningBanner
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
        .focusable()
        .focused($panelFocused)
        .onAppear {
            panelFocused = true
            // Re-poll each time the popover opens so the banner disappears as soon
            // as the user grants access in System Settings — no restart needed.
            accessibilityState.refresh()
        }
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let char: Character = press.characters.first ?? press.key.character
        guard let action = keyBindings.action(forCharacter: char, modifiers: press.modifiers) else {
            return .ignored
        }
        perform(action)
        return .handled
    }

    private func perform(_ action: KeyBindingAction) {
        let rows = registry.sortedInstances
        guard !rows.isEmpty else { return }

        switch action {
        case .selectNext:
            selectedId = neighborId(in: rows, from: selectedId, offset: 1)
        case .selectPrevious:
            selectedId = neighborId(in: rows, from: selectedId, offset: -1)
        case .activate:
            guard let instance = resolvedSelection(rows) else { return }
            onClose()
            TerminalFocuser.focus(pid: instance.pid)
        case .toggleAutoYes:
            guard let instance = resolvedSelection(rows) else { return }
            registry.setAutoYes(
                sessionId: instance.id,
                enabled: !instance.autoYesEnabled
            )
        }
    }

    private func resolvedSelection(_ rows: [ClaudeInstance]) -> ClaudeInstance? {
        if let selectedId, let found = rows.first(where: { $0.id == selectedId }) {
            return found
        }
        return rows.first
    }

    private func neighborId(
        in rows: [ClaudeInstance],
        from current: String?,
        offset: Int
    ) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let current, let index = rows.firstIndex(where: { $0.id == current }) else {
            return offset >= 0 ? rows.first?.id : rows.last?.id
        }
        let next = (index + offset + rows.count) % rows.count
        return rows[next].id
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

    private var accessibilityWarningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission needed")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(
                    "Auto-yes can't send keystrokes until Clauded is granted Accessibility " +
                        "access in System Settings → Privacy & Security → Accessibility."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open settings") {
                accessibilityState.openSystemSettings()
            }
            .controlSize(.small)
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
            turboToggle
        }
        .padding(12)
    }

    private var turboToggle: some View {
        Button {
            registry.setTurbo(enabled: !registry.turboEnabled)
        } label: {
            Label("Turbo", systemImage: registry.turboEnabled ? "bolt.fill" : "bolt.slash")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(registry.turboEnabled ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(registry.turboEnabled
            ? "Turbo on — auto-yes armed for every current and new session"
            : "Turbo off — click to auto-yes every current and new session")
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
                        isSelected: instance.id == selectedId,
                        quickReplies: quickReply.store.enabled ? quickReply.store.responses : [],
                        onTap: {
                            // Keep mouse and keyboard selection in sync so a subsequent
                            // keypress picks up where the user clicked.
                            selectedId = instance.id
                            // Crashed rows have no live terminal to focus — tapping
                            // dismisses the marker instead, matching the issue spec.
                            if instance.state == .crashed {
                                registry.remove(sessionId: instance.id)
                                return
                            }
                            // Close the popover first so macOS's activation-restoration has
                            // already flushed by the time we bring the terminal to the front;
                            // otherwise the popover close fires after our activate and reverts
                            // focus to whichever app was frontmost before the popover opened.
                            onClose()
                            TerminalFocuser.focus(pid: instance.pid)
                        },
                        onToggleAutoYes: {
                            selectedId = instance.id
                            registry.setAutoYes(
                                sessionId: instance.id,
                                enabled: !instance.autoYesEnabled
                            )
                        },
                        onQuickReply: { reply in
                            selectedId = instance.id
                            quickReply.send(reply, to: instance)
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
