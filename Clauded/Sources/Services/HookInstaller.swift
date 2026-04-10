import Foundation
import os

/// Installs Clauded's hook entries into Claude Code's settings file.
///
/// The design rules, in order of importance:
///
/// 1. **Never corrupt the user's settings.** JSON is parsed with JSONSerialization,
///    mutated in memory, and written back via a temp file + atomic rename. If parsing
///    fails we bail out immediately rather than overwriting a file we don't understand.
/// 2. **Idempotent.** Running install twice is a no-op. We match on the marker path
///    `clauded-notify`, not on the full command string, so future command-string
///    changes don't orphan old entries.
/// 3. **Respect existing user hooks.** We merge into the arrays that Claude Code
///    expects; we never replace the whole `hooks` object.
/// 4. **Clean uninstall.** Remove only entries whose command contains our marker.
///    Leave empty arrays cleaned up so the file stays tidy.
/// 5. **Back up once.** On first install, copy the original to `settings.json.clauded.bak`.
///    Never overwrite the backup on subsequent installs.
@MainActor
final class HookInstaller {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "HookInstaller")

    /// Substring we match on to identify entries we own. The shim binary is always
    /// installed with this filename, so this is a stable identifier across versions.
    static let markerCommandName = "clauded-notify"

    /// Hook events Clauded installs. Matches the `HookEventKind` cases 1:1 and is
    /// ordered so the generated settings file reads predictably.
    static let managedEvents: [(claudeCodeEvent: String, argument: String)] = [
        ("SessionStart", HookEventKind.sessionStart.rawValue),
        ("SessionEnd", HookEventKind.sessionEnd.rawValue),
        ("Notification", HookEventKind.notification.rawValue),
        ("Stop", HookEventKind.stop.rawValue),
        ("UserPromptSubmit", HookEventKind.userPromptSubmit.rawValue),
    ]

    enum InstallError: Error, LocalizedError {
        case settingsFileUnparseable(underlying: Error)
        case settingsFileNotDictionary
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .settingsFileUnparseable(underlying):
                "Could not parse ~/.claude/settings.json: \(underlying.localizedDescription)"
            case .settingsFileNotDictionary:
                "~/.claude/settings.json is not a JSON object"
            case let .writeFailed(underlying):
                "Failed to write ~/.claude/settings.json: \(underlying.localizedDescription)"
            }
        }
    }

    enum InstallStatus: Equatable {
        case installed
        case notInstalled
        case partial
    }

    private let settingsURL: URL
    private let shimPath: String

    init(settingsURL: URL? = nil, shimPath: String? = nil) {
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL()
        self.shimPath = shimPath ?? Self.defaultShimPath()
    }

    static func defaultSettingsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    /// Path to the notify shim inside the app bundle. Resolved at runtime so tests can
    /// inject a fixture path.
    static func defaultShimPath() -> String {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: markerCommandName)?.path {
            return bundled
        }
        // Fallback for dev/test environments where the tool isn't bundled yet.
        return "/usr/local/bin/\(markerCommandName)"
    }

    // MARK: - Install

    @discardableResult
    func install() throws -> [String] {
        try ensureParentDirectoryExists()
        var root = try loadSettings()
        backupIfNeeded()

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var mutatedEvents: [String] = []

        for (claudeEvent, argument) in Self.managedEvents {
            var eventArray = (hooks[claudeEvent] as? [[String: Any]]) ?? []
            if ensureOurEntry(in: &eventArray, argument: argument) {
                mutatedEvents.append(claudeEvent)
            }
            hooks[claudeEvent] = eventArray
        }

        if mutatedEvents.isEmpty {
            Self.logger.info("HookInstaller: no changes needed (already installed)")
            return []
        }

        root["hooks"] = hooks
        try writeSettings(root)
        Self.logger
            .info("HookInstaller: installed for events \(mutatedEvents.joined(separator: ", "), privacy: .public)")
        return mutatedEvents
    }

    // MARK: - Uninstall

    @discardableResult
    func uninstall() throws -> [String] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return []
        }
        var root = try loadSettings()
        guard var hooks = root["hooks"] as? [String: Any] else {
            return []
        }

        var removedEvents: [String] = []

        for (claudeEvent, _) in Self.managedEvents {
            guard var eventArray = hooks[claudeEvent] as? [[String: Any]] else { continue }
            let countBefore = eventArray.count
            eventArray = eventArray.compactMap { stripOurHooks(from: $0) }
            if eventArray.count != countBefore {
                removedEvents.append(claudeEvent)
            }
            if eventArray.isEmpty {
                hooks.removeValue(forKey: claudeEvent)
            } else {
                hooks[claudeEvent] = eventArray
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        if removedEvents.isEmpty {
            return []
        }

        try writeSettings(root)
        Self.logger
            .info("HookInstaller: uninstalled from events \(removedEvents.joined(separator: ", "), privacy: .public)")
        return removedEvents
    }

    // MARK: - Status

    func status() -> InstallStatus {
        guard let root = try? loadSettings(),
              let hooks = root["hooks"] as? [String: Any]
        else {
            return .notInstalled
        }
        var installed = 0
        for (claudeEvent, _) in Self.managedEvents {
            let array = (hooks[claudeEvent] as? [[String: Any]]) ?? []
            if array.contains(where: { matcher in
                guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
                return inner.contains(where: { self.isOurs($0) })
            }) {
                installed += 1
            }
        }
        if installed == 0 { return .notInstalled }
        if installed == Self.managedEvents.count { return .installed }
        return .partial
    }

    // MARK: - Merge helpers

    /// Ensure the event array has a matcher block containing our hook entry. Returns
    /// `true` if the array was mutated.
    private func ensureOurEntry(in eventArray: inout [[String: Any]], argument: String) -> Bool {
        let command = "\(shimPath) \(argument)"

        // Check every matcher block already in the array; if any contains our marker,
        // update its command to the current path (handles app-move / reinstall) and exit.
        for matcherIndex in eventArray.indices {
            guard var inner = eventArray[matcherIndex]["hooks"] as? [[String: Any]] else { continue }
            for hookIndex in inner.indices where isOurs(inner[hookIndex]) {
                if (inner[hookIndex]["command"] as? String) == command {
                    return false
                }
                inner[hookIndex]["command"] = command
                eventArray[matcherIndex]["hooks"] = inner
                return true
            }
        }

        // No existing entry — append a new matcher block that only contains our hook.
        // Keeping it in its own block means the user can freely reorder/edit their
        // own matchers without us stepping on them.
        eventArray.append([
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": 5,
            ]],
        ])
        return true
    }

    private func stripOurHooks(from matcher: [String: Any]) -> [String: Any]? {
        guard var inner = matcher["hooks"] as? [[String: Any]] else {
            return matcher
        }
        inner.removeAll(where: { isOurs($0) })
        if inner.isEmpty {
            // Matcher block only contained our entry — drop the whole block.
            return nil
        }
        var next = matcher
        next["hooks"] = inner
        return next
    }

    private func isOurs(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(Self.markerCommandName)
    }

    // MARK: - Disk I/O

    private func ensureParentDirectoryExists() throws {
        let parent = settingsURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    private func loadSettings() throws -> [String: Any] {
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw InstallError.settingsFileUnparseable(underlying: error)
        }
        if data.isEmpty { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw InstallError.settingsFileUnparseable(underlying: error)
        }
        guard let dict = parsed as? [String: Any] else {
            throw InstallError.settingsFileNotDictionary
        }
        return dict
    }

    private func writeSettings(_ root: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            let tempURL = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.clauded.tmp.json")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(
                settingsURL,
                withItemAt: tempURL,
                options: .usingNewMetadataOnly
            )
        } catch {
            throw InstallError.writeFailed(underlying: error)
        }
    }

    private func backupIfNeeded() {
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.clauded.bak")
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              !fm.fileExists(atPath: backupURL.path)
        else { return }
        try? fm.copyItem(at: settingsURL, to: backupURL)
    }
}
