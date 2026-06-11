# Research & Lessons Learned

## State Detection (WORKING / IDLE)

### What works
- `isWorking()` using CPU + child process checks — imperfect but functional for UI display
- Hook state files (`/tmp/claude-dash/<pid>.state`) written by Stop and Notification hooks

### What doesn't work
- **Hooks for notifications**: hooks don't reliably fire for all sessions. Many sessions never get a state file written. Tested multiple times — always unreliable.
- **Hook ts-based notifications**: the state file gets deleted by `resolveState` (or was deleted before we stopped that). Even without deletion, hooks simply don't fire for every session.
- **CPU thresholds**: idle sessions with large context spike to 26% CPU. Threshold of 2% was too low, 10% too low, 30% too high. There's no single threshold that distinguishes idle from working across all sessions.
- **Child process existence check**: Claude always has persistent children (MCP servers, LSP). Checking `pgrep -P <pid>` always returns true. Useless as a sole signal.
- **Child process CPU check**: children (MCP servers) idle at 0% CPU. Only useful as a secondary signal.
- **Deleting state files on WORKING detection**: destroyed the only reliable signal (hook ts) before notification system could read it. Removed this.

### Current approach (as of 2026-06-11)
- `isWorking`: CPU > 30% OR any child CPU > 5%
- State file NOT deleted by resolveState
- If `isWorking` true → WORKING
- If `isWorking` false → check state file: "stop" → IDLE, "needs_input" → NEEDS INPUT

### Known issues
- Sessions with large context idle at 5-26% CPU — can trigger false WORKING
- `isWorking` only detects WORKING for 1-2 polls even during real 15+ second work
- State detection is fundamentally unreliable for precise timing

## Notifications (session finished)

### What works
- Simple state transition: `prev == .working && current != .working` — fires notifications but too many false positives from CPU spikes
- User's spec: track state changes, require WORKING for 5+ seconds before notifying on transition to IDLE

### What doesn't work
- **Hook ts-based notifications**: hooks don't fire reliably for all sessions. Tested 3+ times.
- **Duration-based filtering with isWorking**: `isWorking` only shows WORKING for 1-2 polls even during real work, so duration thresholds (10s, 15s) are never met
- **Debounce (3s idle after WORKING)**: state flickers WORKING↔IDLE every few seconds due to CPU noise, so 3s sustained idle rarely happens
- **Settling period (skip first N polls)**: helps with launch but doesn't prevent false positives during normal operation

### Current approach (as of 2026-06-11)
- Track `prevStates[sessionId]` per poll
- On transition: idle/needsInput → working: start timer (`workingTimer[sid] = Date()`)
- On transition: working → idle/needsInput: check timer duration
  - Timer < 5s: stop timer, no notification (false spike)
  - Timer >= 5s: stop timer, show notification (real work)
- Skip first 5 polls on launch

### Open problem
- CPU threshold (30%) may be too high to detect WORKING reliably, which means `workingTimer` never accumulates 5+ seconds. May need to lower threshold and accept some false WORKING in the UI to make notifications work.

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
