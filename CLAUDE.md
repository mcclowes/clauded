# Clauded

Native macOS menu bar app for managing Claude Code instances running in terminal. Shows live instance list, surfaces which ones need user interaction, and jumps you straight to them. Swift 6 + SwiftUI, menu bar-only app (`LSUIElement`).

## Build & test

```bash
make generate  # XcodeGen from project.yml
make build     # Debug build
make run       # Build + launch
make test      # Run unit tests
make release   # Release build
make package   # Release build + zip for distribution
make clean     # Clean build artifacts
```

## Project structure

```
Clauded/
  project.yml                # XcodeGen spec (source of truth for Xcode project)
  Sources/
    App/ClaudedApp.swift     # Entry point, AppDelegate, MenuBarExtra setup
    Models/
      ClaudeInstance.swift   # Domain model: id, projectDir, state, lastActivity
      HookEvent.swift        # Decoded hook payload from the notify shim
    Services/
      InstanceRegistry.swift # @Observable live instance list + attention count
      HookDaemon.swift       # Unix domain socket listener (Network.framework)
      HookInstaller.swift    # Read-parse-merge-write ~/.claude/settings.json
      HookInstallState.swift # @Observable wrapper around HookInstaller for SwiftUI
      StatusBarController.swift # NSStatusItem + popover
      TerminalFocuser.swift  # AppleScript-based window focus
    Views/
      InstancePanelView.swift
      SettingsView.swift
      Components/InstanceRow.swift
    NotifyShim/main.swift    # `clauded-notify` CLI target shipped inside the app bundle
  Tests/
    HookInstallerTests.swift
    InstanceRegistryTests.swift
    HookEventTests.swift
  Resources/
    Info.plist               # LSUIElement=true
    Clauded.entitlements
```

## How it works

1. **Notify shim.** `clauded-notify` is a tiny Swift CLI bundled inside `Clauded.app/Contents/MacOS/` and symlinked on install. When Claude Code fires a hook, the shim reads the hook's stdin JSON, tags it with event name + `$CLAUDE_PROJECT_DIR` + pid, and writes one line to a Unix socket. Fire-and-forget — exits in <50ms even if the daemon is down.
2. **HookDaemon.** An actor owning a `NWListener` bound to `~/Library/Application Support/Clauded/daemon.sock`. Parses newline-delimited JSON events and hops onto `@MainActor` to update the registry.
3. **InstanceRegistry.** `@Observable` service keyed by session id. Tracks state (`idle`, `working`, `awaitingInput`, `stopped`) and exposes `needsAttentionCount` for the menu bar badge.
4. **HookInstaller.** Installs the five hooks (`Notification`, `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`) into `~/.claude/settings.json` by parsing, merging, and writing atomically. Idempotent. Backs up the original on first write. Uninstall removes only Clauded's entries.
5. **StatusBarController.** `NSStatusItem` with a SF Symbol icon that changes when attention is needed. Popover hosts the SwiftUI panel.

## Pre-PR checklist

Always run these before committing or opening a pull request:

```bash
make lint      # SwiftFormat + SwiftLint — must pass with zero violations
make build     # Debug build must succeed
make test      # All unit tests must pass
```

If `make lint` fails, run `make format` to auto-fix SwiftFormat issues, then re-check with `make lint` (SwiftLint issues must be fixed manually).

Key lint rules to watch:
- **Max line width is 120 characters**
- **Hoist pattern `let`**: use `case let .foo(bar)` not `case .foo(let bar)`
- **Wrap long argument lists** `before-first` with balanced closing paren

## Key conventions

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All services are `@MainActor` unless they own I/O (then `actor`)
- `@Observable` macro (not `ObservableObject`)
- Environment-based DI via `.environment()` in SwiftUI
- No third-party dependencies
- App sandbox disabled (needs to read `~/.claude/settings.json` and bind Unix sockets)

## Testing

Tests use the `Clauded` scheme. The test target is `ClaudedTests`. `HookInstaller` tests must use a temp directory fixture — never touch the user's real `~/.claude/settings.json`.

## Deployment target

macOS 15.0 (Sequoia), Xcode 16+, Swift 6.
