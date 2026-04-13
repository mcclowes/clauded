import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(KeyBindingsStore.self) private var store
    @Environment(GlobalHotkeyStore.self) private var globalStore
    @State private var capturingAction: KeyBindingAction?
    @State private var capturingGlobal: Bool = false
    @FocusState private var captureFocused: Bool

    var body: some View {
        Form {
            Section("Global shortcut") {
                HStack {
                    Text("Jump to next attention-needing session")
                        .font(.callout)
                    Spacer()
                    globalBindingButton
                }
                if globalStore.jumpToAttention != nil {
                    HStack {
                        Spacer()
                        Button("Clear") {
                            globalStore.setJumpToAttention(nil)
                            capturingGlobal = false
                        }
                        .controlSize(.small)
                    }
                }
                Text(
                    "Fires system-wide. Brings the oldest session waiting on input to the "
                        + "front; falls back to opening the Clauded panel. Requires "
                        + "Accessibility permission."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section("Panel shortcuts") {
                ForEach(KeyBindingAction.allCases, id: \.self) { action in
                    HStack {
                        Text(action.displayName)
                            .font(.callout)
                        Spacer()
                        bindingButton(for: action)
                    }
                }
                Text(
                    "Shortcuts fire while the Clauded popover is open. Press Escape "
                        + "during capture to cancel without changing the binding."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        store.resetToDefaults()
                        globalStore.resetToDefault()
                        capturingAction = nil
                        capturingGlobal = false
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .focusable()
        .focused($captureFocused)
        .onKeyPress(phases: .down) { press in
            // Prefer `.characters` so shifted letters land as uppercase; fall back
            // to `.key.character` for named keys (arrows, return) whose `.characters`
            // is empty.
            let char: Character = press.characters.first ?? press.key.character
            // Escape cancels capture.
            if char == Character("\u{1B}") {
                capturingAction = nil
                capturingGlobal = false
                return .handled
            }
            if capturingGlobal {
                globalStore.setJumpToAttention(
                    KeyBinding(character: char, modifiers: press.modifiers)
                )
                capturingGlobal = false
                return .handled
            }
            guard let action = capturingAction else { return .ignored }
            let newBinding = KeyBinding(character: char, modifiers: press.modifiers)
            store.setBinding(newBinding, for: action)
            capturingAction = nil
            return .handled
        }
    }

    private var globalBindingButton: some View {
        let label = capturingGlobal
            ? "Press any key…"
            : describe(globalStore.jumpToAttention)
        return Button {
            capturingGlobal = true
            capturingAction = nil
            captureFocused = true
        } label: {
            Text(label)
                .font(.system(.callout, design: .monospaced))
                .frame(minWidth: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            capturingGlobal ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func bindingButton(for action: KeyBindingAction) -> some View {
        let isCapturing = capturingAction == action
        let label = isCapturing ? "Press any key…" : describe(store.binding(for: action))
        return Button {
            capturingAction = action
            captureFocused = true
        } label: {
            Text(label)
                .font(.system(.callout, design: .monospaced))
                .frame(minWidth: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isCapturing ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func describe(_ binding: KeyBinding?) -> String {
        guard let binding else { return "Unbound" }
        var parts: [String] = []
        let modifiers = binding.eventModifiers
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(displayKey(binding.character))
        return parts.joined()
    }

    private func displayKey(_ char: String) -> String {
        switch char {
        case "\u{F700}": "↑"
        case "\u{F701}": "↓"
        case "\u{F702}": "←"
        case "\u{F703}": "→"
        case "\r": "↵"
        case " ": "Space"
        case "\t": "⇥"
        case "\u{7F}": "⌫"
        default: char.uppercased()
        }
    }
}
