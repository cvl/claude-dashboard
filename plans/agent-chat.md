# Agent Chat — Shared Communication Between Sessions

## Goal

Multiple Claude Code and Codex sessions communicate with each other through a shared chat, grouped by project. Human participates through the dashboard app. Messages can be auto-injected into idle sessions via the PTY proxy.

## Architecture

```
Claude session ─ Bash: cdash chat ──┐
Codex session  ─ Bash: cdash chat ──┼── SQLite (~/.claude/dashboard-chat.db)
Dashboard app (UI + human input) ───┘
PTY proxy (inject "cdash chat read" into idle sessions)
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
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    agent_type TEXT NOT NULL,  -- 'claude' | 'codex' | 'human'
    project_id TEXT NOT NULL REFERENCES projects(id),
    working_directory TEXT,
    pid INTEGER,
    connected_at INTEGER DEFAULT (unixepoch()),
    last_seen INTEGER DEFAULT (unixepoch()),
    UNIQUE(display_name, project_id)
);

CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL REFERENCES projects(id),
    sender_id TEXT NOT NULL,
    recipient TEXT,  -- NULL = broadcast, display_name = DM, 'human' = escalation
    body TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE INDEX idx_messages_project ON messages(project_id, created_at);
CREATE INDEX idx_messages_recipient ON messages(recipient, created_at);
```

### 2. cdash CLI Chat Commands

Extend the existing `cdash` bash script. All operations use `python3` + `sqlite3` (same pattern as existing cdash terminal registration).

#### `cdash chat join [--project NAME] [--name DISPLAY_NAME]`
- Creates project if needed (default: basename of cwd)
- Registers session (agent type detected from parent process or `CDASH_AGENT_TYPE`)
- Stores session PID for presence tracking
- Outputs: project name, active sessions

#### `cdash chat send MESSAGE [--to NAME]`
- Sends broadcast (no --to) or DM (--to session_name or --to human)
- Auto-joins if not yet joined
- If recipient has a known proxy PID and is idle, writes inject file
- Outputs: confirmation

#### `cdash chat read [--since ID] [--limit N]`
- Returns messages for this session's project (broadcasts + DMs to this session)
- Default: last 20 messages, or since last read
- Updates last_seen
- Output format:
  ```
  [12] claude/backend  11:32  I'm modifying UserSession.
  [13] codex/payments  11:33  Please preserve isActive().
  [14] human           11:34  Do that, and add the new method separately.
  ```

#### `cdash chat list`
- Shows active sessions in same project
- Output:
  ```
  claude/backend    active   (pid 12345)
  codex/payments    active   (pid 12346)
  claude/tests      idle     (last seen 2m ago)
  ```

#### `cdash chat notify NAME MESSAGE`
- Writes inject file for target session's proxy: `cdash chat read\n`
- Only works if target is idle (proxy checks state before injecting)

#### Session identity
- `CDASH_SESSION_ID` env var set by `cdash chat join`, persisted for session lifetime
- Or derived from: agent type + display_name + project
- `cdash claude/codex` auto-sets `CDASH_AGENT_TYPE`

### 3. Dashboard Chat UI (Swift, in `claude-dashboard.swift`)

New panel in the dashboard app — chat view alongside the existing session list.

**Layout:** Below the session list or as a toggleable pane. Shows:
- Project selector (dropdown or tabs if multiple projects)
- Message list: `Agent Type / Name    HH:mm` + message body
- Active sessions indicator (dot per session)
- Text input field for human messages
- Unread badge on chat toggle button

**Data flow:**
- Poll `dashboard-chat.db` every 1s (same timer as session poll)
- Read messages table for active project
- Human messages written directly to SQLite via `python3` or Swift SQLite bindings

**Alerts for human-directed messages:**
- Messages with `recipient = 'human'` → dock bounce + ping (same as needs_input)
- Show prominently in notification panel

### 4. PTY Proxy Injection (`pty-proxy.c`)

Add ~15 lines to the proxy's poll loop:

```c
/* Check for inject file */
char inject_path[128];
snprintf(inject_path, sizeof(inject_path), STATE_DIR "/%d.inject", child_pid);
if (current_state == ST_IDLE) {
    FILE *inj = fopen(inject_path, "r");
    if (inj) {
        char inject_buf[1024];
        size_t n = fread(inject_buf, 1, sizeof(inject_buf) - 1, inj);
        fclose(inj);
        unlink(inject_path);
        if (n > 0) {
            inject_buf[n] = '\0';
            write(master_fd, inject_buf, n);
            write(master_fd, "\n", 1);
        }
    }
}
```

Only injects when `ST_IDLE` — never interrupts working sessions or permission prompts.

### 5. cdash CLI Changes for Project Support

```bash
cdash claude --project vpn-platform [args...]
cdash codex --project crypto-checkout [args...]
```

- Sets `CDASH_PROJECT` env var before launching proxy
- Sets `CDASH_AGENT_TYPE=claude` or `codex`
- Default project: basename of cwd if `--project` not given
- Auto-joins chat on session start (calls `cdash chat join` internally)

## Build Order

### Phase 1: Core (get messages flowing)
1. SQLite schema + db init in cdash
2. `cdash chat join/send/read/list` commands
3. Test: two sessions in same project exchange messages via `cdash chat`

### Phase 2: Dashboard integration
4. Chat UI panel in dashboard app (read-only first)
5. Human message input
6. Alerts for human-directed messages (dock bounce + ping)
7. Project selector

### Phase 3: Auto-injection
8. PTY proxy inject file support
9. `cdash chat send` writes inject file for idle recipients
10. Test: agent A sends message, idle agent B auto-receives

### Phase 4: Polish
11. `cdash claude --project` flag + auto-join
12. Unread counts in dashboard
13. Session presence (active/idle/disconnected based on last_seen)
14. `cdash chat notify` command for manual nudging

## Example Flow

```bash
# Terminal 1
$ cdash claude --project vpn-platform
> cdash chat join --name backend
Joined vpn-platform as claude/backend. 0 other sessions active.

> cdash chat send "I'm changing UserSession.isActive() behavior. Anyone relying on it?"

# Terminal 2
$ cdash codex --project vpn-platform
> cdash chat join --name payments
Joined vpn-platform as codex/payments. 1 other session active.

> cdash chat read
[1] claude/backend  11:32  I'm changing UserSession.isActive() behavior. Anyone relying on it?

> cdash chat send --to backend "I am. Payment expiry logic assumes false means expired."

# Dashboard app shows all messages in vpn-platform chat panel
# Human types in dashboard: "Keep isActive() backward compatible."
# Both agents see it on next cdash chat read
```

## Auto-injection Flow

```
1. codex/payments sends: cdash chat send --to backend "Are you done with UserSession?"
2. cdash chat sees claude/backend has proxy_pid=12345, state=idle
3. Writes "/tmp/claude-dash/12345.inject" with content: "cdash chat read"
4. Proxy poll loop sees inject file, state is ST_IDLE
5. Proxy writes "cdash chat read\n" to master_fd
6. Claude session receives it as user input, runs cdash chat read
7. Claude sees the message and can respond
```

## Constraints

- No daemon process — SQLite direct access only
- No MCP server — agents use Bash tool + cdash CLI
- No web server — dashboard app is the UI
- No config changes to Claude Code or Codex settings
- No task management, kanban, orchestration
- No auth, permissions, roles
- Total new code: ~200 LOC cdash additions, ~200 LOC Swift UI, ~15 LOC proxy
- Single SQLite db file, WAL mode
