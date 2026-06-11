# Research & Lessons Learned

## State Detection (WORKING / IDLE)

### What works
- **Hook-based state detection** (proven by tmux-agent-status, claude-control, claude-status):
  - `UserPromptSubmit` hook → write "working" to state file (agent started)
  - `Stop` hook → write "stop" to state file (agent finished)
  - `Notification` hook with `permission_prompt` → write "needs_input" (waiting for approval)
  - No CPU checking. No child process checking. Just hooks.
- **JSONL mtime fallback**: watch `~/.claude/projects/<path>/<sessionId>.jsonl` modification time. If mtime changes between polls, session is actively working. Reliable backup when hooks don't fire.

### What doesn't work
- **CPU-based detection (`isWorking`)**: fundamentally unreliable
  - Idle sessions with large context spike to 5-26% CPU
  - Threshold of 2% too low, 10% too low, 30% too high — no single threshold works
  - `isWorking` only detects WORKING for 1-2 polls even during real 15+ second work
  - Cannot distinguish real work from background CPU noise
- **Child process existence check**: Claude always has persistent children (MCP servers, LSP). `pgrep -P <pid>` always returns true. Useless as a sole signal.
- **Child process CPU check**: children (MCP servers) idle at 0% CPU. Only useful as a secondary signal but still unreliable.
- **Deleting state files on WORKING detection**: destroyed the hook signal before notification system could read it.
- **Duration-based filtering with CPU detection**: `isWorking` shows WORKING for only 1-2 polls even during real work, so duration thresholds (5s, 10s, 15s) are never met.

### Why our hooks "didn't work" before
1. We only had `Stop` and `Notification` hooks — never added `UserPromptSubmit` for detecting "started working"
2. Our hook script was slow — ran python3 per session file to find PID
3. `resolveState` deleted the state file on every poll when CPU was high
4. Known Claude Code bug: hooks stop executing after ~2.5 hours (github.com/anthropics/claude-code/issues/16047)

### Correct approach (from open source projects)
- **tmux-agent-status**: `UserPromptSubmit` → "working", `Stop` → "done", `SessionStart` → seed resumed sessions. State tracked entirely through hooks.
- **claude-control**: hooks + CPU/JSONL heuristic fallback
- **claude-status**: plugin writes `.cstatus` file on lifecycle events + Darwin notification + 5s polling fallback

### References
- https://github.com/samleeney/tmux-agent-status
- https://github.com/sverrirsig/claude-control
- https://github.com/gmr/claude-status
- https://code.claude.com/docs/en/hooks
- https://github.com/anthropics/claude-code/issues/16047 (hooks stop after 2.5h)
- https://github.com/anthropics/claude-code/issues/43058 (session state hook events request)

## Notifications (session finished)

### What works
- User's spec: track state changes, if working >= 5s then notify on idle transition
- Hook-based: `UserPromptSubmit` → start timer, `Stop` → check timer, notify if >= 5s

### What doesn't work
- **Hook ts-based notifications with Stop only**: no "started working" signal, can't measure duration
- **CPU-based state transitions for notifications**: too many false positives from CPU spikes, too few true positives from real work
- **Debounce (3s idle after WORKING)**: state flickers due to CPU noise
- **Settling period (skip first N polls)**: helps with launch but doesn't prevent false positives

## Window Management

### Terminal reveal (click to open)
- Must call `NSRunningApplication.activate()` FIRST on main thread
- Then after 100ms delay, run AppleScript to select the tab/window
- Without the delay, macOS focuses the wrong window (especially cross-monitor)
- `tabPanel.orderFront(nil)` every poll tick steals focus — only call on visibility change

### Window close
- `isReleasedWhenClosed = false` + `windowShouldClose` returns false and hides instead
- Without this, closing the window deallocates it and crashes on next poll

### File descriptors
- `shell()` must close pipe file handles explicitly after reading
- Without this, FDs leak over time (~86400/day) until osascript can't spawn

## Store / Persistence

### Race conditions
- `loadStore` returning empty on parse failure + `saveStore` writing it back = wipes all dead sessions
- Fix: `loadStore` returns `(store, ok)` flag, skip save on parse failure
- Fix: atomic writes with `.atomic` option
- Fix: `removedSessionIds` tracked in memory AND filtered from store before save

### Session resume
- Claude Code creates NEW sessionId on `--resume`
- Must detect by matching name+cwd, transfer: store entry, tab assignment, order position
- All transfers must happen on main thread (not poll queue) to avoid stale data race

## Tabs
- Floating borderless window as child of main panel
- `orderFront` only on visibility change — calling every poll steals focus from main panel
- Tab assignments modified only on main thread
