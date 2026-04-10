import AppKit
import Foundation
import os

/// Best-effort focus of the terminal window running a given Claude Code session.
///
/// Strategy: walk the pid's ancestors until we find a process whose bundle id we
/// recognise (Terminal.app, iTerm, Ghostty, WezTerm, Alacritty, Warp), then
/// activate that app. Per-window focus is terminal-specific and not always
/// scriptable without accessibility permissions, so the v1 contract is:
/// "clicking an instance brings its terminal app to the front."
@MainActor
enum TerminalFocuser {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "TerminalFocuser")

    private static let knownTerminalBundleIds: Set<String> = [
        "com.apple.Terminal",
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
        if let app = NSRunningApplication(processIdentifier: terminalPid) {
            app.activate(options: [])
        }
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
