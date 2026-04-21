import Cocoa

// MARK: - Config

let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("sessions")
let pollInterval: TimeInterval = 1
let notesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-notes").path
let storeFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude").appendingPathComponent("dashboard-store.json").path

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
    proc.waitUntilExit()
    return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                   encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func isWorking(_ pid: pid_t) -> Bool {
    let cpu = Double(shell("/bin/ps", "-o", "%cpu=", "-p", "\(pid)")) ?? 0
    if cpu > 2.0 { return true }
    let kids = shell("/usr/bin/pgrep", "-P", "\(pid)")
    return !kids.isEmpty
}

let stateDir = "/tmp/claude-dash"
var previousState: [pid_t: State] = [:]
var lastActiveTime: [pid_t: Date] = [:]

func stateFileEvent(_ pid: pid_t) -> String? {
    let url = URL(fileURLWithPath: "\(stateDir)/\(pid).state")
    guard let data = try? Data(contentsOf: url),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = j["event"] as? String else { return nil }
    return event
}

func resolveState(_ pid: pid_t) -> State {
    let state: State
    guard kill(pid, 0) == 0 else { state = .dead; return track(pid, state) }
    let working = isWorking(pid)
    if working {
        // Working clears any state file
        try? FileManager.default.removeItem(atPath: "\(stateDir)/\(pid).state")
        state = .working
    } else {
        switch stateFileEvent(pid) {
        case "needs_input": state = .needsInput
        case "stop":        state = .idle
        default:            state = .idle
        }
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
}

func loadStore() -> [String: StoredSession] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: storeFile)),
          let list = try? JSONDecoder().decode([String: StoredSession].self, from: data)
    else { return [:] }
    return list
}

func saveStore(_ store: [String: StoredSession]) {
    guard let data = try? JSONEncoder().encode(store) else { return }
    try? data.write(to: URL(fileURLWithPath: storeFile))
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

    var store = loadStore()

    // Seed in-memory times from store on first load
    if !didSeedTimes {
        didSeedTimes = true
        for (_, stored) in store {
            let p = pid_t(stored.lastPid)
            if lastActiveTime[p] == nil, let ts = stored.lastActiveTs {
                lastActiveTime[p] = Date(timeIntervalSince1970: ts)
                previousState[p] = .idle // assume idle on startup
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
            let s = Session(
                pid: p, sessionId: sid,
                name: sname,
                cwd: (j["cwd"] as? String) ?? "",
                startedAt: startedAt,
                state: resolveState(p),
                tty: shell("/bin/ps", "-o", "tty=", "-p", "\(pid)"),
                hasNotes: hasNotesFile(name: sname, sessionId: sid),
                lastActive: lastActiveTime[p] ?? fallback)
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

        store[sid] = StoredSession(sessionId: sid, name: s.name, cwd: s.cwd,
                                   startedAt: s.startedAt, lastPid: Int(s.pid),
                                   lastActiveTs: lastActiveTime[s.pid]?.timeIntervalSince1970)
    }
    saveStore(store)

    // Build final list: live sessions + dead stored sessions
    var result = Array(liveBySessionId.values)
    for (sid, stored) in store {
        if liveBySessionId[sid] == nil {
            let p = pid_t(stored.lastPid)
            let fallback = Date(timeIntervalSince1970: stored.startedAt / 1000)
            result.append(Session(
                pid: p, sessionId: sid,
                name: stored.name, cwd: stored.cwd,
                startedAt: stored.startedAt, state: .dead,
                tty: "", hasNotes: hasNotesFile(name: stored.name, sessionId: sid),
                lastActive: lastActiveTime[p] ?? Date(timeIntervalSince1970: stored.lastActiveTs ?? fallback.timeIntervalSince1970)))
        }
    }
    return result.sorted { $0.startedAt > $1.startedAt }
}

// MARK: - Notes

func openNotes(for session: Session) {
    let path = notesPath(name: session.name, sessionId: session.sessionId)
    if !FileManager.default.fileExists(atPath: path) {
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

func removeSession(_ session: Session) {
    let alert = NSAlert()
    alert.messageText = "Remove \"\(session.name)\"?"
    alert.informativeText = "The session will be removed from the dashboard.\n\nNotes are kept in:\n\(notesDir)"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    var store = loadStore()
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
    let tty = session.tty
    guard !tty.isEmpty else { return }

    let apps = NSWorkspace.shared.runningApplications
    let hasITerm = apps.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }

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
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    } else {
        script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
    }

    DispatchQueue.global(qos: .userInitiated).async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
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

// MARK: - Dashboard Window View

class DashboardView: NSView {
    var sessions: [Session] = [] {
        didSet {
            rebuildButtons()
            invalidateIntrinsicContentSize()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var onSessionClick: ((Session) -> Void)?
    var onNotesClick: ((Session) -> Void)?
    var onRemoveClick: ((Session) -> Void)?
    var onResumeClick: ((Session) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let cardH: CGFloat = 52
    private let gap: CGFloat = 8
    private let padX: CGFloat = 12
    private let padY: CGFloat = 10
    private var noteButtons: [NSButton] = []
    var resumeButtons: [NSButton] = []
    private var removeButtons: [NSButton] = []

    override var isFlipped: Bool { true }

    var idealHeight: CGFloat {
        guard !sessions.isEmpty else { return 60 }
        return padY + CGFloat(sessions.count) * (cardH + gap) - gap + padY
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

    // ── Click ──
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard let idx = cardIndex(at: loc), idx < sessions.count else { return }
        onSessionClick?(sessions[idx])
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

    func rebuildButtons() {
        noteButtons.forEach { $0.removeFromSuperview() }
        resumeButtons.forEach { $0.removeFromSuperview() }
        removeButtons.forEach { $0.removeFromSuperview() }
        noteButtons.removeAll()
        resumeButtons.removeAll()
        removeButtons.removeAll()

        for (i, s) in sessions.enumerated() {
            let rect = cardRect(at: i)

            // Resume button (copy command to clipboard)
            let rb = NSButton(frame: NSRect(x: rect.maxX - 56, y: rect.minY + 14, width: 24, height: 24))
            rb.bezelStyle = .inline
            rb.image = NSImage(systemSymbolName: "play.fill",
                               accessibilityDescription: "Copy resume command")
            rb.imagePosition = .imageOnly
            rb.tag = i
            rb.target = self
            rb.action = #selector(resumeBtnClicked(_:))
            rb.toolTip = "Copy resume command"
            addSubview(rb)
            resumeButtons.append(rb)

            // Notes button
            let nb = NSButton(frame: NSRect(x: rect.maxX - 30, y: rect.minY + 14, width: 24, height: 24))
            nb.bezelStyle = .inline
            nb.image = NSImage(systemSymbolName: s.hasNotes ? "doc.text.fill" : "doc.text",
                               accessibilityDescription: "Notes")
            nb.imagePosition = .imageOnly
            nb.tag = i
            nb.target = self
            nb.action = #selector(notesBtnClicked(_:))
            nb.toolTip = "Open notes"
            addSubview(nb)
            noteButtons.append(nb)

            // Remove button (dead sessions only) — next to DEAD label on row 1
            if s.state == .dead {
                let nameW = NSAttributedString(string: s.name, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)]).size().width
                let stateW = NSAttributedString(string: "DEAD", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)]).size().width
                let rbX = rect.minX + 14 + nameW + 10 + stateW + 6
                let rb = NSButton(frame: NSRect(x: rbX, y: rect.minY + 8, width: 20, height: 20))
                rb.bezelStyle = .inline
                rb.image = NSImage(systemSymbolName: "xmark.circle",
                                   accessibilityDescription: "Remove")
                rb.imagePosition = .imageOnly
                rb.tag = i
                rb.target = self
                rb.action = #selector(removeBtnClicked(_:))
                rb.toolTip = "Remove session"
                addSubview(rb)
                removeButtons.append(rb)
            }
        }
    }

    // ── Cursor ──
    override func resetCursorRects() {
        for i in 0..<sessions.count {
            addCursorRect(cardRect(at: i), cursor: .pointingHand)
        }
    }

    // ── Draw ──
    override func draw(_ dirtyRect: NSRect) {
        if sessions.isEmpty {
            let str = NSAttributedString(string: "No active sessions", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
            str.draw(at: NSPoint(x: padX, y: 24))
            return
        }

        for (i, s) in sessions.enumerated() {
            let rect = cardRect(at: i)

            // Card background
            let bgAlpha: CGFloat = 0.08
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
            let rightEdge = rect.maxX - 62 // leave space for buttons

            // Row 1: name + state + duration
            let nameAttr = NSAttributedString(string: s.name, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.labelColor])
            nameAttr.draw(at: NSPoint(x: tx, y: rect.minY + 8))

            let stateAttr = NSAttributedString(string: s.state.label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: s.state.color])
            stateAttr.draw(at: NSPoint(x: tx + nameAttr.size().width + 10, y: rect.minY + 10))

            let durAttr = NSAttributedString(string: timeAgo(s.lastActive), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
            durAttr.draw(at: NSPoint(x: rightEdge - durAttr.size().width, y: rect.minY + 9))

            // Row 2: path + pid
            let pathAttr = NSAttributedString(string: shortPath(s.cwd), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
            pathAttr.draw(at: NSPoint(x: tx, y: rect.minY + 30))

            let pidAttr = NSAttributedString(string: "pid:\(s.pid)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
            pidAttr.draw(at: NSPoint(x: rightEdge - pidAttr.size().width, y: rect.minY + 31))

            // Buttons are NSButton subviews managed by rebuildButtons()
        }
    }
}

// MARK: - Auto-setup

let hookScript = """
#!/usr/bin/env bash
event="${1:-stop}"
read -t 2 input || true
sid=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
[ -z "$sid" ] && exit 0
for f in "$HOME/.claude/sessions/"*.json; do
  fsid=$(python3 -c "import json; print(json.load(open('$f')).get('sessionId',''))" 2>/dev/null)
  if [ "$fsid" = "$sid" ]; then
    pid=$(python3 -c "import json; print(json.load(open('$f')).get('pid',''))" 2>/dev/null)
    [ -n "$pid" ] && echo "{\\"event\\":\\"$event\\",\\"ts\\":$(date +%s)}" > /tmp/claude-dash/${pid}.state
    exit 0
  fi
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
    if !fm.fileExists(atPath: hookPath) || (try? String(contentsOfFile: hookPath, encoding: .utf8)) != hookScript {
        try? hookScript.write(toFile: hookPath, atomically: true, encoding: .utf8)
        // chmod +x
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+x", hookPath]
        try? p.run(); p.waitUntilExit()
    }

    // 3. Ensure hooks are registered in settings.json
    let settingsPath = "\(home)/.claude/settings.json"
    // Resolve symlink to get the real path
    let realPath = (try? fm.destinationOfSymbolicLink(atPath: settingsPath)) ?? settingsPath
    let targetPath = fm.fileExists(atPath: realPath) ? realPath : settingsPath

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: targetPath)),
          var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var changed = false

    // Add Notification permission_prompt hook if missing
    let notifHooks = hooks["Notification"] as? [[String: Any]] ?? []
    let hasDashNotif = notifHooks.contains { entry in
        let h = entry["hooks"] as? [[String: Any]] ?? []
        return h.contains { ($0["command"] as? String)?.contains("dash-state.sh") == true }
    }
    if !hasDashNotif {
        var updated = notifHooks
        updated.insert([
            "matcher": "permission_prompt",
            "hooks": [["type": "command", "command": hookPath + " needs_input"]]
        ], at: 0)
        hooks["Notification"] = updated
        changed = true
    }

    // Add Stop hook if missing
    let stopHooks = hooks["Stop"] as? [[String: Any]] ?? []
    let hasDashStop = stopHooks.contains { entry in
        let h = entry["hooks"] as? [[String: Any]] ?? []
        return h.contains { ($0["command"] as? String)?.contains("dash-state.sh") == true }
    }
    if !hasDashStop {
        var updated = stopHooks
        updated.insert([
            "hooks": [["type": "command", "command": hookPath + " stop"]]
        ], at: 0)
        hooks["Stop"] = updated
        changed = true
    }

    if changed {
        settings["hooks"] = hooks
        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: targetPath))
        }
    }
}

// MARK: - App

class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var bar: NSStatusItem!
    var panel: NSWindow!
    var dashView: DashboardView!
    var timer: Timer?
    var currentSessions: [Session] = []
    var wakeOnAttention: Bool {
        get { UserDefaults.standard.bool(forKey: "wakeOnAttention") }
        set { UserDefaults.standard.set(newValue, forKey: "wakeOnAttention") }
    }
    var didWake = false  // prevent repeated wake calls
    var alwaysOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop") }
    }
    var workingStartTime: Date?
    var wasWorking = false
    var idleSleepProc: Process?  // caffeinate -i while sessions are working

    func applicationWillTerminate(_: Notification) {
        stopPreventIdleSleep()
    }

    func applicationDidFinishLaunching(_: Notification) {
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
        dashView.onSessionClick = { s in revealSession(s) }
        dashView.onNotesClick = { s in openNotes(for: s) }
        dashView.onResumeClick = { [weak self] s in
            let cmd = "cd \(s.cwd) && claude --resume \(s.sessionId) --name '\(s.name)'"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            if let btn = self?.dashView.resumeButtons.first(where: {
                $0.tag < (self?.dashView.sessions.count ?? 0) &&
                self?.dashView.sessions[$0.tag].sessionId == s.sessionId
            }) {
                self?.showToast("Resume command copied", near: btn)
            }
        }
        dashView.onRemoveClick = { [weak self] s in
            removeSession(s)
            self?.poll()
        }

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
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { panel.makeKeyAndOrderFront(nil) }
        return true
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) }
        else { panel.makeKeyAndOrderFront(nil) }
    }

    @objc func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        alwaysOnTop = !alwaysOnTop
        panel.level = alwaysOnTop ? .floating : .normal
    }

    @objc func toggleWakeOnAttention(_ sender: NSMenuItem) {
        wakeOnAttention = !wakeOnAttention
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
        idleSleepProc?.terminate()
        idleSleepProc = nil
    }

    @objc func menuSessionClicked(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < currentSessions.count else { return }
        revealSession(currentSessions[idx])
    }

    private let pollQueue = DispatchQueue(label: "poll", qos: .userInitiated)

    func poll() {
        pollQueue.async { [weak self] in
            let ss = loadSessions()
            DispatchQueue.main.async { self?.updateUI(ss) }
        }
    }

    func updateUI(_ ss: [Session]) {
        currentSessions = ss
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

        // ── Window ──
        dashView.sessions = ss
        let idealH = dashView.idealHeight
        var frame = panel.frame
        let topY = frame.maxY
        frame.size.height = idealH + 28
        frame.origin.y = topY - frame.size.height
        panel.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - Entry

let nsApp = NSApplication.shared
let delegate = App()
nsApp.delegate = delegate
nsApp.run()
