# Claude Dashboard — TODO

## Must-have
- [ ] Code signing — unsigned app triggers Gatekeeper warnings. Need Apple Developer ID or ad-hoc signing
- [ ] Stale session cleanup — dead sessions with no notes should auto-prune after X days
- [ ] Clean up `/tmp/claude-dash/` state files for dead PIDs
- [ ] Subprocess timeout — `shell()` calls can hang if `ps`/`pgrep` stall
- [ ] Debounce `saveStore()` — currently writes JSON to disk every 1s poll cycle

## Should-have
- [ ] Proper `.icns` app icon in bundle instead of runtime-generated dot
- [ ] Light mode support — verify HUD material + colors in light mode
- [ ] Multi-monitor — TextEdit positioning assumes same screen as dashboard
- [ ] Auto-update mechanism after install
- [ ] DMG / Homebrew distribution

## Nice-to-have
- [ ] Context window % per session (available in statusline JSON)
- [ ] Search/filter when 10+ sessions
- [ ] Click dead session → open transcript/last conversation
- [ ] Launch at login toggle in menu
- [ ] Sound notification when session changes to NEEDS INPUT
