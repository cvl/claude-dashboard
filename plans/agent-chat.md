# Agent Chat — Shared Communication Between Sessions

## Goal

Multiple Claude Code and Codex sessions communicate with each other through a shared chat, grouped by project. Human participates through the dashboard app. Messages can be auto-injected into idle sessions via the PTY proxy.

## Architecture

```
Claude session → MCP server (stdio) ──┐
Codex session  → MCP server (stdio) ──┼── SQLite (~/.claude/dashboard-chat.db)
Dashboard app (UI + human input) ──────┘
PTY proxy (inject messages into idle sessions)
```

No daemon, no web server. SQLite with WAL mode handles concurrency.

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
    recipient TEXT,  -- NULL = broadcast, session_id or display_name = DM, 'human' = escalation
    body TEXT NOT NULL,
    created_at INTEGER DEFAULT (unixepoch())
);

CREATE INDEX idx_messages_project ON messages(project_id, created_at);
CREATE INDEX idx_messages_recipient ON messages(recipient, created_at);
```

### 2. MCP Server (`agent-chat-mcp/`)

Thin stdio MCP server. Each session spawns its own instance. All instances read/write the same SQLite db.

**Environment:** `CDASH_PROJECT` (set by cdash CLI), `CDASH_SESSION_NAME` (optional).

**Tools:**

#### `join_chat`
- Params: `display_name` (optional), `project` (optional, falls back to `CDASH_PROJECT` or cwd basename)
- Creates project if needed, registers session
- Returns: `session_id`, `project`, list of active sessions
- Tool description includes: "You are `{name}` in project `{project}`. Call read_messages to check for team communication."

#### `send_message`
- Params: `to` (optional — omit for broadcast, or session name / "human"), `message`
- Inserts into messages table
- If recipient has a known proxy PID, writes inject file (`/tmp/claude-dash/{pid}.inject`)
- Returns: confirmation + recipient list

#### `send_message_to_human`
- Params: `message`, `urgency` ("info" | "decision_needed")
- Shortcut for human escalation. Dashboard shows it prominently.

#### `read_messages`
- Params: `since_id` (optional — last seen message ID), `limit` (default 20)
- Returns messages for this session's project (broadcasts + DMs to this session)
- Updates `last_seen` on the session record

#### `list_sessions`
- Returns active sessions in same project with status (last_seen recency)

**Stack:** TypeScript, `@anthropic-ai/sdk` or `@modelcontextprotocol/sdk`, `better-sqlite3`. Single file ~200 LOC.

### 3. Dashboard Chat UI (Swift, in `claude-dashboard.swift`)

New panel in the dashboard app — chat view alongside the existing session list.

**Layout:** Below the session list or as a toggleable pane. Shows:
- Project selector (dropdown or tabs if multiple projects)
- Message list: `Agent Type / Name    HH:mm` + message body
- Active sessions indicator (dot per session)
- Text input field for human messages
- Unread badge on chat toggle button

**Data flow:**
- Poll `dashboard-chat.db` every 1-2s (same timer as session poll)
- Read messages table for active project
- Human messages written directly to SQLite

**Alerts for human-directed messages:**
- Messages with `recipient = 'human'` or `urgency = 'decision_needed'` → dock bounce + ping (same as needs_input)

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

### 5. cdash CLI Changes

```bash
cdash claude --project vpn-platform [args...]
cdash codex --project crypto-checkout [args...]
```

- Sets `CDASH_PROJECT` env var before launching proxy
- Proxy passes it through to child (claude/codex process)
- MCP server reads it to scope all chat operations

Default project: basename of cwd if `--project` not given.

### 6. MCP Registration

Add to `~/.claude/settings.json` (via install.sh):

```json
{
  "mcpServers": {
    "agent-chat": {
      "command": "node",
      "args": ["/usr/local/lib/agent-chat-mcp/index.js"]
    }
  }
}
```

Similarly for Codex (`~/.codex/` config).

## Build Order

### Phase 1: Core (get messages flowing)
1. SQLite schema + db init
2. MCP server with join_chat, send_message, read_messages, list_sessions
3. Install script additions (MCP registration)
4. Test: two Claude sessions in same project exchange messages manually

### Phase 2: Dashboard integration
5. Chat UI panel in dashboard app (read-only first)
6. Human message input
7. Alerts for human-directed messages (dock bounce + ping)
8. Project selector

### Phase 3: Auto-injection
9. PTY proxy inject file support
10. MCP send_message writes inject file for idle recipients
11. Test: PM agent sends task, web-dev agent auto-receives and acts

### Phase 4: Polish
12. `cdash --project` flag
13. Unread counts in dashboard
14. Session presence (active/idle/disconnected based on last_seen)
15. Auto-join on `cdash claude` if project is set

## Constraints

- No daemon process — SQLite direct access only
- No web server — dashboard app is the UI
- No task management, kanban, orchestration
- No auth, permissions, roles
- Total new code: ~400-500 LOC (MCP server ~200, Swift UI ~200, proxy ~15)
- Single SQLite db file, WAL mode, no migrations beyond initial schema

## Risk: Agent Awareness

Agents won't proactively check messages unless prompted. Mitigations:
1. MCP tool descriptions tell agents they're part of a project team
2. `join_chat` response reminds them to check periodically
3. PTY injection for idle sessions (Phase 3) — most reliable
4. Dashboard alerts for human when agents message them
