@testable import Clauded
import Foundation
import XCTest

@MainActor
final class HookInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var settingsURL: URL!
    private var shimPath: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clauded-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent("settings.json")
        shimPath = "/tmp/clauded-notify"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Install

    func testInstallCreatesAllManagedEvents() throws {
        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        let installed = try installer.install()
        XCTAssertEqual(Set(installed), Set(HookInstaller.managedEvents.map(\.claudeCodeEvent)))

        let root = try loadSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for (event, _) in HookInstaller.managedEvents {
            XCTAssertNotNil(hooks[event], "Missing event: \(event)")
        }
    }

    func testInstallIsIdempotent() throws {
        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        _ = try installer.install()
        let secondPass = try installer.install()
        XCTAssertTrue(secondPass.isEmpty, "Second install should be a no-op")

        // And the file should still have exactly one entry per event.
        let root = try loadSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for (event, _) in HookInstaller.managedEvents {
            let array = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let ours = array.compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap(\.self)
                .filter { ($0["command"] as? String)?.contains(HookInstaller.markerCommandName) == true }
            XCTAssertEqual(ours.count, 1, "Duplicate entries after idempotent install for \(event)")
        }
    }

    func testInstallPreservesExistingUserHooks() throws {
        let existing: [String: Any] = [
            "hooks": [
                "Notification": [
                    [
                        "matcher": "*",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "/usr/local/bin/user-custom-script.sh",
                            ],
                        ],
                    ],
                ],
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "jq -r '.tool_input.command' >> ~/.claude/bash-log.txt",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try writeSettings(existing)

        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        _ = try installer.install()

        let root = try loadSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])

        // Existing PreToolUse hook must be untouched.
        let preTool = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preTool.count, 1)
        let preInner = try XCTUnwrap(preTool[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(preInner[0]["command"] as? String, "jq -r '.tool_input.command' >> ~/.claude/bash-log.txt")

        // Notification array should contain BOTH the user's hook and ours.
        let notif = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let allCommands: [String] = notif
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap(\.self)
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(allCommands.contains("/usr/local/bin/user-custom-script.sh"))
        XCTAssertTrue(allCommands.contains(where: { $0.contains(HookInstaller.markerCommandName) }))
    }

    func testInstallUpdatesShimPathIfAppMoved() throws {
        let installer1 = HookInstaller(settingsURL: settingsURL, shimPath: "/old/path/clauded-notify")
        _ = try installer1.install()

        let installer2 = HookInstaller(settingsURL: settingsURL, shimPath: "/new/path/clauded-notify")
        let updated = try installer2.install()
        XCTAssertFalse(updated.isEmpty, "Moving the shim path should rewrite all entries")

        let root = try loadSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let notif = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let commands: [String] = notif
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap(\.self)
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains(where: { $0.contains("/new/path/clauded-notify") }))
        XCTAssertFalse(commands.contains(where: { $0.contains("/old/path/clauded-notify") }))
    }

    func testInstallBacksUpOriginal() throws {
        let original: [String: Any] = ["hooks": ["Notification": [[String: Any]]()]]
        try writeSettings(original)

        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        _ = try installer.install()

        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.clauded.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "Backup should exist")

        // Backup must contain the pre-install content, not the post-install content.
        let backupData = try Data(contentsOf: backupURL)
        let backup = try JSONSerialization.jsonObject(with: backupData) as? [String: Any]
        let backupHooks = backup?["hooks"] as? [String: Any]
        let notif = backupHooks?["Notification"] as? [[String: Any]]
        XCTAssertEqual(notif?.count, 0, "Backup should reflect the pre-install state")
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyOurEntries() throws {
        let userCommand = "/usr/local/bin/user-custom-script.sh"
        let existing: [String: Any] = [
            "hooks": [
                "Notification": [
                    [
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": userCommand,
                        ]],
                    ],
                ],
            ],
        ]
        try writeSettings(existing)

        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        _ = try installer.install()
        _ = try installer.uninstall()

        let root = try loadSettings()
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let notif = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])

        // User's hook should still be there; ours should be gone.
        let allCommands: [String] = notif
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap(\.self)
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(allCommands.contains(userCommand))
        XCTAssertFalse(allCommands.contains(where: { $0.contains(HookInstaller.markerCommandName) }))

        // Events we created exclusively should be cleaned up entirely.
        XCTAssertNil(hooks["SessionStart"], "Empty SessionStart array should be removed")
    }

    func testUninstallOnMissingFileIsNoOp() throws {
        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        XCTAssertNoThrow(try installer.uninstall())
    }

    // MARK: - Status

    func testStatusReflectsInstallState() throws {
        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        XCTAssertEqual(installer.status(), .notInstalled)
        _ = try installer.install()
        XCTAssertEqual(installer.status(), .installed)
        _ = try installer.uninstall()
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testInstallCreatesParentDirectoryWhenMissing() throws {
        let nestedURL = tempDir.appendingPathComponent("fresh/.claude/settings.json")
        let installer = HookInstaller(settingsURL: nestedURL, shimPath: shimPath)
        XCTAssertNoThrow(try installer.install())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
    }

    func testUnparseableSettingsThrows() throws {
        try "not valid json {{{".write(to: settingsURL, atomically: true, encoding: .utf8)
        let installer = HookInstaller(settingsURL: settingsURL, shimPath: shimPath)
        XCTAssertThrowsError(try installer.install()) { error in
            guard case HookInstaller.InstallError.settingsFileUnparseable = error else {
                XCTFail("Expected settingsFileUnparseable, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func loadSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "test", code: 0)
        }
        return dict
    }
}
