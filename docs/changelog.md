# Changelog — Key Decisions

## State Tracking (pty-proxy.c)

### Detection Logic — DO NOT CHANGE

The `detect_state` function order is critical and was tuned through many iterations. The working version (PR #24, commit `383131f`):

```
1. Screen: "do you want to proceed?" + ("yes" | ❯) → needs_input
2. Screen: "esc to cancel" + ("enter to confirm" | "enter to select") → needs_input
3. Title: braille spinner (U+2800-U+28FF) → working
4. Title: ✳ sparkle (U+2733) → idle
5. Fallback: idle
```

**Screen checks MUST come before title checks.** The spinner persists in the title during permission prompts — if title is checked first, needs_input is never detected.

Reverted to this exact logic in `d9581ac`.

### What failed (do NOT repeat)

| Change | Why it failed | Commits |
|--------|--------------|---------|
| Title checks first, screen only when idle | Needs_input never detected — spinner overrides | `22e06a7` |
| Title expiry (30s/5min) | Causes working↔idle flicker when spinner update frequency varies | `37712e9`, `3ac6c36` |
| Require "esc to cancel" for all needs_input | "Esc to cancel" appears in Claude Code's normal UI tips → false positive | `9899a9a`, `033ca0c` |
| Require both "do you want to proceed?" + "esc to cancel" only | Removes detection of "enter to confirm/select" dialog prompts | `033ca0c` |
| Tighten to remove ❯ from needs_input check | Breaks detection of standard permission prompts | `5f600d5` |

### ANSI Stripping

The `ring_recent_clean` function strips ANSI escape sequences and inserts spaces at boundaries. This is essential — without it, "do you want to proceed?" is broken into fragments by escape codes and pattern matching fails.

Commit `893682c` (in PR #28 squash `64dc34f`).

### Ring Buffer

- Size: 8KB (`RING_SIZE`), but only last 4KB examined (`ring_recent_clean` caps at 4096)
- One render cycle is ~3-4KB of raw ANSI, so 4KB captures roughly one full screen
- After a screen redraw, old content gets pushed out naturally

### Debounce

- Working → idle: 4 confirmations × 200ms = 800ms delay (prevents flicker)
- Needs_input → other: no debounce (immediate transition)
- Check interval: 200ms (`CHECK_INTERVAL_MS`)

### Inject + State Interaction

- Inject files checked every poll loop when `current_state == ST_IDLE || idle_confirmations > 0`
- The `idle_confirmations > 0` allows inject during the debounce window
- 50ms delay between text write and `\r` submit — required for Codex TUI
- `\r` submits for Claude Code; Codex sometimes needs the delay but `\r` works

## Chat System (agent-chat.py, cdash)

### Architecture

```
Agent → cdash chat send → agent-chat.py → SQLite (dashboard-chat.db)
                                        → write inject file (/tmp/claude-dash/<pid>.inject)
Proxy → reads inject file when idle → types into terminal → \r to submit
Dashboard app → reads SQLite → displays in chat panel
```

No daemon, no MCP server. Agents use `cdash chat` via Bash tool. SQLite with WAL mode.

Key commit: `43c901d` (initial), squashed in `64dc34f`.

### Session Identity

- State file name is the single source of truth for session identity (`c5a3e13`)
- `cdash chat` resolves channel from chat db by session name
- Chat db stores `session_id` for stable identity across renames (`06938e9`)
- `isInChat` checks both name and session_id

### Channel = Tab

- Each dashboard tab maps to a chat channel
- Right-click session → "Add to Chat" shows channel picker submenu (`9f7db2b`)
- Agent can be in ONE channel at a time
- Moving session between tabs does NOT auto-remove from channel
- Removing from chat injects a notice to the agent

### Inject System

- Messages append to `/tmp/claude-dash/<pid>.inject` — multiple messages accumulate (`86611e7`)
- Proxy wraps accumulated messages with "New chat messages:" header (only if content starts with `- `)
- System notices (join/remove/intro) sent without wrapper
- Stale inject files cleaned on app launch (`3ae4ff7`)
- Inject only fires when agent is idle (proxy checks state)

### What failed (inject)

| Change | Why it failed | Commits |
|--------|--------------|---------|
| Ctrl+U before inject to clear input | Unpredictable in different TUIs | `1b3d774` (reverted `d8d5b69`) |
| Detect text after ❯ to skip inject | False positives from ANSI-stripped content | `206e581` (reverted `abb853e`) |
| `\r\n` for Codex submit | Both treated as newlines, not submit | reverted to `\r` only in `398071a` |
| Proxy auto-intro on first idle | Doubled with dashboard's "Add to Chat" inject | removed in `1893218` |

### Chat Commands

```bash
cdash chat send "message"              # broadcast (injects all agents in channel)
cdash chat send "message" --to name    # DM (injects that agent only)
cdash chat read                        # show new messages (first read: last 5 days)
cdash chat list                        # show online agents
```

### First Read Limit

First read (no cursor) limited to last 5 days to avoid dumping entire history. Subsequent reads show everything since cursor. No message count limit. Commit `5e2da93`, `6e00a79`.

## Session & Notes Tracking

### Session Discovery

- Claude: polls `~/.claude/sessions/*.json` every 0.5s
- Codex: `pgrep` for node processes, lsof for JSONL files, sqlite for names
- Only cdash-launched sessions tracked (`isCdashSession` checks state file for `proxy_pid`)

### Notes Migration on Resume

- Notes filename: `{name}____{sessionId_prefix}.txt`
- On resume: old session matched by name+cwd, notes file migrated to new sessionId
- If new file exists but is empty (0 bytes), overwrite with old notes
- Key fix: `9a44279`

### Dead Codex Sessions

- `loadCodexSessions` had early return when no live codex processes → dead sessions from store never loaded
- Fixed to always load dead sessions from store: `4509e55`

### Resume Commands

- Claude: `cdash claude --resume <id> --name '<name>' --effort max`
- Codex: `cdash codex --name '<name>' resume <id>`
- `--name` passed through to Claude CLI (sets session name), consumed-only for Codex (doesn't support it)
- `--effort max` auto-added for Claude if not specified: `b17a6fe`
- Key fixes: `fe83ec1`, `d78a4d4`, `1f2f3ce`

### Store Safety

- `loadStore` returns `(store, ok)` flag — skip save on parse failure
- Atomic writes
- `removedSessionIds` tracked in memory and filtered from store
- Stale store entries cleaned when PIDs match live sessions
