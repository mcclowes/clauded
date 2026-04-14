import SwiftUI

struct SettingsView: View {
    @Environment(HookInstallState.self) private var hookState
    @Environment(LaunchAtLoginController.self) private var launchAtLogin
    @Environment(QuickReplyStore.self) private var quickReplyStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 380)
    }

    private var generalTab: some View {
        Form {
            Section("Hook integration") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude Code hooks")
                            .font(.callout)
                        Text(statusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(buttonLabel) {
                        hookState.toggleInstallation()
                    }
                }
                if let error = hookState.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(
                    "Clauded writes entries to ~/.claude/settings.json so it can track session "
                        + "lifecycle events. Uninstalling removes them cleanly."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section("Quick reply") {
                Toggle(
                    "Enable quick-reply chips",
                    isOn: Binding(
                        get: { quickReplyStore.enabled },
                        set: { quickReplyStore.setEnabled($0) }
                    )
                )
                Text(
                    "Awaiting-input rows get small chips for each canned response. Clicking a chip "
                        + "focuses the terminal and types the response. Requires Accessibility permission."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                if quickReplyStore.enabled {
                    responsesEditor
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(
                    "Clauded will start automatically when you log in. You may need to approve "
                        + "it once in System Settings ▸ General ▸ Login Items."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @State private var draftResponses: String = ""

    private var responsesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "Responses (comma-separated)",
                text: Binding(
                    get: {
                        draftResponses.isEmpty ? quickReplyStore.responses.joined(separator: ", ") : draftResponses
                    },
                    set: { draftResponses = $0 }
                )
            )
            .onSubmit { commitResponses() }
            Button("Save responses") { commitResponses() }
                .controlSize(.small)
                .disabled(draftResponses.isEmpty)
        }
    }

    private func commitResponses() {
        let parts = draftResponses.split(separator: ",").map(String.init)
        quickReplyStore.setResponses(parts)
        draftResponses = ""
    }

    private var statusDescription: String {
        switch hookState.status {
        case .installed: "Installed — Clauded will receive all session events."
        case .notInstalled: "Not installed — Clauded can't see running sessions."
        case .partial: "Partially installed — some events are missing."
        }
    }

    private var buttonLabel: String {
        switch hookState.status {
        case .installed: "Uninstall"
        case .notInstalled: "Install"
        case .partial: "Repair"
        }
    }
}
