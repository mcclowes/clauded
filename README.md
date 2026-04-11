# Clauded

[![Release](https://github.com/mcclowes/clauded/actions/workflows/release.yml/badge.svg)](https://github.com/mcclowes/clauded/actions/workflows/release.yml)

Native macOS menu bar app for managing Claude Code instances running in your terminal.

Clauded lives in your menu bar and gives you a live view of every Claude Code session across every project, highlights the ones waiting on your input, and jumps you straight to the terminal window that needs attention. No Dock icon, no polling, no configuration — hooks into Claude Code's own event system.

## Install

**Homebrew** (recommended):

```bash
brew install mcclowes/clauded/clauded
```

**Manual download:** Grab the latest `Clauded.zip` from [GitHub Releases](https://github.com/mcclowes/clauded/releases), unzip, and drag Clauded to your Applications folder.

Requires **macOS 15.0 (Sequoia)** or later and [Claude Code](https://docs.claude.com/claude-code) installed.

## Getting started

1. Launch Clauded — it appears as an icon in your menu bar (no Dock icon).
2. On first run Clauded offers to install its hooks into `~/.claude/settings.json`. Accept, and it's wired up — no manual config.
3. Start a Claude Code session anywhere. Clauded picks it up automatically.
4. Click the menu bar icon to see the live session list. Click a row to focus the terminal window running that session.

If you ever want to remove the hooks, open **Settings** → **Uninstall hooks**. Clauded removes only its own entries and leaves any other hooks you have in place untouched.

## Features

- **Live session list** — One row per running Claude Code instance, grouped by project, sorted so anything waiting on you floats to the top.
- **Attention state** — The menu bar icon flips to an attention glyph the instant any session needs input, with a per-instance badge in the popover.
- **Jump-to-terminal** — Click a row to focus the terminal window running that session. Works with Terminal.app (down to the exact tab via AppleScript), iTerm2, Ghostty, WezTerm, Alacritty, and Warp.
- **Hook auto-install** — One-click install into `~/.claude/settings.json`. Idempotent, preserves any existing hooks you have configured, and backs up the original.
- **Orphan reaper** — If a terminal window is closed abruptly and the `SessionEnd` hook never fires, Clauded reconciles against the live process table every 30 seconds and drops dead rows. PID reuse is detected via process start-time, so zombie rows can't come back.
- **Zero third-party dependencies** — Pure Swift 6 + SwiftUI. No bundled runtimes, no network calls, no telemetry.

## Privacy & security

Clauded runs entirely on your Mac. It does not make network requests, does not send telemetry, and has no cloud component.

- **Local IPC only** — Hook events travel over a Unix domain datagram socket at `~/Library/Application Support/Clauded/daemon.sock`, chmod'd to `0600`. Nothing crosses process boundaries except the owning user.
- **Minimal hook install** — Clauded writes only the five hook entries it needs (`Notification`, `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`) into `~/.claude/settings.json`. The original file is backed up to `settings.json.clauded.bak` on first install, and uninstall removes only Clauded's entries.
- **Single instance** — A `flock` on `daemon.pid` prevents a second Clauded from kidnapping the socket or double-firing events.

## Building from source

```bash
brew install xcodegen swiftformat swiftlint
make generate  # Generate Xcode project via XcodeGen
make build     # Build the app
make run       # Build and launch
make test      # Run tests
```

Requires **Xcode 16+** and **Swift 6**. See [CLAUDE.md](./CLAUDE.md) for project structure and architecture details.

## License

MIT
