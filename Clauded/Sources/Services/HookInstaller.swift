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
///    changes don't orphan old entries. Duplicate marker entries are collapsed.
/// 3. **Respect existing user hooks.** We merge into the arrays that Claude Code
///    expects; we never replace the whole `hooks` object.
/// 4. **Clean uninstall.** Remove only entries whose command contains our marker.
///    Leave empty arrays cleaned up so the file stays tidy.
/// 5. **Back up once.** On first install, copy the original to `settings.json.clauded.bak`.
///    Never overwrite the backup on subsequent installs.
final class HookInstaller: Sendable {
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
        case shimMissing(path: String)

        var errorDescription: String? {
            switch self {
            case let .settingsFileUnparseable(underlying):
                "Could not parse ~/.claude/settings.json: \(underlying.localizedDescription)"
            case .settingsFileNotDictionary:
                "~/.claude/settings.json is not a JSON object"
            case let .writeFailed(underlying):
                "Failed to write ~/.claude/settings.json: \(underlying.localizedDescription)"
            case let .shimMissing(path):
                "clauded-notify shim not found at expected path: \(path)"
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
    private let validateShimExists: Bool

    init(settingsURL: URL? = nil, shimPath: String? = nil, validateShimExists: Bool = false) {
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL()
        self.shimPath = shimPath ?? Self.defaultShimPath()
        self.validateShimExists = validateShimExists
    }

    static func defaultSettingsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    /// Path to the notify shim inside the app bundle. In production, this is always
    /// inside the running app bundle's `Contents/MacOS`. In development/test environments
    /// where the shim isn't bundled, returns a sentinel path — callers that need a real
    /// shim should pass `validateShimExists: true` to surface a clear error.
    static func defaultShimPath() -> String {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: markerCommandName)?.path {
            return bundled
        }
        return "/usr/local/bin/\(markerCommandName)"
    }

    // MARK: - Install

    @discardableResult
    func install() throws -> [String] {
        if validateShimExists, !FileManager.default.fileExists(atPath: shimPath) {
            throw InstallError.shimMissing(path: shimPath)
        }
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
        let expectedCommand = "\(shimPath) "
        var healthy = 0
        var stale = 0
        for (claudeEvent, _) in Self.managedEvents {
            let array = (hooks[claudeEvent] as? [[String: Any]]) ?? []
            var foundFresh = false
            var foundStale = false
            for matcher in array {
                guard let inner = matcher["hooks"] as? [[String: Any]] else { continue }
                for hook in inner where isOurs(hook) {
                    if let command = hook["command"] as? String, command.hasPrefix(expectedCommand) {
                        foundFresh = true
                    } else {
                        foundStale = true
                    }
                }
            }
            if foundFresh, !foundStale {
                healthy += 1
            } else if foundFresh || foundStale {
                stale += 1
            }
        }
        if healthy == 0, stale == 0 { return .notInstalled }
        if healthy == Self.managedEvents.count { return .installed }
        return .partial
    }

    // MARK: - Merge helpers

    /// Ensure the event array has exactly one matcher block containing our hook entry.
    /// - Updates existing entries if the shim path has moved.
    /// - Collapses any duplicate marker entries into a single one.
    /// - Appends a new matcher block if none exist.
    /// Returns `true` if the array was mutated.
    private func ensureOurEntry(in eventArray: inout [[String: Any]], argument: String) -> Bool {
        let command = "\(shimPath) \(argument)"
        var mutated = false
        var keptOne = false
        var newArray: [[String: Any]] = []

        for var matcher in eventArray {
            var inner = (matcher["hooks"] as? [[String: Any]]) ?? []
            let before = inner.count
            if !keptOne, let firstOursIndex = inner.firstIndex(where: { isOurs($0) }) {
                // Update the first one we find, drop the rest in this block.
                if (inner[firstOursIndex]["command"] as? String) != command {
                    inner[firstOursIndex]["command"] = command
                    mutated = true
                }
                let firstOurs = inner[firstOursIndex]
                inner.removeAll(where: { isOurs($0) })
                inner.insert(firstOurs, at: firstOursIndex)
                keptOne = true
            } else {
                // Strip any of ours from remaining blocks — they're duplicates.
                inner.removeAll(where: { isOurs($0) })
            }
            if inner.count != before {
                mutated = true
            }
            if !inner.isEmpty {
                matcher["hooks"] = inner
                newArray.append(matcher)
            } else if matcher["hooks"] != nil {
                // Matcher only had our entry and we just stripped it — drop the block.
                mutated = true
            } else {
                newArray.append(matcher)
            }
        }

        if !keptOne {
            // No existing entry — append a new matcher block that only contains our hook.
            newArray.append([
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 5,
                ]],
            ])
            mutated = true
        }

        eventArray = newArray
        return mutated
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
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
            // Note: we intentionally do NOT sort keys. Users often keep ~/.claude under
            // version control, and `.sortedKeys` would churn the whole file on every
            // install. Pretty-print for readability only.
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted]
            )
            let tempName = "settings.clauded.tmp.\(UUID().uuidString).json"
            let tempURL = settingsURL.deletingLastPathComponent()
                .appendingPathComponent(tempName)
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
        do {
            try fm.copyItem(at: settingsURL, to: backupURL)
        } catch {
            Self.logger.error("Backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
