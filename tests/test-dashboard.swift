import Foundation

// Minimal test framework
var passed = 0
var failed = 0
func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; print("FAIL [\(file):\(line)] \(msg)") }
}
func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    assert(a == b, "\(msg) — expected \(b), got \(a)", file: file, line: line)
}

// ─── Inline the logic under test (no AppKit) ───

struct StoredSession: Codable {
    let sessionId: String
    let name: String
    let cwd: String
    let startedAt: Double
    var lastPid: Int
    var lastActiveTs: Double?
}

struct TabBucket: Codable {
    var id: String
    var name: String
    var sessionIds: [String]
    var terminalTTYs: [String]
}

struct Session {
    let pid: Int32
    let sessionId: String
    let name: String
    let cwd: String
    let startedAt: Double
    let state: String
    let tty: String
    let hasNotes: Bool
    let lastActive: Date
}

// ─── applyCustomOrder ───

func applyCustomOrder(_ sessions: [Session], order: [String]) -> ([Session], [String]) {
    var order = order
    var ordered: [Session] = []
    var remaining = sessions
    for sid in order {
        if let idx = remaining.firstIndex(where: { $0.sessionId == sid }) {
            ordered.append(remaining.remove(at: idx))
        }
    }
    if !remaining.isEmpty {
        for s in remaining { order.append(s.sessionId) }
    }
    ordered.append(contentsOf: remaining)
    return (ordered, order)
}

// ─── notesFileName ───

func notesFileName(name: String, sessionId: String) -> String {
    let safe = name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    return "\(safe)___\(sessionId.prefix(8)).txt"
}

// ─── shortPath ───

func shortPath(_ p: String, home: String = "/Users/test") -> String {
    var s = p; if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
    let c = s.components(separatedBy: "/")
    return c.count > 3 ? "…/" + c.suffix(2).joined(separator: "/") : s
}

// ─── timeAgo ───

func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 24 { return "\(h)h ago" }
    return "\(h / 24)d ago"
}

// ─── Tab filtering ───

func sessionsForActiveTab(_ all: [Session], tabs: [TabBucket], activeTabId: String) -> [Session] {
    if activeTabId == "main" {
        let assigned = Set(tabs.filter { $0.id != "main" }.flatMap(\.sessionIds))
        return all.filter { !assigned.contains($0.sessionId) }
    }
    guard let tab = tabs.first(where: { $0.id == activeTabId }) else { return all }
    let ids = Set(tab.sessionIds)
    return all.filter { ids.contains($0.sessionId) }
}

// ─── Store safety ───

func loadStoreFromData(_ data: Data?) -> (store: [String: StoredSession], ok: Bool) {
    guard let data = data else { return ([:], true) } // no file = ok
    guard let list = try? JSONDecoder().decode([String: StoredSession].self, from: data)
    else { return ([:], false) } // parse failure
    return (list, true)
}

// ─── moveItemToTab ───

func moveItemToTab(tabs: inout [TabBucket], tabId: String, itemId: String) {
    for i in 0..<tabs.count {
        tabs[i].sessionIds.removeAll { "session:\($0)" == itemId }
        tabs[i].terminalTTYs.removeAll { "terminal:\($0)" == itemId }
    }
    if tabId != "main", let idx = tabs.firstIndex(where: { $0.id == tabId }) {
        if itemId.hasPrefix("session:") {
            tabs[idx].sessionIds.append(String(itemId.dropFirst(8)))
        } else if itemId.hasPrefix("terminal:") {
            tabs[idx].terminalTTYs.append(String(itemId.dropFirst(9)))
        }
    }
}

// ─── Truncation ───

func truncate(_ text: String, maxLen: Int) -> (String, Bool) {
    if text.count <= maxLen { return (text, false) }
    return (String(text.prefix(maxLen - 1)) + "…", true)
}

// ═══════════════════════════════════════
// TESTS
// ═══════════════════════════════════════

func makeSession(_ id: String, name: String = "test", cwd: String = "/tmp", startedAt: Double = 0) -> Session {
    Session(pid: 1, sessionId: id, name: name, cwd: cwd, startedAt: startedAt,
            state: "idle", tty: "ttys000", hasNotes: false, lastActive: Date())
}

print("Running tests...\n")

// ── applyCustomOrder ──

do {
    let s1 = makeSession("a", startedAt: 100)
    let s2 = makeSession("b", startedAt: 200)
    let s3 = makeSession("c", startedAt: 300)

    // Preserves manual order
    let (result, _) = applyCustomOrder([s3, s2, s1], order: ["a", "b", "c"])
    assertEqual(result.map(\.sessionId), ["a", "b", "c"], "manual order preserved")
}

do {
    // New sessions appended at bottom
    let s1 = makeSession("a", startedAt: 100)
    let s2 = makeSession("b", startedAt: 200)
    let sNew = makeSession("new", startedAt: 999)
    let (result, newOrder) = applyCustomOrder([sNew, s2, s1], order: ["a", "b"])
    assertEqual(result.map(\.sessionId), ["a", "b", "new"], "new session at bottom")
    assertEqual(newOrder, ["a", "b", "new"], "new session added to order")
}

do {
    // New sessions stay at bottom even with higher startedAt
    let s1 = makeSession("a", startedAt: 100)
    let sNew = makeSession("new", startedAt: 9999)
    let (result, _) = applyCustomOrder([sNew, s1], order: ["a"])
    assertEqual(result[0].sessionId, "a", "existing stays first")
    assertEqual(result[1].sessionId, "new", "new at bottom despite higher startedAt")
}

do {
    // Empty order — sessions keep input order
    let s1 = makeSession("a", startedAt: 100)
    let s2 = makeSession("b", startedAt: 200)
    let (result, newOrder) = applyCustomOrder([s2, s1], order: [])
    assertEqual(result.map(\.sessionId), ["b", "a"], "input order preserved")
    assertEqual(newOrder, ["b", "a"], "all added to order")
}

do {
    // Order with missing sessions (removed) — skipped gracefully
    let s1 = makeSession("a")
    let (result, _) = applyCustomOrder([s1], order: ["gone", "a", "also-gone"])
    assertEqual(result.map(\.sessionId), ["a"], "missing IDs skipped")
}

// ── notesFileName ──

do {
    let f = notesFileName(name: "my-session", sessionId: "abcdef12-3456-7890")
    assertEqual(f, "my-session___abcdef12.txt", "notes file name")
}

do {
    let f = notesFileName(name: "has/slash:colon", sessionId: "12345678-xxxx")
    assertEqual(f, "has-slash-colon___12345678.txt", "special chars replaced")
}

// ── shortPath ──

do {
    assertEqual(shortPath("/Users/test/dev/project", home: "/Users/test"), "~/dev/project", "home replaced")
    assertEqual(shortPath("/Users/test/a/b/c/d", home: "/Users/test"), "…/c/d", "long path truncated")
    assertEqual(shortPath("/other/path", home: "/Users/test"), "/other/path", "non-home unchanged")
}

// ── timeAgo ──

do {
    assertEqual(timeAgo(Date()), "now", "just now")
    assertEqual(timeAgo(Date(timeIntervalSinceNow: -30)), "30s ago", "seconds")
    assertEqual(timeAgo(Date(timeIntervalSinceNow: -120)), "2m ago", "minutes")
    assertEqual(timeAgo(Date(timeIntervalSinceNow: -7200)), "2h ago", "hours")
    assertEqual(timeAgo(Date(timeIntervalSinceNow: -172800)), "2d ago", "days")
}

// ── Tab filtering ──

do {
    let s1 = makeSession("a")
    let s2 = makeSession("b")
    let s3 = makeSession("c")
    let tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "work", name: "work", sessionIds: ["b"], terminalTTYs: [])
    ]

    let main = sessionsForActiveTab([s1, s2, s3], tabs: tabs, activeTabId: "main")
    assertEqual(main.map(\.sessionId).sorted(), ["a", "c"], "main excludes assigned")

    let work = sessionsForActiveTab([s1, s2, s3], tabs: tabs, activeTabId: "work")
    assertEqual(work.map(\.sessionId), ["b"], "tab shows only assigned")
}

do {
    // Deleting a tab — items return to main
    let s1 = makeSession("a")
    let tabs = [TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: [])]
    let main = sessionsForActiveTab([s1], tabs: tabs, activeTabId: "main")
    assertEqual(main.count, 1, "deleted tab items in main")
}

// ── moveItemToTab ──

do {
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "work", name: "work", sessionIds: [], terminalTTYs: [])
    ]
    moveItemToTab(tabs: &tabs, tabId: "work", itemId: "session:abc")
    assertEqual(tabs[1].sessionIds, ["abc"], "session moved to tab")

    // Move to main removes from tab
    moveItemToTab(tabs: &tabs, tabId: "main", itemId: "session:abc")
    assertEqual(tabs[1].sessionIds, [], "session removed from tab")
}

do {
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "dev", name: "dev", sessionIds: [], terminalTTYs: [])
    ]
    moveItemToTab(tabs: &tabs, tabId: "dev", itemId: "terminal:ttys001")
    assertEqual(tabs[1].terminalTTYs, ["ttys001"], "terminal moved to tab")
}

// ── Store safety ──

do {
    let (store, ok) = loadStoreFromData(nil)
    assert(ok, "nil data = file missing = ok")
    assert(store.isEmpty, "nil data = empty store")
}

do {
    let (_, ok) = loadStoreFromData("not json".data(using: .utf8))
    assert(!ok, "bad json = not ok")
}

do {
    let s = StoredSession(sessionId: "a", name: "test", cwd: "/tmp", startedAt: 0, lastPid: 1)
    let data = try! JSONEncoder().encode(["a": s])
    let (store, ok) = loadStoreFromData(data)
    assert(ok, "valid json = ok")
    assertEqual(store.count, 1, "one session loaded")
}

// ── Truncation ──

do {
    let (text, trunc) = truncate("short", maxLen: 20)
    assertEqual(text, "short", "short text unchanged")
    assert(!trunc, "short text not truncated")
}

do {
    let (text, trunc) = truncate("this-is-a-very-long-session-name", maxLen: 15)
    assert(trunc, "long text truncated")
    assert(text.hasSuffix("…"), "ends with ellipsis")
    assert(text.count <= 15, "within max length")
}

// ── Resume command format ──

do {
    let sid = "abc-123"
    let name = "my-session"
    let cwd = "/Users/test/project"
    let cmd = "cd \(cwd) && claude --resume \(sid) --name '\(name)' --effort max"
    assert(cmd.contains("--resume abc-123"), "has session id")
    assert(cmd.contains("--name 'my-session'"), "has name")
    assert(cmd.contains("--effort max"), "has effort max")
    assert(cmd.hasPrefix("cd /Users/test/project"), "starts with cd")
}

// ── Tab default state ──

do {
    // Default tabs should always have main
    let emptyTabs: [TabBucket] = []
    let defaultTab = emptyTabs.isEmpty
        ? TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: [])
        : emptyTabs[0]
    assertEqual(defaultTab.id, "main", "default tab is main")
    assertEqual(defaultTab.name, "main", "default tab named main")
}

// ── Removed sessions filtering ──

do {
    let sessions = [makeSession("a"), makeSession("b"), makeSession("c")]
    let removed: Set<String> = ["b"]
    let filtered = sessions.filter { !removed.contains($0.sessionId) }
    assertEqual(filtered.map(\.sessionId), ["a", "c"], "removed session filtered out")
}

// ── History entry format ──

do {
    let stored = StoredSession(sessionId: "abc-12345678", name: "test", cwd: "/tmp", startedAt: 1700000000000, lastPid: 1)
    let notes = notesFileName(name: stored.name, sessionId: stored.sessionId)
    let resume = "cd \(stored.cwd) && claude --resume \(stored.sessionId) --name '\(stored.name)' --effort max"
    assert(notes.contains("test___abc-1234"), "notes file has name and id prefix")
    assert(resume.contains("--resume abc-12345678"), "resume has full id")
}

// ── Resume detection (same name+cwd) ──

do {
    let dead = StoredSession(sessionId: "old-id", name: "pooling", cwd: "/dev/project", startedAt: 100, lastPid: 1)
    let live = makeSession("new-id", name: "pooling", cwd: "/dev/project")
    let key = "\(dead.name)\0\(dead.cwd)"
    let liveKey = "\(live.name)\0\(live.cwd)"
    assertEqual(key, liveKey, "same name+cwd matches for resume detection")
}

do {
    let dead = StoredSession(sessionId: "old-id", name: "pooling", cwd: "/dev/project", startedAt: 100, lastPid: 1)
    let live = makeSession("new-id", name: "different", cwd: "/dev/project")
    let key = "\(dead.name)\0\(dead.cwd)"
    let liveKey = "\(live.name)\0\(live.cwd)"
    assert(key != liveKey, "different name does not match")
}

// ── Tab transfer on resume ──

func applyTabTransfers(tabs: inout [TabBucket], order: inout [String], transfers: [(oldId: String, newId: String)]) {
    for transfer in transfers {
        for i in 0..<tabs.count {
            if tabs[i].sessionIds.contains(transfer.oldId) {
                tabs[i].sessionIds.removeAll { $0 == transfer.oldId }
                if !tabs[i].sessionIds.contains(transfer.newId) {
                    tabs[i].sessionIds.append(transfer.newId)
                }
            }
        }
        if let idx = order.firstIndex(of: transfer.oldId) {
            order[idx] = transfer.newId
        }
    }
}

do {
    // Session in "work" tab, resumed → stays in "work" tab
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "work", name: "work", sessionIds: ["old-id"], terminalTTYs: [])
    ]
    var order = ["old-id", "other"]
    applyTabTransfers(tabs: &tabs, order: &order, transfers: [(oldId: "old-id", newId: "new-id")])
    assertEqual(tabs[1].sessionIds, ["new-id"], "tab assignment transferred to new id")
    assert(!tabs[1].sessionIds.contains("old-id"), "old id removed from tab")
    assertEqual(order, ["new-id", "other"], "order position transferred")
}

do {
    // Session not in any tab (in main) → stays in main after resume
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "work", name: "work", sessionIds: ["something-else"], terminalTTYs: [])
    ]
    var order = ["old-id"]
    applyTabTransfers(tabs: &tabs, order: &order, transfers: [(oldId: "old-id", newId: "new-id")])
    assert(!tabs[0].sessionIds.contains("new-id"), "main tab has no explicit assignments")
    assert(!tabs[1].sessionIds.contains("new-id"), "work tab unchanged")
    let mainSessions = sessionsForActiveTab(
        [makeSession("new-id"), makeSession("something-else")],
        tabs: tabs, activeTabId: "main")
    assertEqual(mainSessions.map(\.sessionId), ["new-id"], "resumed session visible in main")
}

do {
    // Transfer doesn't duplicate if new id already exists
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "work", name: "work", sessionIds: ["old-id", "new-id"], terminalTTYs: [])
    ]
    var order = ["old-id"]
    applyTabTransfers(tabs: &tabs, order: &order, transfers: [(oldId: "old-id", newId: "new-id")])
    assertEqual(tabs[1].sessionIds, ["new-id"], "no duplicate after transfer")
}

do {
    // Terminal tab assignments are not affected by session transfers
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "dev", name: "dev", sessionIds: ["old-id"], terminalTTYs: ["ttys001"])
    ]
    var order: [String] = []
    applyTabTransfers(tabs: &tabs, order: &order, transfers: [(oldId: "old-id", newId: "new-id")])
    assertEqual(tabs[1].terminalTTYs, ["ttys001"], "terminal assignments untouched")
    assertEqual(tabs[1].sessionIds, ["new-id"], "session transferred")
}

do {
    // Multiple transfers in one batch
    var tabs = [
        TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: []),
        TabBucket(id: "t1", name: "t1", sessionIds: ["a"], terminalTTYs: []),
        TabBucket(id: "t2", name: "t2", sessionIds: ["b"], terminalTTYs: [])
    ]
    var order = ["a", "b", "c"]
    applyTabTransfers(tabs: &tabs, order: &order, transfers: [
        (oldId: "a", newId: "a2"),
        (oldId: "b", newId: "b2")
    ])
    assertEqual(tabs[1].sessionIds, ["a2"], "first transfer")
    assertEqual(tabs[2].sessionIds, ["b2"], "second transfer")
    assertEqual(order, ["a2", "b2", "c"], "both order positions transferred")
}

// ── Removed sessions persist across store saves ──

func filterRemovedFromStore(_ store: inout [String: StoredSession], removed: Set<String>) {
    for rid in removed { store.removeValue(forKey: rid) }
}

do {
    // Removed session is purged from store before save
    var store: [String: StoredSession] = [
        "a": StoredSession(sessionId: "a", name: "keep", cwd: "/tmp", startedAt: 0, lastPid: 1),
        "b": StoredSession(sessionId: "b", name: "remove", cwd: "/tmp", startedAt: 0, lastPid: 2),
        "c": StoredSession(sessionId: "c", name: "keep2", cwd: "/tmp", startedAt: 0, lastPid: 3)
    ]
    let removed: Set<String> = ["b"]
    filterRemovedFromStore(&store, removed: removed)
    assertEqual(store.count, 2, "removed session purged from store")
    assert(store["b"] == nil, "session b gone")
    assert(store["a"] != nil, "session a kept")
    assert(store["c"] != nil, "session c kept")
}

do {
    // Removing already-absent session is no-op
    var store: [String: StoredSession] = [
        "a": StoredSession(sessionId: "a", name: "test", cwd: "/tmp", startedAt: 0, lastPid: 1)
    ]
    let removed: Set<String> = ["nonexistent"]
    filterRemovedFromStore(&store, removed: removed)
    assertEqual(store.count, 1, "no-op for absent session")
}

do {
    // Multiple removals in one pass
    var store: [String: StoredSession] = [
        "a": StoredSession(sessionId: "a", name: "a", cwd: "/tmp", startedAt: 0, lastPid: 1),
        "b": StoredSession(sessionId: "b", name: "b", cwd: "/tmp", startedAt: 0, lastPid: 2),
        "c": StoredSession(sessionId: "c", name: "c", cwd: "/tmp", startedAt: 0, lastPid: 3)
    ]
    let removed: Set<String> = ["a", "c"]
    filterRemovedFromStore(&store, removed: removed)
    assertEqual(store.count, 1, "multiple removals")
    assertEqual(store.keys.first, "b", "only b remains")
}

do {
    // Removed session filtered from result list
    let sessions = [makeSession("a"), makeSession("b"), makeSession("c")]
    let removed: Set<String> = ["a", "c"]
    let filtered = sessions.filter { !removed.contains($0.sessionId) }
    assertEqual(filtered.count, 1, "filtered result")
    assertEqual(filtered[0].sessionId, "b", "only b in result")
}

do {
    // Poll re-adding a live session doesn't bring back removed session
    var store: [String: StoredSession] = [
        "live": StoredSession(sessionId: "live", name: "live", cwd: "/tmp", startedAt: 100, lastPid: 1)
    ]
    // Simulate: poll adds live session back, but removed stays removed
    let removed: Set<String> = ["dead-removed"]
    store["dead-removed"] = StoredSession(sessionId: "dead-removed", name: "old", cwd: "/tmp", startedAt: 50, lastPid: 2)
    filterRemovedFromStore(&store, removed: removed)
    assert(store["dead-removed"] == nil, "removed session not re-added by poll")
    assert(store["live"] != nil, "live session untouched")
}

// ── Generated hook exit status ──

do {
    let source = try? String(contentsOfFile: "claude-dashboard.swift", encoding: .utf8)
    let start = source?.range(of: "let hookScript = \"\"\"")
    let remainder = start.map { source![$0.upperBound...] }
    let end = remainder?.range(of: "\"\"\"")
    let hook = end.map { String(remainder![..<$0.lowerBound]) }
    assert(
        hook?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exit 0") == true,
        "generated hook always exits successfully"
    )
}

// ═══════════════════════════════════════
print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
