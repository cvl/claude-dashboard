# Agent Chat — Shared Communication Between Sessions

## Goal

Multiple Claude Code and Codex sessions communicate with each other through a shared chat, grouped by project. Human participates through the dashboard app. Messages can be auto-injected into idle sessions via the PTY proxy.

## Architecture

```
Claude session ─ Bash: cdash chat ──┐
Codex session  ─ Bash: cdash chat ──┼── SQLite (~/.claude/dashboard-chat.db)
Dashboard app (UI + human input) ───┘
PTY proxy (inject prompt into idle sessions)
```

No daemon, no web server, no MCP server, no config changes. Agents use `cdash chat` via Bash tool. SQLite with WAL mode handles concurrency.

## Why Not MCP

- MCP server requires a Node.js package installed + registered in `~/.claude/settings.json`
- Every Claude Code session would see chat tools (global config, can't scope per-session)
- Extra process per session, more things to maintain
- `cdash chat` reuses the existing CLI, needs nothing new installed

## Components

### 1. SQLite Schema (`~/.claude/dashboard-chat.db`)

```sql
CREATE TABLE projects (
    id TEXT PRIMARY KEY,           -- slugified name
    name TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE sessions (
    id TEXT PRIMARY KEY,           -- "{agent_type}/{display_name}"
    display_name TEXT NOT NULL,
    agent_type TEXT NOT NULL,      -- 'claude' | 'codex' | 'human'
    project_id TEXT NOT NULL REFERENCES projects(id),
    working_directory TEXT,
    pid INTEGER,
    proxy_pid INTEGER,             -- for injection targeting
    connected_at INTEGER DEFAULT (unixepoch()),
    last_seen INTEGER DEFAULT (unixepoch()),
    UNIQUE(display_name, project_id)
);

CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL REFERENCES projects(id),
    sender_id TEXT NOT NULL,
    recipient TEXT,                -- NULL = broadcast, session display_name = DM, 'human' = escalation
    body TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE read_cursors (
    session_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    last_read_id INTEGER DEFAULT 0,
    PRIMARY KEY(session_id, project_id)
);

CREATE INDEX idx_messages_project ON messages(project_id, id);
```

Notes:
- Session ID = `"{agent_type}/{display_name}"` — deterministic, no UUID needed
- `read_cursors` tracks per-session read position (separate from messages table)
- `proxy_pid` stored for injection targeting

### 2. Chat Backend (`agent-chat.py`)

Separate python3 script (~150 LOC) handles all SQLite operations. Called by both `cdash` CLI and dashboard app. Keeps cdash script lean.

**Location:** installed to `/usr/local/lib/claude-dashboard/agent-chat.py`

**Commands (called as `python3 agent-chat.py <command> [args]`):**

#### `join`
```
python3 agent-chat.py join --project vpn --name backend --type claude --pid 1234 --proxy-pid 1230 --cwd /home/me/vpn
```
- Creates project if needed
- Upserts session record
- Returns JSON: `{"session_id": "claude/backend", "project": "vpn", "sessions": [...]}`

#### `send`
```
python3 agent-chat.py send --project vpn --from claude/backend --message "changing UserSession" [--to payments]
```
- Inserts message
- Updates sender's last_seen
- If `--to` target has proxy_pid and is idle (checks state file), writes inject file
- Returns JSON: `{"id": 15, "recipients": 3}`

#### `read`
```
python3 agent-chat.py read --project vpn --session claude/backend [--limit 20]
```
- Returns messages since this session's read cursor (broadcasts + DMs to this session)
- Updates read cursor
- Returns JSON array of messages

#### `list`
```
python3 agent-chat.py list --project vpn
```
- Returns sessions with liveness status (checks PID, falls back to last_seen age)

#### `cleanup`
```
python3 agent-chat.py cleanup
```
- Marks sessions with dead PIDs as disconnected (sets pid=0)
- Called by dashboard app periodically

### 3. Session Identity

**Problem:** Each `cdash chat` invocation is a new bash process. Env vars from `cdash chat join` don't persist.

**Solution:** `cdash claude --project X --name Y` sets env vars BEFORE exec'ing the proxy. The proxy passes them to the child. Child (claude/codex) inherits them. All subprocesses (including Bash tool invocations running `cdash chat`) see them.

Env vars set by `cdash`:
- `CDASH_PROJECT` — project name (default: git root dirname, fallback to cwd basename)
- `CDASH_SESSION_NAME` — display name (default: `$CDASH_PROJECT` or folder name)
- `CDASH_AGENT_TYPE` — `claude` or `codex`
- `CDASH_PROXY` — already exists (prevents hook race)

These are inherited by child processes because the proxy does NOT unsetenv them.

The `cdash chat` commands read these env vars — no join step needed. Session is auto-registered on first chat command.

### 4. cdash CLI Chat Commands

Thin wrappers in cdash that call `agent-chat.py`:

```bash
cdash chat send "message"           # broadcast to project
cdash chat send "message" --to NAME # DM to session
cdash chat send "message" --to human # escalate to human
cdash chat read                     # show new messages
cdash chat read --all               # show all messages
cdash chat list                     # show active sessions
```

Each command:
1. Reads `CDASH_PROJECT`, `CDASH_SESSION_NAME`, `CDASH_AGENT_TYPE` from env
2. Falls back to git-root detection if env not set
3. Auto-registers session on first use
4. Calls `python3 agent-chat.py <command> ...`
5. Formats output for terminal

**Output format for `cdash chat read`:**
```
── vpn-platform chat ──
[12] claude/backend   11:32  I'm modifying UserSession.
[13] codex/payments   11:33  Please preserve isActive().
[14] human            11:34  Do that, and add the new method separately.
── 3 messages ──
```

**Output for `cdash chat send`:**
```
Sent to vpn-platform (3 active sessions)
```

### 5. cdash CLI Project Support

```bash
cdash claude --project vpn-platform --name backend [args...]
cdash codex --project crypto --name contracts [args...]
```

Before exec'ing the proxy:
```bash
export CDASH_PROJECT="${project:-$(git_root_name)}"
export CDASH_SESSION_NAME="${name:-$CDASH_PROJECT}"
export CDASH_AGENT_TYPE="claude"  # or "codex"
export CDASH_PROXY=1
exec claude-dashboard-proxy "$@"
```

**Project detection default (no --project flag):**
1. Walk up from cwd to find `.git` directory
2. Use that directory's basename as project name
3. Fallback: cwd basename

### 6. Dashboard Chat UI (Swift)

**Separate window** (like tab sidebar and notification panel) — keeps main panel focused.

**Toggle:** Chat button in main panel or menu bar menu item.

**Layout:**
- Top: project selector (dropdown, populated from projects table)
- Middle: scrolling message list
  ```
  Claude / backend              11:32
  I'm modifying UserSession.

  Codex / payments              11:33
  Please preserve isActive().

  You                           11:34
  Do that, and add the new method.
  ```
- Bottom: text input + send button
- Right edge or header: active session dots

**Data flow:**
- Uses C sqlite3 API directly (`import SQLite3` — available on macOS, no dependencies)
- Polls db every 1s on same timer as session poll
- Human messages inserted directly via sqlite3 API with sender_id="human"

**Alerts for human-directed messages:**
- Messages with `recipient = 'human'` → dock bounce + ping (reuse existing needs_input alert)
- Unread badge on chat button (count of messages since human's read cursor)

### 7. PTY Proxy Injection (`pty-proxy.c`)

Add to the proxy's poll loop (~15 lines):

```c
/* Check for inject file */
char inject_path[128];
snprintf(inject_path, sizeof(inject_path), STATE_DIR "/%d.inject", child_pid);
if (current_state == ST_IDLE) {
    FILE *inj = fopen(inject_path, "r");
    if (inj) {
        char inject_buf[2048];
        size_t n = fread(inject_buf, 1, sizeof(inject_buf) - 1, inj);
        fclose(inj);
        unlink(inject_path);
        if (n > 0) {
            inject_buf[n] = '\0';
            write(master_fd, inject_buf, n);
        }
    }
}
```

Only injects when `ST_IDLE` — never interrupts working sessions or permission prompts.

**What gets injected (natural language, not raw command):**
```
You have a new chat message from codex/payments in project vpn-platform. Run `cdash chat read` to see it and `cdash chat send "reply"` to respond.
```

This is written to the inject file by `agent-chat.py send` when it detects the recipient is idle. The agent sees it as user input and acts naturally.

**Race condition:** Multiple senders writing inject files simultaneously — second overwrites first. Acceptable because:
1. The inject content is always "check messages" (not the message itself)
2. All messages are in SQLite — `cdash chat read` picks up everything
3. If agent is working when inject arrives, file sits until idle. By then, all messages accumulated.

### 8. Session Cleanup

Dashboard app runs `python3 agent-chat.py cleanup` every 60s:
- Checks each session's `pid` — if `kill(pid, 0)` fails, set `pid = 0`
- Sessions with `pid = 0` show as "disconnected" in chat list
- Messages from disconnected sessions are preserved (chat history stays)
- No automatic deletion — human can clear via dashboard

## Build Order

### Phase 1: Foundation
1. `agent-chat.py` — SQLite schema init + all commands (join/send/read/list/cleanup)
2. `cdash chat` subcommands (thin wrappers calling agent-chat.py)
3. `cdash claude/codex --project --name` flags + env var setup
4. Test: two sessions in same project exchange messages manually

### Phase 2: Dashboard integration
5. Chat window (separate NSWindow, toggleable from main panel)
6. Read-only message display from SQLite (C sqlite3 API)
7. Human message input field
8. Alerts for human-directed messages (dock bounce + ping)

### Phase 3: Auto-injection
9. PTY proxy inject file support
10. `agent-chat.py send` writes inject file for idle recipients
11. Test: agent A sends message, idle agent B auto-receives and acts

### Phase 4: Polish
12. Unread counts / badge on chat button
13. Project selector in chat window
14. Session presence indicators (active/idle/disconnected)
15. Install script additions (agent-chat.py installation)

## Example End-to-End Flow

```bash
# Terminal 1
$ cdash claude --project vpn --name backend
# Claude session starts with CDASH_PROJECT=vpn, CDASH_SESSION_NAME=backend

# Agent decides to announce a change:
> cdash chat send "I'm changing UserSession.isActive() behavior. Anyone relying on it?"
Sent to vpn (2 active sessions)

# Terminal 2 (codex, idle, gets auto-injected):
# Proxy sees inject file, injects:
#   "You have a new chat message from claude/backend. Run `cdash chat read`..."
# Agent runs:
> cdash chat read
── vpn chat ──
[1] claude/backend  11:32  I'm changing UserSession.isActive() behavior. Anyone relying on it?
── 1 new message ──

> cdash chat send "I am. Payment expiry logic assumes false means expired." --to backend
Sent to claude/backend

# Dashboard app:
# Chat window shows both messages
# Human types: "Keep isActive() backward compatible."
# Both agents see it on next read
```

## File Layout

```
claude-dashboard/
├── claude-dashboard.swift    # +chat window UI (~150 LOC)
├── pty-proxy.c               # +inject support (~15 LOC)
├── cdash                     # +chat subcommands, --project/--name flags (~40 LOC)
├── agent-chat.py             # NEW: chat backend (~150 LOC)
├── install.sh                # +install agent-chat.py
└── plans/agent-chat.md       # this file
```

## Constraints

- No daemon process — SQLite direct access only
- No MCP server — agents use Bash tool + cdash CLI
- No web server — dashboard app is the UI
- No config changes to Claude Code or Codex settings
- No task management, kanban, orchestration
- No auth, permissions, roles
- Total new code: ~350 LOC
- Single SQLite db file, WAL mode
