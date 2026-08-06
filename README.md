# Claude Dashboard

A native macOS menu bar + floating window app for monitoring multiple [Claude Code](https://claude.ai/code) and [Codex CLI](https://github.com/openai/codex) sessions at a glance, with terminal window management.

## What it does

### Agent Sessions (Claude & Codex)
- **Live session status** — shows each session as a card with real-time state: Working (green), Needs Input (amber), Idle (gray), Dead (red)
- **Source tags** — blue "claude", purple "codex", or teal "terminal" tag on each card
- **Menu bar indicator** — colored dot reflects the most urgent session state; count shown when sessions are active
- **Click to reveal** — click a session card to bring its Terminal window to the foreground (works across monitors)
- **Resume command** — play button copies a resume command to clipboard (`claude --resume` or `codex resume`)
- **Session notes** — each session has a notes button that opens a plain text file in your default editor
- **Persistent sessions** — ended sessions stay in the dashboard until explicitly removed
- **Drag to reorder** — drag session cards to arrange them manually; order persists across restarts
- **Permission prompt detection** — detects when a session is blocked waiting for user approval
- **Session history** — all sessions are logged to `~/.claude/dashboard-notes/history.txt` with resume commands

### Launching Sessions with `cdash`

For reliable state tracking, launch sessions through `cdash`:

```bash
# Claude
cdash claude
cdash claude --resume <session-id> --name 'my-session' --effort max

# Codex
cdash codex
cdash codex resume <session-id>
```

`cdash` intercepts the terminal output stream and detects agent state directly from what the agent renders — spinner characters for working, prompt symbols for idle, permission dialogs for needs-input. The agent behaves exactly as normal; `cdash` is fully transparent.

Sessions launched without `cdash` (plain `claude` or `codex`) still work via hook-based state detection as a fallback, though hooks are less reliable.

### Named Terminals

Register any terminal tab with a name so you can find it from the dashboard:

```bash
cdash dev-server
```

This registers the current terminal tab as "dev-server". It appears in the TERMINALS section with name, live path (updates on `cd`), and active/closed status. Click to reveal.

### Tab Buckets

Organize sessions into tabs:
- Default "main" tab shows all unassigned sessions
- Drag sessions or terminals onto tabs to organize
- New terminals registered with `cdash` go into the currently selected tab
- Tabs are a floating sidebar to the left of the dashboard

### Pin Sessions

Pin important sessions for quick access:
- Pin button on each session/terminal card
- Pinned section at the bottom shows items from all tabs
- Click pinned item to switch to its tab and reveal terminal
- Right-click for pin/unpin/close

### Terminal Window Layout

Automatically saves and restores terminal window positions across sleep/wake and monitor reconnects:

- **Auto-save** — layout saved on launch and every 5 minutes
- **Auto-restore** — triggers on screen wake and display reconfiguration
- **Screen-aware** — skips saving when monitors are disconnected (prevents saving scrambled positions)

### Notifications

In-app notification panel when sessions finish working:
- Appears to the left of the tab sidebar
- Click to reveal terminal, X to dismiss
- Auto-dismissed when session starts working again
- Toggle in tray menu

## How it works

### State Detection via `cdash` (recommended)

When launched via `cdash claude` or `cdash codex`, the terminal output passes through a transparent layer that:

1. Reads every byte the agent writes to the terminal
2. Watches for OSC title sequences (agents set spinner characters when working, status indicators when idle)
3. Scans the recent screen content for known patterns — permission prompts, working indicators, idle prompts
4. Writes the detected state to `/tmp/claude-dash/<pid>.state` every 500ms

The agent sees a real terminal and behaves identically. You see the exact same output. Detection patterns are based on [herdr](https://github.com/nicoulaj/herdr)'s agent detection manifests.

### Hook-based fallback

Sessions launched without `cdash` use Claude Code / Codex hooks:
- `UserPromptSubmit` → marks session as working
- `Stop` → marks session as idle
- `Notification` (permission_prompt) → marks as needs input

Hooks are auto-installed on app launch.

### Session discovery

- **Claude**: polls `~/.claude/sessions/*.json` every second
- **Codex**: finds running `codex` processes, reads session ID from open JSONL files, queries `~/.codex/state_5.sqlite` for names

## Requirements

- **macOS** (uses AppKit, SF Symbols)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Claude Code** and/or **Codex CLI** installed

## Install & Run

```bash
git clone https://github.com/cvl/claude-dashboard.git && cd claude-dashboard
./install.sh
open /Applications/ClaudeDashboard.app
```

The install script compiles the dashboard app, the state detection layer, and the `cdash` CLI.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+H` | Toggle dashboard window |
| `Cmd+Q` | Quit |

## File locations

| Path | Purpose |
|------|---------|
| `~/.claude/dashboard-store.json` | Persisted session metadata (Claude + Codex) |
| `~/.claude/dashboard-notes/` | Session notes (plain text, never auto-deleted) |
| `~/.claude/dashboard-notes/history.txt` | Full session history with resume commands |
| `~/.claude/dashboard-terminals.json` | Registered terminal tabs |
| `~/.claude/dashboard-tabs.json` | Tab buckets and assignments |
| `~/.claude/dashboard-pinned.json` | Pinned items |
| `~/.claude/dashboard-layout.json` | Saved terminal window positions |
| `~/.claude/dashboard.log` | Diagnostic log (auto-rotates at 5000 lines) |
| `/tmp/claude-dash/*.state` | Live state files (working/stop/needs_input) |
| `/usr/local/bin/cdash` | CLI entry point |

## Known limitations

- **Hook reliability** — `UserPromptSubmit` hook doesn't always fire in Claude Code. Use `cdash claude` for reliable state tracking.
- **Codex session names** — Codex may overwrite `/rename`d titles on interaction. The dashboard preserves names in its own store.
- **Layout restore timing** — after sleep/wake, there's a 3-second delay before windows are repositioned to allow monitors to fully reconnect.

## License

MIT
