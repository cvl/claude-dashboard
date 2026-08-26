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

No daemon, no web server, no MCP server, no config changes, no new binaries. Agents use `cdash chat` via Bash tool. SQLite with WAL mode handles concurrency.

## Why Not MCP

- MCP server requires a Node.js package installed + registered in `~/.claude/settings.json`
- Every Claude Code session would see chat tools (global config, can't scope per-session)
- Extra process per session, more things to maintain
- `cdash chat` reuses the existing CLI, needs nothing new installed

## Components

### 1. SQLite Schema (`~/.claude/dashboard-chat.db`)

```sql
PRAGMA journal_mode=WAL;

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
    proxy_pid INTEGER,
    connected_at INTEGER DEFAULT (unixepoch()),
    last_seen INTEGER DEFAULT (unixepoch()),
    PRIMARY KEY(project_id, display_name)
);

CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL REFERENCES projects(id),
    sender_name TEXT NOT NULL,
    sender_type TEXT NOT NULL,     -- 'claude' | 'codex' | 'human'
    recipient TEXT,                -- NULL = broadcast, display_name = DM, 'human' = escalation
    body TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE read_cursors (
    project_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    last_read_id INTEGER DEFAULT 0,
    PRIMARY KEY(project_id, display_name)
);

CREATE INDEX idx_messages_project ON messages(project_id, id);
```

### 2. Session Identity

Env vars set by `cdash` before launching the proxy, inherited by all child processes:

| Var | Set by | Fallback |
|-----|--------|----------|
| `CDASH_PROJECT` | `cdash --project X` | git root dirname, then cwd basename |
| `CDASH_SESSION_NAME` | `cdash --name X` | dashboard session name, then `{cwd-basename}` |
| `CDASH_AGENT_TYPE` | `cdash claude/codex` | (always set) |
| `CDASH_PID` | proxy child before exec | (always set under proxy) |
| `CDASH_PROXY_PID` | proxy child before exec | absent for non-proxy sessions |

**`--name` and `--project` are optional.** Defaults work for most cases. Only needed when multiple sessions share the same cwd (same git root) and need distinct names.

**Proxy sets PID env vars** in child before exec:
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

**Non-cdash sessions:** `cdash chat` works without proxy — falls back to git root for project, cwd basename for name. No injection possible, but send/read still work.

### 3. Chat Backend (`agent-chat.py`)

Internal python3 script. NOT a separate user-facing binary. Lives in the repo, installed alongside cdash. Called internally by `cdash chat` subcommands.

**Location:** `/usr/local/lib/claude-dashboard/agent-chat.py`

The user only ever types `cdash chat ...`. Never touches agent-chat.py directly.

All operations:
- Open db with `PRAGMA journal_mode=WAL`
- Auto-create schema if tables don't exist
- Close db promptly (no long-lived connections)

### 4. cdash CLI — Chat Subcommands

All chat is accessed via `cdash chat`:

```bash
cdash chat send "message"             # broadcast to project
cdash chat send "message" --to NAME   # DM to session
cdash chat send "message" --to human  # escalate to human
cdash chat read                       # show new messages since last read
cdash chat read --all                 # show full history
cdash chat list                       # show sessions in project
```

Internally, each subcommand:
1. Reads `CDASH_PROJECT`, `CDASH_SESSION_NAME`, `CDASH_AGENT_TYPE` from env
2. Falls back to git root / cwd detection if env not set
3. Auto-registers session on first use (upsert into sessions table)
4. Calls `python3 agent-chat.py <operation> ...`

**Output — `cdash chat read`:**
```
── vpn chat ──
[12] claude/backend   11:32  I'm modifying UserSession.
[13] codex/payments   11:33  Please preserve isActive().
[14] human            11:34  Do that, and add the new method separately.
── 3 new messages ──
```

**Output — `cdash chat send`:**
```
Sent to vpn (3 active sessions)
```

**Output — `cdash chat list`:**
```
── vpn sessions ──
claude/backend    active   pid 12345
codex/payments    active   pid 12346
claude/tests      idle     2m ago
```

### 5. cdash CLI — Project/Name Flags

```bash
cdash claude --project vpn --name backend [claude args...]
cdash codex --project crypto --name contracts [codex args...]

# Both optional:
cdash claude                    # project=git root, name=cwd basename
cdash claude --name backend     # project=git root, name=backend
```

### 6. Dashboard Chat UI (Swift)

**Separate borderless floating window** (same pattern as tab sidebar, notification panel).

**Toggle:** "Chat" item in tray menu.

**Layout:**
- Top: project name + session count
- Middle: scrollable message list, color-coded accent per sender type
- Bottom: text input + send button (human sends)

**Data:**
- C sqlite3 API (`import SQLite3`, available on macOS)
- Polls db on existing timer (every 1s)
- Human messages: calls `cdash chat send` via `shell()`

**Alerts:**
- Messages with `recipient = 'human'` → dock bounce + ping (reuse needs_input system)
- Unread badge on chat toggle

### 7. PTY Proxy Injection (`pty-proxy.c`)

~15 lines added to poll loop:

```c
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

**Injected text** (written by agent-chat.py when sending to an idle session):
```
You have a new chat message from codex/payments in project vpn. Run `cdash chat read` to see it and `cdash chat send "reply"` to respond.
```

Only injects when `ST_IDLE`. Never interrupts working or permission prompts.

**Race condition (multiple senders):** Acceptable — inject is always "check messages", all messages are in SQLite. Duplicates just mean the agent checks twice.

**Limitation:** Agent that never goes idle won't get injected. Human sees unread count in dashboard and can intervene manually.

### 8. Session Cleanup

Dashboard calls `python3 agent-chat.py cleanup` every 60s:
- Dead PIDs → set pid=0, proxy_pid=0 (show as "disconnected")
- Chat history preserved

## Build Order

### Phase 1: Foundation
1. `agent-chat.py` — schema init + send/read/list/cleanup operations
2. `cdash chat` subcommands in cdash script
3. `cdash claude/codex --project --name` optional flags + env vars
4. Proxy: set `CDASH_PID` and `CDASH_PROXY_PID` in child before exec
5. `install.sh`: install agent-chat.py
6. Test: two sessions exchange messages via `cdash chat`

### Phase 2: Auto-injection
7. Proxy inject file support
8. `agent-chat.py send` writes inject file for idle recipients
9. Test: agent A sends, idle agent B auto-receives

### Phase 3: Dashboard integration
10. Chat window (separate NSWindow, sqlite3 reads)
11. Human message input
12. Alerts for human-directed messages
13. Unread badge

### Phase 4: Polish
14. Project selector (multiple projects)
15. Session presence indicators
16. Cleanup timer in dashboard

## Example Flow

```bash
# Terminal 1
$ cdash claude --project vpn --name backend

# Agent sends (via Bash tool):
$ cdash chat send "I'm changing UserSession.isActive(). Anyone relying on it?"
Sent to vpn (2 active sessions)

# Terminal 2 — codex is idle, gets auto-injected:
# Proxy injects: "You have a new chat message from claude/backend..."
# Agent runs:
$ cdash chat read
── vpn chat ──
[1] claude/backend  11:32  I'm changing UserSession.isActive(). Anyone relying on it?
── 1 new message ──

$ cdash chat send "I am. Payment expiry assumes false=expired." --to backend
Sent to claude/backend

# Dashboard shows all messages. Human types reply. Agents see it on next read.
```

## File Layout

```
claude-dashboard/
├── claude-dashboard.swift    # +chat window (~150 LOC)
├── pty-proxy.c               # +inject support (~15 LOC), +env vars (~5 LOC)
├── cdash                     # +chat subcommands, --project/--name flags (~50 LOC)
├── agent-chat.py             # NEW: internal chat backend (~150 LOC)
├── install.sh                # +install agent-chat.py
└── plans/agent-chat.md
```

## Constraints

- No daemon, no MCP server, no web server, no new user-facing binaries
- No config changes to Claude Code or Codex
- No task management, kanban, orchestration, auth, permissions
- Total new code: ~370 LOC
- Single SQLite db, WAL mode
