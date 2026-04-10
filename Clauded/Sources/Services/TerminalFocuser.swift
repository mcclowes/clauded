import AppKit
import Darwin
import Foundation
import os

/// Best-effort focus of the terminal window running a given Claude Code session.
///
/// Strategy: walk the pid's ancestors until we find a process whose bundle id we
/// recognise (Terminal.app, iTerm, Ghostty, WezTerm, Alacritty, Warp), then
/// activate that app. For Terminal.app we additionally resolve the pid's
/// controlling tty and drive AppleScript to select the matching tab; other
/// terminals still fall back to app-level activation.
@MainActor
enum TerminalFocuser {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "TerminalFocuser")

    private static let appleTerminalBundleId = "com.apple.Terminal"

    private static let knownTerminalBundleIds: Set<String> = [
        appleTerminalBundleId,
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "dev.warp.Warp-Stable",
    ]

    static func focus(pid: Int32?) {
        guard let pid else { return }
        guard let terminalPid = findAncestorTerminalPid(startingFrom: pid) else {
            Self.logger.info("No known terminal ancestor found for pid \(pid)")
            return
        }
        guard let app = NSRunningApplication(processIdentifier: terminalPid) else { return }
        if app.bundleIdentifier == appleTerminalBundleId, let tty = controllingTTY(of: pid) {
            focusAppleTerminalTab(tty: tty, fallback: app)
            return
        }
        app.activate(options: [])
    }

    private static func focusAppleTerminalTab(tty: String, fallback: NSRunningApplication) {
        let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(escapedTTY)" then
                            set selected of t to true
                            set index of w to 1
                            set frontmost of w to true
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            let logger = Logger(subsystem: "com.mcclowes.clauded", category: "TerminalFocuser")
            logger.error("Terminal.app tab focus AppleScript failed: \(error)")
            await MainActor.run { fallback.activate(options: []) }
        }
    }

    /// Returns the path to the controlling tty (e.g. `/dev/ttys003`) for a pid, or nil if the
    /// process has no controlling terminal.
    private static func controllingTTY(of pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != -1 else { return nil }
        guard let cstr = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: cstr)
    }

    /// Walk the process tree upward looking for a process whose bundle id matches a
    /// known terminal. The kernel's `kinfo_proc` gives us each pid's parent, so this
    /// is an O(depth) loop — typically 2-3 hops (shell → terminal).
    private static func findAncestorTerminalPid(startingFrom pid: Int32) -> Int32? {
        var current = pid
        for _ in 0..<16 {
            if let bundleId = NSRunningApplication(processIdentifier: current)?.bundleIdentifier,
               knownTerminalBundleIds.contains(bundleId)
            {
                return current
            }
            guard let parent = parentPid(of: current), parent > 1, parent != current else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
