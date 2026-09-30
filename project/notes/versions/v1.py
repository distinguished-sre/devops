#!/usr/bin/env python3
"""Заметки v1: маленький HTTP-сервис на стандартной библиотеке."""
import json
import logging
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# Настройки берём из переменных окружения, значения по умолчанию безопасные
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
APP_VERSION = os.environ.get("APP_VERSION", "dev")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    stream=sys.stderr,
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("notes")

# Хранилище v1: список в памяти процесса, после перезапуска пусто
NOTES = []
LOCK = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.status = status

    def _json(self, status, obj):
        self._send(status, json.dumps(obj, ensure_ascii=False))

    def _handle(self, method):
        start = time.monotonic()
        path = urlparse(self.path).path
        if path == "/" and method == "GET":
            self._send(200, "Notes service v%s\n" % APP_VERSION,
                       "text/plain; charset=utf-8")
        elif path == "/notes" and method == "GET":
            with LOCK:
                self._json(200, list(NOTES))
        elif path == "/notes" and method == "POST":
            self._create_note()
        else:
            self._json(404, {"error": "not found"})
        dur = int((time.monotonic() - start) * 1000)
        log.info("method=%s path=%s status=%s dur_ms=%d",
                 method, path, self.status, dur)

    def _create_note(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            text = json.loads(raw)["text"]
        except (ValueError, KeyError, TypeError):
            return self._json(400, {"error": "need JSON {\"text\": \"...\"}"})
        if not isinstance(text, str) or not 1 <= len(text) <= 1000:
            return self._json(400, {"error": "text must be 1..1000 chars"})
        with LOCK:
            note = {
                "id": len(NOTES) + 1,
                "text": text,
                "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            }
            NOTES.append(note)
        self._json(201, {"id": note["id"]})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def log_message(self, *args):
        pass  # штатный лог отключаем, пишем свой

if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log.info("started host=%s port=%s version=%s", HOST, PORT, APP_VERSION)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")
