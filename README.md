# Claude Dashboard

A native macOS menu bar app for monitoring and managing multiple [Claude Code](https://claude.ai/code) and [Codex CLI](https://github.com/openai/codex) sessions — with inter-agent chat, terminal management, and automatic state detection.

## Features

### Session Monitoring
- **Live status** — real-time state for each session: Working (green), Needs Input (amber), Idle (gray), Dead (red)
- **CL/CX tags** — visual indicator showing Claude or Codex source on each session
- **Menu bar dot** — colored indicator reflects the most urgent session state
- **Click to reveal** — click any session to bring its terminal window to the foreground (works across monitors)
- **Resume command** — copies a `cdash claude --resume` or `cdash codex --name ... resume` command to clipboard
- **Session notes** — per-session plain text notes, migrated automatically on resume
- **Drag to reorder** — manual ordering persists across restarts
- **Permission prompt detection** — detects when a session is blocked waiting for approval; dock bounce + repeated ping sound
- **Session history** — all sessions logged to `~/.claude/dashboard-notes/history.txt`
- **Dead session muting** — dead sessions show muted names and red dot

### Agent Chat

Agents can communicate with each other and with you through shared chat channels.

**Adding agents to chat:**
- Right-click a session → "Add to Chat"
- The agent receives an auto-injected prompt telling it about the chat commands
- The chat panel opens showing the channel

**Chat commands** (agents use these via Bash tool):
```bash
cdash chat send "message"              # broadcast to channel
cdash chat send "message" --to name    # DM to specific agent
cdash chat send "message" --to all     # ping all agents
cdash chat send "message" --to human   # escalate to human
cdash chat read                        # check new messages
cdash chat list                        # see who's online
```

**Dashboard chat panel:**
- Type messages as the human participant
- `@name message` sends a DM (Tab to autocomplete)
- `@all message` broadcasts to all agents
- Click agent chips to reveal their terminal
- Right-click chips to remove from channel

**Auto-injection:**
- When a message is sent to an idle agent, the proxy types a notification into its terminal
- Multiple messages accumulate into a single prompt (no spam)
- The agent sees the message and can respond with `cdash chat read` / `cdash chat send`

**Channels:**
- Each tab in the dashboard = a chat channel
- Moving a session to another tab removes it from the old channel
- Channel selector (▾) to switch between channels in the chat panel

### Launching Sessions

All sessions must be launched through `cdash` for state tracking and chat:

```bash
# New sessions
cdash claude                                    # defaults: --effort max
cdash claude --name backend --project myapp
cdash codex --name frontend

# Resume
cdash claude --resume <session-id> --name 'backend'
cdash codex --name 'frontend' resume <session-id>

# Named terminal (not an agent)
cdash dev-server
```

`cdash` wraps the agent in a transparent PTY proxy that:
1. Reads terminal output to detect state (spinners, prompts, permission dialogs)
2. Writes state to `/tmp/claude-dash/<pid>.state`
3. Injects chat prompts when the agent is idle
4. Passes all I/O transparently — the agent behaves identically

### Tab Buckets
- Default "main" tab shows unassigned sessions
- Drag sessions onto tabs to organize
- Tabs = chat channels
- Floating sidebar to the left of the dashboard

### Pinned Sessions
- Pin button on each session/terminal
- Pinned section shows items from all tabs
- Click to switch tab and reveal terminal
- Same action buttons as regular sessions (pin, resume, notes)

### Terminal Layout
- **Auto-save** — window positions saved on launch and every 5 minutes
- **Auto-restore** — triggers on screen wake and monitor reconnect
- **Screen-aware** — skips saving when monitors are disconnected

### Notifications
- In-app panel when sessions finish working or need input
- Needs input: dock icon bounce + repeated ping sound every 5s
- Click to reveal terminal, X to dismiss
- Auto-dismissed when session starts working again

## How State Detection Works

The `cdash` proxy reads the agent's terminal output and detects state from:
- **OSC title sequences** — braille spinner characters = working, ✳ = idle
- **Screen content** — "Do you want to proceed?" + "Yes" = needs input, "Esc to cancel" = needs input
- **Screen checks run before title checks** — permission prompts override the working spinner

State is written to `/tmp/claude-dash/<pid>.state` every 200ms. The dashboard polls these files every 0.5s.

Working→idle transitions are debounced (4 × 200ms = 800ms) to prevent flicker.

## Install

```bash
git clone https://github.com/cvl/claude-dashboard.git && cd claude-dashboard
./scripts/install.sh
open /Applications/ClaudeDashboard.app
```

The install script compiles and installs:
- Dashboard app → `/Applications/ClaudeDashboard.app`
- PTY proxy → `/usr/local/bin/claude-dashboard-proxy` (code-signed)
- CLI → `/usr/local/bin/cdash`
- Chat backend → `/usr/local/lib/claude-dashboard/agent-chat.py`

### Development

```bash
./scripts/rebuild-relaunch.sh    # kill, rebuild, relaunch
```

## Requirements

- **macOS** (AppKit, SF Symbols, SQLite3)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Claude Code** and/or **Codex CLI**

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+H` | Toggle dashboard |
| `Cmd+Q` | Quit |

## File Locations

| Path | Purpose |
|------|---------|
| `~/.claude/dashboard-store.json` | Session metadata |
| `~/.claude/dashboard-notes/` | Session notes |
| `~/.claude/dashboard-notes/history.txt` | Session history with resume commands |
| `~/.claude/dashboard-terminals.json` | Registered terminals |
| `~/.claude/dashboard-tabs.json` | Tab assignments |
| `~/.claude/dashboard-pinned.json` | Pinned items |
| `~/.claude/dashboard-layout.json` | Terminal window positions |
| `~/.claude/dashboard-chat.db` | Chat messages and sessions (SQLite) |
| `~/.claude/dashboard.log` | Diagnostic log |
| `/tmp/claude-dash/*.state` | Live state files |
| `/tmp/claude-dash/*.inject` | Queued chat prompts |
| `/usr/local/bin/cdash` | CLI entry point |
| `/usr/local/bin/claude-dashboard-proxy` | PTY proxy binary |
| `/usr/local/lib/claude-dashboard/agent-chat.py` | Chat backend |

## Architecture

```
Terminal → cdash → claude-dashboard-proxy → claude/codex
                        ↓                       ↓
                  state files ←──── terminal output parsing
                        ↓
              ClaudeDashboard.app ←── polls state files + chat db
                        ↓
              menu bar + floating panels (sessions, tabs, notifications, chat)
```

## Known Limitations

- **Codex inject submit** — `\r` (Enter) doesn't always submit in Codex's TUI. Claude Code works reliably.
- **Codex session names** — Codex may overwrite `/rename`d titles. Dashboard preserves names in its own store.
- **Layout restore** — 3-second delay after sleep/wake for monitors to reconnect.
- **Non-cdash sessions** — sessions launched without `cdash` are not tracked.

## License

MIT
