# Claude Dashboard

A native macOS menu bar + floating window app for monitoring multiple [Claude Code](https://claude.ai/code) sessions at a glance.

## What it does

- **Live session status** — shows each Claude Code session as a card with real-time state: Working (green), Needs Input (amber), Idle (gray), Dead (red)
- **Menu bar indicator** — colored dot reflects the most urgent session state; count shown when sessions are active
- **Click to reveal** — click a session card to bring its Terminal window to the foreground
- **Session notes** — each session has a notes button that opens a plain text file in your default editor, persisted in `~/.claude/dashboard-notes/`
- **Persistent sessions** — ended sessions stay in the dashboard with their notes until explicitly removed
- **Permission prompt detection** — uses Claude Code's `Notification` hook with `permission_prompt` matcher to detect when a session is blocked waiting for user approval

## How it works

The app polls `~/.claude/sessions/*.json` every second to discover active Claude Code sessions. For each session it checks:

- **CPU usage** and **child processes** to determine if a session is actively working
- **Hook state files** in `/tmp/claude-dash/` written by Claude Code hooks to detect permission prompts and turn completion

On first launch, the app automatically sets up all dependencies — hooks, directories, settings registration. No manual configuration needed.

## Requirements

- **macOS** (uses AppKit, SF Symbols)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Claude Code** installed

## Install & Run

```bash
git clone https://github.com/cvl/claude-dashboard.git && cd claude-dashboard
./install.sh
open /Applications/ClaudeDashboard.app
```

The install script compiles the Swift source and creates the `.app` bundle in `/Applications/`.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+H` | Toggle dashboard window |
| `Cmd+Q` | Quit |

## File locations

| Path | Purpose |
|------|---------|
| `~/.claude/dashboard-store.json` | Persisted session metadata |
| `~/.claude/dashboard-notes/` | Session notes (plain text, never auto-deleted) |
| `~/.claude/hooks/dash-state.sh` | Hook script (auto-installed) |

## License

MIT
