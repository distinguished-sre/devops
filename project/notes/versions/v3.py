#!/usr/bin/env python3
"""Заметки v3: HTTP/1.1, диагностика HTTP и файловое хранилище."""
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
    # HTTP/1.1: соединение остаётся открытым, поэтому Content-Length обязателен
    protocol_version = "HTTP/1.1"

    def _send(self, status, body, ctype="application/json; charset=utf-8", extra=None):
        """Единственное место, где пишется ответ: всегда с Content-Length."""
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _json(self, status, obj, extra=None):
        self._send(status, json.dumps(obj, ensure_ascii=False), extra=extra)

    def _text(self, status, body):
        self._send(status, body, "text/plain; charset=utf-8")

    def _handle(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        routes = {"/", "/notes", "/healthz", "/readyz", "/headers", "/slow",
                  "/error", "/leak", "/burn"}
        if path not in routes:
            self.close_connection = True  # тело неизвестного запроса не читаем
            return self._json(404, {"error": "not found"})
        allowed = "GET, POST" if path == "/notes" else "GET"
        if self.command not in allowed.split(", ") and self.command != "HEAD":
            self.close_connection = True  # непрочитанное тело не станет следующим запросом
            return self._json(405, {"error": "method not allowed"}, {"Allow": allowed})
        if self.command == "POST":
            return self._create_note()
        if path == "/":
            return self._text(200, f"Notes service v{VERSION}\n")
        if path == "/healthz":
            return self._text(200, "ok")
        if path == "/readyz":
            ok = os.access(os.path.dirname(DATA), os.W_OK)
            return self._text(200 if ok else 503, "ready" if ok else "not ready")
        if path == "/notes":
            try:
                return self._json(200, read_notes())
            except (OSError, ValueError) as e:
                log.error("ошибка хранилища: %s", e)
                return self._json(500, {"error": "storage"})
        if path == "/headers":
            # демонстрационный эндпоинт: приложение показывает, что оно получило
            self._send(200, json.dumps(dict(self.headers.items()), ensure_ascii=False))
            return
        if path == "/slow":
            try:
                sec = int(parse_qs(parsed.query).get("sec", ["0"])[0])
            except ValueError:
                sec = -1
            if not 0 <= sec <= 120:
                self._send(400, '{"error":"sec must be 0..120"}')
                return
            time.sleep(sec)
            self._send(200, "slept %d" % sec, "text/plain; charset=utf-8")
            return
        if path == "/error":
            # всегда 500: для тренировки алертов и разбора логов
            self._send(500, '{"error":"synthetic"}')
            return
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

    def _create_note(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0:
                raise ValueError
            text = json.loads(self.rfile.read(length))["text"]
        except (ValueError, KeyError, TypeError):
            self.close_connection = True
            return self._json(400, {"error": "нужен JSON {\"text\": \"...\"}"})
        if not isinstance(text, str) or not text.strip() or len(text) > 1000:
            return self._json(400, {"error": "text: от 1 до 1000 символов"})
        try:
            self._json(201, {"id": add_note(text)})
        except (OSError, ValueError) as e:
            log.error("ошибка хранилища: %s", e)
            self._json(500, {"error": "storage"})

    def do_GET(self):
        self._handle()

    do_POST = do_HEAD = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_GET

    def __getattr__(self, name):
        # BaseHTTPRequestHandler ищет do_<метод>; неизвестные методы тоже дают 405.
        if name.startswith("do_"):
            return self._handle
        raise AttributeError(name)

    def log_message(self, fmt, *args):
        if urlparse(self.path).path not in ("/healthz", "/readyz"):
            log.info("%s %s", self.address_string(), fmt % args)


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
