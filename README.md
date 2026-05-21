# Claude Dashboard

A native macOS menu bar + floating window app for monitoring multiple [Claude Code](https://claude.ai/code) sessions at a glance, with terminal window management.

## What it does

### Claude Sessions
- **Live session status** — shows each Claude Code session as a card with real-time state: Working (green), Needs Input (amber), Idle (gray), Dead (red)
- **Menu bar indicator** — colored dot reflects the most urgent session state; count shown when sessions are active
- **Click to reveal** — click a session card to bring its Terminal window to the foreground (works across monitors)
- **Resume command** — play button copies a `claude --resume` command to clipboard, including session name
- **Session notes** — each session has a notes button that opens a plain text file in your default editor
- **Persistent sessions** — ended sessions stay in the dashboard until explicitly removed
- **Drag to reorder** — drag session cards to arrange them manually; order persists across restarts
- **Permission prompt detection** — detects when a session is blocked waiting for user approval
- **Session history** — all sessions are logged to `~/.claude/dashboard-notes/history.txt` with resume commands, working directory, and notes filename. Updated on rename.

### Named Terminals
Register any terminal tab with a name so you can find it from the dashboard:

```bash
claudedashboard dev-server
```

This registers the current terminal tab as "dev-server". It appears in the TERMINALS section with name, path, and active/closed status. Click to reveal, X to remove.

### Terminal Window Layout
Automatically saves and restores terminal window positions across sleep/wake and monitor reconnects:

- **Auto-save** — layout saved on launch and every 5 minutes
- **Auto-restore** — triggers on screen wake and display reconfiguration, with a 3s delay for monitors to settle
- **Screen-aware** — skips saving when monitors are disconnected (prevents saving scrambled positions); skips restoring until all monitors are reconnected
- **Manual fallback** — "Save Terminal Layout" and "Restore Terminal Layout" available in the tray menu

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

The install script compiles the Swift source, creates the `.app` bundle in `/Applications/`, and installs the `claudedashboard` CLI to `/usr/local/bin/`.

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
| `~/.claude/dashboard-notes/history.txt` | Full session history with resume commands |
| `~/.claude/dashboard-terminals.json` | Registered terminal tabs |
| `~/.claude/dashboard-layout.json` | Saved terminal window positions |
| `~/.claude/hooks/dash-state.sh` | Hook script (auto-installed) |
| `/usr/local/bin/claudedashboard` | CLI for registering terminal tabs |

## Known limitations

- **Needs Input state after cancel** — if a permission prompt is denied or canceled, the "Needs Input" status may persist until the next user prompt triggers a Stop hook. This is because Claude Code doesn't fire a Stop event on prompt cancellation.
- **Layout restore timing** — after sleep/wake, there's a 3-second delay before windows are repositioned to allow monitors to fully reconnect.

## License

MIT
