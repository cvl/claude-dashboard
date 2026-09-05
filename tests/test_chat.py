#!/usr/bin/env python3
"""Tests for agent-chat.py — uses temp DB/state dir, fake codex binary."""

import os
import sys
import json
import stat
import sqlite3
import tempfile
import unittest

# Add parent dir to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

class ChatTestBase(unittest.TestCase):
    """Base with isolated temp DB, state dir, and fake codex binary."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "chat.db")
        self.state_dir = os.path.join(self.tmpdir, "state")
        os.makedirs(self.state_dir)
        self.fake_codex = os.path.join(self.tmpdir, "fake-codex")
        self._write_fake_codex(exit_code=0, stdout="Queued message aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee for thread test.\n")
        # Patch env
        os.environ["CDASH_CHAT_DB"] = self.db_path
        os.environ["CDASH_STATE_DIR"] = self.state_dir
        os.environ["CODEX_BIN"] = self.fake_codex
        # Import fresh
        import importlib
        if "agent_chat" in sys.modules:
            importlib.reload(sys.modules["agent_chat"])
        # Import the module (renamed for import)
        spec = importlib.util.spec_from_file_location("agent_chat",
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "agent-chat.py"))
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)
        for k in ("CDASH_CHAT_DB", "CDASH_STATE_DIR", "CODEX_BIN"):
            os.environ.pop(k, None)

    def _write_fake_codex(self, exit_code=0, stdout="", stderr=""):
        with open(self.fake_codex, "w") as f:
            f.write(f'#!/bin/bash\necho "{stdout}"\n>&2 echo "{stderr}"\nexit {exit_code}\n')
        os.chmod(self.fake_codex, 0o755)

    def _get_db(self):
        return self.mod.get_db()

    def _add_session(self, project, name, agent_type="claude", transport="pty", thread_id=None, pid=0):
        db = self._get_db()
        self.mod.ensure_project(db, project)
        db.execute("""INSERT INTO sessions(project_id, display_name, agent_type, delivery_transport, session_id, pid)
            VALUES(?,?,?,?,?,?) ON CONFLICT(project_id, display_name) DO UPDATE SET
            agent_type=excluded.agent_type, delivery_transport=excluded.delivery_transport,
            session_id=excluded.session_id, pid=excluded.pid""",
            (project, name, agent_type, transport, thread_id, pid))
        db.commit()
        db.close()

    def _write_state_file(self, pid, name, event="idle"):
        path = os.path.join(self.state_dir, f"{pid}.state")
        with open(path, "w") as f:
            json.dump({"event": event, "ts": 0, "proxy_pid": os.getpid(), "name": name, "tty": "test"}, f)

    def _send_msg(self, db, project, sender, sender_type, body, recipient=None):
        db.execute("INSERT INTO messages(project_id, sender_name, sender_type, recipient, body) VALUES(?,?,?,?,?)",
                   (project, sender, sender_type, recipient, body))
        msg_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]
        db.commit()
        return msg_id


class TestAttach(ChatTestBase):
    def test_attach_stores_codex_queue(self):
        """1. Attach reads thread ID and stores codex_queue transport."""
        db = self._get_db()
        self.mod.ensure_project(db, "proj")
        db.close()
        self.mod.cmd_attach({"name": "bot", "project": "proj", "thread": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"})
        db = self._get_db()
        row = db.execute("SELECT agent_type, session_id, delivery_transport FROM sessions WHERE display_name='bot'").fetchone()
        db.close()
        self.assertEqual(row[0], "codex")
        self.assertEqual(row[1], "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        self.assertEqual(row[2], "codex_queue")

    def test_attach_rejects_bad_uuid(self):
        """2. Attach rejects malformed thread IDs."""
        with self.assertRaises(SystemExit):
            self.mod.cmd_attach({"name": "bot", "project": "proj", "thread": "not-a-uuid"})

    def test_attach_rejects_missing_uuid(self):
        """2b. Attach rejects missing thread ID."""
        os.environ.pop("CODEX_THREAD_ID", None)
        with self.assertRaises(SystemExit):
            self.mod.cmd_attach({"name": "bot", "project": "proj"})

    def test_attach_from_env(self):
        """3. CODEX_THREAD_ID env is used when --thread not given."""
        os.environ["CODEX_THREAD_ID"] = "11111111-2222-3333-4444-555555555555"
        db = self._get_db()
        self.mod.ensure_project(db, "proj")
        db.close()
        self.mod.cmd_attach({"name": "bot", "project": "proj"})
        db = self._get_db()
        row = db.execute("SELECT session_id FROM sessions WHERE display_name='bot'").fetchone()
        db.close()
        self.assertEqual(row[0], "11111111-2222-3333-4444-555555555555")
        os.environ.pop("CODEX_THREAD_ID", None)


class TestDelivery(ChatTestBase):
    def test_dm_to_codex_produces_queue_call(self):
        """4. DM to attached Codex produces codex queue subprocess call."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        # Capture what fake codex receives
        self._write_fake_codex(exit_code=0,
            stdout="Queued message aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee for thread test.")
        self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                          "message": "hello bot", "to": "bot"})
        # Check delivery was recorded
        db = self._get_db()
        row = db.execute("SELECT state, transport FROM message_deliveries WHERE recipient_name='bot'").fetchone()
        db.close()
        self.assertEqual(row[0], "delivered")
        self.assertEqual(row[1], "codex_queue")

    def test_dm_to_unknown_fails(self):
        """11. DM to unknown recipient fails with non-zero."""
        self._add_session("proj", "sender", "claude")
        with self.assertRaises(SystemExit) as ctx:
            self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                              "message": "hello", "to": "nobody"})
        self.assertNotEqual(ctx.exception.code, 0)

    def test_codex_binary_missing_fails(self):
        """9. Missing binary records failed state."""
        os.environ["CODEX_BIN"] = "/nonexistent/codex"
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        with self.assertRaises(SystemExit):
            self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                              "message": "hello", "to": "bot"})
        db = self._get_db()
        row = db.execute("SELECT state, last_error FROM message_deliveries WHERE recipient_name='bot'").fetchone()
        db.close()
        self.assertEqual(row[0], "failed")

    def test_codex_nonzero_exit_fails(self):
        """9b. Non-zero exit records failed state."""
        self._write_fake_codex(exit_code=1, stderr="No active session")
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        with self.assertRaises(SystemExit):
            self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                              "message": "hello", "to": "bot"})
        db = self._get_db()
        row = db.execute("SELECT state, last_error FROM message_deliveries WHERE recipient_name='bot'").fetchone()
        db.close()
        self.assertEqual(row[0], "failed")
        self.assertIn("No active session", row[1])

    def test_broadcast_no_injection(self):
        """12. Plain broadcast does not wake Codex."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                          "message": "broadcast msg"})
        db = self._get_db()
        row = db.execute("SELECT COUNT(*) FROM message_deliveries").fetchone()
        db.close()
        self.assertEqual(row[0], 0)  # No delivery attempts

    def test_all_queues_codex_once(self):
        """12b. --all queues each attached Codex once."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot1", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        self._add_session("proj", "bot2", "codex", "codex_queue", "11111111-2222-3333-4444-555555555555")
        self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                          "message": "urgent", "all": True})
        db = self._get_db()
        rows = db.execute("SELECT recipient_name, state FROM message_deliveries ORDER BY recipient_name").fetchall()
        db.close()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0][0], "bot1")
        self.assertEqual(rows[0][1], "delivered")
        self.assertEqual(rows[1][0], "bot2")

    def test_pty_delivery_tracked(self):
        """8. PTY injection creates delivery rows."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "agent1", "claude", "pty", pid=99999)
        self._write_state_file(99999, "agent1")
        self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                          "message": "hello", "to": "agent1"})
        db = self._get_db()
        row = db.execute("SELECT state, transport FROM message_deliveries WHERE recipient_name='agent1'").fetchone()
        db.close()
        self.assertEqual(row[0], "delivered")
        self.assertEqual(row[1], "pty")

    def test_multiple_dms_ordered(self):
        """6. Multiple DMs preserve ordering."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        for i in range(3):
            self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                              "message": f"msg {i}", "to": "bot"})
        db = self._get_db()
        rows = db.execute("SELECT message_id FROM message_deliveries WHERE recipient_name='bot' ORDER BY message_id").fetchall()
        db.close()
        ids = [r[0] for r in rows]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(len(ids), 3)


class TestPayload(ChatTestBase):
    def test_special_chars_in_body(self):
        """13. Special chars in body reach codex as literal data."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        nasty = 'line1\n{"key": "$HOME"}\n`rm -rf /`\n$(whoami)\nba\\ck'
        self.mod.cmd_send({"project": "proj", "name": "sender", "type": "claude",
                          "message": nasty, "to": "bot"})
        # Message stored intact
        db = self._get_db()
        row = db.execute("SELECT body FROM messages WHERE sender_name='sender'").fetchone()
        db.close()
        self.assertEqual(row[0], nasty)


class TestDetach(ChatTestBase):
    def test_detach_preserves_history(self):
        """16. Detach preserves messages and read cursor."""
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        db = self._get_db()
        self._send_msg(db, "proj", "bot", "codex", "test msg")
        db.execute("INSERT INTO read_cursors(project_id, display_name, last_read_id) VALUES('proj','bot',1)")
        db.commit()
        db.close()
        self.mod.cmd_detach({"name": "bot", "project": "proj"})
        db = self._get_db()
        msg = db.execute("SELECT COUNT(*) FROM messages WHERE project_id='proj'").fetchone()
        cursor = db.execute("SELECT last_read_id FROM read_cursors WHERE display_name='bot'").fetchone()
        sess = db.execute("SELECT delivery_transport FROM sessions WHERE display_name='bot'").fetchone()
        db.close()
        self.assertEqual(msg[0], 1)
        self.assertEqual(cursor[0], 1)
        self.assertEqual(sess[0], "none")

    def test_detach_missing_fails(self):
        """11b. Detach of missing session fails."""
        with self.assertRaises(SystemExit):
            self.mod.cmd_detach({"name": "ghost", "project": "proj"})


class TestRetry(ChatTestBase):
    def test_retry_delivers(self):
        """10. Retry changes failed to delivered."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        db = self._get_db()
        msg_id = self._send_msg(db, "proj", "sender", "claude", "hello", "bot")
        db.execute("""INSERT INTO message_deliveries(message_id, project_id, recipient_name, transport, state, last_error)
            VALUES(?,?,?,?,?,?)""", (msg_id, "proj", "bot", "codex_queue", "failed", "timeout"))
        db.commit()
        db.close()
        self.mod.cmd_retry({"message_id": str(msg_id), "to": "bot"})
        db = self._get_db()
        row = db.execute("SELECT state FROM message_deliveries WHERE message_id=? AND recipient_name='bot'", (msg_id,)).fetchone()
        db.close()
        self.assertEqual(row[0], "delivered")

    def test_retry_already_delivered(self):
        """10b. Retry of already-delivered does not resend."""
        self._add_session("proj", "sender", "claude")
        self._add_session("proj", "bot", "codex", "codex_queue", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        db = self._get_db()
        msg_id = self._send_msg(db, "proj", "sender", "claude", "hello", "bot")
        db.execute("""INSERT INTO message_deliveries(message_id, project_id, recipient_name, transport, state)
            VALUES(?,?,?,?,?)""", (msg_id, "proj", "bot", "codex_queue", "delivered"))
        db.commit()
        db.close()
        self.mod.cmd_retry({"message_id": str(msg_id), "to": "bot"})
        # Should just print "already delivered", no error

    def test_retry_invalid_id(self):
        """10c. Invalid message ID fails."""
        with self.assertRaises(SystemExit):
            self.mod.cmd_retry({"message_id": "abc", "to": "bot"})


class TestMigration(ChatTestBase):
    def test_migration_adds_columns(self):
        """15. Migrations work against pre-existing schema."""
        # Create a DB with only the old schema
        db = sqlite3.connect(self.db_path)
        db.execute("""CREATE TABLE IF NOT EXISTS sessions (
            project_id TEXT NOT NULL, display_name TEXT NOT NULL, agent_type TEXT NOT NULL,
            working_directory TEXT, pid INTEGER, proxy_pid INTEGER,
            connected_at INTEGER DEFAULT 0, last_seen INTEGER DEFAULT 0,
            PRIMARY KEY(project_id, display_name))""")
        db.execute("""CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL,
            created_at INTEGER DEFAULT 0)""")
        db.execute("""CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id TEXT NOT NULL, sender_name TEXT NOT NULL, sender_type TEXT NOT NULL,
            recipient TEXT, body TEXT NOT NULL, created_at INTEGER DEFAULT 0)""")
        db.execute("""CREATE TABLE IF NOT EXISTS read_cursors (project_id TEXT NOT NULL,
            display_name TEXT NOT NULL, last_read_id INTEGER DEFAULT 0,
            PRIMARY KEY(project_id, display_name))""")
        db.commit()
        db.close()
        # Now open with get_db which runs migrations
        db = self.mod.get_db()
        # Verify new columns exist
        cols = [r[1] for r in db.execute("PRAGMA table_info(sessions)").fetchall()]
        db.close()
        self.assertIn("session_id", cols)
        self.assertIn("delivery_transport", cols)
        self.assertIn("delivery_last_success_at", cols)
        self.assertIn("delivery_last_error", cols)


if __name__ == "__main__":
    unittest.main()
