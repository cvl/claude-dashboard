# Claude Dashboard — Specification

## Overview

Native macOS menu bar + floating window app for monitoring Claude Code sessions, managing terminal tabs, and restoring window layouts.

## Claude Sessions

### Discovery
- Polls `~/.claude/sessions/*.json` every 1 second to discover sessions.
- Live sessions: process is alive (`kill(pid, 0) == 0`).
- Dead sessions: loaded from the persistent store (`dashboard-store.json`).

### State Detection
- **WORKING**: process CPU > 2% OR any child process exists.
- **NEEDS INPUT**: hook state file says `needs_input` (permission prompt).
- **IDLE**: hook state file says `stop`, or no signal from CPU/children.
- **DEAD**: process no longer exists.
- When WORKING is detected, the hook state file is cleared.
- State detection uses Claude Code hooks (`Notification` and `Stop`) that write to `/tmp/claude-dash/<pid>.state`.

### Session Cards
- Each session is a card showing: name, state label, state color accent, path, PID, time since last activity.
- Long names are truncated with "…". Hovering the card shows the full name instantly (no system tooltip delay).
- Dead sessions show a remove button (X) next to the state label.

### Session Ordering
- Sessions can ONLY be reordered manually via drag and drop.
- New sessions are automatically appended to the saved order when first seen.
- Resumed sessions (new sessionId, same name+cwd) inherit the order position of the old session.
- Order persists in UserDefaults (`sessionOrder`).
- No automatic sorting ever overrides the manual order.

### Session Resume
- Play button copies a resume command to clipboard: `cd <cwd> && claude --resume <id> --name '<name>' --effort max`
- A toast "Resume command copied" appears centered on the card for 2 seconds.

### Resumed Session Detection
- When a session is resumed, Claude Code creates a new sessionId.
- Dashboard detects this by matching dead store entries with live sessions by name+cwd.
- Old store entry is removed; tab assignment and order position transfer to the new sessionId.
- Notes file is renamed to match the new sessionId.

### Session Removal
- Click X on a dead session → confirmation dialog → removed from store.
- Removed session IDs are tracked in memory to prevent poll re-adding them.
- Notes files are kept (never auto-deleted).

### Session Notes
- Each session has a notes file at `~/.claude/dashboard-notes/<name>___<sessionId[:8]>.txt`.
- Notes button opens the file in the default text editor.
- When a session is renamed, the notes file is renamed too.

### Session History
- All sessions are logged to `~/.claude/dashboard-notes/history.txt`.
- Each entry: date, name, cwd, notes filename, resume command.
- When a session is renamed, a `[renamed from '<old>']` entry is appended with updated info.
- Existing sessions are backfilled on first run (when history.txt doesn't exist).

## Named Terminals

### Registration
- `claudedashboard <name>` CLI registers the current terminal tab.
- Stores TTY, name, cwd, timestamp in `~/.claude/dashboard-terminals.json`.

### Display
- Shown in a TERMINALS section below Claude sessions.
- Each card: name, path, ACTIVE/CLOSED status, teal accent.
- Click to reveal terminal window. X to remove.
- Active/closed determined by checking if the TTY has running processes.

## Terminal Reveal
- Click a session or terminal card → activates Terminal.app (or iTerm2) first via `NSRunningApplication.activate()`, then after 100ms selects the correct tab/window via AppleScript.
- The 100ms delay ensures the app is frontmost before tab selection, which fixes cross-monitor focus issues.
- Works with both Terminal.app and iTerm2 (auto-detected).

## Tab Buckets

### Structure
- Vertical tab sidebar as a separate borderless floating window to the left of the main dashboard.
- Default tab: "main" (renamable but not deletable). Shows all sessions/terminals not assigned to other tabs.
- Other tabs show only their assigned items.
- Tabs persist to `~/.claude/dashboard-tabs.json`.

### Interaction
- Click tab to switch view.
- "+" button to add new tab (prompts for name, auto-selects).
- Double-click tab to rename.
- Right-click tab: Rename / Delete (delete has confirmation, items return to main).
- Drag session or terminal card onto a tab to move it there.
- Dragging to "main" removes the item from its current tab (returns to unassigned).

### Visibility
- "Show Tabs" toggle in tray menu (off by default).
- Hiding tabs hides the sidebar but preserves all assignments.

## Window Layout Save/Restore

### Auto-save
- Saves all terminal window positions on launch and every 5 minutes.
- Saves screen count alongside positions.
- Skips saving when screen count is less than previously saved (monitors disconnected = scrambled state).

### Auto-restore
- Triggers on screen wake and display reconfiguration (monitor reconnect).
- 3-second delay for displays to settle.
- Skips restore if current screen count < saved screen count (monitors not all back).

### Manual
- "Save Terminal Layout" and "Restore Terminal Layout" in tray menu.
- Layout stored in `~/.claude/dashboard-layout.json`.

## Menu Bar

### Icon
- Colored dot: orange (needs input), green (working), gray (idle/none).
- Count shown next to dot for working or needs-input sessions.

### Dock Icon
- Rounded square with colored dot matching the menu bar state.

### Tray Menu Items
1. Show/Hide Dashboard (Cmd+H)
2. Always on Top (toggle, default on)
3. Wake on Attention (toggle)
4. Show Tabs (toggle, default off)
5. Open Notes Folder
6. Save Terminal Layout
7. Restore Terminal Layout
8. Session list with state emoji
9. Quit (Cmd+Q)

## Window Behavior
- Closing the window hides it (does not release). Reopen via dock click, tray menu, or Cmd+H.
- Always on Top: floating window level.
- Movable by window background.
- Appears on all Spaces.

## Idle Sleep Prevention
- While any session is WORKING, runs `caffeinate -i` to prevent idle sleep.
- Stops when no sessions are working.
- Checks `isRunning` before terminating caffeinate (prevents crash if already exited).

## Wake on Attention
- When enabled: wakes the display when a session transitions from working to needs-input, or finishes after 1+ minute of work.
- One-shot per transition (doesn't repeatedly wake).

## Store Safety
- `loadStore` distinguishes "file missing" (ok) from "parse failed" (skip save).
- `saveStore` uses atomic writes.
- Prevents race condition where a failed read + save would wipe dead sessions.

## Auto-setup
- On first launch, creates all directories, installs hook script, registers hooks in Claude Code settings.json.
- Hooks: `Notification` (permission_prompt → needs_input), `Stop` (→ stop).
