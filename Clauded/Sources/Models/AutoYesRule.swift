import Foundation

/// What to do when an auto-yes rule matches (or when nothing matches, via `defaultAction`).
///
/// Deliberately only two cases in v1. `.approve` sends `1` — always the first option in
/// Claude Code's permission prompt regardless of whether the prompt is 2-option (yes/no)
/// or 3-option (yes/yes+allowlist/no). A `.deny` action would need to send different
/// keys for each shape and we can't tell them apart from the Notification-hook message,
/// so denial is left to the human for now.
enum AutoYesAction: String, Codable, CaseIterable, Equatable {
    /// Send `1` + Return. Safe in both 2-option and 3-option permission prompts.
    case approve
    /// Do nothing; leave the prompt for the user to answer.
    case skip
}

/// A single match-and-act rule. `pattern` is a case-insensitive substring check against
/// the Notification-hook message (e.g. `"Claude needs your permission to use Bash(git push)"`).
/// Empty patterns match nothing — guarded at store level so the UI can't wedge in a
/// catch-all by mistake.
struct AutoYesRule: Codable, Identifiable, Equatable {
    var id: UUID
    var pattern: String
    var action: AutoYesAction

    init(id: UUID = UUID(), pattern: String, action: AutoYesAction) {
        self.id = id
        self.pattern = pattern
        self.action = action
    }

    func matches(message: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return message.range(of: pattern, options: .caseInsensitive) != nil
    }
}

/// Per-codebase override. `name` matches the basename of a session's `projectDir`
/// (case-insensitive exact). Basename keeps the UI ergonomic — users think in repo
/// names, not absolute paths — at the cost of collisions when two repos share a name.
/// That tradeoff is documented in the settings UI.
struct CodebaseRuleSet: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// When `false`, auto-yes is forcibly suppressed for this codebase regardless of any
    /// matching rule. Gives users a single kill-switch per repo without having to clear
    /// their rule list.
    var enabled: Bool
    var rules: [AutoYesRule]

    init(id: UUID = UUID(), name: String, enabled: Bool = true, rules: [AutoYesRule] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.rules = rules
    }

    func matches(projectDir: String?) -> Bool {
        guard let projectDir, !name.isEmpty else { return false }
        let basename = (projectDir as NSString).lastPathComponent
        return basename.caseInsensitiveCompare(name) == .orderedSame
    }
}
