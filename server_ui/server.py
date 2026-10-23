"""Local WhatsReply dashboard and history server.

Run on the same Windows PC as Ollama:
    python server.py

The server listens on all interfaces so the Android app can reach it over
Tailscale. It stores history in whatsapp_history.sqlite3 beside this file.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HOST = "0.0.0.0"
PORT = 8765
ROOT = Path(__file__).resolve().parent
DATABASE = ROOT / "whatsapp_history.sqlite3"


def connection() -> sqlite3.Connection:
    db = sqlite3.connect(DATABASE)
    db.row_factory = sqlite3.Row
    return db


def init_database() -> None:
    with connection() as db:
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sender TEXT NOT NULL,
                incoming TEXT NOT NULL,
                reply TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id TEXT PRIMARY KEY,
                device_name TEXT NOT NULL,
                last_seen TEXT NOT NULL
            )
            """
        )
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS chat_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_message TEXT NOT NULL,
                ai_reply TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                device_name TEXT NOT NULL DEFAULT 'WhatsReply Android'
            )
            """
        )
        db.commit()


class Handler(BaseHTTPRequestHandler):
    server_version = "WhatsReplyServer/1.0"

    def log_message(self, format: str, *args: object) -> None:
        print(f"[{self.log_date_time_string()}] {format % args}")

    def send_json(self, payload: object, status: int = HTTPStatus.OK) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/health":
            self.send_json({"ok": True, "service": "WhatsReply history server"})
            return
        if path == "/api/logs":
            with connection() as db:
                rows = db.execute(
                    "SELECT id, sender, incoming, reply, timestamp FROM messages ORDER BY id DESC LIMIT 200"
                ).fetchall()
            self.send_json([dict(row) for row in rows])
            return
        if path == "/api/devices":
            with connection() as db:
                rows = db.execute(
                    "SELECT device_id, device_name, last_seen FROM devices ORDER BY last_seen DESC"
                ).fetchall()
            self.send_json([dict(row) for row in rows])
            return
        if path == "/api/chat":
            with connection() as db:
                rows = db.execute(
                    "SELECT id, user_message, ai_reply, timestamp, device_name "
                    "FROM chat_messages ORDER BY id DESC LIMIT 200"
                ).fetchall()
            self.send_json([dict(row) for row in rows])
            return
        if path in ("/", "/index.html"):
            data = (ROOT / "index.html").read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path not in ("/api/logs", "/api/chat", "/api/heartbeat"):
            self.send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            if path == "/api/heartbeat":
                device_id = str(body.get("device_id", "")).strip()
                device_name = str(body.get("device_name", "Android phone")).strip()
                if not device_id:
                    raise ValueError("device_id is required")
                with connection() as db:
                    db.execute(
                        "INSERT INTO devices(device_id, device_name, last_seen) VALUES (?, ?, ?) "
                        "ON CONFLICT(device_id) DO UPDATE SET device_name=excluded.device_name, last_seen=excluded.last_seen",
                        (device_id, device_name, datetime.now(timezone.utc).isoformat()),
                    )
                    db.commit()
                self.send_json({"ok": True, "device_id": device_id}, HTTPStatus.OK)
                return

            if path == "/api/chat":
                user_message = str(body.get("user_message", "")).strip()
                ai_reply = str(body.get("ai_reply", "")).strip()
                timestamp = str(body.get("timestamp", "")).strip() or datetime.now(timezone.utc).isoformat()
                device_name = str(body.get("device_name", "WhatsReply Android")).strip()
                if not user_message or not ai_reply:
                    raise ValueError("user_message and ai_reply are required")
                with connection() as db:
                    cursor = db.execute(
                        "INSERT INTO chat_messages(user_message, ai_reply, timestamp, device_name) VALUES (?, ?, ?, ?)",
                        (user_message, ai_reply, timestamp, device_name),
                    )
                    db.commit()
                self.send_json({"ok": True, "id": cursor.lastrowid}, HTTPStatus.CREATED)
                return

            sender = str(body.get("sender", "")).strip()
            incoming = str(body.get("incoming", "")).strip()
            reply = str(body.get("reply", "")).strip()
            timestamp = str(body.get("timestamp", "")).strip() or datetime.now(timezone.utc).isoformat()
            if not sender or not incoming or not reply:
                raise ValueError("sender, incoming and reply are required")
            with connection() as db:
                cursor = db.execute(
                    "INSERT INTO messages(sender, incoming, reply, timestamp) VALUES (?, ?, ?, ?)",
                    (sender, incoming, reply, timestamp),
                )
                db.commit()
            self.send_json({"ok": True, "id": cursor.lastrowid}, HTTPStatus.CREATED)
        except (ValueError, json.JSONDecodeError) as error:
            self.send_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if path not in ("/api/logs", "/api/chat"):
            self.send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return
        with connection() as db:
            db.execute("DELETE FROM messages" if path == "/api/logs" else "DELETE FROM chat_messages")
            db.commit()
        self.send_json({"ok": True})


if __name__ == "__main__":
    init_database()
    print(f"WhatsReply Server UI running at http://127.0.0.1:{PORT}")
    print(f"Tailscale dashboard: http://<TAILSCALE_IP>:{PORT}")
    print("Press Ctrl+C to stop.")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
