#!/usr/bin/env python3
"""Agent chat backend. Internal — called by cdash chat subcommands."""

import sqlite3
import sys
import os
import json
import time
import glob

DB_PATH = os.path.expanduser("~/.claude/dashboard-chat.db")
STATE_DIR = "/tmp/claude-dash"

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=3000")
    db.execute("""CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        created_at INTEGER DEFAULT (unixepoch()))""")
    db.execute("""CREATE TABLE IF NOT EXISTS sessions (
        project_id TEXT NOT NULL REFERENCES projects(id),
        display_name TEXT NOT NULL, agent_type TEXT NOT NULL,
        working_directory TEXT, pid INTEGER, proxy_pid INTEGER,
        connected_at INTEGER DEFAULT (unixepoch()),
        last_seen INTEGER DEFAULT (unixepoch()),
        PRIMARY KEY(project_id, display_name))""")
    db.execute("""CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL, sender_name TEXT NOT NULL,
        sender_type TEXT NOT NULL, recipient TEXT, body TEXT NOT NULL,
        created_at INTEGER DEFAULT (unixepoch()))""")
    db.execute("""CREATE TABLE IF NOT EXISTS read_cursors (
        project_id TEXT NOT NULL, display_name TEXT NOT NULL,
        last_read_id INTEGER DEFAULT 0,
        PRIMARY KEY(project_id, display_name))""")
    db.execute("CREATE INDEX IF NOT EXISTS idx_messages_project ON messages(project_id, id)")
    db.commit()
    return db

def ensure_project(db, project_id):
    db.execute("INSERT OR IGNORE INTO projects(id, name) VALUES(?, ?)",
               (project_id, project_id))

def ensure_session(db, project_id, name, agent_type, pid=None, proxy_pid=None, cwd=None):
    ensure_project(db, project_id)
    db.execute("""INSERT INTO sessions(project_id, display_name, agent_type, working_directory, pid, proxy_pid)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(project_id, display_name) DO UPDATE SET
            agent_type=excluded.agent_type, pid=COALESCE(excluded.pid, pid),
            proxy_pid=COALESCE(excluded.proxy_pid, proxy_pid),
            working_directory=COALESCE(excluded.working_directory, working_directory),
            last_seen=unixepoch()""",
        (project_id, name, agent_type, cwd, pid, proxy_pid))
    db.commit()

def read_state_file(pid):
    """Read state file for a PID. Returns (event, proxy_pid) or None."""
    try:
        with open(f"{STATE_DIR}/{pid}.state") as f:
            j = json.load(f)
            return j.get("event", ""), j.get("proxy_pid", 0)
    except Exception:
        return None

def find_all_state_files():
    """Read all state files. Returns list of (child_pid, event, proxy_pid, tty, name, project)."""
    results = []
    try:
        for fname in os.listdir(STATE_DIR):
            if not fname.endswith(".state"): continue
            pid_str = fname[:-6]
            if not pid_str.isdigit(): continue
            try:
                with open(f"{STATE_DIR}/{fname}") as f:
                    j = json.load(f)
                    results.append((int(pid_str), j.get("event", ""), j.get("proxy_pid", 0),
                                    j.get("tty", ""), j.get("name", ""), j.get("project", "")))
            except: pass
    except: pass
    return results

def write_inject(pid, text):
    """Write inject file for a proxy child PID."""
    path = f"{STATE_DIR}/{pid}.inject"
    try:
        with open(path, "w") as f:
            f.write(text)
    except Exception:
        pass

def cmd_send(args):
    project = args["project"]
    name = args["name"]
    agent_type = args["type"]
    message = args["message"]
    recipient = args.get("to")
    pid = args.get("pid")
    proxy_pid = args.get("proxy_pid")
    cwd = args.get("cwd")

    db = get_db()
    ensure_session(db, project, name, agent_type, pid, proxy_pid, cwd)

    db.execute("INSERT INTO messages(project_id, sender_name, sender_type, recipient, body) VALUES(?,?,?,?,?)",
               (project, name, agent_type, recipient, message))
    db.execute("UPDATE sessions SET last_seen=unixepoch() WHERE project_id=? AND display_name=?",
               (project, name))
    db.commit()

    # Find sessions to notify — use live state files with name/project from proxy
    rows = db.execute("SELECT display_name, pid FROM sessions WHERE project_id=? AND display_name!=? AND pid>0",
                       (project, name)).fetchall()
    db.close()

    state_files = find_all_state_files()

    # Match by name+project in state files (proxy writes these from env vars)
    target_names = {recipient} if recipient else {r[0] for r in rows}

    for sf_pid, sf_event, sf_proxy_pid, sf_tty, sf_name, sf_project in state_files:
        if sf_event != "stop": continue  # only inject idle
        if sf_project != project: continue  # same project only
        if sf_name not in target_names: continue
        snippet = message[:100] + ("..." if len(message) > 100 else "")
        inject_text = (f"Chat from {agent_type}/{name}: \"{snippet}\" "
                      f"— Run `cdash chat read` for context, `cdash chat send \"reply\"` to respond.\n")
        write_inject(sf_pid, inject_text)

    active = len([r for r in rows if r[1] and r[1] > 0])
    if recipient:
        print(f"Sent to {recipient}")
    else:
        print(f"Sent to {project} ({active} active sessions)")

def cmd_read(args):
    project = args["project"]
    name = args["name"]
    agent_type = args["type"]
    show_all = args.get("all", False)
    limit = args.get("limit", 50)
    pid = args.get("pid")
    proxy_pid = args.get("proxy_pid")
    cwd = args.get("cwd")

    db = get_db()
    ensure_session(db, project, name, agent_type, pid, proxy_pid, cwd)

    # Get read cursor
    cursor = 0
    if not show_all:
        row = db.execute("SELECT last_read_id FROM read_cursors WHERE project_id=? AND display_name=?",
                         (project, name)).fetchone()
        if row:
            cursor = row[0]

    # Fetch messages: broadcasts + DMs to this session
    rows = db.execute("""SELECT id, sender_name, sender_type, recipient, body, created_at
        FROM messages WHERE project_id=? AND id>? AND (recipient IS NULL OR recipient=? OR sender_name=?)
        ORDER BY id ASC LIMIT ?""",
        (project, cursor, name, name, limit)).fetchall()

    if not rows:
        print(f"No new messages in {project}")
        db.close()
        return

    # Update cursor
    max_id = max(r[0] for r in rows)
    db.execute("""INSERT INTO read_cursors(project_id, display_name, last_read_id) VALUES(?,?,?)
        ON CONFLICT(project_id, display_name) DO UPDATE SET last_read_id=MAX(last_read_id, excluded.last_read_id)""",
        (project, name, max_id))
    db.commit()
    db.close()

    # Format output
    print(f"── {project} chat ──")
    for msg_id, s_name, s_type, recip, body, ts in rows:
        t = time.strftime("%H:%M", time.localtime(ts))
        sender = f"{s_type}/{s_name}" if s_type != "human" else "human"
        dm = f" → {recip}" if recip else ""
        print(f"[{msg_id}] {sender}{dm}  {t}  {body}")
    count = len(rows)
    label = "new messages" if not show_all else "messages"
    print(f"── {count} {label} ──")

def cmd_list(args):
    project = args["project"]
    db = get_db()
    ensure_project(db, project)
    rows = db.execute("""SELECT display_name, agent_type, pid, last_seen FROM sessions
        WHERE project_id=? ORDER BY last_seen DESC""", (project,)).fetchall()
    db.close()

    if not rows:
        print(f"No sessions in {project}")
        return

    print(f"── {project} sessions ──")
    now = int(time.time())
    for name, atype, pid, last_seen in rows:
        alive = pid and pid > 0 and os.path.exists(f"/proc/{pid}") if sys.platform == "linux" else (
            pid and pid > 0 and os.system(f"kill -0 {pid} 2>/dev/null") == 0)
        if alive:
            status = f"active   pid {pid}"
        elif pid and pid > 0:
            ago = now - last_seen
            if ago < 60: status = f"idle     {ago}s ago"
            elif ago < 3600: status = f"idle     {ago // 60}m ago"
            else: status = f"offline  {ago // 3600}h ago"
        else:
            status = "disconnected"
        print(f"  {atype}/{name:<20s} {status}")

def cmd_cleanup(args):
    db = get_db()
    rows = db.execute("SELECT project_id, display_name, pid FROM sessions WHERE pid>0").fetchall()
    cleaned = 0
    for proj, name, pid in rows:
        alive = os.system(f"kill -0 {pid} 2>/dev/null") == 0
        if not alive:
            db.execute("UPDATE sessions SET pid=0, proxy_pid=0 WHERE project_id=? AND display_name=?",
                       (proj, name))
            cleaned += 1
    if cleaned:
        db.commit()
    db.close()
    print(f"Cleaned {cleaned} dead sessions")

def main():
    if len(sys.argv) < 2:
        print("Usage: agent-chat.py <send|read|list|cleanup> [args]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    # Parse key=value args
    args = {}
    i = 2
    while i < len(sys.argv):
        a = sys.argv[i]
        if a.startswith("--"):
            key = a[2:].replace("-", "_")
            if i + 1 < len(sys.argv) and not sys.argv[i + 1].startswith("--"):
                args[key] = sys.argv[i + 1]
                i += 2
            else:
                args[key] = True
                i += 1
        else:
            # Positional — treat as message for send
            if "message" not in args:
                args["message"] = a
            i += 1

    # Convert numeric args
    for k in ("pid", "proxy_pid", "limit"):
        if k in args and isinstance(args[k], str) and args[k].isdigit():
            args[k] = int(args[k])

    if cmd == "send":
        cmd_send(args)
    elif cmd == "read":
        cmd_read(args)
    elif cmd == "list":
        cmd_list(args)
    elif cmd == "cleanup":
        cmd_cleanup(args)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
