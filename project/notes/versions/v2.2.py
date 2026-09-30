#!/usr/bin/env python3
"""Заметки v2.2: файловое хранилище, сигналы, /leak и /burn."""
import json
import logging
import signal
import os
import sys
import threading
import time                                  # для busy-цикла в /burn
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = os.environ.get("APP_VERSION", "dev")
HOST = os.environ.get("HOST", "127.0.0.1")
DATA = os.environ.get("NOTES_DATA", "/var/lib/notes/notes.txt")
try:
    PORT = int(os.environ.get("PORT", "8080"))
except ValueError:
    print("ошибка: PORT должен быть числом", file=sys.stderr)
    sys.exit(2)

LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()
logging.basicConfig(
    stream=sys.stderr,
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("notes")

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


LEAK = []                                    # сюда складываем занятую память
LEAK_MAX_MB = int(os.environ.get("LEAK_MAX_MB", "1024"))   # потолок суммарной утечки


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

    def _json(self, code, obj):
        self.json(code, obj)

    def _text(self, code, body):
        self.send(code, body, "text/plain; charset=utf-8")

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        # демонстрационные эндпоинты: в реальном сервисе их бы не было
        if parsed.path == "/leak":
            try:
                mb = int(qs.get("mb", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "limit"})
            if not 1 <= mb <= 256 or sum(len(b) for b in LEAK) // 1048576 + mb > LEAK_MAX_MB:
                return self._json(400, {"error": "limit"})
            LEAK.append(bytearray(mb * 1048576))     # bytearray занимает реальную память
            total = sum(len(b) for b in LEAK) // 1048576
            return self._text(200, "leaked total %d MB\n" % total)
        if parsed.path == "/burn":
            try:
                sec = int(qs.get("sec", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "sec 0-60"})
            if not 0 <= sec <= 60:
                return self._json(400, {"error": "sec 0-60"})
            end = time.monotonic() + sec
            while time.monotonic() < end:            # активное ожидание грузит одно ядро
                pass
            return self._text(200, "burned %d\n" % sec)
        path = parsed.path
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

    def do_PUT(self):
        # Контракт тестов урока 1.6: неподдерживаемый метод даёт 405.
        self.json(405, {"error": "method not allowed"})

    do_DELETE = do_PATCH = do_OPTIONS = do_PUT

    def log_message(self, fmt, *args):
        if self.path not in ("/healthz", "/readyz"):
            print(f"{self.address_string()} {fmt % args}", file=sys.stderr)


STOP_TIMEOUT = 10  # секунд на дорабатывание открытых запросов


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = False  # server_close() ждёт обработчики запросов
    stopping = threading.Event()

    def on_signal(signum, frame):
        # второй сигнал во время остановки: выходим немедленно, код 1
        if stopping.is_set():
            os._exit(1)
        stopping.set()
        logging.info("shutting down")
        # shutdown() ждёт выхода из serve_forever(), поэтому вызываем его
        # из отдельного потока, а не из обработчика сигнала
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    logging.info("started host=%s port=%s", HOST, PORT)
    server.serve_forever()

    # сюда попадаем после shutdown(): ждём открытые запросы не дольше STOP_TIMEOUT
    watchdog = threading.Timer(STOP_TIMEOUT, lambda: os._exit(1))
    watchdog.daemon = True
    watchdog.start()
    server.server_close()  # дожидается потоков обработчиков
    watchdog.cancel()
    logging.info("stopped")
    sys.exit(0)


if __name__ == "__main__":
    main()
