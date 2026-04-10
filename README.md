# Clauded

Native macOS menu bar app for managing Claude Code instances running in your terminal.

- **See every live session** — one row per running Claude Code instance, grouped by project.
- **Know which one needs you** — the menu bar icon flips to an attention state the instant any instance is waiting on input, with a per-instance badge in the popover.
- **Jump to the terminal** — click a row to focus the terminal window (Terminal.app, iTerm2, Ghostty, WezTerm) running that session.
- **Zero configuration** — click "Install hooks" once. Clauded writes the necessary entries into `~/.claude/settings.json` and removes them cleanly on uninstall.

Swift 6 + SwiftUI. Menu bar only. No third-party dependencies.

## Requirements

- macOS 15.0 (Sequoia) or later
- Claude Code installed
- Xcode 16+ to build from source

## Build from source

```bash
brew install xcodegen swiftformat swiftlint
make generate
make run
```

See [`CLAUDE.md`](./CLAUDE.md) for architecture and development guidelines.

## License

MIT
