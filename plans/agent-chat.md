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
PRAGMA journal_mode=WAL;  -- required for concurrent read/write

CREATE TABLE projects (
    id TEXT PRIMARY KEY,           -- slugified name (e.g. "vpn-platform")
    name TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE sessions (
    project_id TEXT NOT NULL REFERENCES projects(id),
    display_name TEXT NOT NULL,
    agent_type TEXT NOT NULL,      -- 'claude' | 'codex' | 'human'
    working_directory TEXT,
    pid INTEGER,
    proxy_pid INTEGER,             -- for injection targeting
    connected_at INTEGER DEFAULT (unixepoch()),
    last_seen INTEGER DEFAULT (unixepoch()),
    PRIMARY KEY(project_id, display_name)
);

CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL REFERENCES projects(id),
    sender_name TEXT NOT NULL,     -- display_name of sender
    sender_type TEXT NOT NULL,     -- 'claude' | 'codex' | 'human'
    recipient TEXT,                -- NULL = broadcast, display_name = DM, 'human' = escalation
    body TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE read_cursors (
    project_id TEXT NOT NULL,
    display_name TEXT NOT NULL,    -- reader's display_name
    last_read_id INTEGER DEFAULT 0,
    PRIMARY KEY(project_id, display_name)
);

CREATE INDEX idx_messages_project ON messages(project_id, id);
```

Key decisions:
- Session primary key = `(project_id, display_name)` — no cross-project collision
- No UUID session IDs — identity is deterministic from env vars
- Messages store sender_name + sender_type inline (no FK, simpler queries)
- `read_cursors` keyed by `(project_id, display_name)` — matches session identity

### 2. Session Identity via Env Vars

**Problem:** Each `cdash chat` invocation is a new bash process. Env vars from a "join" command don't persist.

**Solution:** Env vars set by `cdash` BEFORE launching the proxy, inherited by all child processes:

| Var | Set by | Example | Fallback |
|-----|--------|---------|----------|
| `CDASH_PROJECT` | `cdash --project` | `vpn-platform` | git root dirname, then cwd basename |
| `CDASH_SESSION_NAME` | `cdash --name` | `backend` | **required** — no default, cdash refuses to launch without it |
| `CDASH_AGENT_TYPE` | `cdash claude/codex` | `claude` | detect from parent process name |
| `CDASH_PROXY` | `cdash` | `1` | (existing, prevents hook race) |
| `CDASH_PID` | proxy child, before exec | `12345` | `$$` of agent process |
| `CDASH_PROXY_PID` | proxy child, before exec | `12340` | absent for non-proxy sessions |

**Proxy sets PID env vars** (in child process before exec):
```c
if (child_pid == 0) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", getpid());
    setenv("CDASH_PID", buf, 1);
    snprintf(buf, sizeof(buf), "%d", getppid());
    setenv("CDASH_PROXY_PID", buf, 1);
    execvp(argv[1], &argv[1]);
}
```

All `cdash chat` commands read these env vars. Session is auto-registered on first chat command.

**Non-cdash sessions:** If agent wasn't launched via `cdash`, env vars are absent. `cdash chat` falls back:
- Project: detect from git root
- Name: must be provided as argument (`cdash chat send --name researcher "message"`)
- No injection possible (no proxy). Messages still work via manual `cdash chat read`.

### 3. Chat Backend (`agent-chat.py`)

Standalone python3 script (~150 LOC). Handles all SQLite operations. Installed to `/usr/local/bin/cdash-chat`.

Every command opens db with `PRAGMA journal_mode=WAL` and closes promptly.

**Commands:**

#### `cdash-chat join --project P --name N --type T [--pid PID] [--proxy-pid PPID] [--cwd DIR]`
- Creates project if needed
- Upserts session record (INSERT OR REPLACE on primary key)
- Outputs JSON: `{"project": "vpn", "name": "backend", "sessions": [...]}`

#### `cdash-chat send --project P --name N --type T --message M [--to TARGET]`
- Auto-joins if session not registered yet
- Inserts message (sender_name=N, sender_type=T, recipient=TARGET or NULL)
- Updates sender's last_seen
- **Injection logic:** if `--to` specifies a target:
  1. Looks up target's `pid` in sessions table
  2. Reads `/tmp/claude-dash/<pid>.state` for state + proxy_pid
  3. If state is "stop" (idle), writes inject file at `/tmp/claude-dash/<pid>.inject`
  4. If broadcast (no --to), checks ALL sessions in project, injects idle ones
- Outputs: `{"id": 15, "recipients": ["codex/payments", "claude/tests"]}`

#### `cdash-chat read --project P --name N [--limit 20] [--all]`
- Returns messages since this session's read cursor
- Includes: broadcasts in project + DMs where recipient = N
- Updates read cursor to latest message ID
- `--all` returns all messages (ignores cursor)
- Outputs: formatted text for agent readability

#### `cdash-chat list --project P`
- Returns sessions with liveness (checks PID, falls back to last_seen age)
- Outputs: formatted text

#### `cdash-chat cleanup`
- Marks sessions with dead PIDs as disconnected (sets pid=0, proxy_pid=0)
- Called by dashboard app periodically

### 4. cdash CLI Chat Wrappers

Thin wrappers in `cdash` that read env vars and call `cdash-chat`:

```bash
# In cdash script:
chat)
  shift
  subcmd="${1:-read}"; shift || true
  project="${CDASH_PROJECT:-$(git_root_name)}"
  name="${CDASH_SESSION_NAME:-}"
  type="${CDASH_AGENT_TYPE:-claude}"
  pid="${CDASH_PID:-$$}"
  proxy_pid="${CDASH_PROXY_PID:-}"

  case "$subcmd" in
    send)
      msg="$1"; shift || true
      to_flag=""
      [ "${1:-}" = "--to" ] && { to_flag="--to $2"; shift 2; }
      cdash-chat send --project "$project" --name "$name" --type "$type" \
        --message "$msg" $to_flag
      ;;
    read)
      cdash-chat read --project "$project" --name "$name" "$@"
      ;;
    list)
      cdash-chat list --project "$project"
      ;;
  esac
  ;;
```

**Output format for `cdash chat read`:**
```
── vpn-platform chat ──
[12] claude/backend   11:32  I'm modifying UserSession.
[13] codex/payments   11:33  Please preserve isActive().
[14] human            11:34  Do that, and add the new method separately.
── 3 new messages ──
```

### 5. cdash CLI Project/Name Flags

```bash
cdash claude --project vpn-platform --name backend [claude args...]
cdash codex --project crypto --name contracts [codex args...]
```

`--name` is required. `--project` defaults to git root detection.

Before exec'ing the proxy:
```bash
export CDASH_PROJECT="${project:-$(git_root_name)}"
export CDASH_SESSION_NAME="$name"
export CDASH_AGENT_TYPE="claude"  # or "codex"
export CDASH_PROXY=1
exec claude-dashboard-proxy "$@"
```

**`git_root_name` function:**
```bash
git_root_name() {
  local root
  root=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null) || { basename "$(pwd)"; return; }
  basename "$root"
}
```

### 6. Dashboard Chat UI (Swift)

**Separate borderless floating window** (same pattern as tab sidebar and notification panel).

**Toggle:** "Chat" menu item in tray menu, or keyboard shortcut.

**Layout:**
- Top bar: project name + session count indicator
- Middle: scrolling message list (NSScrollView + custom draw)
  ```
  Claude / backend              11:32
  I'm modifying UserSession.

  Codex / payments              11:33
  Please preserve isActive().

  You                           11:34
  Do that, and add the new method.
  ```
- Bottom: NSTextField input + send button
- Color-coded left accent per sender type (green=claude, blue=codex, gray=human)

**Data flow:**
- Uses C sqlite3 API directly (`import SQLite3` — included in macOS SDK, zero dependencies)
- Opens db read-only, polls every 1s on existing timer
- Human messages: calls `cdash-chat send --project P --name human --type human --message M`
- Project list: queries projects table, shows most recent activity first

**Alerts for human-directed messages:**
- Messages with `recipient = 'human'` → dock bounce + ping (reuse needs_input alert system)
- Badge count on menu bar icon or chat button

### 7. PTY Proxy Injection (`pty-proxy.c`)

Add to poll loop (~15 lines):

```c
/* Check for inject file when idle */
if (current_state == ST_IDLE) {
    char inject_path[128];
    snprintf(inject_path, sizeof(inject_path), STATE_DIR "/%d.inject", child_pid);
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

**What gets injected** (natural language prompt written by `cdash-chat send`):
```
You have a new chat message from codex/payments in project vpn-platform. Run `cdash chat read` to see it and `cdash chat send "reply"` to respond.
```

The agent sees this as user input and acts naturally.

**Race condition (multiple senders):** Acceptable — inject content is always "check messages", not the message itself. All messages are in SQLite. If overwritten, the agent still sees everything on `cdash chat read`. If agent is working when file appears, it waits until idle.

**Limitation:** If an agent never goes idle (continuous work), inject file sits. Human must manually intervene. Dashboard should show unread count per session so human knows which agents have pending messages.

### 8. Session Cleanup

Dashboard app calls `cdash-chat cleanup` every 60s:
- Checks each session's `pid` — if process is dead, sets `pid = 0, proxy_pid = 0`
- Sessions with `pid = 0` show as "disconnected" in chat list
- Chat history preserved — no automatic deletion

## Build Order

### Phase 1: Foundation
1. `cdash-chat` (agent-chat.py) — schema init + join/send/read/list/cleanup
2. `cdash chat` wrappers in cdash script
3. `cdash claude/codex --project --name` flags + env var setup
4. Proxy: set `CDASH_PID` and `CDASH_PROXY_PID` env vars in child before exec
5. `install.sh` additions (install cdash-chat)
6. Test: two sessions in same project exchange messages via `cdash chat`

### Phase 2: Auto-injection
7. PTY proxy inject file support (read + write to master_fd when idle)
8. `cdash-chat send` writes inject file for idle recipients
9. Test: agent A sends message, idle agent B auto-receives and acts

### Phase 3: Dashboard integration
10. Chat window (separate NSWindow, C sqlite3 API for reading)
11. Human message input (calls cdash-chat send)
12. Alerts for human-directed messages (dock bounce + ping)
13. Unread badge

### Phase 4: Polish
14. Project selector in chat window (multiple projects)
15. Session presence indicators (active/idle/disconnected)
16. Dashboard session cleanup timer

## Example End-to-End Flow

```bash
# Terminal 1
$ cdash claude --project vpn --name backend
# Env: CDASH_PROJECT=vpn, CDASH_SESSION_NAME=backend, CDASH_AGENT_TYPE=claude,
#       CDASH_PID=12345, CDASH_PROXY_PID=12340

# Agent announces a change (via Bash tool):
$ cdash chat send "I'm changing UserSession.isActive(). Anyone relying on it?"
Sent to vpn (2 active sessions)

# Terminal 2 (codex, currently idle):
# cdash-chat send detected codex/payments is idle (state file says "stop")
# Wrote /tmp/claude-dash/12350.inject with:
#   "You have a new chat message from claude/backend..."
# Proxy reads inject file, writes to master_fd
# Agent sees user input, runs:
$ cdash chat read
── vpn chat ──
[1] claude/backend  11:32  I'm changing UserSession.isActive(). Anyone relying on it?
── 1 new message ──

$ cdash chat send "I am. Payment expiry assumes false=expired." --to backend
Sent to claude/backend

# Dashboard app:
# Chat window shows both messages
# Human types: "Keep isActive() backward compatible."
# Message stored with sender_name=human, sender_type=human
# Both agents see it on next cdash chat read (or via injection if idle)
```

## File Layout

```
claude-dashboard/
├── claude-dashboard.swift    # +chat window UI (~150 LOC)
├── pty-proxy.c               # +inject support (~15 LOC), +env var setup (~5 LOC)
├── cdash                     # +chat wrappers, --project/--name flags (~50 LOC)
├── agent-chat.py             # NEW: chat backend, installed as cdash-chat (~150 LOC)
├── install.sh                # +install cdash-chat
└── plans/agent-chat.md       # this file
```

## Constraints

- No daemon process — SQLite direct access only
- No MCP server — agents use Bash tool + cdash CLI
- No web server — dashboard app is the UI
- No config changes to Claude Code or Codex settings
- No task management, kanban, orchestration
- No auth, permissions, roles
- Total new code: ~370 LOC
- Single SQLite db file, WAL mode, no migrations
