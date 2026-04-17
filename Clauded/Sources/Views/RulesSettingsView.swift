import SwiftUI

/// Settings tab for auto-yes rules. Two sections:
///
/// 1. **Global** — default action (approve/skip) applied when nothing else matches,
///    plus an ordered rule list.
/// 2. **Codebases** — one entry per repo (click "+" to add). Each entry has a
///    kill-switch and its own rule list that takes priority over globals but falls
///    through to them on no-match.
///
/// Rule matching is a case-insensitive substring check against the permission-prompt
/// message Claude Code fires over the Notification hook. Patterns are raw strings;
/// regex is deliberately out of scope for v1 to keep the UI approachable.
struct RulesSettingsView: View {
    @Environment(AutoYesRulesStore.self) private var store
    @Environment(InstanceRegistry.self) private var registry

    var body: some View {
        Form {
            explainerSection
            globalDefaultSection
            globalRulesSection
            codebasesSection
        }
        .formStyle(.grouped)
    }

    private var explainerSection: some View {
        Section {
            Text(
                "Auto-yes rules decide what happens when an instance is armed and Claude asks for "
                    + "permission. Matches are case-insensitive substrings of the prompt message. "
                    + "`Approve` sends `1`. `Skip` leaves the prompt for you."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Global default

    private var globalDefaultSection: some View {
        Section("Default") {
            Picker(
                "When nothing matches",
                selection: Binding(
                    get: { store.globalDefaultAction },
                    set: { store.setGlobalDefaultAction($0) }
                )
            ) {
                Text("Approve").tag(AutoYesAction.approve)
                Text("Skip").tag(AutoYesAction.skip)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Global rules

    @State private var draftGlobalPattern: String = ""
    @State private var draftGlobalAction: AutoYesAction = .skip

    private var globalRulesSection: some View {
        Section("Global rules") {
            if store.globalRules.isEmpty {
                Text("No global rules. The default above applies to every prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.globalRules) { rule in
                    ruleRow(
                        rule: rule,
                        onUpdate: { store.updateGlobalRule($0) },
                        onDelete: { store.removeGlobalRule(id: rule.id) }
                    )
                }
            }
            HStack {
                TextField("Pattern (e.g. rm -rf, git push)", text: $draftGlobalPattern)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $draftGlobalAction) {
                    Text("Approve").tag(AutoYesAction.approve)
                    Text("Skip").tag(AutoYesAction.skip)
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    store.addGlobalRule(pattern: draftGlobalPattern, action: draftGlobalAction)
                    draftGlobalPattern = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(draftGlobalPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Codebases

    @State private var draftCodebaseName: String = ""
    @State private var expandedCodebase: UUID?

    private var codebasesSection: some View {
        Section("Codebases") {
            ForEach(store.codebases) { codebase in
                codebaseCard(codebase)
            }
            HStack {
                TextField(
                    "Directory name (e.g. clauded)",
                    text: $draftCodebaseName
                )
                .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(suggestedCodebaseNames, id: \.self) { name in
                        Button(name) { draftCodebaseName = name }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(suggestedCodebaseNames.isEmpty)
                Button {
                    if let added = store.addCodebase(name: draftCodebaseName) {
                        expandedCodebase = added.id
                    }
                    draftCodebaseName = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(draftCodebaseName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(
                "Codebase names match the basename of a session's working directory "
                    + "(case-insensitive). Rules here take priority; unmatched prompts fall "
                    + "through to the global list."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func codebaseCard(_ codebase: CodebaseRuleSet) -> some View {
        let isExpanded = expandedCodebase == codebase.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    expandedCodebase = isExpanded ? nil : codebase.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(codebase.name)
                            .font(.callout)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { codebase.enabled },
                        set: { store.setCodebaseEnabled(id: codebase.id, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Button(role: .destructive) {
                    store.removeCodebase(id: codebase.id)
                    if expandedCodebase == codebase.id { expandedCodebase = nil }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            if !codebase.enabled {
                Text("Disabled — auto-yes is suppressed for this codebase.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if isExpanded {
                codebaseRulesEditor(codebase)
            }
        }
        .padding(.vertical, 2)
    }

    @State private var draftCodebasePattern: [UUID: String] = [:]
    @State private var draftCodebaseAction: [UUID: AutoYesAction] = [:]

    private func codebaseRulesEditor(_ codebase: CodebaseRuleSet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if codebase.rules.isEmpty {
                Text("No rules — prompts fall through to the global list.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(codebase.rules) { rule in
                    ruleRow(
                        rule: rule,
                        onUpdate: { store.updateRule(inCodebase: codebase.id, rule: $0) },
                        onDelete: { store.removeRule(fromCodebase: codebase.id, ruleId: rule.id) }
                    )
                }
            }
            HStack {
                TextField(
                    "Pattern",
                    text: Binding(
                        get: { draftCodebasePattern[codebase.id] ?? "" },
                        set: { draftCodebasePattern[codebase.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                Picker(
                    "",
                    selection: Binding(
                        get: { draftCodebaseAction[codebase.id] ?? .skip },
                        set: { draftCodebaseAction[codebase.id] = $0 }
                    )
                ) {
                    Text("Approve").tag(AutoYesAction.approve)
                    Text("Skip").tag(AutoYesAction.skip)
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    let pattern = draftCodebasePattern[codebase.id] ?? ""
                    let action = draftCodebaseAction[codebase.id] ?? .skip
                    store.addRule(toCodebase: codebase.id, pattern: pattern, action: action)
                    draftCodebasePattern[codebase.id] = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(
                    (draftCodebasePattern[codebase.id] ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .isEmpty
                )
            }
        }
        .padding(.leading, 18)
    }

    // MARK: - Shared rule row

    private func ruleRow(
        rule: AutoYesRule,
        onUpdate: @escaping (AutoYesRule) -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack {
            TextField(
                "Pattern",
                text: Binding(
                    get: { rule.pattern },
                    set: { onUpdate(AutoYesRule(id: rule.id, pattern: $0, action: rule.action)) }
                )
            )
            .textFieldStyle(.roundedBorder)
            Picker(
                "",
                selection: Binding(
                    get: { rule.action },
                    set: { onUpdate(AutoYesRule(id: rule.id, pattern: rule.pattern, action: $0)) }
                )
            ) {
                Text("Approve").tag(AutoYesAction.approve)
                Text("Skip").tag(AutoYesAction.skip)
            }
            .labelsHidden()
            .frame(width: 110)
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
    }

    /// Distinct project basenames from live sessions — seeds the `+` menu so users can
    /// pick a repo they've actually been working in rather than typing it by hand.
    private var suggestedCodebaseNames: [String] {
        let existing = Set(store.codebases.map { $0.name.lowercased() })
        let names = registry.instances
            .map(\.projectName)
            .filter { !$0.isEmpty && !existing.contains($0.lowercased()) }
        var seen: Set<String> = []
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}
