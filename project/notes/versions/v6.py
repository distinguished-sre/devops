#!/usr/bin/env python3
"""Заметки v6: JSON-логи в stdout, метрики и хранилище file/postgres."""
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

from prometheus_client import (CONTENT_TYPE_LATEST, Counter, Gauge,
                               Histogram, generate_latest)

VERSION = os.environ.get("APP_VERSION", "dev")
HOST = os.environ.get("HOST", "127.0.0.1")
DATA = os.environ.get("NOTES_DATA", "/var/lib/notes/notes.txt")
try:
    PORT = int(os.environ.get("PORT", "8080"))
except ValueError:
    print("ошибка: PORT должен быть числом", file=sys.stderr)
    sys.exit(2)

class JsonFormatter(logging.Formatter):
    """Одна запись лога это одна строка JSON. Ключи не меняем между версиями."""

    def format(self, record):
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "msg": record.getMessage(),
        }
        # дополнительные поля приходят через extra={"fields": {...}}
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry, ensure_ascii=False, separators=(",", ":"))


handler = logging.StreamHandler(sys.stdout)  # в stdout, не в stderr
handler.setFormatter(JsonFormatter())
log = logging.getLogger("notes")
log.addHandler(handler)
log.setLevel(os.environ.get("LOG_LEVEL", "info").upper())
log.propagate = False

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


# v4.1: демонстрационные сбои для тренировки проб
def _int_env(name, default):
    raw = os.environ.get(name, str(default))
    try:
        return int(raw)
    except ValueError:
        print(f"{name} must be an integer, got {raw!r}", file=sys.stderr)
        sys.exit(2)

STARTUP_DELAY = _int_env("STARTUP_DELAY", 0)
READY_FAIL = _int_env("READY_FAIL", 0)
STARTED_AT = 0.0


LEAK = []                                    # сюда складываем занятую память
LEAK_MAX_MB = int(os.environ.get("LEAK_MAX_MB", "1024"))   # потолок суммарной утечки


STORE = os.environ.get("STORE", "file")
DATABASE_URL = os.environ.get("DATABASE_URL", "")

# Драйвер PostgreSQL нужен только при STORE=postgres.
if STORE == "postgres":
    try:
        import psycopg
    except ImportError:
        print("STORE=postgres требует psycopg[binary]>=3.2,<4", file=sys.stderr)
        sys.exit(2)
elif STORE != "file":
    print("STORE должен быть file или postgres", file=sys.stderr)
    sys.exit(2)

STORAGE_ERRORS = (OSError, ValueError) + ((psycopg.Error,) if STORE == "postgres" else ())

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS notes (
    id         serial PRIMARY KEY,
    text       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
)
"""


def pg_connect():
    # Соединение на каждый запрос: просто, но без пула и с лишней задержкой.
    # Компромисс осознанный, пул появится, когда нагрузка это оправдает.
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def pg_init():
    with pg_connect() as conn:
        conn.execute(SCHEMA_SQL)


def pg_list():
    with pg_connect() as conn:
        rows = conn.execute(
            "SELECT id, text, created_at FROM notes ORDER BY id"
        ).fetchall()
    return [
        {"id": r[0], "text": r[1], "created_at": r[2].isoformat()} for r in rows
    ]


def pg_add(text):
    with pg_connect() as conn:
        # параметры передаются отдельно от SQL: защита от SQL-инъекций
        return conn.execute(
            "INSERT INTO notes (text) VALUES (%s) RETURNING id", (text,)
        ).fetchone()[0]


def pg_ready():
    try:
        with pg_connect() as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error:
        return False


def pg_sleep(sec):
    with pg_connect() as conn:
        conn.execute("SELECT pg_sleep(%s)", (sec,))

PG_INITIALIZED = False
PG_INIT_LOCK = threading.Lock()


def ensure_pg_schema():
    # Если база была недоступна при старте, повторяем создание схемы при запросе.
    global PG_INITIALIZED
    with PG_INIT_LOCK:
        if not PG_INITIALIZED:
            pg_init()
            PG_INITIALIZED = True


def list_notes():
    if STORE == "postgres":
        ensure_pg_schema()
        return pg_list()
    return read_notes()


def save_note(text):
    if STORE == "postgres":
        ensure_pg_schema()
        return pg_add(text)
    return add_note(text)


def storage_ready():
    if STORE == "postgres":
        try:
            ensure_pg_schema()
            return pg_ready()
        except psycopg.Error:
            return False
    return os.access(os.path.dirname(DATA), os.W_OK)


def initialize_storage():
    if STORE == "postgres":
        try:
            ensure_pg_schema()
        except psycopg.Error as e:
            log.warning("база пока недоступна: %s", e)


# Метрики из урока 8.2: реестр prometheus_client и текстовый /metrics.
KNOWN_ROUTES = {"/", "/notes", "/healthz", "/readyz", "/headers", "/slow",
                "/error", "/leak", "/burn", "/slowsql", "/metrics"}
HTTP_REQUESTS = Counter(
    "notes_http_requests_total", "Число HTTP-запросов",
    ["method", "path", "status"])
HTTP_DURATION = Histogram(
    "notes_http_request_duration_seconds", "Длительность запроса, секунды",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))
NOTES_TOTAL = Gauge("notes_notes_total", "Сколько заметок сохранено")
BUILD_INFO = Gauge("notes_build_info", "Версия сборки", ["version"])
NOTES_TOTAL_LOCK = threading.Lock()


def route_label(path):
    # сырой URL в метку не попадает никогда: только известные маршруты
    return path if path in KNOWN_ROUTES else "other"


def update_notes_total():
    # Чтение и обновление идут по очереди: старый результат не затрёт новый.
    with NOTES_TOTAL_LOCK:
        NOTES_TOTAL.set(len(list_notes()))


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1: соединение остаётся открытым, поэтому Content-Length обязателен
    protocol_version = "HTTP/1.1"

    def _send(self, status, body, ctype="application/json; charset=utf-8", extra=None):
        """Единственное место, где пишется ответ: всегда с Content-Length."""
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self._status = status
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
        started = time.monotonic()
        self._status = None
        try:
            self._dispatch()
        finally:
            if self._status is not None:
                self._access_log(self._status, started)

    def _dispatch(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        routes = {"/", "/notes", "/healthz", "/readyz", "/headers", "/slow",
                  "/error", "/leak", "/burn", "/slowsql", "/metrics"}
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
            if READY_FAIL == -1 or (READY_FAIL > 0 and time.monotonic() - STARTED_AT < READY_FAIL):
                return self._text(503, "not ready")
            ok = storage_ready()
            return self._text(200 if ok else 503, "ready" if ok else "not ready")
        if path == "/notes":
            try:
                return self._json(200, list_notes())
            except STORAGE_ERRORS as e:
                log.error("ошибка хранилища: %s", e)
                return self._json(500, {"error": "storage"})
        if path == "/metrics":
            return self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
        if path == "/slowsql":
            if STORE == "file":
                return self._json(501, {"error": "postgres only"})
            try:
                sec = int(qs.get("sec", ["0"])[0])
            except ValueError:
                sec = -1
            if not 0 <= sec <= 30:
                return self._json(400, {"error": "sec must be 0..30"})
            try:
                pg_sleep(sec)
            except psycopg.Error as e:
                log.error("ошибка хранилища: %s", e)
                return self._json(500, {"error": "storage"})
            return self._text(200, "slept %d" % sec)
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
            note_id = save_note(text)
            update_notes_total()
            self._json(201, {"id": note_id})
        except STORAGE_ERRORS as e:
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

    def parse_request(self):
        self._t0 = time.monotonic()
        return super().parse_request()

    def log_request(self, code="-", size="-"):
        path = route_label(urlparse(self.path).path)
        HTTP_REQUESTS.labels(self.command, path, str(code)).inc()
        HTTP_DURATION.labels(self.command, path).observe(
            time.monotonic() - self._t0)
        super().log_request(code, size)

    def log_message(self, fmt, *args):
        pass  # одна JSON-запись после ответа, стандартный access-лог отключён

    def _access_log(self, status, started):
        if urlparse(self.path).path in ("/healthz", "/readyz", "/metrics"):
            return  # служебные пути не шумят в логе
        log.info("request", extra={"fields": {
            "method": self.command,
            "path": self.path,
            "status": status,
            "dur_ms": round((time.monotonic() - started) * 1000),
            "version": VERSION,
        }})


STOP_TIMEOUT = 10  # секунд на дорабатывание открытых запросов


def main():
    global STARTED_AT
    if STARTUP_DELAY > 0:
        time.sleep(STARTUP_DELAY)  # порт ещё не слушается
    initialize_storage()
    BUILD_INFO.labels(VERSION).set(1)
    try:
        update_notes_total()
    except STORAGE_ERRORS as e:
        log.warning("не удалось прочитать число заметок: %s", e)
    STARTED_AT = time.monotonic()  # READY_FAIL отсчитывается от начала обслуживания
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = False  # server_close() ждёт обработчики запросов
    stopping = threading.Event()

    def on_signal(signum, frame):
        # второй сигнал во время остановки: выходим немедленно, код 1
        if stopping.is_set():
            os._exit(1)
        stopping.set()
        log.info("shutting down")
        # shutdown() ждёт выхода из serve_forever(), поэтому вызываем его
        # из отдельного потока, а не из обработчика сигнала
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    log.info("started", extra={"fields": {
        "host": HOST, "port": PORT, "store": STORE, "version": VERSION,
    }})
    server.serve_forever()

    # сюда попадаем после shutdown(): ждём открытые запросы не дольше STOP_TIMEOUT
    watchdog = threading.Timer(STOP_TIMEOUT, lambda: os._exit(1))
    watchdog.daemon = True
    watchdog.start()
    server.server_close()  # дожидается потоков обработчиков
    watchdog.cancel()
    log.info("stopped")
    sys.exit(0)


if __name__ == "__main__":
    main()
