import Cocoa
import SQLite3

// MARK: - Config

let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("sessions")
let pollInterval: TimeInterval = 0.5
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
let chatDbPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-chat.db").path
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
        case .working:    return NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.35, alpha: 1)
        case .needsInput: return NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.15, alpha: 1)
        case .idle:       return NSColor(calibratedWhite: 0.78, alpha: 1)
        case .dead:       return NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1)
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
        // Look up current TTY and cwd from the shell PID
        let tty = alive ? shell("/bin/ps", "-o", "tty=", "-p", "\(storedPid)") : ""
        var liveCwd = cwd
        if alive {
            let lsofOut = shell("/usr/sbin/lsof", "-a", "-p", "\(storedPid)", "-d", "cwd", "-F", "n")
            for line in lsofOut.components(separatedBy: "\n") {
                if line.hasPrefix("n/") { liveCwd = String(line.dropFirst(1)); break }
            }
        }
        result.append(Terminal(tty: tty, name: name, cwd: liveCwd, isAlive: alive))
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

func isCdashSession(_ pid: pid_t) -> Bool {
    let url = URL(fileURLWithPath: "\(stateDir)/\(pid).state")
    guard let data = try? Data(contentsOf: url),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return j["proxy_pid"] != nil
}

func stateFileEvent(_ pid: pid_t) -> (event: String, ts: Int, tty: String?)? {
    let url = URL(fileURLWithPath: "\(stateDir)/\(pid).state")
    guard let data = try? Data(contentsOf: url),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = j["event"] as? String,
          let ts = j["ts"] as? Int else { return nil }
    // If proxy_pid is set, check it's still alive (stale file from crashed proxy)
    if let proxyPid = j["proxy_pid"] as? Int, proxyPid > 0 {
        if kill(pid_t(proxyPid), 0) != 0 { return nil }
    }
    let tty = j["tty"] as? String  // set by pty-proxy, nil for hook-based state files
    return (event, ts, tty)
}

func resolveState(_ pid: pid_t) -> State {
    guard kill(pid, 0) == 0 else { return track(pid, .dead) }
    // Check state file for this PID, then child PIDs (codex writes to native binary PID)
    var sf = stateFileEvent(pid)
    if sf == nil {
        let kids = shell("/usr/bin/pgrep", "-P", "\(pid)")
        for kid in kids.components(separatedBy: "\n") {
            guard let kpid = pid_t(kid.trimmingCharacters(in: .whitespaces)), kpid > 0 else { continue }
            if let ksf = stateFileEvent(kpid) { sf = ksf; break }
        }
    }
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
    let isCodex = session.source == "codex"
    let resume = isCodex
        ? "cd \(session.cwd) && cdash codex --name '\(session.name)' resume \(session.sessionId)"
        : "cd \(session.cwd) && cdash claude --resume \(session.sessionId) --name '\(session.name)' --effort max"

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
            guard isCdashSession(p) else { continue } // skip non-cdash sessions
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
                tty: stateFileEvent(p)?.tty ?? shell("/bin/ps", "-o", "tty=", "-p", "\(pid)"),
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
                if oldPath != newPath && fm.fileExists(atPath: oldPath) {
                    let newSize = (try? fm.attributesOfItem(atPath: newPath)[.size] as? Int) ?? 0
                    if !fm.fileExists(atPath: newPath) || newSize == 0 {
                        try? fm.removeItem(atPath: newPath)
                        try? fm.moveItem(atPath: oldPath, toPath: newPath)
                    }
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
    if codexProcs.isEmpty {
        // No live codex — still load dead sessions from store
        var result: [Session] = []
        let (store, _) = loadStore()
        for (sid, stored) in store {
            guard stored.source == "codex" else { continue }
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
        } else {
            // Find real session ID from the JSONL file the process tree has open
            // Check both node wrapper and its child (native binary)
            var pidsToCheck = ["\(proc.pid)"]
            let childPids = shell("/usr/bin/pgrep", "-P", "\(proc.pid)")
            pidsToCheck += childPids.components(separatedBy: "\n").filter { !$0.isEmpty }
            let lsofFiles = shell("/usr/sbin/lsof", "-p", pidsToCheck.joined(separator: ","))
            for line in lsofFiles.components(separatedBy: "\n") {
                guard line.contains(".jsonl") else { continue }
                // Extract session ID from filename: rollout-...-<uuid>.jsonl
                let parts = line.components(separatedBy: "/")
                if let filename = parts.last, filename.hasSuffix(".jsonl") {
                    // UUID is the last 36 chars before .jsonl
                    let base = filename.replacingOccurrences(of: ".jsonl", with: "")
                    if base.count >= 36 {
                        let uuid = String(base.suffix(36))
                        if uuid.contains("-") && uuid.count == 36 {
                            sid = uuid
                            if let info = jsonlMap[sid] { cwd = info.cwd; startedAt = info.startedAt }
                            break
                        }
                    }
                }
            }
        }

        // No JSONL yet — use PID as temporary ID
        if sid.isEmpty {
            sid = "codex-\(proc.pid)"
            cwd = procCwd
            startedAt = Date().timeIntervalSince1970 * 1000
        }

        guard !usedIds.contains(sid) else { continue }
        usedIds.insert(sid)

        // Get name: 1) codex db (short title = /rename'd), 2) dashboard store, 3) folder name
        var sname = ""
        let dbPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
        if !sid.hasPrefix("codex-"), sid.count > 10 {
            let dbOut = shell("/usr/bin/sqlite3", dbPath,
                "SELECT COALESCE(NULLIF(name,''), title) FROM threads WHERE id='\(sid)' LIMIT 1")
            let candidate = dbOut.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate.count <= 40 { sname = candidate }
        }
        // Check dashboard store for existing name (user may have renamed in codex previously)
        if sname.isEmpty, let storedName = loadStore().store[sid]?.name, !storedName.isEmpty {
            sname = storedName
        }
        if sname.isEmpty {
            sname = (cwd as NSString).lastPathComponent.isEmpty ? "codex-\(proc.pid)" : (cwd as NSString).lastPathComponent
        }
        let resolvedState = resolveState(proc.pid)
        // Check state file for node wrapper and child (native binary) PIDs
        var hookTs = 0
        var proxyTty: String? = nil
        if let sf = stateFileEvent(proc.pid) {
            hookTs = sf.ts; proxyTty = sf.tty
        }
        if hookTs == 0 {
            let kids = shell("/usr/bin/pgrep", "-P", "\(proc.pid)")
            for kid in kids.components(separatedBy: "\n") {
                guard let kpid = pid_t(kid.trimmingCharacters(in: .whitespaces)), kpid > 0 else { continue }
                if let sf = stateFileEvent(kpid) {
                    hookTs = sf.ts; proxyTty = sf.tty; break
                }
            }
        }

        result.append(Session(
            pid: proc.pid, sessionId: sid, name: sname, cwd: cwd,
            startedAt: startedAt, state: resolvedState,
            tty: proxyTty ?? proc.tty, hasNotes: hasNotesFile(name: sname, sessionId: sid),
            lastActive: lastActiveTime[proc.pid] ?? Date(timeIntervalSince1970: startedAt / 1000),
            hookTs: hookTs, source: "codex"))

    }

    // Persist live codex sessions + load dead ones — single store read/write
    let liveIds = Set(result.map(\.sessionId))
    var (store, storeOk) = loadStore()
    // Save live sessions (skip temp IDs — can't be resumed)
    for s in result where !s.sessionId.hasPrefix("codex-") {
        let stored = StoredSession(sessionId: s.sessionId, name: s.name, cwd: s.cwd,
                                    startedAt: s.startedAt, lastPid: Int(s.pid),
                                    lastActiveTs: lastActiveTime[s.pid]?.timeIntervalSince1970,
                                    source: "codex")
        store[s.sessionId] = stored
        appendToHistory(stored)
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
    let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 6, height: 6)).fill()
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
        NSColor.windowBackgroundColor.setFill()
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
    var tabs: [TabBucket] = [] { didSet { needsDisplay = true; rebuildClickTargets() } }
    var activeTabId: String = "main" { didSet { needsDisplay = true } }
    var dropTargetTabId: String? { didSet { needsDisplay = true } }
    var workingTabIds: Set<String> = [] { didSet { needsDisplay = true } }
    private var hoveredTabIdx: Int? = nil

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

    private var hoverArea: NSTrackingArea?
    private var clickTargets: [PointerButton] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let h = hoverArea { removeTrackingArea(h) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(hoverArea!)
    }

    private func rebuildClickTargets() {
        clickTargets.forEach { $0.removeFromSuperview() }
        clickTargets.removeAll()

        for (i, tab) in tabs.enumerated() {
            let button = PointerButton(frame: tabRect(at: i))
            button.isBordered = false
            button.title = ""
            button.focusRingType = .none
            button.tag = i
            button.target = self
            button.action = #selector(tabClicked(_:))
            button.toolTip = tab.name
            button.menu = contextMenu(for: tab)
            addSubview(button)
            clickTargets.append(button)
        }

        let addButton = PointerButton(frame: addBtnRect())
        addButton.isBordered = false
        addButton.title = ""
        addButton.focusRingType = .none
        addButton.target = self
        addButton.action = #selector(addTabClicked(_:))
        addButton.toolTip = "Add tab"
        addSubview(addButton)
        clickTargets.append(addButton)
    }

    private func contextMenu(for tab: TabBucket) -> NSMenu {
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
        return menu
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard sender.tag < tabs.count else { return }
        let tab = tabs[sender.tag]
        if NSApp.currentEvent?.clickCount == 2 {
            onTabRename?(tab.id, tab.name)
        } else {
            onTabSelect?(tab.id)
        }
    }

    @objc private func addTabClicked(_ sender: NSButton) {
        onTabAdd?()
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        var found: Int? = nil
        for i in 0..<tabs.count {
            if tabRect(at: i).contains(loc) { found = i; break }
        }
        if found != hoveredTabIdx { hoveredTabIdx = found; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return }
        if hoveredTabIdx != nil { hoveredTabIdx = nil; needsDisplay = true }
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

            // Background
            let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if isDropTarget {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                bg.fill()
            } else if hoveredTabIdx == i && !isActive {
                NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1).setFill()
                bg.fill()
            } else if isActive {
                NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
                bg.fill()
            }

            let hasWorking = workingTabIds.contains(tab.id)
            if hasWorking {
                // Green accent for tabs with working sessions
                NSColor.systemGreen.setFill()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY + 4, width: 3, height: rect.height - 8)).fill()
            }

            // Label
            let font = NSFont.systemFont(ofSize: 9, weight: isActive ? .semibold : .regular)
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
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
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
    var isInputNeeded: Bool = false
}

class NotificationPanelView: NSView {
    var notifications: [DashNotification] = [] { didSet { needsDisplay = true; rebuildClickTargets() } }
    var onClickNotification: ((DashNotification) -> Void)?
    var onDismissNotification: ((String) -> Void)?
    var onClearAll: (() -> Void)?

    private let itemH: CGFloat = 44
    private let gap: CGFloat = 4
    private let padX: CGFloat = 6
    private let padY: CGFloat = 6
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let smallFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private let clearH: CGFloat = 22

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var idealHeight: CGFloat {
        guard !notifications.isEmpty else { return 0 }
        return padY + clearH + gap + CGFloat(notifications.count) * (itemH + gap) - gap + padY
    }

    var idealWidth: CGFloat { 180 }

    private func itemRect(at index: Int) -> NSRect {
        let y = padY + clearH + gap + CGFloat(index) * (itemH + gap)
        return NSRect(x: padX, y: y, width: max(0, bounds.width - padX * 2), height: itemH)
    }

    private func clearRect() -> NSRect {
        let text = NSAttributedString(string: "Clear all", attributes: [.font: smallFont])
        let w = text.size().width + 12
        return NSRect(x: bounds.width - padX - w, y: padY, width: w, height: clearH)
    }

    private func closeRect(for itemRect: NSRect) -> NSRect {
        NSRect(x: itemRect.maxX - 16, y: itemRect.minY + 4, width: 12, height: 12)
    }

    private var hoveredNotifIdx: Int? = nil
    private var hoveredClearAll = false
    private var notifHoverArea: NSTrackingArea?
    private var clickTargets: [PointerButton] = []

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutClickTargets()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let h = notifHoverArea { removeTrackingArea(h) }
        notifHoverArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(notifHoverArea!)
    }

    private func rebuildClickTargets() {
        clickTargets.forEach { $0.removeFromSuperview() }
        clickTargets.removeAll()

        guard !notifications.isEmpty else { return }

        let clearButton = PointerButton(frame: clearRect())
        clearButton.isBordered = false
        clearButton.title = ""
        clearButton.focusRingType = .none
        clearButton.target = self
        clearButton.action = #selector(clearAllClicked(_:))
        clearButton.toolTip = "Clear all notifications"
        addSubview(clearButton)
        clickTargets.append(clearButton)

        for (i, notification) in notifications.enumerated() {
            let button = PointerButton(frame: itemRect(at: i))
            button.isBordered = false
            button.title = ""
            button.focusRingType = .none
            button.tag = i
            button.target = self
            button.action = #selector(notificationClicked(_:))
            button.toolTip = notification.sessionName
            addSubview(button)
            clickTargets.append(button)
        }
    }

    private func layoutClickTargets() {
        guard clickTargets.count == notifications.count + 1 else { return }
        clickTargets[0].frame = clearRect()
        for i in notifications.indices {
            clickTargets[i + 1].frame = itemRect(at: i)
        }
    }

    @objc private func clearAllClicked(_ sender: NSButton) {
        onClearAll?()
    }

    @objc private func notificationClicked(_ sender: NSButton) {
        guard sender.tag < notifications.count else { return }
        let notification = notifications[sender.tag]
        if let event = NSApp.currentEvent {
            let location = convert(event.locationInWindow, from: nil)
            if closeRect(for: itemRect(at: sender.tag)).contains(location) {
                onDismissNotification?(notification.id)
                return
            }
        }
        onClickNotification?(notification)
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        var found: Int? = nil
        for (i, _) in notifications.enumerated() {
            if itemRect(at: i).contains(loc) { found = i; break }
        }
        let overClear = clearRect().contains(loc)
        if found != hoveredNotifIdx || overClear != hoveredClearAll {
            hoveredNotifIdx = found; hoveredClearAll = overClear; needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === notifHoverArea else { return }
        if hoveredNotifIdx != nil || hoveredClearAll { hoveredNotifIdx = nil; hoveredClearAll = false; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !notifications.isEmpty else { return }

        // Clear all button
        let cr = clearRect()
        if hoveredClearAll {
            let hoverBg = NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4)
            NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1).setFill()
            hoverBg.fill()
        }
        let clearAttr = NSAttributedString(string: "Clear all", attributes: [
            .font: smallFont, .foregroundColor: hoveredClearAll ? NSColor(calibratedWhite: 0.3, alpha: 1) : NSColor.secondaryLabelColor])
        let cx = cr.midX - clearAttr.size().width / 2
        clearAttr.draw(at: NSPoint(x: cx, y: cr.minY + 4))

        for (i, notif) in notifications.enumerated() {
            let rect = itemRect(at: i)

            // Hover
            if hoveredNotifIdx == i {
                NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: rect.minY, width: bounds.width, height: itemH)).fill()
            }

            // Top border
            NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: rect.minY, width: bounds.width, height: 1)).fill()

            // Accent dot
            let accentColor: NSColor = notif.isInputNeeded ?
                NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.15, alpha: 1) : .controlAccentColor
            accentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 4, y: rect.minY + 10, width: 6, height: 6)).fill()

            let tx = rect.minX + 16

            // Name
            let nameAttr = NSAttributedString(string: notif.sessionName, attributes: [
                .font: font, .foregroundColor: NSColor(calibratedWhite: 0.11, alpha: 1)])
            nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 5))

            // Status + time
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            let timeStr = notif.isInputNeeded
                ? "input needed \(df.string(from: notif.time))"
                : "finished \(df.string(from: notif.time))"
            let timeAttr = NSAttributedString(string: timeStr, attributes: [
                .font: smallFont, .foregroundColor: NSColor(calibratedWhite: 0.56, alpha: 1)])
            timeAttr.draw(at: NSPoint(x: tx, y: rect.minY + 20))

            // Path
            let pathAttr = NSAttributedString(string: shortPath(notif.cwd), attributes: [
                .font: smallFont, .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)])
            pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 31))

            // X button
            let xr = closeRect(for: rect)
            let xAttr = NSAttributedString(string: "✕", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)])
            xAttr.draw(at: NSPoint(x: xr.minX, y: xr.minY))

        }
    }

}

// MARK: - Chat Panel

struct ChatMessage {
    let id: Int
    let senderName: String
    let senderType: String
    let recipient: String?
    let body: String
    let timestamp: Int
}

func loadChatMessages(project: String, limit: Int = 50) -> [ChatMessage] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_WAL, nil) == SQLITE_OK,
          let db else { return [] }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = "SELECT id, sender_name, sender_type, recipient, body, created_at FROM messages WHERE project_id=? ORDER BY id DESC LIMIT ?"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, project, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_int(stmt, 2, Int32(limit))

    var msgs: [ChatMessage] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let id = Int(sqlite3_column_int(stmt, 0))
        let sName = String(cString: sqlite3_column_text(stmt, 1))
        let sType = String(cString: sqlite3_column_text(stmt, 2))
        let recip = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let body = String(cString: sqlite3_column_text(stmt, 4))
        let ts = Int(sqlite3_column_int(stmt, 5))
        msgs.append(ChatMessage(id: id, senderName: sName, senderType: sType,
                                recipient: recip, body: body, timestamp: ts))
    }
    return msgs.reversed()
}

func loadChatProjects() -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_WAL, nil) == SQLITE_OK,
          let db else { return [] }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = "SELECT DISTINCT project_id FROM messages ORDER BY project_id"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    var projects: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        projects.append(String(cString: sqlite3_column_text(stmt, 0)))
    }
    return projects
}

func isInChat(name: String, sessionId: String = "") -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_WAL, nil) == SQLITE_OK,
          let db else { return false }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT COUNT(*) FROM sessions WHERE display_name=? OR (session_id=? AND session_id!='')"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(stmt, 2, sessionId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
}

func loadChatMembers(project: String) -> [ChatMember] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_WAL, nil) == SQLITE_OK,
          let db else { return [] }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = "SELECT display_name, agent_type, pid, COALESCE(session_id,'') FROM sessions WHERE project_id=? ORDER BY display_name"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, project, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

    var result: [ChatMember] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let name = String(cString: sqlite3_column_text(stmt, 0))
        let atype = String(cString: sqlite3_column_text(stmt, 1))
        let pid = Int(sqlite3_column_int(stmt, 2))
        let sid = String(cString: sqlite3_column_text(stmt, 3))
        let state: State
        if pid > 0 && kill(pid_t(pid), 0) == 0 {
            state = resolveState(pid_t(pid))
        } else {
            state = .dead
        }
        result.append(ChatMember(name: name, agentType: atype, state: state, sessionId: sid))
    }
    return result
}

func chatUnreadCount(project: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_WAL, nil) == SQLITE_OK,
          let db else { return 0 }
    defer { sqlite3_close(db) }

    // Get human's read cursor
    var cursor = 0
    var stmt: OpaquePointer?
    let cursorSql = "SELECT last_read_id FROM read_cursors WHERE project_id=? AND display_name='human'"
    if sqlite3_prepare_v2(db, cursorSql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(stmt, 1, project, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW { cursor = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
    }

    // Count messages after cursor
    let countSql = "SELECT COUNT(*) FROM messages WHERE project_id=? AND id>?"
    if sqlite3_prepare_v2(db, countSql, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(stmt, 1, project, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(cursor))
        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = Int(sqlite3_column_int(stmt, 0))
            sqlite3_finalize(stmt)
            return count
        }
        sqlite3_finalize(stmt)
    }
    return 0
}

func updateHumanReadCursor(project: String, maxId: Int) {
    let _ = shell("/usr/bin/python3", "/usr/local/lib/claude-dashboard/agent-chat.py",
                   "read", "--project", project, "--name", "human", "--type", "human")
}

struct ChatMember {
    let name: String
    let agentType: String
    let state: State
    let sessionId: String
}

class ChatPanelView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    var messages: [ChatMessage] = [] { didSet { needsDisplay = true } }
    var activeProject: String = ""
    var projects: [String] = []
    var members: [ChatMember] = [] { didSet { refreshMembers() } }
    var onSend: ((String, String) -> Void)?  // (project, message)
    var onRemoveFromChat: ((String) -> Void)?  // session name
    var onSwitchChannel: ((String) -> Void)?
    var onAddChannel: (() -> Void)?
    var onRemoveChannel: ((String) -> Void)?

    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let smallFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    private let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let padX: CGFloat = 10
    private let padY: CGFloat = 8
    private let inputH: CGFloat = 52
    private let headerH: CGFloat = 22
    var membersH: CGFloat = 36

    private var inputField: NSTextField?  // legacy compat
    var inputTV: NSTextView?
    private var inputScroll: NSScrollView?
    private var sendButton: NSButton?
    private var inputMinH: CGFloat = 0
    private var scrollView: NSScrollView?
    private var contentView: NSView?
    private var channelLabel: NSTextField?
    var membersView: NSView?
    var sessionNames: [String] = []

    override var isFlipped: Bool { true }

    func setupViews() {
        // Channel header — label + arrow button
        let label = NSTextField(labelWithString: "# main")
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.frame = NSRect(x: padX, y: padY, width: bounds.width - padX - 30, height: 18)
        label.autoresizingMask = [.width]
        addSubview(label)
        channelLabel = label

        let arrow = PointerButton(frame: NSRect(x: bounds.width - padX - 28, y: padY - 2, width: 28, height: 22))
        arrow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Channels")
        arrow.imageScaling = .scaleProportionallyDown
        arrow.isBordered = false
        arrow.focusRingType = .none
        arrow.contentTintColor = .secondaryLabelColor
        arrow.target = self
        arrow.action = #selector(channelArrowClicked(_:))
        arrow.autoresizingMask = [.minXMargin]
        addSubview(arrow)

        // Scroll view for messages — main area
        let scrollY = headerH + padY
        let inputY = bounds.height - inputH - membersH - padY * 2
        let scrollH = inputY - scrollY
        let sv = NSScrollView(frame: NSRect(x: 0, y: scrollY, width: bounds.width, height: scrollH))
        sv.autoresizingMask = [.width]
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        let cv = FlippedView(frame: NSRect(x: 0, y: 0, width: sv.contentSize.width, height: 0))
        cv.autoresizingMask = [.width]
        sv.documentView = cv
        addSubview(sv)
        scrollView = sv
        contentView = cv

        // Input — NSTextView in NSScrollView for proper multiline + expansion
        let sendW: CGFloat = 30
        let inputAreaY = bounds.height - inputH - membersH - padY
        let sendX = bounds.width - padX - sendW
        let inputW = sendX - padX - 6
        inputMinH = inputH

        let sc = NSScrollView(frame: NSRect(x: padX, y: inputAreaY, width: inputW, height: inputH))
        sc.hasVerticalScroller = true
        sc.autohidesScrollers = true
        sc.hasHorizontalScroller = false
        sc.borderType = .noBorder
        sc.drawsBackground = true
        sc.backgroundColor = .white
        // Rounded border on clipView — scroll view's clipView draws on top of any scroll view layer
        sc.contentView.wantsLayer = true
        sc.contentView.layer?.cornerRadius = 8
        sc.contentView.layer?.borderWidth = 1
        sc.contentView.layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
        sc.contentView.layer?.masksToBounds = true
        sc.contentView.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(sc)

        let tv = ChatInputTextView(frame: NSRect(x: 0, y: 0, width: sc.contentSize.width, height: inputH))
        tv.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        tv.minSize = NSSize(width: 0, height: inputH)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.placeholderString = "@name to DM, Tab to complete"
        tv.delegate = self
        sc.documentView = tv
        addSubview(sc)
        inputTV = tv
        inputScroll = sc

        let btnH: CGFloat = 24
        let sb = TintHoverButton(frame: NSRect(x: sendX, y: inputAreaY + (inputH - btnH) / 2, width: sendW, height: btnH))
        sb.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Send")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        sb.imagePosition = .imageOnly
        sb.isBordered = false
        sb.normalTint = .controlAccentColor
        sb.hoverTint = NSColor(calibratedRed: 0.0, green: 0.3, blue: 0.8, alpha: 1)
        sb.contentTintColor = .controlAccentColor
        sb.target = self
        sb.action = #selector(sendClicked(_:))
        sb.autoresizingMask = [.minXMargin]
        addSubview(sb)
        sendButton = sb as? NSButton

        // Members strip below input
        let mvY = bounds.height - membersH
        let mv = FlippedView(frame: NSRect(x: 0, y: mvY, width: 2000, height: membersH))
        addSubview(mv)
        membersView = mv
    }

    func updateChannelLabel() {
        channelLabel?.stringValue = "# \(activeProject)"
    }

    @objc func channelArrowClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for p in projects {
            let item = NSMenuItem(title: "# \(p)", action: #selector(channelSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p
            if p == activeProject { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let addItem = NSMenuItem(title: "Add Channel...", action: #selector(addChannelClicked(_:)), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.maxY), in: self)
    }

    @objc func channelSelected(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        activeProject = p
        updateChannelLabel()
        onSwitchChannel?(p)
    }

    @objc func addChannelClicked(_ sender: NSMenuItem) {
        onAddChannel?()
    }

    // Right-click on channel label → remove channel
    override func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        if let label = channelLabel, label.frame.contains(loc), !activeProject.isEmpty {
            let menu = NSMenu()
            let rm = NSMenuItem(title: "Remove Channel \"\(activeProject)\"",
                                action: #selector(removeChannelClicked(_:)), keyEquivalent: "")
            rm.target = self
            menu.addItem(rm)
            return menu
        }
        return nil
    }

    @objc func removeChannelClicked(_ sender: NSMenuItem) {
        onRemoveChannel?(activeProject)
    }

    @objc func sendClicked(_ sender: Any) {
        let text = (inputTV?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var msg = text
        var target: String? = nil
        if msg.hasPrefix("@") {
            let parts = msg.dropFirst().split(separator: " ", maxSplits: 1)
            if let name = parts.first {
                target = String(name)
                msg = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        guard !msg.isEmpty else { return }
        if let target, target.lowercased() != "all" {
            onSendDM?(activeProject, msg, target)
        } else {
            onSend?(activeProject, msg)
        }
        inputTV?.string = ""
    }

    var onSendDM: ((String, String, String) -> Void)?  // (project, message, target)

    // NSTextViewDelegate
    func textDidChange(_ notification: Notification) {}

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) { return false }
            sendClicked(textView)
            return true
        }
        if sel == #selector(insertTab(_:)) {
            let text = textView.string
            guard let atIdx = text.lastIndex(of: "@") else { return false }
            let partial = String(text[text.index(after: atIdx)...]).lowercased()
            if partial.isEmpty { return false }
            if let match = sessionNames.first(where: { $0.lowercased().hasPrefix(partial) && $0 != "human" }) {
                let prefix = String(text[...atIdx])
                textView.string = prefix + match + " "
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            }
            return true
        }
        return false
    }

    // No dynamic resize — fixed input with scroll for overflow

    func updateProjects(_ newProjects: [String]) {
        projects = newProjects
        if activeProject.isEmpty, let first = newProjects.first {
            activeProject = first
        }
        updateChannelLabel()
    }

    var onMemberReveal: ((String) -> Void)?  // session name → reveal terminal

    var onMembersHeightChanged: ((CGFloat) -> Void)?

    func refreshMembers() {
        guard let mv = membersView else { return }
        mv.subviews.forEach { $0.removeFromSuperview() }
        let chipH: CGFloat = 24
        let chipGapX: CGFloat = 6
        let chipGapY: CGFloat = 4
        let maxW = mv.superview?.frame.width ?? bounds.width
        var x: CGFloat = padX
        var row: CGFloat = 0
        for (i, m) in members.enumerated() where m.name != "human" {
            let stateColor = m.state.color
            let testLabel = NSTextField(labelWithString: m.name)
            testLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            testLabel.sizeToFit()
            let chipW = testLabel.frame.width + 22

            // Wrap to next row if needed
            if x + chipW > maxW - padX && x > padX {
                x = padX
                row += 1
            }
            let chipY: CGFloat = 3 + row * (chipH + chipGapY)

            let chip = NSView(frame: NSRect(x: x, y: chipY, width: chipW, height: chipH))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
            chip.layer?.cornerRadius = 6
            chip.layer?.borderWidth = 0.5
            chip.layer?.borderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor

            // State dot
            let dotSize: CGFloat = 6
            let dot = NSView(frame: NSRect(x: 6, y: (chipH - dotSize) / 2, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = stateColor.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            chip.addSubview(dot)

            // Name label
            let nameLabel = NSTextField(labelWithString: m.name)
            nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            nameLabel.textColor = NSColor(calibratedWhite: 0.25, alpha: 1)
            nameLabel.isBezeled = false
            nameLabel.drawsBackground = false
            nameLabel.isEditable = false
            nameLabel.isSelectable = false
            nameLabel.lineBreakMode = .byClipping
            nameLabel.sizeToFit()
            nameLabel.frame.origin = NSPoint(x: 14, y: (chipH - nameLabel.frame.height) / 2)
            chip.addSubview(nameLabel)

            // Clickable button — LAST so it's on top, catches all clicks
            let btn = PointerButton(frame: NSRect(x: 0, y: 0, width: chipW, height: chipH))
            btn.title = ""
            btn.isBordered = false
            btn.isTransparent = true
            btn.tag = i
            btn.target = self
            btn.action = #selector(memberClicked(_:))
            btn.hoverBackground = NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1)
            chip.addSubview(btn)

            mv.addSubview(chip)
            x += chipW + chipGapX
        }
        // Report needed height
        let neededH = (row + 1) * (chipH + chipGapY) + 6
        if neededH != membersH {
            onMembersHeightChanged?(neededH)
        }
    }

    @objc func memberClicked(_ sender: NSButton) {
        guard sender.tag < members.count else { return }
        let name = members[sender.tag].name
        onMemberReveal?(name)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let mv = membersView else { super.rightMouseDown(with: event); return }
        let loc = convert(event.locationInWindow, from: nil)
        let mvLoc = mv.convert(loc, from: self)
        // Members are chips — match non-human members by chip index
        let nonHuman = members.enumerated().filter { $0.element.name != "human" }
        for (chipIdx, (memberIdx, m)) in nonHuman.enumerated() {
            guard chipIdx < mv.subviews.count else { break }
            if mv.subviews[chipIdx].frame.contains(mvLoc) {
                let menu = NSMenu()
                let item = NSMenuItem(title: "Remove \(m.name) from Chat",
                                      action: #selector(removeMemberFromChat(_:)), keyEquivalent: "")
                item.target = self
                item.tag = memberIdx
                menu.addItem(item)
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
        }
        super.rightMouseDown(with: event)
    }

    @objc func removeMemberFromChat(_ sender: NSMenuItem) {
        guard sender.tag < members.count else { return }
        onRemoveFromChat?(members[sender.tag].name)
    }

    private var chatTextView: NSTextView?

    func refreshMessages() {
        guard let sv = scrollView else { return }

        // Use a single NSTextView for full cross-message text selection
        let tv: NSTextView
        if let existing = chatTextView {
            tv = existing
        } else {
            tv = ChatMessageTextView(frame: NSRect(x: 0, y: 0, width: sv.contentSize.width, height: 0))
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: padX, height: 4)
            tv.textContainer?.lineFragmentPadding = 0
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            sv.documentView = tv
            chatTextView = tv
        }

        let full = NSMutableAttributedString()
        let df = DateFormatter()
        df.dateFormat = "HH:mm"

        for (i, msg) in messages.enumerated() {
            let timeStr = df.string(from: Date(timeIntervalSince1970: Double(msg.timestamp)))
            let senderColor: NSColor = msg.senderType == "claude" ?
                NSColor(calibratedRed: 0.25, green: 0.72, blue: 0.35, alpha: 1) :
                msg.senderType == "codex" ? .controlAccentColor :
                NSColor(calibratedWhite: 0.4, alpha: 1)
            let sender = msg.senderType == "human" ? "You" : "\(msg.senderName)"
            let dm = msg.recipient != nil ? " → \(msg.recipient!)" : ""

            // Tag + Sender + time
            if msg.senderType != "human" {
                let tagText = msg.senderType == "codex" ? "CX" : "CL"
                let tagColor: NSColor = msg.senderType == "codex"
                    ? NSColor(calibratedRed: 0.6, green: 0.4, blue: 0.15, alpha: 1)
                    : NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.8, alpha: 1)
                full.append(NSAttributedString(string: tagText, attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: tagColor,
                    .backgroundColor: tagColor.withAlphaComponent(0.12)]))
                full.append(NSAttributedString(string: " "))
            }
            full.append(NSAttributedString(string: "\(sender)\(dm)", attributes: [
                .font: font, .foregroundColor: senderColor]))
            full.append(NSAttributedString(string: "  \(timeStr)\n", attributes: [
                .font: smallFont, .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)]))
            // Body
            full.append(NSAttributedString(string: msg.body, attributes: [
                .font: bodyFont, .foregroundColor: NSColor(calibratedWhite: 0.11, alpha: 1)]))
            if i < messages.count - 1 {
                full.append(NSAttributedString(string: "\n\n"))
            }
        }

        tv.textContainerInset = NSSize(width: padX, height: 4)
        (tv as! ChatMessageTextView).topPadding = 4
        tv.textStorage?.setAttributedString(full)
        tv.sizeToFit()

        // Measure actual text height
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        let textH = lm.usedRect(for: tv.textContainer!).height + 8
        let visibleH = sv.contentSize.height

        if textH < visibleH {
            // Push text to bottom via top padding
            (tv as! ChatMessageTextView).topPadding = visibleH - textH
            tv.setFrameSize(NSSize(width: tv.frame.width, height: visibleH))
        } else {
            (tv as! ChatMessageTextView).topPadding = 4
            tv.sizeToFit()
            tv.scrollToEndOfDocument(nil)
        }
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Child window that stays attached to parent — hides by moving offscreen instead of orderOut
/// (orderOut breaks macOS child window auto-move during drag)
class AttachedChildWindow: NSWindow {
    private var _hidden = false
    var isHiddenOffscreen: Bool { _hidden }

    override var isVisible: Bool { !_hidden }

    func hideOffscreen() {
        guard !_hidden else { return }
        _hidden = true
        super.setFrame(NSRect(x: -9999, y: -9999, width: 1, height: 1), display: false)
    }

    func showAt(_ frame: NSRect) {
        _hidden = false
        super.setFrame(frame, display: true)
        super.orderFront(nil)
    }

    override func orderOut(_ sender: Any?) {
        hideOffscreen()
    }

    override func orderFront(_ sender: Any?) {
        _hidden = false
        super.orderFront(sender)
    }
}

/// Message display — selectable but doesn't grab focus on its own
class ChatMessageTextView: NSTextView {
    var topPadding: CGFloat = 4

    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: topPadding)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// Button with pointer cursor + rounded hover background, works on non-key windows
class TintHoverButton: NSButton {
    var normalTint: NSColor = .controlAccentColor
    var hoverTint: NSColor = .systemBlue

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = hoverTint
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = normalTint
    }
}

class PointerButton: NSButton {
    var hoverBackground: NSColor?
    var normalBackground = NSColor(calibratedWhite: 0.96, alpha: 1)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if let bg = hoverBackground {
            superview?.layer?.backgroundColor = bg.cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverBackground != nil {
            superview?.layer?.backgroundColor = normalBackground.cgColor
        }
    }
}

class ChatInputTextView: NSTextView {
    var placeholderString: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholderString.isEmpty {
            let attr = NSAttributedString(string: placeholderString, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)])
            attr.draw(at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height))
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}

class KeyableBorderlessWindow: AttachedChildWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    var onAddToChat: ((Session) -> Void)?
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

    private let cardH: CGFloat = 46
    private let termCardH: CGFloat = 46
    private let sectionHeaderH: CGFloat = 28
    private let gap: CGFloat = 0
    private let padX: CGFloat = 16
    private let padY: CGFloat = 8
    private var noteButtons: [NSButton] = []
    var resumeButtons: [NSButton] = []
    private var pinButtons: [NSButton] = []
    private var termPinButtons: [NSButton] = []
    private var pinnedNoteButtons: [NSButton] = []
    private var pinnedPinButtons: [NSButton] = []
    private var pinnedResumeButtons: [NSButton] = []

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

    private let pinnedCardH: CGFloat = 46

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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
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
            if s.state != .dead && !isInChat(name: s.name, sessionId: s.sessionId) {
                let chatItem = NSMenuItem(title: "Add to Chat",
                    action: #selector(contextAddToChat(_:)), keyEquivalent: "")
                chatItem.target = self
                chatItem.tag = idx
                menu.addItem(chatItem)
            }
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
            let item = pinnedItems[idx]
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
            if let s = allSessions.first(where: { $0.sessionId == item.id }), s.state != .dead, !isInChat(name: s.name, sessionId: s.sessionId) {
                let chatItem = NSMenuItem(title: "Add to Chat",
                    action: #selector(contextAddPinnedToChat(_:)), keyEquivalent: "")
                chatItem.target = self
                chatItem.tag = idx
                menu.addItem(chatItem)
            }
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

    @objc func contextAddToChat(_ sender: NSMenuItem) {
        guard sender.tag < sessions.count else { return }
        onAddToChat?(sessions[sender.tag])
    }

    @objc func contextAddPinnedToChat(_ sender: NSMenuItem) {
        guard sender.tag < pinnedItems.count else { return }
        let item = pinnedItems[sender.tag]
        if let s = allSessions.first(where: { $0.sessionId == item.id }) {
            onAddToChat?(s)
        }
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

        let btnSize: CGFloat = 22
        let btnY: (NSRect) -> CGFloat = { rect in rect.minY + (self.cardH - btnSize) / 2 }
        for (i, s) in sessions.enumerated() {
            let rect = cardRect(at: i)
            let by = btnY(rect)
            var bx = rect.maxX - 8

            // Notes (rightmost)
            bx -= btnSize
            let nb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                icon: s.hasNotes ? "doc.text.fill" : "doc.text", tooltip: "Open notes")
            nb.tag = i; nb.target = self; nb.action = #selector(notesBtnClicked(_:))
            addSubview(nb); noteButtons.append(nb)

            // Resume
            bx -= btnSize + 2
            let rb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                icon: "play.fill", tooltip: "Copy resume command")
            rb.tag = i; rb.target = self; rb.action = #selector(resumeBtnClicked(_:))
            addSubview(rb); resumeButtons.append(rb)

            // Pin
            bx -= btnSize + 2
            let isPinned = pinnedItems.contains { $0.id == s.sessionId }
            let pb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                icon: isPinned ? "pin.fill" : "pin",
                tint: isPinned ? .controlAccentColor : NSColor(calibratedWhite: 0.6, alpha: 1),
                tooltip: isPinned ? "Unpin" : "Pin")
            pb.tag = i; pb.target = self; pb.action = #selector(pinBtnClicked(_:))
            addSubview(pb); pinButtons.append(pb)
        }
    }

    func rebuildTermButtons() {
        termPinButtons.forEach { $0.removeFromSuperview() }
        termPinButtons.removeAll()
        let btnSize: CGFloat = 22
        for (i, t) in terminals.enumerated() {
            let rect = termCardRect(at: i)
            let by = rect.minY + (termCardH - btnSize) / 2
            let bx = rect.maxX - 8 - btnSize
            let isPinned = pinnedItems.contains { $0.id == t.name }
            let pb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                icon: isPinned ? "pin.fill" : "pin",
                tint: isPinned ? .controlAccentColor : NSColor(calibratedWhite: 0.6, alpha: 1),
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

    @objc func pinnedResumeBtnClicked(_ sender: NSButton) {
        guard sender.tag < pinnedItems.count else { return }
        let item = pinnedItems[sender.tag]
        if let s = allSessions.first(where: { $0.sessionId == item.id }) {
            onResumeClick?(s)
        }
    }

    func rebuildPinnedButtons() {
        pinnedNoteButtons.forEach { $0.removeFromSuperview() }
        pinnedPinButtons.forEach { $0.removeFromSuperview() }
        pinnedResumeButtons.forEach { $0.removeFromSuperview() }
        pinnedNoteButtons.removeAll()
        pinnedPinButtons.removeAll()
        pinnedResumeButtons.removeAll()
        let btnSize: CGFloat = 22
        for (i, item) in pinnedItems.enumerated() {
            let rect = pinnedCardRect(at: i)
            let by = rect.minY + (pinnedCardH - btnSize) / 2
            var bx = rect.maxX - 8

            // Notes (rightmost, sessions only)
            if item.type == "session" {
                bx -= btnSize
                let hasNotes = allSessions.first(where: { $0.sessionId == item.id })?.hasNotes ?? false
                let nb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                    icon: hasNotes ? "doc.text.fill" : "doc.text", tooltip: "Open notes")
                nb.tag = i; nb.target = self; nb.action = #selector(pinnedNoteBtnClicked(_:))
                addSubview(nb); pinnedNoteButtons.append(nb)

                // Resume
                bx -= btnSize + 2
                let rb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                    icon: "play.fill", tooltip: "Copy resume command")
                rb.tag = i; rb.target = self; rb.action = #selector(pinnedResumeBtnClicked(_:))
                addSubview(rb); pinnedResumeButtons.append(rb)
            }

            // Pin
            bx -= btnSize + 2
            let pb = makeIconButton(frame: NSRect(x: bx, y: by, width: btnSize, height: btnSize),
                icon: "pin.fill", tint: .controlAccentColor, tooltip: "Unpin")
            pb.tag = i; pb.target = self; pb.action = #selector(pinnedPinBtnClicked(_:))
            addSubview(pb); pinnedPinButtons.append(pb)
        }
    }

    // ── Cursor + Hover tooltip ──
    private var truncatedNames: [Int: String] = [:] // index → full name (only if truncated)
    private var hoverTip: NSWindow?
    private var trackingAreas2: [NSTrackingArea] = []

    override func resetCursorRects() {
        // Tooltip tracking only — no cursor rects
        for ta in trackingAreas2 { removeTrackingArea(ta) }
        trackingAreas2.removeAll()
        for i in 0..<sessions.count {
            if truncatedNames[i] != nil {
                let ta = NSTrackingArea(rect: cardRect(at: i),
                    options: [.mouseEnteredAndExited, .activeInActiveApp],
                    owner: self, userInfo: ["idx": i])
                addTrackingArea(ta)
                trackingAreas2.append(ta)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let idx = event.trackingArea?.userInfo?["idx"] as? Int,
              let fullName = truncatedNames[idx] else { return }
        hoverTip?.orderOut(nil)
        hoverTip = nil

        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let padH: CGFloat = 6, padV: CGFloat = 3
        let textSize = (fullName as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: textSize.width + padH * 2, height: textSize.height + padV * 2)

        let tip = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        tip.isOpaque = false
        tip.backgroundColor = NSColor.windowBackgroundColor
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
    private func makeIconButton(frame: NSRect, icon: String, tint: NSColor? = NSColor(calibratedWhite: 0.6, alpha: 1), tooltip: String) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = true
        btn.showsBorderOnlyWhileMouseInside = true
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        btn.imagePosition = .imageOnly
        btn.contentTintColor = tint
        btn.toolTip = tooltip
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 4
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

    // ── Fonts — macOS native sizes ──
    private static let fontBold12  = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let fontSemi9   = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let fontReg10   = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let fontReg12   = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let fontReg9    = NSFont.systemFont(ofSize: 10, weight: .regular)

    // ── Draw ──
    override func draw(_ dirtyRect: NSRect) {
        let ss = sessions // local snapshot
        if ss.isEmpty {
            let str = NSAttributedString(string: "No sessions", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.56, alpha: 1)])
            let sub = NSAttributedString(string: "\nLaunch with cdash claude", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)])
            let m = NSMutableAttributedString(); m.append(str); m.append(sub)
            m.draw(at: NSPoint(x: padX, y: 20))
        }

        var newTruncated: [Int: String] = [:]
        for (i, s) in ss.enumerated() {
            let rect = cardRect(at: i)

            // Hover — full width, light blue
            let isHovered = hoveredCardType == "session" && hoveredCardIndex == i
            if isHovered {
                NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: rect.minY, width: bounds.width, height: cardH)).fill()
            }

            // State dot
            let dotSize: CGFloat = 6
            let dotY = rect.minY + 13
            s.state.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: padX, y: dotY, width: dotSize, height: dotSize)).fill()

            var tx = padX + 14
            let rightEdge = rect.maxX - 68
            let isDead = s.state == .dead

            // Source tag before name
            let tagText = s.source == "codex" ? "CX" : "CL"
            let tagColor: NSColor = s.source == "codex"
                ? NSColor(calibratedRed: 0.6, green: 0.4, blue: 0.15, alpha: isDead ? 0.5 : 1.0)
                : NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.8, alpha: isDead ? 0.5 : 1.0)
            let tagFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
            let tagAttr = NSAttributedString(string: tagText, attributes: [
                .font: tagFont, .foregroundColor: tagColor])
            let tagTextSize = tagAttr.size()
            let tagPadX: CGFloat = 4
            let tagPadY: CGFloat = 2
            let tagW = tagTextSize.width + tagPadX * 2
            let tagH = tagTextSize.height + tagPadY * 2
            let tagY = rect.minY + 8
            let tagBg = NSBezierPath(roundedRect: NSRect(x: tx, y: tagY, width: tagW, height: tagH), xRadius: 3, yRadius: 3)
            tagColor.withAlphaComponent(isDead ? 0.08 : 0.15).setFill()
            tagBg.fill()
            tagAttr.draw(at: NSPoint(x: tx + tagPadX, y: tagY + tagPadY))
            tx += tagW + 5

            // Row 1: name + time
            let charLimitName = s.name.count > 20 ? String(s.name.prefix(19)) + "…" : s.name
            let maxNameW = rightEdge - tx - 60
            let (displayName, wasTruncated) = truncate(charLimitName, font: Self.fontBold12, maxWidth: maxNameW)
            let nameTruncated = wasTruncated || s.name.count > 20
            if nameTruncated { newTruncated[i] = s.name }
            let nameColor: NSColor = isDead ?
                NSColor(calibratedWhite: 0.55, alpha: 1) :
                NSColor(calibratedWhite: 0.11, alpha: 1)
            let nameAttr = NSAttributedString(string: displayName, attributes: [
                .font: Self.fontBold12, .foregroundColor: nameColor])
            nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 8))

            let timeDate = s.hookTs > 0 ? Date(timeIntervalSince1970: Double(s.hookTs)) : s.lastActive
            let durAttr = NSAttributedString(string: timeAgo(timeDate), attributes: [
                .font: Self.fontReg9,
                .foregroundColor: NSColor(calibratedWhite: isDead ? 0.7 : 0.56, alpha: 1)])
            durAttr.draw(at: NSPoint(x: tx + nameAttr.size().width + 6, y: rect.minY + 10))

            // Row 2: path
            let pathStr = shortPath(s.cwd)
            let pathAttr = NSAttributedString(string: pathStr, attributes: [
                .font: Self.fontReg9,
                .foregroundColor: NSColor(calibratedWhite: isDead ? 0.75 : 0.56, alpha: 1)])
            let maxPathW = rightEdge - tx
            let pathClip = NSRect(x: tx, y: rect.minY + 26, width: maxPathW, height: 14)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: pathClip).addClip()
            pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 26))
            NSGraphicsContext.restoreGraphicsState()

            // Full-width separator
            NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1)).fill()

            // Buttons are NSButton subviews managed by rebuildButtons()
        }
        if newTruncated != truncatedNames {
            truncatedNames = newTruncated
            window?.invalidateCursorRects(for: self)
        }

        // ── Terminals section ──
        if !terminals.isEmpty {
            let headerY = terminalsTopY
            let headerAttr = NSAttributedString(string: "Terminals", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.56, alpha: 1)])
            headerAttr.draw(at: NSPoint(x: padX, y: headerY + 8))

            for (i, t) in terminals.enumerated() {
                let rect = termCardRect(at: i)
                let isHovered = hoveredCardType == "terminal" && hoveredCardIndex == i
                if isHovered {
                    NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1).setFill()
                    NSBezierPath(rect: NSRect(x: 0, y: rect.minY, width: bounds.width, height: termCardH)).fill()
                }

                // State dot — same position as sessions
                let dotColor: NSColor = t.isAlive ? .systemTeal :
                    NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1)
                let dotSize: CGFloat = 6
                dotColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: padX, y: rect.minY + 13, width: dotSize, height: dotSize)).fill()

                let tx = padX + 14
                let nameColor: NSColor = t.isAlive ?
                    NSColor(calibratedWhite: 0.11, alpha: 1) :
                    NSColor(calibratedWhite: 0.55, alpha: 1)

                // Row 1: name
                let nameAttr = NSAttributedString(string: t.name, attributes: [
                    .font: Self.fontBold12, .foregroundColor: nameColor])
                nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 8))

                // Row 2: path
                let pathAttr = NSAttributedString(string: shortPath(t.cwd), attributes: [
                    .font: Self.fontReg9,
                    .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1)])
                pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 26))

                // Full-width separator
                NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: rect.maxY - 0.5, width: bounds.width, height: 0.5)).fill()
            }
        }

        // ── Pinned section ──
        if !pinnedItems.isEmpty {
            let headerY = pinnedTopY
            let headerAttr = NSAttributedString(string: "Pinned", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.56, alpha: 1)])
            headerAttr.draw(at: NSPoint(x: padX, y: headerY + 6))

            for (i, item) in pinnedItems.enumerated() {
                let rect = pinnedCardRect(at: i)
                let isHovered = hoveredCardType == "pinned" && hoveredCardIndex == i
                let bg = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                if isHovered {
                    NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
                    bg.fill()
                }

                // Left accent — use allSessions for state lookup (not tab-filtered)
                let accentColor: NSColor
                let stateLabel: String
                if item.type == "session" {
                    let state = allSessions.first(where: { $0.sessionId == item.id })?.state ?? .dead
                    accentColor = state.color
                    stateLabel = state.label
                } else {
                    let alive = allTerminals.first(where: { $0.name == item.id })?.isAlive ?? false
                    accentColor = alive ? .systemTeal : NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1)
                    stateLabel = alive ? "ACTIVE" : "CLOSED"
                }
                // Hover — full width, same as sessions
                if isHovered {
                    NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.0, alpha: 1).setFill()
                    NSBezierPath(rect: NSRect(x: 0, y: rect.minY, width: bounds.width, height: pinnedCardH)).fill()
                }

                // State dot
                let dotSize: CGFloat = 6
                accentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: padX, y: rect.minY + 13, width: dotSize, height: dotSize)).fill()

                var tx = padX + 14
                let pIsDead: Bool
                if item.type == "session" {
                    pIsDead = (allSessions.first(where: { $0.sessionId == item.id })?.state ?? .dead) == .dead
                } else {
                    pIsDead = !(allTerminals.first(where: { $0.name == item.id })?.isAlive ?? false)
                }

                // Source tag
                let pinnedSession = allSessions.first(where: { $0.sessionId == item.id })
                let pSrc = pinnedSession?.source ?? (item.type == "terminal" ? "terminal" : "claude")
                if pSrc != "terminal" {
                    let pTagText = pSrc == "codex" ? "CX" : "CL"
                    let pTagColor: NSColor = pSrc == "codex"
                        ? NSColor(calibratedRed: 0.6, green: 0.4, blue: 0.15, alpha: pIsDead ? 0.5 : 1.0)
                        : NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.8, alpha: pIsDead ? 0.5 : 1.0)
                    let pTagFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
                    let pTagAttr = NSAttributedString(string: pTagText, attributes: [
                        .font: pTagFont, .foregroundColor: pTagColor])
                    let pTagSize = pTagAttr.size()
                    let pTagPadX: CGFloat = 4
                    let pTagPadY: CGFloat = 2
                    let pTagW = pTagSize.width + pTagPadX * 2
                    let pTagH = pTagSize.height + pTagPadY * 2
                    let pTagY = rect.minY + 8
                    let pTagBg = NSBezierPath(roundedRect: NSRect(x: tx, y: pTagY, width: pTagW, height: pTagH), xRadius: 3, yRadius: 3)
                    pTagColor.withAlphaComponent(pIsDead ? 0.08 : 0.15).setFill()
                    pTagBg.fill()
                    pTagAttr.draw(at: NSPoint(x: tx + pTagPadX, y: pTagY + pTagPadY))
                    tx += pTagW + 5
                }

                // Row 1: name + time
                let pinnedDispName = item.name.count > 20 ? String(item.name.prefix(19)) + "…" : item.name
                let pNameColor: NSColor = pIsDead ?
                    NSColor(calibratedWhite: 0.55, alpha: 1) :
                    NSColor(calibratedWhite: 0.11, alpha: 1)
                let nameAttr = NSAttributedString(string: pinnedDispName, attributes: [
                    .font: Self.fontBold12, .foregroundColor: pNameColor])
                nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 8))

                let pinnedTime: Date
                if let ps = pinnedSession {
                    pinnedTime = ps.hookTs > 0 ? Date(timeIntervalSince1970: Double(ps.hookTs)) : ps.lastActive
                } else {
                    pinnedTime = Date()
                }
                let timeAttr = NSAttributedString(string: timeAgo(pinnedTime), attributes: [
                    .font: Self.fontReg9, .foregroundColor: NSColor(calibratedWhite: 0.56, alpha: 1)])
                timeAttr.draw(at: NSPoint(x: tx + nameAttr.size().width + 6, y: rect.minY + 10))

                // Row 2: path
                let pathAttr = NSAttributedString(string: shortPath(item.cwd), attributes: [
                    .font: Self.fontReg9, .foregroundColor: NSColor(calibratedWhite: pIsDead ? 0.75 : 0.56, alpha: 1)])
                let pPathX = tx
                let maxPW = rect.maxX - 68 - pPathX
                let pClip = NSRect(x: pPathX, y: rect.minY + 26, width: maxPW, height: 14)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: pClip).addClip()
                pathAttr.draw(at: NSPoint(x: pPathX, y: rect.minY + 26))
                NSGraphicsContext.restoreGraphicsState()

                // Full-width separator
                NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: rect.maxY - 0.5, width: bounds.width, height: 0.5)).fill()
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
# Skip hooks when running under cdash proxy (proxy handles state detection)
[ -n "$CDASH_PROXY" ] && exit 0
event="${1:-stop}"
read -t 2 input || true
sid=$(echo "$input" | sed -n 's/.*"session_id":"\\([^"]*\\)".*/\\1/p')
[ -z "$sid" ] && exit 0
mkdir -p /tmp/claude-dash
# Claude: look up PID from session files
for f in "$HOME/.claude/sessions/"*.json; do
  grep -q "$sid" "$f" 2>/dev/null || continue
  pid=$(sed -n 's/.*"pid":\\([0-9]*\\).*/\\1/p' "$f")
  [ -n "$pid" ] && echo "{\\"event\\":\\"$event\\",\\"ts\\":$(date +%s)}" > /tmp/claude-dash/${pid}.state
  exit 0
done
# Codex: hook runs as child of codex process, use PPID
echo "{\\"event\\":\\"$event\\",\\"ts\\":$(date +%s)}" > /tmp/claude-dash/${PPID}.state
exit 0
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
    var inputSoundTimer: Timer?
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
    var chatPanel: NSWindow!
    var chatView: ChatPanelView!
    var showChat: Bool {
        get { UserDefaults.standard.object(forKey: "showChat") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showChat"); layoutViews() }
    }
    var lastChatFingerprint = ""
    var lastChatMaxId = 0
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
        panel.appearance = NSAppearance(named: .aqua)

        panel.contentView!.wantsLayer = true
        panel.contentView!.layer?.backgroundColor = NSColor.white.cgColor

        dashView = DashboardView(frame: panel.contentView!.bounds)
        dashView.autoresizingMask = [.width, .height]
        dashView.wantsLayer = true
        dashView.layer?.backgroundColor = NSColor.white.cgColor
        panel.contentView!.addSubview(dashView)
        dashView.onSessionClick = { [weak self] s in
            revealSession(s)
            self?.dismissNotification(s.sessionId)
        }
        dashView.onNotesClick = { s in openNotes(for: s) }
        dashView.onResumeClick = { [weak self] s in
            let cmd: String
            if s.source == "codex" {
                cmd = "cd \(s.cwd) && cdash codex --name '\(s.name)' resume \(s.sessionId)"
            } else {
                cmd = "cd \(s.cwd) && cdash claude --resume \(s.sessionId) --name '\(s.name)' --effort max"
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
        dashView.onAddToChat = { [weak self] s in
            guard let self else { return }
            guard !isInChat(name: s.name, sessionId: s.sessionId) else { return }
            // Project = tab the session belongs to, or active tab for unassigned (main) sessions
            let sessionTab = self.tabs.first(where: { $0.sessionIds.contains(s.sessionId) })
            let project: String
            if let tab = sessionTab {
                project = tab.name
            } else {
                // Session is in "main" (unassigned) — use active tab name or "main"
                let activeTab = self.tabs.first(where: { $0.id == self.activeTabId })
                project = activeTab?.name ?? "main"
            }
            // Register in chat db with session_id for stable identity
            let _ = shell("/usr/bin/python3", "/usr/local/lib/claude-dashboard/agent-chat.py",
                          "send", "--project", project, "--name", s.name,
                          "--type", s.source, "--pid", "\(s.pid)",
                          "--session-id", s.sessionId,
                          "--message", "\(s.name) joined the chat")
            // Build member list for intro
            let members = loadChatMembers(project: project)
                .filter { $0.name != s.name && $0.name != "human" }
                .map { $0.name }
            let memberList = members.isEmpty ? "none yet" : members.joined(separator: ", ")

            // Inject intro via state file's child PID
            let injectPath = "\(stateDir)/\(s.pid).inject"
            let intro = "You have been added to team chat channel \"\(project)\". " +
                "Other agents in channel: \(memberList). " +
                "Commands: `cdash chat read` (check messages), " +
                "`cdash chat send \"msg\"` (broadcast), " +
                "`cdash chat send \"msg\" --to name` (DM agent), " +
                "`cdash chat list` (see who's online). " +
                "Check messages now and before making breaking changes."
            try? intro.write(toFile: injectPath, atomically: true, encoding: .utf8)
            // Open chat panel and switch to that channel
            if !self.showChat { self.showChat = true }
            self.chatView.activeProject = project
            self.chatView.updateChannelLabel()
            self.lastChatFingerprint = ""
            self.pollChat()
        }
        dashView.onRemoveClick = { [weak self] s in
            removeSession(s)
            // Also remove from pinned
            var pinned = loadPinned()
            pinned.removeAll { $0.id == s.sessionId }
            savePinned(pinned)
            // Remove from chat
            let _ = shell("/usr/bin/sqlite3", chatDbPath,
                          "DELETE FROM sessions WHERE display_name='\(s.name.replacingOccurrences(of: "'", with: "''"))'")
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
        tabPanel.hasShadow = true
        tabPanel.level = panel.level
        tabPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tabPanel.isMovableByWindowBackground = false
        tabPanel.appearance = NSAppearance(named: .aqua)

        tabPanel.contentView!.wantsLayer = true
        tabPanel.contentView!.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        tabPanel.contentView!.layer?.cornerRadius = 8
        tabPanel.contentView!.layer?.masksToBounds = true
        let tabVisual = tabPanel.contentView!

        tabSidebar = TabSidebarView(frame: tabPanel.contentView!.bounds)
        tabSidebar.autoresizingMask = [.width, .height]
        tabPanel.contentView!.addSubview(tabSidebar)
        dashView.tabSidebar = tabSidebar

        // Keep tab panel attached to main panel
        panel.addChildWindow(tabPanel, ordered: .below)

        // Notification panel — floating to the left of tabs
        notifPanel = AttachedChildWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        notifPanel.isOpaque = false
        notifPanel.backgroundColor = .clear
        notifPanel.hasShadow = true
        notifPanel.appearance = NSAppearance(named: .aqua)
        notifPanel.level = panel.level
        notifPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        notifPanel.contentView!.wantsLayer = true
        notifPanel.contentView!.layer?.backgroundColor = NSColor.white.cgColor
        notifPanel.contentView!.layer?.cornerRadius = 10
        notifPanel.contentView!.layer?.masksToBounds = true
        notifPanel.contentView!.layer?.borderWidth = 0.5
        notifPanel.contentView!.layer?.borderColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor

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

        // Chat panel — separate floating window
        chatPanel = KeyableBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        chatPanel.isOpaque = false
        chatPanel.backgroundColor = .clear
        chatPanel.hasShadow = true
        chatPanel.appearance = NSAppearance(named: .aqua)
        chatPanel.level = panel.level
        chatPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        chatPanel.contentView!.wantsLayer = true
        chatPanel.contentView!.layer?.backgroundColor = NSColor.white.cgColor
        chatPanel.contentView!.layer?.cornerRadius = 10
        chatPanel.contentView!.layer?.masksToBounds = true
        chatPanel.contentView!.layer?.borderWidth = 0.5
        chatPanel.contentView!.layer?.borderColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor

        chatView = ChatPanelView(frame: chatPanel.contentView!.bounds)
        chatView.autoresizingMask = [.width, .height]
        chatPanel.contentView!.addSubview(chatView)
        chatView.setupViews()
        panel.addChildWindow(chatPanel, ordered: .below)
        chatPanel.orderOut(nil)

        chatView.onSend = { [weak self] project, message in
            guard !project.isEmpty, !message.isEmpty else { return }
            let _ = shell("/usr/bin/python3", "/usr/local/lib/claude-dashboard/agent-chat.py",
                          "send", "--project", project, "--name", "human",
                          "--type", "human", "--message", message)
            self?.pollChat()
        }
        chatView.onSendDM = { [weak self] project, message, target in
            guard !project.isEmpty, !message.isEmpty else { return }
            let _ = shell("/usr/bin/python3", "/usr/local/lib/claude-dashboard/agent-chat.py",
                          "send", "--project", project, "--name", "human",
                          "--type", "human", "--message", message, "--to", target)
            self?.pollChat()
        }
        chatView.onMemberReveal = { [weak self] name in
            guard let self else { return }
            if let s = self.currentSessions.first(where: { $0.name == name }) {
                // Switch to the tab containing this session
                let targetTab = self.tabs.first(where: { $0.sessionIds.contains(s.sessionId) })?.id ?? "main"
                if self.activeTabId != targetTab {
                    self.activeTabId = targetTab
                    self.tabSidebar.activeTabId = targetTab
                    try? targetTab.write(toFile: activeTabFile, atomically: true, encoding: .utf8)
                    self.refreshView()
                }
                revealSession(s)
            }
        }
        chatView.onMembersHeightChanged = { [weak self] newH in
            guard let self else { return }
            let delta = newH - self.chatView.membersH
            guard abs(delta) > 1 else { return }
            self.chatView.membersH = newH
            // Expand panel downward
            var f = self.chatPanel.frame
            f.size.height += delta
            f.origin.y -= delta
            self.chatPanel.setFrame(f, display: true)
            // Reposition members view
            if let mv = self.chatView.membersView {
                mv.frame = NSRect(x: 0, y: self.chatView.bounds.height - newH,
                                  width: mv.frame.width, height: newH)
            }
        }
        chatView.onRemoveFromChat = { [weak self] name in
            guard let self, !chatView.activeProject.isEmpty else { return }
            let project = chatView.activeProject
            // Inject removal notice
            if let s = self.currentSessions.first(where: { $0.name == name }) {
                let injectPath = "\(stateDir)/\(s.pid).inject"
                let notice = "You have been removed from the team chat channel \"\(project)\". " +
                    "Stop using cdash chat commands for this channel."
                try? notice.write(toFile: injectPath, atomically: true, encoding: .utf8)
            }
            let _ = shell("/usr/bin/sqlite3", chatDbPath,
                          "DELETE FROM sessions WHERE display_name='\(name.replacingOccurrences(of: "'", with: "''"))'")
            self.pollChat()
        }
        chatView.onSwitchChannel = { [weak self] project in
            self?.lastChatFingerprint = ""
            self?.pollChat()
        }
        chatView.onAddChannel = { [weak self] in
            guard let self else { return }
            if let name = self.promptTabName("New Channel", defaultValue: "") {
                let _ = shell("/usr/bin/python3", "/usr/local/lib/claude-dashboard/agent-chat.py",
                              "send", "--project", name, "--name", "human", "--type", "human",
                              "--message", "Channel created")
                self.chatView.activeProject = name
                self.chatView.updateChannelLabel()
                self.lastChatFingerprint = ""
                self.pollChat()
            }
        }
        chatView.onRemoveChannel = { [weak self] project in
            guard let self else { return }
            let _ = shell("/usr/bin/sqlite3", chatDbPath,
                          "DELETE FROM messages WHERE project_id='\(project)'; DELETE FROM sessions WHERE project_id='\(project)'; DELETE FROM projects WHERE id='\(project)'; DELETE FROM read_cursors WHERE project_id='\(project)'")
            self.chatView.activeProject = ""
            self.lastChatFingerprint = ""
            self.pollChat()
        }

        tabs = loadTabs()
        tabSidebar.tabs = tabs
        tabSidebar.activeTabId = activeTabId

        // Write initial active tab
        try? activeTabId.write(toFile: activeTabFile, atomically: true, encoding: .utf8)

        tabSidebar.onTabSelect = { [weak self] id in
            guard let self else { return }
            self.activeTabId = id
            self.tabSidebar.activeTabId = id
            try? id.write(toFile: activeTabFile, atomically: true, encoding: .utf8)
            // Sync chat to tab's project
            let tabName = self.tabs.first(where: { $0.id == id })?.name ?? "main"
            if self.chatView.projects.contains(tabName) {
                self.chatView.activeProject = tabName
                self.chatView.updateChannelLabel()
                self.lastChatFingerprint = ""  // force refresh
            }
            self.refreshView()
            if self.showChat { self.pollChat() }
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

        // Main menu — needed for Cmd+A, Cmd+C, etc. in text views
        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

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
        updateInputSoundTimer()
    }

    func updateInputSoundTimer() {
        let hasInputNeeded = dashNotifications.contains { $0.isInputNeeded }
        if hasInputNeeded && inputSoundTimer == nil {
            NSSound(named: "Ping")?.play()
            NSApp.requestUserAttention(.informationalRequest)
            inputSoundTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                NSSound(named: "Ping")?.play()
                NSApp.requestUserAttention(.informationalRequest)
            }
        } else if !hasInputNeeded {
            if inputSoundTimer != nil {
                inputSoundTimer?.invalidate()
                inputSoundTimer = nil
            }
        }
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

        // Tabs
        let wantTabs = showTabs && !mainHidden
        if wantTabs {
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
        let wantNotif = !dashNotifications.isEmpty && !mainHidden
        if wantNotif {
            let w = notifView.idealWidth
            let h = notifView.idealHeight
            let anchor = (wantTabs && tabPanel.isVisible) ? tabPanel.frame : panel.frame
            let x = anchor.minX - w - 4
            let y = anchor.maxY - h
            notifPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            if !notifPanel.isVisible { notifPanel.orderFront(nil) }
        } else {
            if notifPanel.isVisible { notifPanel.orderOut(nil) }
        }

        // Chat panel
        let wantChat = showChat && !mainHidden
        if wantChat {
            let w: CGFloat = 300
            let h: CGFloat = 400
            let x = panel.frame.maxX + 4
            let y = panel.frame.maxY - h
            chatPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            if !chatPanel.isVisible { chatPanel.orderFront(nil) }
        } else {
            if chatPanel.isVisible { chatPanel.orderOut(nil) }
        }
    }

    func moveItemToTab(tabId: String, itemId: String) {
        // If session is in a chat channel for its old tab, remove it
        if itemId.hasPrefix("session:") {
            let sid = String(itemId.dropFirst(8))
            if let session = currentSessions.first(where: { $0.sessionId == sid }) {
                // Find old tab
                let oldTab = tabs.first(where: { $0.sessionIds.contains(sid) })
                let oldChannel = oldTab?.name ?? "main"
                let _ = shell("/usr/bin/sqlite3", chatDbPath,
                    "DELETE FROM sessions WHERE display_name='\(session.name.replacingOccurrences(of: "'", with: "''"))'")
            }
        }
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

    @objc func toggleShowChat(_ sender: NSMenuItem) {
        showChat = !showChat
        if showChat {
            pollChat()
            layoutChatPanel()
            // Focus the input
            if let tv = chatView.inputTV {
                chatPanel.makeFirstResponder(tv)
            }
        } else {
            chatPanel.orderOut(nil)
        }
    }

    func pollChat() {
        let projects = loadChatProjects()
        chatView.updateProjects(projects)
        if chatView.activeProject.isEmpty, let first = projects.first {
            chatView.activeProject = first
        }
        guard !chatView.activeProject.isEmpty else { return }
        // Load members and feed names for autocomplete
        var mbrs = loadChatMembers(project: chatView.activeProject)
        // Match members to live sessions by session_id (stable) or name (fallback)
        let allSess = dashView.allSessions
        for i in 0..<mbrs.count {
            let sid = mbrs[i].sessionId
            let dbName = mbrs[i].name
            // Match by session_id first (stable across renames), then by name
            let live = (!sid.isEmpty ? allSess.first(where: { $0.sessionId == sid && $0.state != .dead }) : nil)
                    ?? allSess.first(where: { $0.name == dbName && $0.state != .dead })
                    ?? (!sid.isEmpty ? allSess.first(where: { $0.sessionId == sid }) : nil)
                    ?? allSess.first(where: { $0.name == dbName })
            if let live {
                mbrs[i] = ChatMember(name: live.name, agentType: mbrs[i].agentType, state: live.state, sessionId: sid)
                // Sync name in chat db if it changed (e.g. session renamed)
                if live.name != dbName {
                    let _ = shell("/usr/bin/sqlite3", chatDbPath,
                        "UPDATE sessions SET display_name='\(live.name.replacingOccurrences(of: "'", with: "''"))' WHERE project_id='\(chatView.activeProject.replacingOccurrences(of: "'", with: "''"))' AND display_name='\(dbName.replacingOccurrences(of: "'", with: "''"))'")
                }
            }
        }
        chatView.members = mbrs
        chatView.sessionNames = mbrs.map(\.name)
        let msgs = loadChatMessages(project: chatView.activeProject)
        let fp = msgs.map { "\($0.id)" }.joined()
        if fp != lastChatFingerprint {
            lastChatFingerprint = fp
            chatView.messages = msgs
            chatView.refreshMessages()

            // Track max ID for human-directed message alerts
            if let maxId = msgs.last?.id, maxId > lastChatMaxId {
                // Check for new human-directed messages
                for msg in msgs where msg.id > lastChatMaxId {
                    if msg.recipient == "human" && msg.senderType != "human" {
                        NSApp.requestUserAttention(.informationalRequest)
                        NSSound(named: "Ping")?.play()
                    }
                }
                lastChatMaxId = maxId
            }
        }
    }

    func layoutChatPanel() { layoutViews() }

    func showToast(_ message: String, near button: NSView) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 11, weight: .medium)
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
        chatPanel.orderOut(nil)
        return false
    }

    // Don't call layoutViews on windowDidMove — child windows auto-move with parent.
    // Calling setFrame during drag fights with macOS auto-positioning and causes glitching.
    // Only reposition on resize (changes relative offsets).
    func windowDidResize(_ notification: Notification) {
        layoutViews()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        tabPanel.orderOut(nil)
        notifPanel.orderOut(nil)
        chatPanel.orderOut(nil)
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
            if showChat { chatPanel.orderFront(nil) }
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
            chatPanel.orderOut(nil)
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
        chatPanel.level = panel.level
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

    func refreshView() {
        let orderedSessions = applyCustomOrder(currentSessions)
        dashView.sessions = sessionsForActiveTab(orderedSessions)
        dashView.terminals = terminalsForActiveTab(currentTerminals)
        dashView.allSessions = orderedSessions
        dashView.allTerminals = currentTerminals
        dashView.pinnedItems = loadPinned()
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
            DispatchQueue.main.async {
                self?.updateUI(ss, terminals: terms)
                if self?.showChat == true { self?.pollChat() }
            }
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

        let chatToggle = NSMenuItem(
            title: "Show Chat",
            action: #selector(toggleShowChat(_:)), keyEquivalent: "")
        chatToggle.target = self
        chatToggle.state = showChat ? .on : .off
        menu.addItem(chatToggle)

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
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]))
            a.append(NSAttributedString(string: "  \(s.state.label)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
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
                // Dismiss input-needed notification when resolved
                if prev == .needsInput && s.state != .needsInput {
                    dismissNotification(sid)
                }

                if prev == .working && s.state != .working {
                    if !dashNotifications.contains(where: { $0.id == sid }) {
                        dashLog("NOTIFY \(s.name) \(State.working.label) → \(s.state.label)")
                        dashNotifications.append(DashNotification(
                            id: sid, sessionName: s.name,
                            cwd: s.cwd, tty: s.tty, time: Date(),
                            isInputNeeded: s.state == .needsInput))
                        layoutNotifPanel()
                        if s.state == .needsInput {
                            NSApp.requestUserAttention(.informationalRequest)
                            updateInputSoundTimer()
                        }
                    }
                }
                // Also notify on idle → needsInput (working→needsInput handled above)
                if prev == .idle && s.state == .needsInput {
                    if !dashNotifications.contains(where: { $0.id == sid }) {
                        dashLog("NOTIFY \(s.name) \(prev!.label) → \(s.state.label)")
                        dashNotifications.append(DashNotification(
                            id: sid, sessionName: s.name,
                            cwd: s.cwd, tty: s.tty, time: Date(),
                            isInputNeeded: true))
                        layoutNotifPanel()
                        NSApp.requestUserAttention(.informationalRequest)
                        updateInputSoundTimer()
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
