import Foundation
import Observation
import os

/// Persisted policy for auto-yes: global rules + default, plus per-codebase overrides.
///
/// Resolution order for a single permission prompt:
///   1. If a codebase entry matches the session's projectDir basename and is disabled,
///      return `.skip` (codebase kill-switch beats all rules).
///   2. Else the first matching rule wins, searching the codebase's rules before
///      the globals — codebase rules take priority but fall through to globals when
///      nothing matches.
///   3. Else `globalDefaultAction`.
///
/// Persistence is a single JSON blob in `UserDefaults` (simple, schema-stable, easy to
/// roundtrip in tests). Rules are small and edited rarely; no need for a file or DB.
@MainActor
@Observable
final class AutoYesRulesStore {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "AutoYesRulesStore")
    private static let storageKey = "com.mcclowes.clauded.autoYesRules.v1"

    private(set) var globalRules: [AutoYesRule]
    private(set) var globalDefaultAction: AutoYesAction
    private(set) var codebases: [CodebaseRuleSet]

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if let data = storage.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            globalRules = decoded.globalRules
            globalDefaultAction = decoded.globalDefaultAction
            codebases = decoded.codebases
        } else {
            globalRules = []
            globalDefaultAction = .approve
            codebases = []
        }
    }

    /// Decides what to do for a permission prompt. Pure function of current policy;
    /// safe to call off the hot path.
    func resolveAction(message: String, projectDir: String?) -> AutoYesAction {
        if let codebase = codebases.first(where: { $0.matches(projectDir: projectDir) }) {
            if !codebase.enabled { return .skip }
            if let match = codebase.rules.first(where: { $0.matches(message: message) }) {
                return match.action
            }
        }
        if let match = globalRules.first(where: { $0.matches(message: message) }) {
            return match.action
        }
        return globalDefaultAction
    }

    // MARK: - Global mutations

    func setGlobalDefaultAction(_ action: AutoYesAction) {
        globalDefaultAction = action
        persist()
    }

    func setGlobalRules(_ rules: [AutoYesRule]) {
        globalRules = sanitize(rules)
        persist()
    }

    func addGlobalRule(pattern: String, action: AutoYesAction) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        globalRules.append(AutoYesRule(pattern: trimmed, action: action))
        persist()
    }

    func updateGlobalRule(_ rule: AutoYesRule) {
        guard let index = globalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        globalRules[index] = AutoYesRule(id: rule.id, pattern: trimmed, action: rule.action)
        persist()
    }

    func removeGlobalRule(id: UUID) {
        globalRules.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Codebase mutations

    @discardableResult
    func addCodebase(name: String) -> CodebaseRuleSet? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Prevent duplicates (case-insensitive) — first one wins at resolution time so
        // a second entry is dead weight and confusing in the UI.
        if codebases.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return nil
        }
        let entry = CodebaseRuleSet(name: trimmed)
        codebases.append(entry)
        persist()
        return entry
    }

    func renameCodebase(id: UUID, to newName: String) {
        guard let index = codebases.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Prevent collisions with another codebase after rename.
        if codebases.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return
        }
        codebases[index].name = trimmed
        persist()
    }

    func setCodebaseEnabled(id: UUID, enabled: Bool) {
        guard let index = codebases.firstIndex(where: { $0.id == id }) else { return }
        codebases[index].enabled = enabled
        persist()
    }

    func removeCodebase(id: UUID) {
        codebases.removeAll { $0.id == id }
        persist()
    }

    func addRule(toCodebase codebaseId: UUID, pattern: String, action: AutoYesAction) {
        guard let index = codebases.firstIndex(where: { $0.id == codebaseId }) else { return }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        codebases[index].rules.append(AutoYesRule(pattern: trimmed, action: action))
        persist()
    }

    func updateRule(inCodebase codebaseId: UUID, rule: AutoYesRule) {
        guard let codebaseIndex = codebases.firstIndex(where: { $0.id == codebaseId }),
              let ruleIndex = codebases[codebaseIndex].rules.firstIndex(where: { $0.id == rule.id })
        else { return }
        let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        codebases[codebaseIndex].rules[ruleIndex] = AutoYesRule(
            id: rule.id,
            pattern: trimmed,
            action: rule.action
        )
        persist()
    }

    func removeRule(fromCodebase codebaseId: UUID, ruleId: UUID) {
        guard let index = codebases.firstIndex(where: { $0.id == codebaseId }) else { return }
        codebases[index].rules.removeAll { $0.id == ruleId }
        persist()
    }

    // MARK: - Persistence

    private func sanitize(_ rules: [AutoYesRule]) -> [AutoYesRule] {
        rules.compactMap { rule in
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AutoYesRule(id: rule.id, pattern: trimmed, action: rule.action)
        }
    }

    private func persist() {
        let state = PersistedState(
            globalRules: globalRules,
            globalDefaultAction: globalDefaultAction,
            codebases: codebases
        )
        do {
            let data = try JSONEncoder().encode(state)
            storage.set(data, forKey: Self.storageKey)
        } catch {
            Self.logger.error("Failed to persist auto-yes rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct PersistedState: Codable {
        var globalRules: [AutoYesRule]
        var globalDefaultAction: AutoYesAction
        var codebases: [CodebaseRuleSet]
    }
}
