import Cocoa

// MARK: - Config

let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("sessions")
let pollInterval: TimeInterval = 1
let notesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-notes").path
let storeFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-store.json").path
let layoutFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-layout.json").path
let tabsFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-tabs.json").path
let activeTabFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-active-tab").path
let logFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard.log").path
let codexSessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex").appendingPathComponent("sessions")
let codexHooksFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex").appendingPathComponent("hooks.json").path

func dashLog(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: logFile) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: logFile, atomically: true, encoding: .utf8)
    }
    // Rotate: keep last 1000 lines
    if let content = try? String(contentsOfFile: logFile, encoding: .utf8) {
        let lines = content.components(separatedBy: "\n")
        if lines.count > 5500 {
            let trimmed = lines.suffix(5000).joined(separator: "\n")
            try? trimmed.write(toFile: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Tabs

struct TabBucket: Codable {
    var id: String
    var name: String
    var sessionIds: [String]
    var terminalTTYs: [String]
}

func loadTabs() -> [TabBucket] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: tabsFile)),
          let tabs = try? JSONDecoder().decode([TabBucket].self, from: data)
    else { return [TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: [])] }
    return tabs.isEmpty ? [TabBucket(id: "main", name: "main", sessionIds: [], terminalTTYs: [])] : tabs
}

func saveTabs(_ tabs: [TabBucket]) {
    guard let data = try? JSONEncoder().encode(tabs) else { return }
    try? data.write(to: URL(fileURLWithPath: tabsFile), options: .atomic)
}

// MARK: - Model

enum State: String, CaseIterable {
    case working, needsInput, idle, dead

    var label: String {
        switch self {
        case .working: return "WORKING"
        case .needsInput: return "NEEDS INPUT"
        case .idle: return "IDLE"
        case .dead: return "DEAD"
        }
    }
    var color: NSColor {
        switch self {
        case .working:    return .systemGreen
        case .needsInput: return .systemOrange
        case .idle:       return .systemGray
        case .dead:       return .systemRed
        }
    }
    var emoji: String {
        switch self {
        case .working: return "🟢"
        case .needsInput: return "🟡"
        case .idle: return "⚫"
        case .dead: return "🔴"
        }
    }
    var order: Int {
        switch self {
        case .working: return 0; case .needsInput: return 1
        case .idle: return 2; case .dead: return 3
        }
    }
}

struct Session {
    let pid: pid_t
    let sessionId: String
    let name: String
    let cwd: String
    let startedAt: Double
    let state: State
    let tty: String
    let hasNotes: Bool
    let lastActive: Date
    let hookTs: Int  // timestamp from hook state file, 0 if none
    let source: String  // "claude" or "codex"
}

struct Terminal {
    let tty: String
    let name: String
    let cwd: String
    let isAlive: Bool
}

let pinnedFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-pinned.json").path

struct PinnedItem: Codable {
    let id: String       // sessionId or terminal name
    let type: String     // "session" or "terminal"
    let name: String
    let cwd: String
    let tty: String
}

func loadPinned() -> [PinnedItem] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: pinnedFile)),
          let list = try? JSONDecoder().decode([PinnedItem].self, from: data)
    else { return [] }
    return list
}

func savePinned(_ items: [PinnedItem]) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    try? data.write(to: URL(fileURLWithPath: pinnedFile), options: .atomic)
}

let termStoreFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-terminals.json").path

func loadRegisteredTerminals() -> [Terminal] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: termStoreFile)),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return [] }
    var result: [Terminal] = []
    for (_, entry) in dict {
        guard let name = entry["name"] as? String else { continue }
        let cwd = entry["cwd"] as? String ?? ""
        let storedPid = entry["pid"] as? Int ?? 0
        // Check liveness by stored shell PID
        let alive = storedPid > 0 && kill(pid_t(storedPid), 0) == 0
        // Look up current TTY from the shell PID (not stored TTY which may be stale)
        let tty = alive ? shell("/bin/ps", "-o", "tty=", "-p", "\(storedPid)") : ""
        result.append(Terminal(tty: tty, name: name, cwd: cwd, isAlive: alive))
    }
    return result.sorted { $0.name < $1.name }
}

func removeRegisteredTerminal(_ name: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: termStoreFile)),
          var dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return }
    dict.removeValue(forKey: name)
    if let out = try? JSONSerialization.data(withJSONObject: dict) {
        try? out.write(to: URL(fileURLWithPath: termStoreFile))
    }
}



// MARK: - Process helpers

func shell(_ path: String, _ args: String...) -> String {
    let proc = Process()
    let pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = Array(args)
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return "" }
    // Read before wait to avoid pipe buffer deadlock
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    pipe.fileHandleForReading.closeFile()
    pipe.fileHandleForWriting.closeFile()
    proc.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

let stateDir = "/tmp/claude-dash"
var previousState: [pid_t: State] = [:]
var lastActiveTime: [pid_t: Date] = [:]

func stateFileEvent(_ pid: pid_t) -> (event: String, ts: Int)? {
    let url = URL(fileURLWithPath: "\(stateDir)/\(pid).state")
    guard let data = try? Data(contentsOf: url),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = j["event"] as? String,
          let ts = j["ts"] as? Int else { return nil }
    return (event, ts)
}

func resolveState(_ pid: pid_t) -> State {
    guard kill(pid, 0) == 0 else { return track(pid, .dead) }
    let sf = stateFileEvent(pid)
    let state: State
    switch sf?.event {
    case "working":     state = .working
    case "needs_input": state = .needsInput
    case "stop":        state = .idle
    default:            state = .idle
    }
    // Log state transitions
    let prev = previousState[pid]
    if prev != nil && prev != state {
        dashLog("STATE pid=\(pid) \(prev!.label) → \(state.label) hook=\(sf?.event ?? "none") ts=\(sf?.ts ?? 0)")
    }
    return track(pid, state)
}

func track(_ pid: pid_t, _ state: State) -> State {
    let prev = previousState[pid]
    if prev != state {
        // Only update time on real transitions, not initial discovery
        if prev != nil { lastActiveTime[pid] = Date() }
        previousState[pid] = state
    }
    return state
}

// MARK: - Session Store (persistence)

struct StoredSession: Codable {
    let sessionId: String
    let name: String
    let cwd: String
    let startedAt: Double
    var lastPid: Int
    var lastActiveTs: Double?
    var source: String?  // "claude" or "codex", nil = claude (backward compat)
}

/// Returns (store, didLoad). didLoad=false means file exists but failed to parse.
func loadStore() -> (store: [String: StoredSession], ok: Bool) {
    guard FileManager.default.fileExists(atPath: storeFile) else { return ([:], true) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: storeFile)),
          let list = try? JSONDecoder().decode([String: StoredSession].self, from: data)
    else { return ([:], false) }
    return (list, true)
}

func saveStore(_ store: [String: StoredSession]) {
    guard let data = try? JSONEncoder().encode(store) else { return }
    try? data.write(to: URL(fileURLWithPath: storeFile), options: .atomic)
}

let historyFile = "\(notesDir)/history.txt"
var knownSessions: [String: String] = [:]  // sessionId → last known name

func appendToHistory(_ session: StoredSession) {
    let prev = knownSessions[session.sessionId]
    if prev == session.name { return } // no change
    knownSessions[session.sessionId] = session.name

    // Rename notes file if it exists under the old name
    if let oldName = prev {
        let oldPath = notesPath(name: oldName, sessionId: session.sessionId)
        let newPath = notesPath(name: session.name, sessionId: session.sessionId)
        if oldPath != newPath && FileManager.default.fileExists(atPath: oldPath) {
            try? FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
        }
    }

    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    let date = df.string(from: Date(timeIntervalSince1970: session.startedAt / 1000))
    let notes = notesFileName(name: session.name, sessionId: session.sessionId)
    let resume = "cd \(session.cwd) && claude --resume \(session.sessionId) --name '\(session.name)' --effort max"

    let prefix = prev != nil ? "[renamed from '\(prev!)'] " : ""
    let entry = """
    [\(date)] \(prefix)\(session.name)
      cwd:    \(session.cwd)
      notes:  \(notes)
      resume: \(resume)

    """
    let line = entry.split(separator: "\n").map { $0.drop(while: { $0 == " " }) }.joined(separator: "\n") + "\n\n"

    if let fh = FileHandle(forWritingAtPath: historyFile) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: historyFile, atomically: true, encoding: .utf8)
    }
}

func notesFileName(name: String, sessionId: String) -> String {
    let safe = name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    return "\(safe)___\(sessionId.prefix(8)).txt"
}

func notesPath(name: String, sessionId: String) -> String {
    "\(notesDir)/\(notesFileName(name: name, sessionId: sessionId))"
}

func hasNotesFile(name: String, sessionId: String) -> Bool {
    FileManager.default.fileExists(atPath: notesPath(name: name, sessionId: sessionId))
}

/// Seed lastActiveTime from persisted store (once on first load)
var didSeedTimes = false

func loadSessions() -> [Session] {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)

    let (loadedStore, storeOk) = loadStore()
    var store = loadedStore

    // Seed in-memory times from store on first load; backfill history
    if !didSeedTimes {
        didSeedTimes = true
        let needsBackfill = !fm.fileExists(atPath: historyFile)
        for (sid, stored) in store {
            let p = pid_t(stored.lastPid)
            if lastActiveTime[p] == nil, let ts = stored.lastActiveTs {
                lastActiveTime[p] = Date(timeIntervalSince1970: ts)
                previousState[p] = .idle // assume idle on startup
            }
            if needsBackfill {
                appendToHistory(stored)
            } else {
                knownSessions[sid] = stored.name
            }
        }
    }

    // Live sessions from Claude — only include alive PIDs
    var liveBySessionId: [String: Session] = [:]
    if let files = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil) {
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = j["pid"] as? Int else { continue }
            let p = pid_t(pid)
            guard kill(p, 0) == 0 else { continue } // skip dead PIDs
            let sid = (j["sessionId"] as? String) ?? ""
            let sname = (j["name"] as? String) ?? "session-\(pid)"
            let startedAt = (j["startedAt"] as? Double) ?? 0
            let fallback = Date(timeIntervalSince1970: startedAt / 1000)
            let resolvedState = resolveState(p)
            let hookTs = stateFileEvent(p)?.ts ?? 0
            let s = Session(
                pid: p, sessionId: sid,
                name: sname,
                cwd: (j["cwd"] as? String) ?? "",
                startedAt: startedAt,
                state: resolvedState,
                tty: shell("/bin/ps", "-o", "tty=", "-p", "\(pid)"),
                hasNotes: hasNotesFile(name: sname, sessionId: sid),
                lastActive: lastActiveTime[p] ?? fallback,
                hookTs: hookTs,
                source: "claude")
            // Skip agent-looper sessions (names like "xxx-rev-f1-ab" or "xxx-fix-f2-cd")
            if sname.range(of: #"-(?:rev|fix)-f\d+-[a-z]{2}$"#, options: .regularExpression) != nil { continue }
            if !sid.isEmpty { liveBySessionId[sid] = s }
        }
    }

    // Merge with store — carry over lastActiveTime when PID changes (resume)
    for (sid, s) in liveBySessionId {
        if let old = store[sid], old.lastPid != Int(s.pid) {
            let oldPid = pid_t(old.lastPid)
            if let t = lastActiveTime[oldPid], lastActiveTime[s.pid] == nil {
                lastActiveTime[s.pid] = t
                previousState[s.pid] = previousState[oldPid]
            }
        }
        // Remove stale store entries whose PID is now used by this live session
        let staleKeys = store.filter { $0.key != sid && $0.value.lastPid == Int(s.pid) }.map(\.key)
        for k in staleKeys { store.removeValue(forKey: k) }

        let stored = StoredSession(sessionId: sid, name: s.name, cwd: s.cwd,
                                   startedAt: s.startedAt, lastPid: Int(s.pid),
                                   lastActiveTs: lastActiveTime[s.pid]?.timeIntervalSince1970)
        store[sid] = stored
        appendToHistory(stored)
    }
    // Remove explicitly deleted sessions before saving
    for rid in removedSessionIds { store.removeValue(forKey: rid) }
    if storeOk { saveStore(store) }

    // Build final list: live sessions + dead stored sessions
    // Remove dead sessions that were resumed under a new sessionId (same name+cwd as a live one)
    let liveByKey: [String: Session] = Dictionary(
        liveBySessionId.values.map { ("\($0.name)\0\($0.cwd)", $0) },
        uniquingKeysWith: { a, _ in a })
    var resumedOldIds: [String] = []
    var result = Array(liveBySessionId.values)
    for (sid, stored) in store {
        // Skip codex sessions — handled by loadCodexSessions
        if stored.source == "codex" { continue }
        if liveBySessionId[sid] == nil {
            let key = "\(stored.name)\0\(stored.cwd)"
            if let live = liveByKey[key] {
                // Resumed under new sessionId — migrate notes, remove old entry
                let oldPath = notesPath(name: stored.name, sessionId: sid)
                let newPath = notesPath(name: live.name, sessionId: live.sessionId)
                if oldPath != newPath && fm.fileExists(atPath: oldPath) && !fm.fileExists(atPath: newPath) {
                    try? fm.moveItem(atPath: oldPath, toPath: newPath)
                }
                resumedOldIds.append(sid)
                continue
            }
            let p = pid_t(stored.lastPid)
            let fallback = Date(timeIntervalSince1970: stored.startedAt / 1000)
            result.append(Session(
                pid: p, sessionId: sid,
                name: stored.name, cwd: stored.cwd,
                startedAt: stored.startedAt, state: .dead,
                tty: "", hasNotes: hasNotesFile(name: stored.name, sessionId: sid),
                lastActive: lastActiveTime[p] ?? Date(timeIntervalSince1970: stored.lastActiveTs ?? fallback.timeIntervalSince1970),
                hookTs: 0,
                source: "claude"))
        }
    }
    // Remove old resumed entries from store, queue tab transfers for main thread
    if !resumedOldIds.isEmpty {
        for oldId in resumedOldIds {
            if let stored = store[oldId],
               let liveKey = "\(stored.name)\0\(stored.cwd)" as String?,
               let live = liveByKey[liveKey] {
                pendingTabTransfers.append(TabTransfer(oldId: oldId, newId: live.sessionId))
            }
            store.removeValue(forKey: oldId)
        }
        if storeOk { saveStore(store) }
    }
    return result.filter { !removedSessionIds.contains($0.sessionId) }
        .sorted { $0.startedAt > $1.startedAt }
}

// MARK: - Codex Sessions

func loadCodexSessions() -> [Session] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: codexSessionsDir.path) else { return [] }

    // Find running codex processes — use pgrep to find node codex wrappers
    let pids = shell("/usr/bin/pgrep", "-f", "node.*codex")
    var codexProcs: [(pid: pid_t, tty: String, sessionId: String)] = []
    for pidStr in pids.components(separatedBy: "\n") {
        guard let pid = pid_t(pidStr.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
        let args = shell("/bin/ps", "-o", "args=", "-p", "\(pid)")
        guard args.hasPrefix("node ") && args.contains("/codex") else { continue }
        let tty = shell("/bin/ps", "-o", "tty=", "-p", "\(pid)")
        guard !tty.isEmpty && tty != "??" else { continue }
        var sid = ""
        if let range = args.range(of: "resume ") {
            let after = String(args[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let parts = after.split(separator: " ")
            if let first = parts.first, first.count > 8 { sid = String(first) }
        }
        codexProcs.append((pid: pid, tty: tty, sessionId: sid))
    }
    guard !codexProcs.isEmpty else { return [] }

    // Build session ID → metadata map from JSONL headers
    // Only scan recent files (last 30 days) to avoid slow enumeration
    var jsonlEntries: [(id: String, cwd: String, startedAt: Double, mtime: Date)] = []
    let cutoff = Date(timeIntervalSinceNow: -30 * 86400)
    if let enumerator = fm.enumerator(at: codexSessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = vals.contentModificationDate, mtime < cutoff { continue }
            guard let handle = FileHandle(forReadingAtPath: url.path) else { continue }
            let headerData = handle.readData(ofLength: 512)
            handle.closeFile()
            guard let header = String(data: headerData, encoding: .utf8) else { continue }
            // Extract fields — header can be 18KB+, only read first 512 bytes
            func extractField(_ key: String, from str: String) -> String? {
                guard let range = str.range(of: "\"\(key)\":\"") else { return nil }
                let after = str[range.upperBound...]
                guard let end = after.firstIndex(of: "\"") else { return nil }
                return String(after[..<end])
            }
            guard let sessionId = extractField("session_id", from: header) else { continue }
            let cwd = extractField("cwd", from: header) ?? ""
            let timestamp = extractField("timestamp", from: header) ?? ""
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = df.date(from: timestamp) ?? Date()
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            jsonlEntries.append((id: sessionId, cwd: cwd, startedAt: date.timeIntervalSince1970 * 1000, mtime: mtime))
        }
    }
    let jsonlMap = Dictionary(jsonlEntries.map { ($0.id, (cwd: $0.cwd, startedAt: $0.startedAt)) },
                              uniquingKeysWith: { a, _ in a })

    var result: [Session] = []
    var usedIds = Set<String>()
    for proc in codexProcs {
        var sid = proc.sessionId
        var cwd = ""
        var startedAt: Double = 0

        // Get process cwd via lsof (always needed for matching)
        let lsofOut = shell("/usr/sbin/lsof", "-a", "-p", "\(proc.pid)", "-d", "cwd", "-F", "n")
        var procCwd = ""
        for line in lsofOut.components(separatedBy: "\n") {
            if line.hasPrefix("n/") { procCwd = String(line.dropFirst(1)); break }
        }

        if !sid.isEmpty, let info = jsonlMap[sid] {
            cwd = info.cwd; startedAt = info.startedAt
        }
        // Sessions without resume ID: use folder name + temp ID
        // Don't match old JONLs — they belong to previous sessions

        // No JSONL yet — use PID as temporary ID
        if sid.isEmpty {
            sid = "codex-\(proc.pid)"
            cwd = procCwd
            startedAt = Date().timeIntervalSince1970 * 1000
        }

        guard !usedIds.contains(sid) else { continue }
        usedIds.insert(sid)

        // Get name from Codex state database
        // /rename updates the "title" column. "name" is always empty.
        var sname = ""
        let dbPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
        if !sid.hasPrefix("codex-"), sid.count > 10 {
            // Try name first, then title (but only if short — long titles are first prompt text)
            let dbOut = shell("/usr/bin/sqlite3", dbPath,
                "SELECT COALESCE(NULLIF(name,''), title) FROM threads WHERE id='\(sid)' LIMIT 1")
            let candidate = dbOut.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate.count <= 40 { sname = candidate }
        }
        if sname.isEmpty {
            sname = (cwd as NSString).lastPathComponent.isEmpty ? "codex-\(proc.pid)" : (cwd as NSString).lastPathComponent
        }
        let resolvedState = resolveState(proc.pid)
        let hookTs = stateFileEvent(proc.pid)?.ts ?? 0

        result.append(Session(
            pid: proc.pid, sessionId: sid, name: sname, cwd: cwd,
            startedAt: startedAt, state: resolvedState,
            tty: proc.tty, hasNotes: hasNotesFile(name: sname, sessionId: sid),
            lastActive: lastActiveTime[proc.pid] ?? Date(timeIntervalSince1970: startedAt / 1000),
            hookTs: hookTs, source: "codex"))

    }

    // Persist live codex sessions + load dead ones — single store read/write
    let liveIds = Set(result.map(\.sessionId))
    var (store, storeOk) = loadStore()
    // Save live sessions
    for s in result {
        store[s.sessionId] = StoredSession(sessionId: s.sessionId, name: s.name, cwd: s.cwd,
                                            startedAt: s.startedAt, lastPid: Int(s.pid),
                                            lastActiveTs: lastActiveTime[s.pid]?.timeIntervalSince1970,
                                            source: "codex")
    }
    // Filter removed
    for rid in removedSessionIds { store.removeValue(forKey: rid) }
    if storeOk { saveStore(store) }
    // Load dead
    for (sid, stored) in store {
        guard stored.source == "codex" else { continue }
        guard !liveIds.contains(sid) else { continue }
        guard !removedSessionIds.contains(sid) else { continue }
        let p = pid_t(stored.lastPid)
        let fallback = Date(timeIntervalSince1970: stored.startedAt / 1000)
        result.append(Session(
            pid: p, sessionId: sid, name: stored.name, cwd: stored.cwd,
            startedAt: stored.startedAt, state: .dead,
            tty: "", hasNotes: hasNotesFile(name: stored.name, sessionId: sid),
            lastActive: lastActiveTime[p] ?? Date(timeIntervalSince1970: stored.lastActiveTs ?? fallback.timeIntervalSince1970),
            hookTs: 0, source: "codex"))
    }

    return result
}

struct TabTransfer {
    let oldId: String
    let newId: String
}

var pendingTabTransfers: [TabTransfer] = []

// MARK: - Notes

func openNotes(for session: Session) {
    let path = notesPath(name: session.name, sessionId: session.sessionId)
    if !FileManager.default.fileExists(atPath: path) {
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

var removedSessionIds: Set<String> = []

func removeSession(_ session: Session) {
    let alert = NSAlert()
    alert.messageText = "Remove \"\(session.name)\"?"
    alert.informativeText = "Notes are kept in:\n\(notesDir)"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    removedSessionIds.insert(session.sessionId)
    var (store, _) = loadStore()
    store.removeValue(forKey: session.sessionId)
    saveStore(store)
}

// MARK: - Formatting

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

func shortPath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var s = p; if s.hasPrefix(home) { s = "~" + s.dropFirst(home.count) }
    let c = s.components(separatedBy: "/")
    return c.count > 3 ? "…/" + c.suffix(2).joined(separator: "/") : s
}

// MARK: - Terminal reveal

func revealSession(_ session: Session) {
    revealTTY(session.tty)
}

func revealTTY(_ tty: String) {
    guard !tty.isEmpty else { return }
    let apps = NSWorkspace.shared.runningApplications
    let hasITerm = apps.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
    let bundleId = hasITerm ? "com.googlecode.iterm2" : "com.apple.Terminal"
    let appName = hasITerm ? "iTerm2" : "Terminal"

    // Activate the terminal app first from the main thread
    if let app = apps.first(where: { $0.bundleIdentifier == bundleId }) {
        app.activate()
    }

    let script: String
    if hasITerm {
        script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "/dev/\(tty)" then
                            select s
                            tell t to select
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    } else {
        script = """
        tell application "\(appName)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }
    // Small delay to let the app activate before selecting the tab
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}

// MARK: - Window layout save/restore

var savedScreenCount = 0

func currentScreenCount() -> Int {
    // Must be called on main thread
    var count = 0
    if Thread.isMainThread {
        count = NSScreen.screens.count
    } else {
        DispatchQueue.main.sync { count = NSScreen.screens.count }
    }
    return count
}

func saveTerminalLayout(autoSave: Bool = false) {
    let screenCount = currentScreenCount()

    // Don't auto-save if screens decreased (windows are scrambled)
    if autoSave && savedScreenCount > 0 && screenCount < savedScreenCount { return }

    let apps = NSWorkspace.shared.runningApplications
    let hasITerm = apps.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }

    let script: String
    if hasITerm {
        script = """
        set output to ""
        tell application "iTerm2"
            repeat with w in windows
                set {x, y} to position of w
                set {width, height} to size of w
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set output to output & (tty of s) & "," & x & "," & y & "," & width & "," & height & linefeed
                    end repeat
                end repeat
            end repeat
        end tell
        return output
        """
    } else {
        script = """
        set output to ""
        tell application "Terminal"
            repeat with w in windows
                set {x, y} to position of w
                set {width, height} to size of w
                repeat with t in tabs of w
                    set output to output & (tty of t) & "," & x & "," & y & "," & width & "," & height & linefeed
                end repeat
            end repeat
        end tell
        return output
        """
    }

    let raw = shell("/usr/bin/osascript", "-e", script)
    guard !raw.isEmpty else { return }

    var windows: [[String: Any]] = []
    for line in raw.components(separatedBy: "\n") {
        let parts = line.split(separator: ",")
        guard parts.count == 5 else { continue }
        let tty = String(parts[0]).replacingOccurrences(of: "/dev/", with: "")
        guard let x = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[2].trimmingCharacters(in: .whitespaces)),
              let w = Int(parts[3].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[4].trimmingCharacters(in: .whitespaces))
        else { continue }
        windows.append(["tty": tty, "x": x, "y": y, "w": w, "h": h])
    }

    let payload: [String: Any] = ["screenCount": screenCount, "windows": windows]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return }
    try? data.write(to: URL(fileURLWithPath: layoutFile), options: .atomic)
    savedScreenCount = screenCount
}

func restoreTerminalLayout() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: layoutFile)),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let savedCount = payload["screenCount"] as? Int,
          let windows = payload["windows"] as? [[String: Any]]
    else { return }

    // Don't restore if monitors aren't all connected yet
    let screenCount = currentScreenCount()
    if screenCount < savedCount { return }

    let apps = NSWorkspace.shared.runningApplications
    let hasITerm = apps.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }

    for entry in windows {
        guard let tty = entry["tty"] as? String,
              let x = entry["x"] as? Int, let y = entry["y"] as? Int,
              let w = entry["w"] as? Int, let h = entry["h"] as? Int
        else { continue }

        let script: String
        if hasITerm {
            script = """
            tell application "iTerm2"
                repeat with win in windows
                    repeat with t in tabs of win
                        repeat with s in sessions of t
                            if tty of s is "/dev/\(tty)" then
                                set position of win to {\(x), \(y)}
                                set size of win to {\(w), \(h)}
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                repeat with win in windows
                    repeat with t in tabs of win
                        if tty of t is "/dev/\(tty)" then
                            set position of win to {\(x), \(y)}
                            set size of win to {\(w), \(h)}
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}

// MARK: - Menu bar icon

func dot(_ color: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

func dockIcon(_ color: NSColor) -> NSImage {
    let s: CGFloat = 128
    let r: CGFloat = 28
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let bg = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: s - 8, height: s - 8),
                              xRadius: r, yRadius: r)
        NSColor(white: 0.15, alpha: 1).setFill()
        bg.fill()
        NSColor(white: 0.3, alpha: 1).setStroke()
        bg.lineWidth = 1.5
        bg.stroke()
        let dotSize: CGFloat = 32
        let origin = (s - dotSize) / 2
        NSBezierPath(ovalIn: NSRect(x: origin, y: origin,
                                    width: dotSize, height: dotSize)).fill(color)
        return true
    }
    return img
}

private extension NSBezierPath {
    func fill(_ color: NSColor) {
        color.setFill()
        fill()
    }
}

// MARK: - Tab Sidebar View

class TabSidebarView: NSView {
    var tabs: [TabBucket] = [] { didSet { needsDisplay = true } }
    var activeTabId: String = "main" { didSet { needsDisplay = true } }
    var dropTargetTabId: String? { didSet { needsDisplay = true } }
    var workingTabIds: Set<String> = [] { didSet { needsDisplay = true } }

    var onTabSelect: ((String) -> Void)?
    var onTabAdd: (() -> Void)?
    var onTabRename: ((String, String) -> Void)?  // (tabId, newName)
    var onTabDelete: ((String) -> Void)?

    private let tabW: CGFloat = 56
    private let tabH: CGFloat = 28
    private let gap: CGFloat = 4
    private let padY: CGFloat = 8

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var idealWidth: CGFloat { tabW + 8 }

    private func tabRect(at index: Int) -> NSRect {
        let y = padY + CGFloat(index) * (tabH + gap)
        return NSRect(x: 4, y: y, width: tabW, height: tabH)
    }

    private func addBtnRect() -> NSRect {
        let y = padY + CGFloat(tabs.count) * (tabH + gap)
        return NSRect(x: 4, y: y, width: tabW, height: tabH)
    }

    func tabIdAt(_ point: NSPoint) -> String? {
        for (i, tab) in tabs.enumerated() {
            if tabRect(at: i).contains(point) { return tab.id }
        }
        return nil
    }

    var idealHeight: CGFloat {
        padY + CGFloat(tabs.count + 1) * (tabH + gap)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if addBtnRect().contains(loc) {
            onTabAdd?()
            return
        }
        for (i, tab) in tabs.enumerated() {
            if tabRect(at: i).contains(loc) {
                onTabSelect?(tab.id)
                return
            }
        }
    }

    // Double-click to rename
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let loc = convert(event.locationInWindow, from: nil)
        for (i, tab) in tabs.enumerated() {
            guard tabRect(at: i).contains(loc) else { continue }
            onTabRename?(tab.id, tab.name)
            return
        }
    }

    // Right-click context menu
    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        for (i, tab) in tabs.enumerated() {
            guard tabRect(at: i).contains(loc) else { continue }
            let menu = NSMenu()
            let renameItem = NSMenuItem(title: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = tab.id
            menu.addItem(renameItem)
            if tab.id != "main" {
                let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = tab.id
                menu.addItem(deleteItem)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
    }

    @objc func contextRename(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String,
              let tab = tabs.first(where: { $0.id == tabId }) else { return }
        onTabRename?(tab.id, tab.name)
    }

    @objc func contextDelete(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onTabDelete?(tabId)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, tab) in tabs.enumerated() {
            let rect = tabRect(at: i)
            let isActive = tab.id == activeTabId
            let isDropTarget = tab.id == dropTargetTabId

            // Background — only for active/drop target
            let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if isDropTarget {
                NSColor.systemBlue.withAlphaComponent(0.3).setFill()
                bg.fill()
            } else if isActive {
                NSColor(white: 0.5, alpha: 0.12).setFill()
                bg.fill()
            }

            let hasWorking = workingTabIds.contains(tab.id)
            if hasWorking {
                // Green accent for tabs with working sessions
                NSColor.systemGreen.setFill()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY + 4, width: 3, height: rect.height - 8)).fill()
            }

            // Label
            let font = NSFont.monospacedSystemFont(ofSize: 9, weight: isActive ? .bold : .medium)
            let color: NSColor = isActive ? .labelColor : .secondaryLabelColor
            let attr = NSAttributedString(string: tab.name, attributes: [
                .font: font, .foregroundColor: color])
            let textY = rect.midY - attr.size().height / 2
            let textX = rect.minX + 8
            attr.draw(at: NSPoint(x: textX, y: textY))
        }

        // + button
        let addRect = addBtnRect()
        let plus = NSAttributedString(string: "+", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor])
        let px = addRect.midX - plus.size().width / 2
        let py = addRect.midY - plus.size().height / 2
        plus.draw(at: NSPoint(x: px, y: py))
    }
}

// MARK: - Notification Panel

struct DashNotification {
    let id: String
    let sessionName: String
    let cwd: String
    let tty: String
    let time: Date
}

class NotificationPanelView: NSView {
    var notifications: [DashNotification] = [] { didSet { needsDisplay = true } }
    var onClickNotification: ((DashNotification) -> Void)?
    var onDismissNotification: ((String) -> Void)?
    var onClearAll: (() -> Void)?

    private let itemH: CGFloat = 44
    private let gap: CGFloat = 4
    private let padX: CGFloat = 6
    private let padY: CGFloat = 6
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    private let smallFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    private let clearH: CGFloat = 20

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var idealHeight: CGFloat {
        guard !notifications.isEmpty else { return 0 }
        return padY + clearH + gap + CGFloat(notifications.count) * (itemH + gap) - gap + padY
    }

    var idealWidth: CGFloat { 180 }

    private func itemRect(at index: Int) -> NSRect {
        let y = padY + clearH + gap + CGFloat(index) * (itemH + gap)
        return NSRect(x: padX, y: y, width: bounds.width - padX * 2, height: itemH)
    }

    private func clearRect() -> NSRect {
        NSRect(x: padX, y: padY, width: bounds.width - padX * 2, height: clearH)
    }

    private func closeRect(for itemRect: NSRect) -> NSRect {
        NSRect(x: itemRect.maxX - 16, y: itemRect.minY + 4, width: 12, height: 12)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        // Clear all
        if clearRect().contains(loc) {
            onClearAll?()
            return
        }

        for (i, notif) in notifications.enumerated() {
            let rect = itemRect(at: i)
            guard rect.contains(loc) else { continue }
            // X button
            if closeRect(for: rect).contains(loc) {
                onDismissNotification?(notif.id)
            } else {
                onClickNotification?(notif)
            }
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !notifications.isEmpty else { return }

        // Clear all button
        let cr = clearRect()
        let clearAttr = NSAttributedString(string: "Clear all", attributes: [
            .font: smallFont, .foregroundColor: NSColor.secondaryLabelColor])
        let cx = cr.maxX - clearAttr.size().width
        clearAttr.draw(at: NSPoint(x: cx, y: cr.minY + 4))

        for (i, notif) in notifications.enumerated() {
            let rect = itemRect(at: i)

            // Background
            let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor(white: 0.5, alpha: 0.08).setFill()
            bg.fill()

            // Accent
            NSGraphicsContext.saveGraphicsState()
            bg.addClip()
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: itemH)).fill()
            NSGraphicsContext.restoreGraphicsState()

            let tx = rect.minX + 10

            // Name
            let nameAttr = NSAttributedString(string: notif.sessionName, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor])
            nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 5))

            // "finished" + time
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            let timeStr = "finished \(df.string(from: notif.time))"
            let timeAttr = NSAttributedString(string: timeStr, attributes: [
                .font: smallFont, .foregroundColor: NSColor.secondaryLabelColor])
            timeAttr.draw(at: NSPoint(x: tx, y: rect.minY + 20))

            // Path
            let pathAttr = NSAttributedString(string: shortPath(notif.cwd), attributes: [
                .font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor])
            pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 31))

            // X button
            let xr = closeRect(for: rect)
            let xAttr = NSAttributedString(string: "✕", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
            xAttr.draw(at: NSPoint(x: xr.minX, y: xr.minY))
        }
    }
}

// MARK: - Dashboard Window View

class DashboardView: NSView {
    private var sessionsFingerprint = ""
    private var terminalsFingerprint = ""

    var sessions: [Session] = [] {
        didSet {
            let pinnedIds = pinnedItems.map(\.id).joined(separator: ",")
            let fp = sessions.map { "\($0.sessionId)|\($0.state)|\($0.name)|\($0.hasNotes)" }.joined() + "P:\(pinnedIds)"
            if fp != sessionsFingerprint {
                sessionsFingerprint = fp
                rebuildButtons()
                invalidateIntrinsicContentSize()
                window?.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var terminals: [Terminal] = [] {
        didSet {
            let pinnedIds = pinnedItems.map(\.id).joined(separator: ",")
            let fp = terminals.map { "\($0.tty)|\($0.name)|\($0.isAlive)" }.joined() + "P:\(pinnedIds)"
            if fp != terminalsFingerprint {
                terminalsFingerprint = fp
                rebuildTermButtons()
                window?.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var onSessionClick: ((Session) -> Void)?
    var onNotesClick: ((Session) -> Void)?
    var onRemoveClick: ((Session) -> Void)?
    var onResumeClick: ((Session) -> Void)?
    var onReorder: ((Int, Int) -> Void)?  // (fromIndex, toInsertBeforeIndex)
    var onTerminalClick: ((Terminal) -> Void)?
    var onTerminalRemove: ((Terminal) -> Void)?
    var onDragToTab: ((String, String) -> Void)?
    var onPinSession: ((Session) -> Void)?
    var onPinTerminal: ((Terminal) -> Void)?
    var onUnpin: ((String) -> Void)?  // pinned item id
    var onPinnedClick: ((PinnedItem) -> Void)?
    var onPinnedReorder: ((Int, Int) -> Void)?
    var tabSidebar: TabSidebarView?
    var pinnedItems: [PinnedItem] = [] {
        didSet {
            rebuildPinnedButtons()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var allSessions: [Session] = []  // unfiltered, for pinned state lookup
    var allTerminals: [Terminal] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private let cardH: CGFloat = 52
    private let termCardH: CGFloat = 44
    private let sectionHeaderH: CGFloat = 24
    private let gap: CGFloat = 8
    private let padX: CGFloat = 12
    private let padY: CGFloat = 10
    private var noteButtons: [NSButton] = []
    var resumeButtons: [NSButton] = []
    private var pinButtons: [NSButton] = []
    private var termPinButtons: [NSButton] = []
    private var pinnedNoteButtons: [NSButton] = []
    private var pinnedPinButtons: [NSButton] = []

    // Hover state
    private var hoveredCardType: String = ""  // "session", "terminal", "pinned", ""
    private var hoveredCardIndex: Int = -1
    private var hoverTracker: NSTrackingArea?

    // Drag state
    private var dragSourceIndex: Int?
    private var dragSourceType: String = "session" // "session" or "terminal"
    private var dragStartPoint: NSPoint?
    private var isDragging = false
    private var dropTargetIndex: Int?
    private var isDraggingToTab = false
    private let dragThreshold: CGFloat = 5

    override var isFlipped: Bool { true }

    private var terminalsTopY: CGFloat {
        let sessH = sessions.isEmpty ? 30 : CGFloat(sessions.count) * (cardH + gap) - gap
        return padY + sessH + gap
    }

    private let pinnedCardH: CGFloat = 36

    private var pinnedTopY: CGFloat {
        var h = terminalsTopY
        if !terminals.isEmpty {
            h += sectionHeaderH + CGFloat(terminals.count) * (termCardH + gap) - gap + gap
        }
        return h
    }

    var idealHeight: CGFloat {
        var h = pinnedTopY
        if !pinnedItems.isEmpty {
            h += sectionHeaderH + CGFloat(pinnedItems.count) * (pinnedCardH + gap) - gap
        }
        return h + padY
    }

    private func pinnedCardRect(at index: Int) -> NSRect {
        let y = pinnedTopY + sectionHeaderH + CGFloat(index) * (pinnedCardH + gap)
        return NSRect(x: padX, y: y, width: bounds.width - padX * 2, height: pinnedCardH)
    }

    func pinnedIndex(at point: NSPoint) -> Int? {
        let baseY = pinnedTopY + sectionHeaderH
        let y = point.y - baseY
        guard y >= 0 else { return nil }
        let idx = Int(y / (pinnedCardH + gap))
        let within = y - CGFloat(idx) * (pinnedCardH + gap)
        guard within <= pinnedCardH, idx < pinnedItems.count else { return nil }
        return idx
    }

    func cardIndex(at point: NSPoint) -> Int? {
        let y = point.y - padY
        guard y >= 0 else { return nil }
        let idx = Int(y / (cardH + gap))
        let within = y - CGFloat(idx) * (cardH + gap)
        guard within <= cardH, idx < sessions.count else { return nil }
        return idx
    }

    private func cardRect(at index: Int) -> NSRect {
        let y = padY + CGFloat(index) * (cardH + gap)
        return NSRect(x: padX, y: y, width: bounds.width - padX * 2, height: cardH)
    }

    private func termCardRect(at index: Int) -> NSRect {
        let y = terminalsTopY + sectionHeaderH + CGFloat(index) * (termCardH + gap)
        return NSRect(x: padX, y: y, width: bounds.width - padX * 2, height: termCardH)
    }

    func termIndex(at point: NSPoint) -> Int? {
        let baseY = terminalsTopY + sectionHeaderH
        let y = point.y - baseY
        guard y >= 0 else { return nil }
        let idx = Int(y / (termCardH + gap))
        let within = y - CGFloat(idx) * (termCardH + gap)
        guard within <= termCardH, idx < terminals.count else { return nil }
        return idx
    }

    // ── Hover tracking ──
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracker { removeTrackingArea(t) }
        hoverTracker = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(hoverTracker!)
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        var newType = ""; var newIdx = -1
        if let idx = cardIndex(at: loc), idx < sessions.count {
            newType = "session"; newIdx = idx
        } else if let idx = termIndex(at: loc), idx < terminals.count {
            newType = "terminal"; newIdx = idx
        } else if let idx = pinnedIndex(at: loc), idx < pinnedItems.count {
            newType = "pinned"; newIdx = idx
        }
        if newType != hoveredCardType || newIdx != hoveredCardIndex {
            hoveredCardType = newType; hoveredCardIndex = newIdx
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverTracker {
            hoveredCardType = ""; hoveredCardIndex = -1
            needsDisplay = true
        }
        hoverTip?.orderOut(nil)
        hoverTip = nil
    }

    // ── Right-click context menu ──
    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // Session context menu
        if let idx = cardIndex(at: loc), idx < sessions.count {
            let s = sessions[idx]
            let menu = NSMenu()
            let pinned = pinnedItems.contains { $0.id == s.sessionId }
            let pinItem = NSMenuItem(title: pinned ? "Unpin" : "Pin",
                action: #selector(contextPinSession(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.tag = idx
            menu.addItem(pinItem)
            let closeItem = NSMenuItem(title: "Close",
                action: #selector(contextCloseSession(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.tag = idx
            menu.addItem(closeItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // Terminal context menu
        if let idx = termIndex(at: loc), idx < terminals.count {
            let t = terminals[idx]
            let menu = NSMenu()
            let pinned = pinnedItems.contains { $0.id == t.name }
            let pinItem = NSMenuItem(title: pinned ? "Unpin" : "Pin",
                action: #selector(contextPinTerminal(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.tag = idx
            menu.addItem(pinItem)
            let closeItem = NSMenuItem(title: "Close",
                action: #selector(contextCloseTerminal(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.tag = idx
            menu.addItem(closeItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // Pinned context menu
        if let idx = pinnedIndex(at: loc), idx < pinnedItems.count {
            let menu = NSMenu()
            let unpinItem = NSMenuItem(title: "Unpin",
                action: #selector(contextUnpin(_:)), keyEquivalent: "")
            unpinItem.target = self
            unpinItem.tag = idx
            menu.addItem(unpinItem)
            let closeItem = NSMenuItem(title: "Close",
                action: #selector(contextUnpinAndClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.tag = idx
            menu.addItem(closeItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
    }

    @objc func contextPinSession(_ sender: NSMenuItem) {
        guard sender.tag < sessions.count else { return }
        let s = sessions[sender.tag]
        if pinnedItems.contains(where: { $0.id == s.sessionId }) {
            onUnpin?(s.sessionId)
        } else {
            onPinSession?(s)
        }
    }

    @objc func contextCloseSession(_ sender: NSMenuItem) {
        guard sender.tag < sessions.count else { return }
        onRemoveClick?(sessions[sender.tag])
    }

    @objc func contextPinTerminal(_ sender: NSMenuItem) {
        guard sender.tag < terminals.count else { return }
        let t = terminals[sender.tag]
        if pinnedItems.contains(where: { $0.id == t.name }) {
            onUnpin?(t.name)
        } else {
            onPinTerminal?(t)
        }
    }

    @objc func contextCloseTerminal(_ sender: NSMenuItem) {
        guard sender.tag < terminals.count else { return }
        onTerminalRemove?(terminals[sender.tag])
    }

    @objc func contextUnpin(_ sender: NSMenuItem) {
        guard sender.tag < pinnedItems.count else { return }
        onUnpin?(pinnedItems[sender.tag].id)
    }

    @objc func contextUnpinAndClose(_ sender: NSMenuItem) {
        guard sender.tag < pinnedItems.count else { return }
        let item = pinnedItems[sender.tag]
        onUnpin?(item.id)
        // Close the underlying session/terminal
        if item.type == "session" {
            if let s = sessions.first(where: { $0.sessionId == item.id }) { onRemoveClick?(s) }
        } else {
            if let t = terminals.first(where: { $0.name == item.id }) { onTerminalRemove?(t) }
        }
    }

    // ── Click / Drag ──
    override func mouseDown(with event: NSEvent) {
        // Control+click = right-click on trackpad
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        if let idx = cardIndex(at: loc), idx < sessions.count {
            dragSourceIndex = idx
            dragSourceType = "session"
            dragStartPoint = loc
            isDragging = false
        } else if let idx = termIndex(at: loc) {
            dragSourceIndex = idx
            dragSourceType = "terminal"
            dragStartPoint = loc
            isDragging = false
        } else if let idx = pinnedIndex(at: loc), idx < pinnedItems.count {
            dragSourceIndex = idx
            dragSourceType = "pinned"
            dragStartPoint = loc
            isDragging = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let srcIdx = dragSourceIndex, let start = dragStartPoint else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if !isDragging {
            let dist = hypot(loc.x - start.x, loc.y - start.y)
            guard dist > dragThreshold else { return }
            isDragging = true
        }

        // Check if dragging over tab sidebar (separate window)
        if let sidebar = tabSidebar, let sidebarWindow = sidebar.window, let myWindow = window {
            let screenPt = myWindow.convertPoint(toScreen: event.locationInWindow)
            let sidebarWindowPt = sidebarWindow.convertPoint(fromScreen: screenPt)
            let tabLoc = sidebar.convert(sidebarWindowPt, from: nil)
            if sidebar.bounds.contains(tabLoc) {
                sidebar.dropTargetTabId = sidebar.tabIdAt(tabLoc)
                isDraggingToTab = true
                dropTargetIndex = nil
                needsDisplay = true
                return
            }
        }
        isDraggingToTab = false
        tabSidebar?.dropTargetTabId = nil

        if dragSourceType == "session" {
            let relY = loc.y - padY + gap / 2
            var idx = Int(round(relY / (cardH + gap)))
            idx = max(0, min(idx, sessions.count))
            dropTargetIndex = (idx == srcIdx || idx == srcIdx + 1) ? nil : idx
        } else if dragSourceType == "pinned" {
            let baseY = pinnedTopY + sectionHeaderH
            let relY = loc.y - baseY + gap / 2
            var idx = Int(round(relY / (pinnedCardH + gap)))
            idx = max(0, min(idx, pinnedItems.count))
            dropTargetIndex = (idx == srcIdx || idx == srcIdx + 1) ? nil : idx
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging, isDraggingToTab, let src = dragSourceIndex,
           let targetTabId = tabSidebar?.dropTargetTabId {
            // Drop item onto tab
            let itemId: String
            if dragSourceType == "session" && src < sessions.count {
                itemId = "session:\(sessions[src].sessionId)"
            } else if dragSourceType == "terminal" && src < terminals.count {
                itemId = "terminal:\(terminals[src].name)"
            } else { itemId = "" }
            if !itemId.isEmpty { onDragToTab?(targetTabId, itemId) }
        } else if isDragging, let src = dragSourceIndex, let tgt = dropTargetIndex, dragSourceType == "session" {
            onReorder?(src, tgt)
        } else if isDragging, let src = dragSourceIndex, let tgt = dropTargetIndex, dragSourceType == "pinned" {
            onPinnedReorder?(src, tgt)
        } else if let src = dragSourceIndex, !isDragging {
            if dragSourceType == "session" && src < sessions.count {
                onSessionClick?(sessions[src])
            } else if dragSourceType == "terminal" && src < terminals.count {
                onTerminalClick?(terminals[src])
            } else if dragSourceType == "pinned" && src < pinnedItems.count {
                onPinnedClick?(pinnedItems[src])
            }
        }
        dragSourceIndex = nil
        dragStartPoint = nil
        isDragging = false
        isDraggingToTab = false
        dropTargetIndex = nil
        tabSidebar?.dropTargetTabId = nil
        needsDisplay = true
    }

    @objc func notesBtnClicked(_ sender: NSButton) {
        guard sender.tag < sessions.count else { return }
        onNotesClick?(sessions[sender.tag])
    }

    @objc func resumeBtnClicked(_ sender: NSButton) {
        guard sender.tag < sessions.count else { return }
        onResumeClick?(sessions[sender.tag])
    }

    @objc func removeBtnClicked(_ sender: NSButton) {
        guard sender.tag < sessions.count else { return }
        onRemoveClick?(sessions[sender.tag])
    }

    @objc func pinBtnClicked(_ sender: NSButton) {
        guard sender.tag < sessions.count else { return }
        let s = sessions[sender.tag]
        if pinnedItems.contains(where: { $0.id == s.sessionId }) {
            onUnpin?(s.sessionId)
        } else {
            onPinSession?(s)
        }
    }

    @objc func termPinBtnClicked(_ sender: NSButton) {
        guard sender.tag < terminals.count else { return }
        let t = terminals[sender.tag]
        if pinnedItems.contains(where: { $0.id == t.name }) {
            onUnpin?(t.name)
        } else {
            onPinTerminal?(t)
        }
    }

    func rebuildButtons() {
        noteButtons.forEach { $0.removeFromSuperview() }
        resumeButtons.forEach { $0.removeFromSuperview() }
        pinButtons.forEach { $0.removeFromSuperview() }
        noteButtons.removeAll()
        resumeButtons.removeAll()
        pinButtons.removeAll()

        for (i, s) in sessions.enumerated() {
            let rect = cardRect(at: i)

            // Pin button — positioned after state label (where close button used to be)
            let isPinned = pinnedItems.contains { $0.id == s.sessionId }
            let maxNameW = rect.maxX - 88 - (rect.minX + 14) - 80
            let (dispName, _) = truncate(s.name, font: Self.fontBold12, maxWidth: maxNameW)
            let nameW = NSAttributedString(string: dispName, attributes: [
                .font: Self.fontBold12]).size().width
            let stateW = NSAttributedString(string: s.state.label, attributes: [
                .font: Self.fontSemi9]).size().width
            let pinX = min(rect.minX + 14 + nameW + 10 + stateW + 6, rect.maxX - 90)
            let pb = makeIconButton(frame: NSRect(x: pinX, y: rect.minY + 8, width: 20, height: 20),
                icon: isPinned ? "pin.fill" : "pin",
                tint: isPinned ? .systemBlue : .secondaryLabelColor,
                tooltip: isPinned ? "Unpin" : "Pin")
            pb.tag = i; pb.target = self; pb.action = #selector(pinBtnClicked(_:))
            addSubview(pb); pinButtons.append(pb)

            // Resume button
            let rb = makeIconButton(frame: NSRect(x: rect.maxX - 56, y: rect.minY + 14, width: 24, height: 24),
                icon: "play.fill", tooltip: "Copy resume command")
            rb.tag = i; rb.target = self; rb.action = #selector(resumeBtnClicked(_:))
            addSubview(rb); resumeButtons.append(rb)

            // Notes button
            let nb = makeIconButton(frame: NSRect(x: rect.maxX - 30, y: rect.minY + 14, width: 24, height: 24),
                icon: s.hasNotes ? "doc.text.fill" : "doc.text", tooltip: "Open notes")
            nb.tag = i; nb.target = self; nb.action = #selector(notesBtnClicked(_:))
            addSubview(nb); noteButtons.append(nb)
        }
    }

    func rebuildTermButtons() {
        termPinButtons.forEach { $0.removeFromSuperview() }
        termPinButtons.removeAll()
        for (i, t) in terminals.enumerated() {
            let rect = termCardRect(at: i)
            let isPinned = pinnedItems.contains { $0.id == t.name }
            // Position after name + status label
            let nameW = NSAttributedString(string: t.name, attributes: [
                .font: Self.fontBold12]).size().width
            let statusLabel = t.isAlive ? "ACTIVE" : "CLOSED"
            let statusW = NSAttributedString(string: statusLabel, attributes: [
                .font: Self.fontSemi9]).size().width
            let pinX = min(rect.minX + 14 + nameW + 10 + statusW + 6, rect.maxX - 30)
            let pb = makeIconButton(frame: NSRect(x: pinX, y: rect.minY + 4, width: 20, height: 20),
                icon: isPinned ? "pin.fill" : "pin",
                tint: isPinned ? .systemBlue : .secondaryLabelColor,
                tooltip: isPinned ? "Unpin" : "Pin")
            pb.tag = i; pb.target = self; pb.action = #selector(termPinBtnClicked(_:))
            addSubview(pb); termPinButtons.append(pb)
        }
    }

    @objc func pinnedNoteBtnClicked(_ sender: NSButton) {
        guard sender.tag < pinnedItems.count else { return }
        let item = pinnedItems[sender.tag]
        if item.type == "session" {
            if let s = allSessions.first(where: { $0.sessionId == item.id }) { onNotesClick?(s) }
        }
    }

    @objc func pinnedPinBtnClicked(_ sender: NSButton) {
        guard sender.tag < pinnedItems.count else { return }
        onUnpin?(pinnedItems[sender.tag].id)
    }

    func rebuildPinnedButtons() {
        pinnedNoteButtons.forEach { $0.removeFromSuperview() }
        pinnedPinButtons.forEach { $0.removeFromSuperview() }
        pinnedNoteButtons.removeAll()
        pinnedPinButtons.removeAll()
        for (i, item) in pinnedItems.enumerated() {
            let rect = pinnedCardRect(at: i)

            // Pin toggle — positioned after name + status label
            let nameW = NSAttributedString(string: item.name, attributes: [
                .font: Self.fontBold12]).size().width
            let stateLabel: String
            if item.type == "session" {
                stateLabel = (allSessions.first(where: { $0.sessionId == item.id })?.state ?? .dead).label
            } else {
                stateLabel = (allTerminals.first(where: { $0.name == item.id })?.isAlive ?? false) ? "ACTIVE" : "CLOSED"
            }
            let stateW = NSAttributedString(string: stateLabel, attributes: [
                .font: Self.fontSemi9]).size().width
            let pinX = min(rect.minX + 14 + nameW + 8 + stateW + 6, rect.maxX - 50)
            let pb = makeIconButton(frame: NSRect(x: pinX, y: rect.minY + 2, width: 20, height: 20),
                icon: "pin.fill", tint: .systemBlue, tooltip: "Unpin")
            pb.tag = i; pb.target = self; pb.action = #selector(pinnedPinBtnClicked(_:))
            addSubview(pb); pinnedPinButtons.append(pb)

            // Notes button (sessions only)
            if item.type == "session" {
                let hasNotes = allSessions.first(where: { $0.sessionId == item.id })?.hasNotes ?? false
                let nb = makeIconButton(frame: NSRect(x: rect.maxX - 26, y: rect.minY + 8, width: 20, height: 20),
                    icon: hasNotes ? "doc.text.fill" : "doc.text", tooltip: "Open notes")
                nb.tag = i; nb.target = self; nb.action = #selector(pinnedNoteBtnClicked(_:))
                addSubview(nb); pinnedNoteButtons.append(nb)
            }
        }
    }

    // ── Cursor + Hover tooltip ──
    private var truncatedNames: [Int: String] = [:] // index → full name (only if truncated)
    private var hoverTip: NSWindow?
    private var trackingAreas2: [NSTrackingArea] = []

    override func resetCursorRects() {
        for ta in trackingAreas2 { removeTrackingArea(ta) }
        trackingAreas2.removeAll()

        for i in 0..<sessions.count {
            addCursorRect(cardRect(at: i), cursor: .pointingHand)
            if truncatedNames[i] != nil {
                let ta = NSTrackingArea(rect: cardRect(at: i),
                    options: [.mouseEnteredAndExited, .activeAlways],
                    owner: self, userInfo: ["idx": i])
                addTrackingArea(ta)
                trackingAreas2.append(ta)
            }
        }
        for i in 0..<terminals.count {
            addCursorRect(termCardRect(at: i), cursor: .pointingHand)
        }
        for i in 0..<pinnedItems.count {
            addCursorRect(pinnedCardRect(at: i), cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let idx = event.trackingArea?.userInfo?["idx"] as? Int,
              let fullName = truncatedNames[idx] else { return }
        hoverTip?.orderOut(nil)
        hoverTip = nil

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let padH: CGFloat = 6, padV: CGFloat = 3
        let textSize = (fullName as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: textSize.width + padH * 2, height: textSize.height + padV * 2)

        let tip = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        tip.isOpaque = false
        tip.backgroundColor = NSColor(white: 0.15, alpha: 0.92)
        tip.hasShadow = true
        tip.level = .floating
        tip.contentView!.wantsLayer = true
        tip.contentView!.layer?.cornerRadius = 4

        let label = NSTextField(labelWithString: fullName)
        label.font = font
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.frame = NSRect(x: padH, y: padV, width: textSize.width, height: textSize.height)
        tip.contentView!.addSubview(label)

        // Position just below the card
        let rect = cardRect(at: idx)
        let screenPt = window!.convertPoint(toScreen:
            convert(NSPoint(x: rect.minX, y: rect.maxY + 2), to: nil))
        tip.setFrameOrigin(NSPoint(x: screenPt.x, y: screenPt.y - size.height))
        tip.orderFront(nil)
        hoverTip = tip
    }

    // mouseExited is in the hover tracking section above

    // ── Button helper ──
    private func makeIconButton(frame: NSRect, icon: String, tint: NSColor? = .secondaryLabelColor, tooltip: String) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        btn.contentTintColor = tint
        btn.toolTip = tooltip
        // Hover: show background
        btn.showsBorderOnlyWhileMouseInside = true
        btn.isBordered = true
        return btn
    }

    // ── Truncation helper ──
    private func truncate(_ text: String, font: NSFont, maxWidth: CGFloat) -> (String, Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let fullWidth = (text as NSString).size(withAttributes: attrs).width
        if fullWidth <= maxWidth { return (text, false) }
        let ellipsis = "…"
        var truncated = text
        while !truncated.isEmpty {
            truncated = String(truncated.dropLast())
            let w = (truncated + ellipsis as NSString).size(withAttributes: attrs).width
            if w <= maxWidth { return (truncated + ellipsis, true) }
        }
        return (ellipsis, true)
    }

    // ── Fonts (cached) ──
    private static let fontBold12  = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private static let fontSemi9   = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
    private static let fontReg10   = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let fontReg12   = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let fontReg9    = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)

    // ── Draw ──
    override func draw(_ dirtyRect: NSRect) {
        let ss = sessions // local snapshot
        if ss.isEmpty {
            let str = NSAttributedString(string: "No active sessions", attributes: [
                .font: Self.fontReg12,
                .foregroundColor: NSColor.secondaryLabelColor])
            str.draw(at: NSPoint(x: padX, y: 24))
        }

        var newTruncated: [Int: String] = [:]
        for (i, s) in ss.enumerated() {
            let rect = cardRect(at: i)

            // Card background
            let isHovered = hoveredCardType == "session" && hoveredCardIndex == i
            let bgAlpha: CGFloat = isHovered ? 0.15 : 0.08
            let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor(white: 0.5, alpha: bgAlpha).setFill()
            bg.fill()

            // Left accent bar
            NSGraphicsContext.saveGraphicsState()
            bg.addClip()
            s.state.color.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY,
                                      width: 3, height: cardH)).fill()
            NSGraphicsContext.restoreGraphicsState()

            let tx = rect.minX + 14
            let rightEdge = rect.maxX - 62 // leave space for resume + notes buttons

            // Row 1: name (truncated if needed) + state + duration
            let maxNameW = rightEdge - tx - 60 // room for state label + pin + duration
            let (displayName, wasTruncated) = truncate(s.name, font: Self.fontBold12, maxWidth: maxNameW)
            if wasTruncated { newTruncated[i] = s.name }
            let nameAttr = NSAttributedString(string: displayName, attributes: [
                .font: Self.fontBold12,
                .foregroundColor: NSColor.labelColor])
            nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 8))

            let stateAttr = NSAttributedString(string: s.state.label, attributes: [
                .font: Self.fontSemi9,
                .foregroundColor: s.state.color])
            stateAttr.draw(at: NSPoint(x: tx + nameAttr.size().width + 10, y: rect.minY + 10))

            let durAttr = NSAttributedString(string: timeAgo(s.lastActive), attributes: [
                .font: Self.fontReg10,
                .foregroundColor: NSColor.secondaryLabelColor])
            durAttr.draw(at: NSPoint(x: rightEdge - durAttr.size().width, y: rect.minY + 9))

            // Row 2: path + pid
            let pathAttr = NSAttributedString(string: shortPath(s.cwd), attributes: [
                .font: Self.fontReg10,
                .foregroundColor: NSColor.secondaryLabelColor])
            pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 30))

            let pidAttr = NSAttributedString(string: "pid:\(s.pid)", attributes: [
                .font: Self.fontReg9,
                .foregroundColor: NSColor.secondaryLabelColor])
            pidAttr.draw(at: NSPoint(x: rightEdge - pidAttr.size().width, y: rect.minY + 31))

            // Buttons are NSButton subviews managed by rebuildButtons()
        }
        if newTruncated != truncatedNames {
            truncatedNames = newTruncated
            window?.invalidateCursorRects(for: self)
        }

        // ── Terminals section ──
        if !terminals.isEmpty {
            let headerY = terminalsTopY
            let headerAttr = NSAttributedString(string: "TERMINALS", attributes: [
                .font: Self.fontSemi9,
                .foregroundColor: NSColor.tertiaryLabelColor])
            headerAttr.draw(at: NSPoint(x: padX, y: headerY + 6))

            for (i, t) in terminals.enumerated() {
                let rect = termCardRect(at: i)
                let isHovered = hoveredCardType == "terminal" && hoveredCardIndex == i
                let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                NSColor(white: 0.5, alpha: isHovered ? 0.12 : 0.05).setFill()
                bg.fill()

                // Left accent
                let accentColor: NSColor = t.isAlive ? .systemTeal : .systemRed
                NSGraphicsContext.saveGraphicsState()
                bg.addClip()
                accentColor.setFill()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: termCardH)).fill()
                NSGraphicsContext.restoreGraphicsState()

                let tx = rect.minX + 14

                // Row 1: name + status
                let nameAttr = NSAttributedString(string: t.name, attributes: [
                    .font: Self.fontBold12,
                    .foregroundColor: NSColor.labelColor])
                nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 5))

                let statusLabel = t.isAlive ? "ACTIVE" : "CLOSED"
                let statusColor: NSColor = t.isAlive ? .systemTeal : .systemRed
                let statusAttr = NSAttributedString(string: statusLabel, attributes: [
                    .font: Self.fontSemi9,
                    .foregroundColor: statusColor])
                statusAttr.draw(at: NSPoint(x: tx + nameAttr.size().width + 10, y: rect.minY + 7))

                // Row 2: path
                let pathAttr = NSAttributedString(string: shortPath(t.cwd), attributes: [
                    .font: Self.fontReg10,
                    .foregroundColor: NSColor.secondaryLabelColor])
                pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 25))
            }
        }

        // ── Pinned section ──
        if !pinnedItems.isEmpty {
            let headerY = pinnedTopY
            let headerAttr = NSAttributedString(string: "PINNED", attributes: [
                .font: Self.fontSemi9,
                .foregroundColor: NSColor.tertiaryLabelColor])
            headerAttr.draw(at: NSPoint(x: padX, y: headerY + 6))

            for (i, item) in pinnedItems.enumerated() {
                let rect = pinnedCardRect(at: i)
                let isHovered = hoveredCardType == "pinned" && hoveredCardIndex == i
                let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                NSColor(white: 0.5, alpha: isHovered ? 0.12 : 0.05).setFill()
                bg.fill()

                // Left accent — use allSessions for state lookup (not tab-filtered)
                let accentColor: NSColor
                let stateLabel: String
                if item.type == "session" {
                    let state = allSessions.first(where: { $0.sessionId == item.id })?.state ?? .dead
                    accentColor = state.color
                    stateLabel = state.label
                } else {
                    let alive = allTerminals.first(where: { $0.name == item.id })?.isAlive ?? false
                    accentColor = alive ? .systemTeal : .systemRed
                    stateLabel = alive ? "ACTIVE" : "CLOSED"
                }
                NSGraphicsContext.saveGraphicsState()
                bg.addClip()
                accentColor.setFill()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: pinnedCardH)).fill()
                NSGraphicsContext.restoreGraphicsState()

                let tx = rect.minX + 14
                // Name + status
                let nameAttr = NSAttributedString(string: item.name, attributes: [
                    .font: Self.fontBold12, .foregroundColor: NSColor.labelColor])
                nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 3))
                let statusAttr = NSAttributedString(string: stateLabel, attributes: [
                    .font: Self.fontSemi9, .foregroundColor: accentColor])
                statusAttr.draw(at: NSPoint(x: tx + nameAttr.size().width + 8, y: rect.minY + 5))
                // Path
                let pathAttr = NSAttributedString(string: shortPath(item.cwd), attributes: [
                    .font: Self.fontReg9, .foregroundColor: NSColor.secondaryLabelColor])
                pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 20))
                // Buttons are added in rebuildPinnedButtons
            }
        }

        // ── Drop indicator ──
        if isDragging, let tgt = dropTargetIndex {
            let lineY: CGFloat
            if dragSourceType == "pinned" {
                lineY = pinnedTopY + sectionHeaderH + CGFloat(tgt) * (pinnedCardH + gap) - gap / 2
            } else {
                lineY = padY + CGFloat(tgt) * (cardH + gap) - gap / 2
            }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: padX, y: lineY))
            line.line(to: NSPoint(x: bounds.width - padX, y: lineY))
            line.lineWidth = 2
            NSColor.systemBlue.setStroke()
            line.stroke()
            for x in [padX, bounds.width - padX] {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3, y: lineY - 3, width: 6, height: 6)).fill()
            }
        }
    }
}

// MARK: - Auto-setup

let hookScript = """
#!/usr/bin/env bash
event="${1:-stop}"
read -t 2 input || true
# Fast: use grep+sed instead of python3 loop
sid=$(echo "$input" | sed -n 's/.*"session_id":"\\([^"]*\\)".*/\\1/p')
[ -z "$sid" ] && exit 0
for f in "$HOME/.claude/sessions/"*.json; do
  grep -q "$sid" "$f" 2>/dev/null || continue
  pid=$(sed -n 's/.*"pid":\\([0-9]*\\).*/\\1/p' "$f")
  [ -n "$pid" ] && mkdir -p /tmp/claude-dash && echo "{\\"event\\":\\"$event\\",\\"ts\\":$(date +%s)}" > /tmp/claude-dash/${pid}.state
  exit 0
done
"""

func setupDependencies() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path

    // 1. Create directories
    try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: "\(home)/.claude/hooks", withIntermediateDirectories: true)

    // 2. Install hook script
    let hookPath = "\(home)/.claude/hooks/dash-state.sh"
    let hookExists = fm.fileExists(atPath: hookPath)
    let hookMatches = (try? String(contentsOfFile: hookPath, encoding: .utf8)) == hookScript
    if !hookExists || !hookMatches {
        dashLog("HOOK INSTALL exists=\(hookExists) matches=\(hookMatches)")
    }
    if !hookExists || !hookMatches {
        try? hookScript.write(toFile: hookPath, atomically: true, encoding: .utf8)
        // chmod +x
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+x", hookPath]
        try? p.run(); p.waitUntilExit()
    }

    // 3. Ensure hooks are registered in settings.json (uses python3 to preserve formatting)
    let settingsPath = "\(home)/.claude/settings.json"
    let realPath = (try? fm.destinationOfSymbolicLink(atPath: settingsPath)) ?? settingsPath
    let targetPath = fm.fileExists(atPath: realPath) ? realPath : settingsPath

    let pyScript = """
    import json, sys
    path = sys.argv[1]
    hook_path = sys.argv[2]
    with open(path) as f:
        s = json.load(f)
    hooks = s.setdefault('hooks', {})
    changed = False
    needed = {
        'UserPromptSubmit': {'hooks': [{'type': 'command', 'command': hook_path + ' working'}]},
        'Stop': {'hooks': [{'type': 'command', 'command': hook_path + ' stop'}]},
        'Notification': {'matcher': 'permission_prompt', 'hooks': [{'type': 'command', 'command': hook_path + ' needs_input'}]}
    }
    for event, entry in needed.items():
        existing = hooks.get(event, [])
        has = any('dash-state.sh' in h.get('command', '') for e in existing for h in e.get('hooks', []))
        if not has:
            existing.insert(0, entry)
            hooks[event] = existing
            changed = True
    if changed:
        with open(path, 'w') as f:
            json.dump(s, f, indent=2)
            f.write('\\n')
    """
    let py = Process()
    py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    py.arguments = ["-c", pyScript, targetPath, hookPath]
    py.standardOutput = FileHandle.nullDevice
    py.standardError = FileHandle.nullDevice
    try? py.run()
    py.waitUntilExit()

    // 4. Ensure Codex hooks are registered in hooks.json
    if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path) {
        let codexPyScript = """
        import json, os, sys
        path = sys.argv[1]
        hook_path = sys.argv[2]
        d = {'hooks': {}}
        if os.path.exists(path):
            with open(path) as f:
                d = json.load(f)
        hooks = d.setdefault('hooks', {})
        changed = False
        needed = {
            'UserPromptSubmit': {'hooks': [{'type': 'command', 'command': hook_path + ' working'}]},
            'Stop': {'hooks': [{'type': 'command', 'command': hook_path + ' stop'}]}
        }
        for event, entry in needed.items():
            existing = hooks.get(event, [])
            has = any('dash-state.sh' in h.get('command', '') for e in existing for h in e.get('hooks', []))
            if not has:
                existing.insert(0, entry)
                hooks[event] = existing
                changed = True
        if changed:
            with open(path, 'w') as f:
                json.dump(d, f, indent=2)
                f.write('\\n')
        """
        let codexPy = Process()
        codexPy.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        codexPy.arguments = ["-c", codexPyScript, codexHooksFile, hookPath]
        codexPy.standardOutput = FileHandle.nullDevice
        codexPy.standardError = FileHandle.nullDevice
        try? codexPy.run()
        codexPy.waitUntilExit()
    }
}

// MARK: - App

class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var bar: NSStatusItem!
    var panel: NSWindow!
    var dashView: DashboardView!
    var tabSidebar: TabSidebarView!
    var timer: Timer?
    var currentSessions: [Session] = []
    var currentTerminals: [Terminal] = []
    var tabs: [TabBucket] = []
    var activeTabId: String = "main"
    var showTabs: Bool {
        get { UserDefaults.standard.object(forKey: "showTabs") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showTabs"); layoutViews() }
    }
    var wakeOnAttention: Bool {
        get { UserDefaults.standard.bool(forKey: "wakeOnAttention") }
        set { UserDefaults.standard.set(newValue, forKey: "wakeOnAttention") }
    }
    var didWake = false  // prevent repeated wake calls
    var alwaysOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop") }
    }
    var sessionOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sessionOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "sessionOrder") }
    }
    var workingStartTime: Date?
    var wasWorking = false
    var idleSleepProc: Process?  // caffeinate -i while sessions are working
    var layoutSaveTimer: Timer?
    var layoutRestoreTimer: Timer?
    var notifPanel: NSWindow!
    var notifView: NotificationPanelView!
    var dashNotifications: [DashNotification] = []
    var prevStates: [String: State] = [:]
    var pollCount = 0

    func applicationWillTerminate(_: Notification) {
        stopPreventIdleSleep()
    }

    func applicationDidFinishLaunching(_: Notification) {
        dashLog("APP LAUNCH")
        setupDependencies()
        NSApp.setActivationPolicy(.regular)

        bar = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        panel.title = "Claude Dashboard"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = alwaysOnTop ? .floating : .normal
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visual = NSVisualEffectView(frame: panel.contentView!.bounds)
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(visual)

        dashView = DashboardView(frame: panel.contentView!.bounds)
        dashView.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(dashView)
        dashView.onSessionClick = { [weak self] s in
            revealSession(s)
            self?.dismissNotification(s.sessionId)
        }
        dashView.onNotesClick = { s in openNotes(for: s) }
        dashView.onResumeClick = { [weak self] s in
            let cmd: String
            if s.source == "codex" {
                cmd = "cd \(s.cwd) && codex resume \(s.sessionId)"
            } else {
                cmd = "cd \(s.cwd) && claude --resume \(s.sessionId) --name '\(s.name)' --effort max"
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            if let btn = self?.dashView.resumeButtons.first(where: {
                $0.tag < (self?.dashView.sessions.count ?? 0) &&
                self?.dashView.sessions[$0.tag].sessionId == s.sessionId
            }) {
                self?.showToast("Resume command copied", near: btn)
            }
        }
        dashView.onTerminalClick = { t in revealTTY(t.tty) }
        dashView.onTerminalRemove = { [weak self] t in
            removeRegisteredTerminal(t.name)
            var pinned = loadPinned()
            pinned.removeAll { $0.id == t.name }
            savePinned(pinned)
            self?.poll()
        }
        dashView.onReorder = { [weak self] from, to in
            guard let self else { return }
            var ids = self.dashView.sessions.map(\.sessionId)
            let sid = ids.remove(at: from)
            let insertAt = to > from ? to - 1 : to
            ids.insert(sid, at: insertAt)
            self.sessionOrder = ids
            self.poll()
        }
        dashView.onRemoveClick = { [weak self] s in
            removeSession(s)
            // Also remove from pinned
            var pinned = loadPinned()
            pinned.removeAll { $0.id == s.sessionId }
            savePinned(pinned)
            self?.poll()
        }
        dashView.onPinSession = { [weak self] s in
            guard let self else { return }
            var pinned = loadPinned()
            guard !pinned.contains(where: { $0.id == s.sessionId }) else { return }
            pinned.append(PinnedItem(id: s.sessionId, type: "session", name: s.name, cwd: s.cwd, tty: s.tty))
            savePinned(pinned)
            self.poll()
        }
        dashView.onPinTerminal = { [weak self] t in
            guard let self else { return }
            var pinned = loadPinned()
            guard !pinned.contains(where: { $0.id == t.name }) else { return }
            pinned.append(PinnedItem(id: t.name, type: "terminal", name: t.name, cwd: t.cwd, tty: t.tty))
            savePinned(pinned)
            self.poll()
        }
        dashView.onUnpin = { [weak self] id in
            var pinned = loadPinned()
            pinned.removeAll { $0.id == id }
            savePinned(pinned)
            self?.poll()
        }
        dashView.onPinnedClick = { [weak self] item in
            guard let self else { return }
            // Switch to the tab containing this item
            let targetTab: String
            if item.type == "session" {
                targetTab = self.tabs.first(where: { $0.sessionIds.contains(item.id) })?.id ?? "main"
            } else {
                targetTab = self.tabs.first(where: { $0.terminalTTYs.contains(item.id) })?.id ?? "main"
            }
            if self.activeTabId != targetTab {
                self.activeTabId = targetTab
                self.tabSidebar.activeTabId = targetTab
                try? targetTab.write(toFile: activeTabFile, atomically: true, encoding: .utf8)
            }
            // Reveal terminal
            let tty: String
            if item.type == "terminal" {
                tty = self.currentTerminals.first(where: { $0.name == item.id })?.tty ?? item.tty
            } else {
                tty = self.currentSessions.first(where: { $0.sessionId == item.id })?.tty ?? item.tty
            }
            if !tty.isEmpty { revealTTY(tty) }
            self.poll()
        }
        dashView.onPinnedReorder = { [weak self] from, to in
            var pinned = loadPinned()
            guard from < pinned.count else { return }
            let item = pinned.remove(at: from)
            let insertAt = to > from ? to - 1 : to
            pinned.insert(item, at: insertAt)
            savePinned(pinned)
            self?.poll()
        }
        dashView.onDragToTab = { [weak self] tabId, itemId in
            self?.moveItemToTab(tabId: tabId, itemId: itemId)
        }

        // Tab sidebar — separate borderless floating window
        tabPanel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        tabPanel.isOpaque = false
        tabPanel.backgroundColor = .clear
        tabPanel.hasShadow = false
        tabPanel.level = panel.level
        tabPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tabPanel.isMovableByWindowBackground = false

        let tabVisual = NSVisualEffectView(frame: tabPanel.contentView!.bounds)
        tabVisual.material = .hudWindow
        tabVisual.blendingMode = .behindWindow
        tabVisual.state = .active
        tabVisual.autoresizingMask = [.width, .height]
        tabVisual.wantsLayer = true
        tabVisual.layer?.cornerRadius = 8
        tabVisual.layer?.masksToBounds = true
        tabPanel.contentView!.addSubview(tabVisual)

        tabSidebar = TabSidebarView(frame: tabPanel.contentView!.bounds)
        tabSidebar.autoresizingMask = [.width, .height]
        tabPanel.contentView!.addSubview(tabSidebar)
        dashView.tabSidebar = tabSidebar

        // Keep tab panel attached to main panel
        panel.addChildWindow(tabPanel, ordered: .below)

        // Notification panel — floating to the left of tabs
        notifPanel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        notifPanel.isOpaque = false
        notifPanel.backgroundColor = .clear
        notifPanel.hasShadow = false
        notifPanel.level = panel.level
        notifPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let notifVisual = NSVisualEffectView(frame: notifPanel.contentView!.bounds)
        notifVisual.material = .hudWindow
        notifVisual.blendingMode = .behindWindow
        notifVisual.state = .active
        notifVisual.autoresizingMask = [.width, .height]
        notifVisual.wantsLayer = true
        notifVisual.layer?.cornerRadius = 8
        notifVisual.layer?.masksToBounds = true
        notifPanel.contentView!.addSubview(notifVisual)

        notifView = NotificationPanelView(frame: notifPanel.contentView!.bounds)
        notifView.autoresizingMask = [.width, .height]
        notifPanel.contentView!.addSubview(notifView)
        panel.addChildWindow(notifPanel, ordered: .below)
        notifPanel.orderOut(nil)

        notifView.onClickNotification = { [weak self] notif in
            self?.dismissNotification(notif.id)
            // Switch to the tab containing this session
            if let self {
                let sid = notif.id
                let targetTab = self.tabs.first(where: { $0.sessionIds.contains(sid) })?.id ?? "main"
                if self.activeTabId != targetTab {
                    self.activeTabId = targetTab
                    self.tabSidebar.activeTabId = targetTab
                    self.poll()
                }
            }
            revealTTY(notif.tty)
        }
        notifView.onDismissNotification = { [weak self] id in
            self?.dismissNotification(id)
        }
        notifView.onClearAll = { [weak self] in
            self?.dashNotifications.removeAll()
            self?.layoutNotifPanel()
        }

        tabs = loadTabs()
        tabSidebar.tabs = tabs
        tabSidebar.activeTabId = activeTabId

        // Write initial active tab
        try? activeTabId.write(toFile: activeTabFile, atomically: true, encoding: .utf8)

        tabSidebar.onTabSelect = { [weak self] id in
            self?.activeTabId = id
            self?.tabSidebar.activeTabId = id
            try? id.write(toFile: activeTabFile, atomically: true, encoding: .utf8)
            self?.poll()
        }
        tabSidebar.onTabAdd = { [weak self] in
            guard let self else { return }
            let newId = UUID().uuidString
            // Ask for name immediately
            let name = self.promptTabName("New tab name", defaultValue: "new")
            guard let name, !name.isEmpty else { return }
            self.tabs.append(TabBucket(id: newId, name: name, sessionIds: [], terminalTTYs: []))
            saveTabs(self.tabs)
            self.activeTabId = newId
            self.tabSidebar.activeTabId = newId
            self.tabSidebar.tabs = self.tabs
            self.poll()
        }
        tabSidebar.onTabRename = { [weak self] id, currentName in
            guard let self, let idx = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            guard let newName = self.promptTabName("Rename tab", defaultValue: currentName),
                  !newName.isEmpty else { return }
            self.tabs[idx].name = newName
            saveTabs(self.tabs)
            self.tabSidebar.tabs = self.tabs
        }
        tabSidebar.onTabDelete = { [weak self] id in
            guard let self,
                  let tab = self.tabs.first(where: { $0.id == id }) else { return }
            let alert = NSAlert()
            alert.messageText = "Delete tab \"\(tab.name)\"?"
            alert.informativeText = "Sessions in this tab will move back to main."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.tabs.removeAll { $0.id == id }
            saveTabs(self.tabs)
            if self.activeTabId == id { self.activeTabId = "main" }
            self.tabSidebar.activeTabId = self.activeTabId
            self.tabSidebar.tabs = self.tabs
            self.poll()
        }

        layoutViews()
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case "h": self?.togglePanel(); return nil
            case "q": NSApp.terminate(nil); return nil
            default: return event
            }
        }

        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }

        // Seed screen count and do initial save
        savedScreenCount = NSScreen.screens.count
        DispatchQueue.global(qos: .utility).async { saveTerminalLayout() }

        // Auto-save terminal layout every 5 minutes
        layoutSaveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { saveTerminalLayout(autoSave: true) }
        }

        // Restore layout after wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.scheduleLayoutRestore() }

        // Restore layout after display reconfiguration (monitor reconnect)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.scheduleLayoutRestore() }
    }

    func scheduleLayoutRestore() {
        layoutRestoreTimer?.invalidate()
        layoutRestoreTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.global(qos: .userInitiated).async { restoreTerminalLayout() }
        }
    }

    func dismissNotification(_ id: String) {
        dashNotifications.removeAll { $0.id == id }
        notifView.notifications = dashNotifications
    }

    func layoutNotifPanel() {
        notifView.notifications = dashNotifications
        if dashNotifications.isEmpty {
            if notifPanel.isVisible { notifPanel.orderOut(nil) }
            return
        }
        let w = notifView.idealWidth
        let h = notifView.idealHeight
        let anchor: NSRect
        if showTabs && tabPanel.isVisible {
            anchor = tabPanel.frame
        } else {
            anchor = panel.frame
        }
        let x = anchor.minX - w - 4
        let y = anchor.maxY - h
        notifPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !notifPanel.isVisible { notifPanel.orderFront(nil) }
    }

    let baseWidth: CGFloat = 340
    let sidebarWidth: CGFloat = 68
    var tabPanel: NSWindow!

    func layoutViews() {
        // Don't show child windows if main panel is minimized or hidden
        let mainHidden = !panel.isVisible || panel.isMiniaturized

        if showTabs && !mainHidden {
            let mainFrame = panel.frame
            let tabH = tabSidebar.idealHeight + 8
            let tabX = mainFrame.minX - sidebarWidth - 4
            let tabY = mainFrame.maxY - tabH - 28
            tabPanel.setFrame(NSRect(x: tabX, y: tabY, width: sidebarWidth, height: tabH),
                              display: true)
            if !tabPanel.isVisible { tabPanel.orderFront(nil) }
        } else {
            if tabPanel.isVisible { tabPanel.orderOut(nil) }
        }

        // Notification panel
        if !dashNotifications.isEmpty && !mainHidden {
            let w = notifView.idealWidth
            let h = notifView.idealHeight
            let anchor: NSRect
            if showTabs && tabPanel.isVisible {
                anchor = tabPanel.frame
            } else {
                anchor = panel.frame
            }
            let x = anchor.minX - w - 4
            let y = anchor.maxY - h
            notifPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            if !notifPanel.isVisible { notifPanel.orderFront(nil) }
        } else {
            if notifPanel.isVisible { notifPanel.orderOut(nil) }
        }
    }

    func moveItemToTab(tabId: String, itemId: String) {
        // Remove item from all tabs first
        for i in 0..<tabs.count {
            tabs[i].sessionIds.removeAll { "session:\($0)" == itemId }
            tabs[i].terminalTTYs.removeAll { "terminal:\($0)" == itemId }
        }
        // Add to target tab (unless "main" — main shows unassigned items)
        if tabId != "main", let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            if itemId.hasPrefix("session:") {
                tabs[idx].sessionIds.append(String(itemId.dropFirst(8)))
            } else if itemId.hasPrefix("terminal:") {
                tabs[idx].terminalTTYs.append(String(itemId.dropFirst(9)))
            }
        }
        saveTabs(tabs)
        tabSidebar.tabs = tabs
        poll()
    }

    func sessionsForActiveTab(_ all: [Session]) -> [Session] {
        if activeTabId == "main" {
            // Main shows items not assigned to any other tab
            let assigned = Set(tabs.filter { $0.id != "main" }.flatMap(\.sessionIds))
            return all.filter { !assigned.contains($0.sessionId) }
        }
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else { return all }
        let ids = Set(tab.sessionIds)
        return all.filter { ids.contains($0.sessionId) }
    }

    func terminalsForActiveTab(_ all: [Terminal]) -> [Terminal] {
        // terminalTTYs stores terminal names (not TTYs) despite the field name
        if activeTabId == "main" {
            let assigned = Set(tabs.filter { $0.id != "main" }.flatMap(\.terminalTTYs))
            return all.filter { !assigned.contains($0.name) }
        }
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else { return all }
        let names = Set(tab.terminalTTYs)
        return all.filter { names.contains($0.name) }
    }

    func promptTabName(_ title: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        // Select all text so user can type to replace
        input.selectText(nil)
        input.currentEditor()?.selectAll(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc func toggleShowTabs(_ sender: NSMenuItem) {
        showTabs = !showTabs
    }

    func showToast(_ message: String, near button: NSView) {
        let label = NSTextField(labelWithString: message)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.alignment = .center
        label.sizeToFit()

        let padX: CGFloat = 12, padY: CGFloat = 6
        let toast = NSView(frame: NSRect(x: 0, y: 0,
            width: label.frame.width + padX * 2,
            height: label.frame.height + padY * 2))
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor
        toast.layer?.cornerRadius = 6
        label.frame.origin = NSPoint(x: padX, y: padY)
        toast.addSubview(label)

        let btnFrame = button.convert(button.bounds, to: panel.contentView!)
        let x = (panel.contentView!.bounds.width - toast.frame.width) / 2
        let y = btnFrame.midY - toast.frame.height / 2
        toast.frame.origin = NSPoint(x: x, y: y)
        panel.contentView!.addSubview(toast)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.removeFromSuperview()
            })
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        tabPanel.orderOut(nil)
        notifPanel.orderOut(nil)
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        tabPanel.orderOut(nil)
        notifPanel.orderOut(nil)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        layoutViews()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        layoutViews()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if panel.isVisible && !panel.isMiniaturized {
            // Force child windows to front — they may be behind other apps
            if showTabs { tabPanel.orderFront(nil) }
            if !dashNotifications.isEmpty { notifPanel.orderFront(nil) }
            layoutViews()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            panel.makeKeyAndOrderFront(nil)
        }
        layoutViews()
        return true
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            tabPanel.orderOut(nil)
            notifPanel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            layoutViews()
        }
    }

    @objc func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        alwaysOnTop = !alwaysOnTop
        panel.level = alwaysOnTop ? .floating : .normal
        tabPanel.level = panel.level
        notifPanel.level = panel.level
    }

    @objc func toggleWakeOnAttention(_ sender: NSMenuItem) {
        wakeOnAttention = !wakeOnAttention
    }

    var showNotifications: Bool {
        get { UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showNotifications") }
    }

    @objc func toggleShowNotifications(_ sender: NSMenuItem) {
        showNotifications = !showNotifications
        if !showNotifications {
            dashNotifications.removeAll()
            notifView.notifications = dashNotifications
            if notifPanel.isVisible { notifPanel.orderOut(nil) }
        }
    }

    @objc func openNotesFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: notesDir))
    }

    @objc func saveLayout() {
        DispatchQueue.global(qos: .userInitiated).async {
            saveTerminalLayout()
        }
    }

    @objc func restoreLayout() {
        DispatchQueue.global(qos: .userInitiated).async {
            restoreTerminalLayout()
        }
    }

    func wakeDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "30"]
        try? p.run()
    }

    func startPreventIdleSleep() {
        guard idleSleepProc == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i"] // prevent idle sleep only, display can still sleep
        try? p.run()
        idleSleepProc = p
    }

    func stopPreventIdleSleep() {
        if let p = idleSleepProc, p.isRunning { p.terminate() }
        idleSleepProc = nil
    }

    @objc func menuSessionClicked(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < currentSessions.count else { return }
        revealSession(currentSessions[idx])
    }

    func applyCustomOrder(_ sessions: [Session]) -> [Session] {
        var order = sessionOrder
        var ordered: [Session] = []
        var remaining = sessions
        for sid in order {
            if let idx = remaining.firstIndex(where: { $0.sessionId == sid }) {
                ordered.append(remaining.remove(at: idx))
            }
        }
        // New sessions — append to saved order so they stay put
        if !remaining.isEmpty {
            for s in remaining { order.append(s.sessionId) }
            sessionOrder = order
        }
        ordered.append(contentsOf: remaining)
        return ordered
    }

    private let pollQueue = DispatchQueue(label: "poll", qos: .userInitiated)

    func poll() {
        pollQueue.async { [weak self] in
            let claudeSessions = loadSessions()
            let codexSessions = loadCodexSessions()
            let ss = claudeSessions + codexSessions
            let terms = loadRegisteredTerminals()
            DispatchQueue.main.async { self?.updateUI(ss, terminals: terms) }
        }
    }

    func updateUI(_ ss: [Session], terminals: [Terminal] = []) {
        currentSessions = ss
        currentTerminals = terminals
        let counts = Dictionary(grouping: ss, by: \.state).mapValues(\.count)
        let w = counts[.working] ?? 0
        let n = counts[.needsInput] ?? 0

        let c: NSColor =
            n > 0 ? .systemOrange :
            w > 0 ? .systemGreen  : .systemGray
        bar.button?.image = dot(c)
        bar.button?.title = n > 0 ? " \(n)" : (w > 0 ? " \(w)" : "")
        NSApp.applicationIconImage = dockIcon(c)

        // ── Prevent idle sleep while working (always active) ──
        if w > 0 { startPreventIdleSleep() }
        else { stopPreventIdleSleep() }

        // ── Wake on attention (one-shot per transition) ──
        if wakeOnAttention {
            let isWorking = w > 0
            if isWorking {
                if !wasWorking { workingStartTime = Date() }
                didWake = false // reset so we can wake on next transition
            } else if !didWake {
                var shouldWake = false
                if n > 0 { shouldWake = true } // needs input
                if wasWorking, let start = workingStartTime,
                   Date().timeIntervalSince(start) > 60 {
                    shouldWake = true // finished after 1+ min
                    workingStartTime = nil
                }
                if shouldWake {
                    wakeDisplay()
                    didWake = true
                }
            }
            wasWorking = isWorking
        }

        // ── Dropdown menu ──
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: panel.isVisible ? "Hide Dashboard" : "Show Dashboard",
            action: #selector(togglePanel), keyEquivalent: "h")
        toggle.target = self
        menu.addItem(toggle)

        let onTop = NSMenuItem(
            title: "Always on Top",
            action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        onTop.target = self
        onTop.state = alwaysOnTop ? .on : .off
        menu.addItem(onTop)

        let awake = NSMenuItem(
            title: "Wake on Attention",
            action: #selector(toggleWakeOnAttention(_:)), keyEquivalent: "")
        awake.target = self
        awake.state = wakeOnAttention ? .on : .off
        menu.addItem(awake)

        let notifToggle = NSMenuItem(
            title: "Show Notifications",
            action: #selector(toggleShowNotifications(_:)), keyEquivalent: "")
        notifToggle.target = self
        notifToggle.state = showNotifications ? .on : .off
        menu.addItem(notifToggle)

        let tabsToggle = NSMenuItem(
            title: "Show Tabs",
            action: #selector(toggleShowTabs(_:)), keyEquivalent: "")
        tabsToggle.target = self
        tabsToggle.state = showTabs ? .on : .off
        menu.addItem(tabsToggle)

        let openNotes = NSMenuItem(
            title: "Open Notes Folder",
            action: #selector(openNotesFolder), keyEquivalent: "")
        openNotes.target = self
        menu.addItem(openNotes)

        menu.addItem(.separator())

        let save = NSMenuItem(
            title: "Save Terminal Layout",
            action: #selector(saveLayout), keyEquivalent: "s")
        save.keyEquivalentModifierMask = [.command, .shift]
        save.target = self
        menu.addItem(save)

        let restore = NSMenuItem(
            title: "Restore Terminal Layout",
            action: #selector(restoreLayout), keyEquivalent: "r")
        restore.keyEquivalentModifierMask = [.command, .shift]
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())

        for (i, s) in ss.enumerated() {
            let row = NSMenuItem()
            row.target = self
            row.action = #selector(menuSessionClicked(_:))
            row.tag = i
            let a = NSMutableAttributedString()
            a.append(NSAttributedString(string: "\(s.state.emoji)  "))
            a.append(NSAttributedString(string: s.name, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)]))
            a.append(NSAttributedString(string: "  \(s.state.label)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: s.state.color]))
            row.attributedTitle = a
            menu.addItem(row)
        }
        if ss.isEmpty {
            let e = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            e.isEnabled = false; menu.addItem(e)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)),
                                keyEquivalent: "q"))
        bar.menu = menu

        // ── Periodic status log (every 60s) ──
        pollCount += 1
        if pollCount % 60 == 0 {
            let live = ss.filter { $0.state != .dead }
            let states = live.map { "\($0.name)=\($0.state.label)" }.joined(separator: " ")
            let stateFiles = live.compactMap { s -> String? in
                let sf = stateFileEvent(s.pid)
                return sf != nil ? "\(s.name):\(sf!.event)@\(sf!.ts)" : "\(s.name):none"
            }.joined(separator: " ")
            dashLog("POLL#\(pollCount) sessions=\(ss.count) live=\(live.count) states=[\(states)] hooks=[\(stateFiles)]")
        }

        // ── Notifications ──
        if pollCount > 5 && showNotifications {
            for s in ss where s.state != .dead {
                let sid = s.sessionId
                let prev = prevStates[sid]
                prevStates[sid] = s.state

                guard prev != nil else { continue }

                if s.state == .working {
                    dismissNotification(sid)
                }

                if prev == .working && s.state != .working {
                    if !dashNotifications.contains(where: { $0.id == sid }) {
                        dashLog("NOTIFY \(s.name) \(State.working.label) → \(s.state.label)")
                        dashNotifications.append(DashNotification(
                            id: sid, sessionName: s.name,
                            cwd: s.cwd, tty: s.tty, time: Date()))
                        layoutNotifPanel()
                    }
                }
            }
        }

        // ── Apply pending tab/order transfers from resume detection ──
        if !pendingTabTransfers.isEmpty {
            for transfer in pendingTabTransfers {
                // Transfer tab assignment
                for i in 0..<tabs.count {
                    if tabs[i].sessionIds.contains(transfer.oldId) {
                        tabs[i].sessionIds.removeAll { $0 == transfer.oldId }
                        if !tabs[i].sessionIds.contains(transfer.newId) {
                            tabs[i].sessionIds.append(transfer.newId)
                        }
                    }
                }
                // Transfer order position
                var order = sessionOrder
                if let idx = order.firstIndex(of: transfer.oldId) {
                    order[idx] = transfer.newId
                    sessionOrder = order
                }
            }
            saveTabs(tabs)
            tabSidebar.tabs = tabs
            pendingTabTransfers.removeAll()
        }

        // ── Window ──
        let orderedSessions = applyCustomOrder(ss)
        dashView.sessions = sessionsForActiveTab(orderedSessions)
        dashView.terminals = terminalsForActiveTab(terminals)
        dashView.allSessions = orderedSessions
        dashView.allTerminals = terminals
        // Refresh pinned items with current names from live data
        var pinned = loadPinned()
        var pinChanged = false
        for i in 0..<pinned.count {
            if pinned[i].type == "session" {
                if let s = orderedSessions.first(where: { $0.sessionId == pinned[i].id }), s.name != pinned[i].name {
                    pinned[i] = PinnedItem(id: pinned[i].id, type: "session", name: s.name, cwd: s.cwd, tty: s.tty)
                    pinChanged = true
                }
            } else if let t = terminals.first(where: { $0.name == pinned[i].id }), t.cwd != pinned[i].cwd {
                pinned[i] = PinnedItem(id: pinned[i].id, type: "terminal", name: t.name, cwd: t.cwd, tty: t.tty)
                pinChanged = true
            }
        }
        if pinChanged { savePinned(pinned) }
        dashView.pinnedItems = pinned

        // Compute which tabs have working sessions
        let workingSessions = Set(orderedSessions.filter { $0.state == .working }.map(\.sessionId))
        var wTabIds = Set<String>()
        // Check "main" — sessions not assigned to any tab
        let allAssigned = Set(tabs.filter { $0.id != "main" }.flatMap(\.sessionIds))
        if workingSessions.contains(where: { !allAssigned.contains($0) }) { wTabIds.insert("main") }
        for tab in tabs where tab.id != "main" {
            if tab.sessionIds.contains(where: { workingSessions.contains($0) }) { wTabIds.insert(tab.id) }
        }
        tabSidebar.workingTabIds = wTabIds
        let idealH = dashView.idealHeight
        var frame = panel.frame
        let topY = frame.maxY
        frame.size.height = idealH + 28
        frame.origin.y = topY - frame.size.height
        panel.setFrame(frame, display: true, animate: false)
        layoutViews()
    }
}

// MARK: - Entry

let nsApp = NSApplication.shared
let delegate = App()
nsApp.delegate = delegate
nsApp.run()
