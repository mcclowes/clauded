import SwiftUI

struct SettingsView: View {
    @Environment(HookInstallState.self) private var hookState

    var body: some View {
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
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 240)
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
