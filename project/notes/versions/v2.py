#!/usr/bin/env python3
"""Заметки v2: файловое хранилище и /healthz."""
import json
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

VERSION = os.environ.get("APP_VERSION", "dev")
HOST = os.environ.get("HOST", "127.0.0.1")
DATA = os.environ.get("NOTES_DATA", "/var/lib/notes/notes.txt")
try:
    PORT = int(os.environ.get("PORT", "8080"))
except ValueError:
    print("ошибка: PORT должен быть числом", file=sys.stderr)
    sys.exit(2)

LOCK = threading.Lock()  # записи в файл идут по одной


def read_notes():
    """Одна заметка на строку, формат JSON. Нет файла: заметок нет."""
    try:
        with open(DATA, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def add_note(text):
    with LOCK:
        note = {
            "id": len(read_notes()) + 1,
            "text": text,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        with open(DATA, "a", encoding="utf-8") as f:
            f.write(json.dumps(note, ensure_ascii=False) + "\n")
        return note["id"]


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def json(self, code, obj):
        self.send(code, json.dumps(obj, ensure_ascii=False))

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self.send(200, f"Notes service v{VERSION}\n", "text/plain; charset=utf-8")
        elif path == "/healthz":
            self.send(200, "ok", "text/plain; charset=utf-8")
        elif path == "/readyz":
            ok = os.access(os.path.dirname(DATA), os.W_OK)
            self.send(200 if ok else 503, "ready" if ok else "not ready",
                      "text/plain; charset=utf-8")
        elif path == "/notes":
            try:
                self.json(200, read_notes())
            except OSError as e:
                print(f"ошибка хранилища: {e}", file=sys.stderr)
                self.json(500, {"error": "storage"})
        else:
            self.json(404, {"error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path != "/notes":
            self.json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            text = json.loads(self.rfile.read(length))["text"]
        except (ValueError, KeyError, TypeError):
            self.json(400, {"error": "нужен JSON {\"text\": \"...\"}"})
            return
        if not isinstance(text, str) or not text.strip() or len(text) > 1000:
            self.json(400, {"error": "text: от 1 до 1000 символов"})
            return
        try:
            self.json(201, {"id": add_note(text)})
        except OSError as e:
            print(f"ошибка хранилища: {e}", file=sys.stderr)
            self.json(500, {"error": "storage"})

    def log_message(self, fmt, *args):
        if self.path not in ("/healthz", "/readyz"):
            print(f"{self.address_string()} {fmt % args}", file=sys.stderr)


if __name__ == "__main__":
    print(f"Notes v{VERSION} слушает {HOST}:{PORT}, данные {DATA}", file=sys.stderr)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
