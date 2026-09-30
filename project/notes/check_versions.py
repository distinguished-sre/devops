#!/usr/bin/env python3
"""Проверка эталонов: Python 3.12+, curl, свободные порты и отдельные данные."""
import json
from importlib import import_module
import os
import py_compile
import queue
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VERSIONS = ("v1", "v2", "v2.1", "v2.2", "v3", "v4", "v4.1", "v5", "v6", "v7", "v7.1")
DEPENDENCIES = (
    (7, "prometheus_client", "prometheus_client==0.26.0"),
    (9, "opentelemetry.trace", "opentelemetry-api==1.45.0"),
    (9, "opentelemetry.sdk.trace", "opentelemetry-sdk==1.45.0"),
    (9, "opentelemetry.exporter.otlp.proto.http.trace_exporter",
     "opentelemetry-exporter-otlp-proto-http==1.45.0"),
)


def available_versions():
    missing = []
    for rank, module, package in DEPENDENCIES:
        try:
            import_module(module)
        except ImportError as error:
            missing.append((rank, package, str(error)))
    available = []
    for rank, version in enumerate(VERSIONS):
        required = [(package, error) for minimum, package, error in missing if rank >= minimum]
        if required:
            command = shlex.join([sys.executable, "-m", "pip", "install"] +
                                 [package for package, _ in required])
            print(f"{version}: пропуск, не установлены зависимости: " +
                  "; ".join(error for _, error in required) + f". Установи в venv: {command}",
                  flush=True)
        else:
            available.append(version)
    return available


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Service:
    def __init__(self, version, work, **settings):
        self.version = version
        self.port = free_port()
        self.env = dict(os.environ)
        self.env.update(
            HOST="127.0.0.1", PORT=str(self.port), APP_VERSION="test",
            NOTES_DATA=str(work / (version + ".notes")), LOG_LEVEL="info",
            STORE="file", STARTUP_DELAY="0", READY_FAIL="0", FAIL_RATE="0",
            LEAK_MAX_MB="10", OTEL_EXPORTER_OTLP_ENDPOINT="", OTEL_SERVICE_NAME="notes-test",
        )
        self.env.update(settings)
        self.out = open(work / (version + ".stdout"), "w+")
        self.err = open(work / (version + ".stderr"), "w+")
        self.proc = subprocess.Popen(
            [sys.executable, "-u", str(ROOT / "versions" / (version + ".py"))],
            env=self.env, stdout=self.out, stderr=self.err,
        )

    def call(self, path, method="GET", body=None, headers=()):
        args = ["curl", "--silent", "--show-error", "--noproxy", "*",
                "--max-time", "8", "--include", "--write-out", "\n%{http_code}"]
        args += ["--head"] if method == "HEAD" else ["-X", method]
        for header in headers:
            args += ["-H", header]
        if body is not None:
            args += ["-H", "Expect:", "--data-binary", body]
        args.append(f"http://127.0.0.1:{self.port}{path}")
        result = subprocess.run(args, capture_output=True)
        if result.returncode:
            raise OSError(result.stderr.decode().strip())
        response, code = result.stdout.rsplit(b"\n", 1)
        raw_headers, _, raw_body = response.partition(b"\r\n\r\n")
        lines = raw_headers.decode().split("\r\n")
        fields = dict(line.split(": ", 1) for line in lines[1:] if ": " in line)
        if method != "HEAD":
            assert int(fields["Content-Length"]) == len(raw_body), (path, fields)
        return int(code), raw_body.decode(), fields, lines[0]

    def expect(self, path, code, method="GET", body=None, text=None, headers=()):
        response = self.call(path, method, body, headers)
        assert response[0] == code, (self.version, method, path, response)
        if text is not None:
            assert response[1] == text, (self.version, path, response[1])
        return response

    def ready(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise AssertionError((self.version, self.proc.returncode, self.logs()))
            try:
                self.expect("/", 200, text="Notes service vtest\n")
                return
            except OSError:
                time.sleep(0.05)
        raise AssertionError("сервис не начал отвечать: " + self.version)

    def stop(self, sig=signal.SIGTERM):
        self.proc.send_signal(sig)
        return self.proc.wait(timeout=15)

    def logs(self):
        self.out.seek(0)
        self.err.seek(0)
        return self.out.read(), self.err.read()

    def close(self):
        if self.proc.poll() is None:
            try:
                self.stop(signal.SIGINT if self.version == "v1" else signal.SIGTERM)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.out.close()
        self.err.close()


@contextmanager
def running(version, work, **settings):
    service = Service(version, work, **settings)
    try:
        service.ready()
        yield service
    finally:
        service.close()


def check_version(version, work):
    rank = VERSIONS.index(version)
    with running(version, work) as app:
        app.expect("/nope", 404)
        app.expect("/healthz", 404 if rank == 0 else 200)
        app.expect("/readyz", 404 if rank == 0 else 200)
        assert json.loads(app.expect("/notes", 200)[1]) == []
        app.expect("/notes", 400, "POST", "")
        app.expect("/notes", 400, "POST", '{"text": 12}')
        app.expect("/notes", 400, "POST", json.dumps({"text": "x" * 1001}))
        for i in (1, 2):
            result = app.expect("/notes", 201, "POST", json.dumps({"text": f"заметка {i}"}))
            assert json.loads(result[1]) == {"id": i}
        notes = json.loads(app.expect("/notes", 200)[1])
        assert [note["text"] for note in notes] == ["заметка 1", "заметка 2"]
        assert all("created_at" in note for note in notes)
        app.expect("/notes", 501 if rank < 3 else 405, "PUT", "{}")
        if rank >= 3:
            app.expect("/leak?mb=10", 200, text="leaked total 10 MB\n")
            for suffix in ("0", "1", "999", "oops"):
                app.expect("/leak?mb=" + suffix, 400)
            app.expect("/burn?sec=0", 200, text="burned 0\n")
            started = time.monotonic()
            app.expect("/burn?sec=1", 200, text="burned 1\n")
            assert time.monotonic() - started >= 0.9
            for suffix in ("-1", "61", "oops"):
                app.expect("/burn?sec=" + suffix, 400)
        if rank >= 4:
            result = app.expect("/healthz", 200)
            assert result[3].startswith("HTTP/1.1")
            app.expect("/notes", 405, "DELETE")
            app.expect("/notes", 405, "TRACE")
            app.expect("/notes", 405, "UNKNOWN")
            app.expect("/nope", 404, "UNKNOWN")
            assert app.expect("/notes", 405, "PUT", "{}")[2]["Allow"] == "GET, POST"
            app.expect("/healthz", 200, "HEAD", text="")
            echoed = app.expect("/headers", 200, headers=("X-Lesson: hello",))
            assert json.loads(echoed[1])["X-Lesson"] == "hello"
            app.expect("/error", 500, text='{"error":"synthetic"}')
            app.expect("/slow?sec=0", 200, text="slept 0")
            started = time.monotonic()
            app.expect("/slow?sec=1", 200, text="slept 1")
            assert time.monotonic() - started >= 0.9
            for suffix in ("-1", "999", "oops"):
                app.expect("/slow?sec=" + suffix, 400)
        if rank >= 5:
            response = app.expect("/slowsql?sec=2", 501)
            assert json.loads(response[1]) == {"error": "postgres only"}
        if rank >= 7:
            from prometheus_client import CONTENT_TYPE_LATEST
            from prometheus_client.parser import text_string_to_metric_families

            app.expect("/other-1", 404)
            app.expect("/other-2", 404)
            metrics = app.expect("/metrics", 200)
            assert metrics[2]["Content-Type"].startswith("text/plain;")
            assert metrics[2]["Content-Type"] == CONTENT_TYPE_LATEST
            families = {family.name: family for family in text_string_to_metric_families(metrics[1])}
            for name, kind in (("notes_http_requests", "counter"),
                               ("notes_http_request_duration_seconds", "histogram"),
                               ("notes_notes_total", "gauge"), ("notes_build_info", "gauge")):
                assert families[name].type == kind, (version, name, families[name])
            samples = [sample for family in families.values() for sample in family.samples]

            def value(name, **labels):
                return next(sample.value for sample in samples
                            if sample.name == name and sample.labels == labels)

            assert value("notes_build_info", version="test") == 1
            assert value("notes_notes_total") == 2
            assert value("notes_http_requests_total", method="POST", path="/notes", status="201") == 2
            assert value("notes_http_requests_total", method="GET", path="other", status="404") == 3
            buckets = [sample for sample in samples
                       if sample.name == "notes_http_request_duration_seconds_bucket" and
                       sample.labels["method"] == "GET" and sample.labels["path"] == "/notes"]
            assert {sample.labels["le"] for sample in buckets} == {
                "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1.0",
                "2.5", "5.0", "10.0", "+Inf"}
            counts = [sample.value for sample in sorted(buckets, key=lambda s: float(s.labels["le"]))]
            assert counts == sorted(counts) and counts[-1] == 2
            assert value("notes_http_request_duration_seconds_count", method="GET", path="/notes") == 2
            assert value("notes_http_request_duration_seconds_sum", method="GET", path="/slow") >= 0.9
            assert '/other-1' not in metrics[1]
        exit_code = app.stop(signal.SIGINT if rank == 0 else signal.SIGTERM)
        assert exit_code == (-signal.SIGTERM if rank == 1 else 0), (version, exit_code)
        stdout, stderr = app.logs()
        if rank >= 8:
            entries = [json.loads(line) for line in stdout.splitlines()]
            assert any(entry["msg"] == "started" for entry in entries)
            requests = [entry for entry in entries if entry["msg"] == "request"]
            assert requests and all(isinstance(e["status"], int) and isinstance(e["dur_ms"], int)
                                    for e in requests)
            assert all(e["path"] not in ("/healthz", "/readyz", "/metrics") for e in requests)
            assert "shutting down" in stdout and "stopped" in stdout
            assert not stderr, stderr
            if rank >= 9:
                assert all("trace_id" not in entry for entry in entries), entries
        elif rank >= 2:
            assert "shutting down" in stderr and "stopped" in stderr
    with running(version, work) as app:
        notes = json.loads(app.expect("/notes", 200)[1])
        assert len(notes) == (0 if rank == 0 else 2), (version, notes)
    print(f"{version}: curl, контракт эндпоинтов, перезапуск и сигналы — OK", flush=True)


def check_probes(work, versions):
    for version in versions:
        if version not in VERSIONS[6:]:
            continue
        with running(version, work, READY_FAIL="-1") as app:
            app.expect("/healthz", 200)
            app.expect("/readyz", 503, text="not ready")
        app = Service(version, work, STARTUP_DELAY="1", READY_FAIL="1")
        try:
            time.sleep(0.3)
            try:
                app.call("/healthz")
            except OSError:
                pass  # до истечения STARTUP_DELAY порт закрыт
            else:
                raise AssertionError("STARTUP_DELAY не задержал открытие порта")
            app.ready()
            # ready() ждёт открытия порта; окно READY_FAIL должно оставаться после паузы.
            app.expect("/readyz", 503)
            time.sleep(1.05)
            app.expect("/readyz", 200, text="ready")
        finally:
            app.close()
        for variable in ("STARTUP_DELAY", "READY_FAIL"):
            app = Service(version, work, **{variable: "oops"})
            try:
                assert app.proc.wait(timeout=5) == 2
            finally:
                app.close()
    print("Доступные v4.1+: STARTUP_DELAY, READY_FAIL и код 2 — OK", flush=True)


def check_graceful_shutdown(work, versions):
    for version in versions:
        if version not in VERSIONS[4:]:
            continue
        with running(version, work) as app:
            # Запрос уже принят: обработчик читает POST и ждёт продолжения тела.
            with socket.create_connection(("127.0.0.1", app.port)) as sock:
                payload = b'{"text":"shutdown"}'
                sock.sendall(f"POST /notes HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode())
                time.sleep(0.1)
                app.proc.send_signal(signal.SIGTERM)
                time.sleep(0.7)
                assert app.proc.poll() is None, "сервис бросил незаконченный запрос"
                sock.sendall(payload)
                response = b""
                while chunk := sock.recv(65536):
                    response += chunk
                assert b"201 Created" in response, response
            assert app.proc.wait(timeout=5) == 0
    print("Доступные v3+: SIGTERM ждёт открытый запрос — OK", flush=True)


def check_failure_injection(work):
    with running("v7.1", work, FAIL_RATE="1") as app:
        for method in ("GET", "POST"):
            response = app.expect("/notes", 500, method, '{"text":"fail"}' if method == "POST" else None)
            assert json.loads(response[1]) == {"error": "injected failure"}
        for path in ("/healthz", "/readyz", "/metrics"):
            app.expect(path, 200)
        assert app.env["NOTES_DATA"] and "fail" not in Path(app.env["NOTES_DATA"]).read_text()
    for value in ("oops", "-1", "1.1", "nan", "inf"):
        app = Service("v7.1", work, FAIL_RATE=value)
        try:
            assert app.proc.wait(timeout=5) == 2
        finally:
            app.close()
    print("v7.1: FAIL_RATE=0/1, изоляция проб и неверные значения — OK", flush=True)


def check_tracing(work, versions):
    from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import (
        ExportTraceServiceRequest, ExportTraceServiceResponse)

    received = queue.Queue()

    class Receiver(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/v1/traces"
            assert self.headers["Content-Type"] == "application/x-protobuf"
            message = ExportTraceServiceRequest()
            message.ParseFromString(self.rfile.read(int(self.headers["Content-Length"])))
            received.put(message)
            body = ExportTraceServiceResponse().SerializeToString()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-protobuf")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        endpoint = f"http://127.0.0.1:{server.server_port}"
        for version in versions:
            with running(version, work, OTEL_EXPORTER_OTLP_ENDPOINT=endpoint,
                         OTEL_BSP_SCHEDULE_DELAY="50") as app:
                trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
                parent_id = "00f067aa0ba902b7"
                for method in ("POST", "GET"):
                    # Заголовок читается и в обычном, и в смешанном регистре.
                    key = "traceparent" if method == "POST" else "Traceparent"
                    header = f"{key}: 00-{trace_id}-{parent_id}-01"
                    app.expect("/notes", 201 if method == "POST" else 200, method,
                               '{"text":"trace"}' if method == "POST" else None, headers=(header,))
                unsampled_id = "1" * 32
                app.expect("/notes", 200, headers=(f"traceparent: 00-{unsampled_id}-{parent_id}-00",))
                app.expect("/error", 500, headers=("traceparent: invalid",))
                # shutdown SDK отправляет всю очередь, независимо от границ пакетов.
                app.stop()
                spans = []
                while not received.empty():
                    for resource in received.get_nowait().resource_spans:
                        attributes = {attr.key: attr.value.string_value for attr in resource.resource.attributes}
                        assert attributes["service.name"] == "notes-test"
                        for scope in resource.scope_spans:
                            assert scope.scope.name == "notes"
                            spans.extend(scope.spans)
                assert spans and all(span.name != "db" for span in spans)
                continued = [span for span in spans if span.trace_id.hex() == trace_id]
                assert sorted(span.name for span in continued) == ["HTTP GET /notes", "HTTP POST /notes"]
                for span in continued:
                    assert span.parent_span_id.hex() == parent_id and span.kind == 2
                assert all(span.trace_id.hex() != unsampled_id for span in spans)
                for span in spans:
                    assert len(span.trace_id) == 16 and any(span.trace_id)
                    assert len(span.span_id) == 8 and any(span.span_id)
                    assert span.end_time_unix_nano >= span.start_time_unix_nano > 0
                errors = [span for span in spans if span.name == "HTTP GET /error"]
                assert len(errors) == 1 and errors[0].status.code == 2
                entries = [json.loads(line) for line in app.logs()[0].splitlines()]
                assert sum(entry.get("trace_id") == trace_id for entry in entries) == 2
                assert sum(entry.get("trace_id") == unsampled_id for entry in entries) == 1
                assert all(re.fullmatch("[0-9a-f]{32}", entry["trace_id"])
                           for entry in entries if "trace_id" in entry)
                assert not app.logs()[1], app.logs()[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print("Доступные v7+: traceparent, trace_id, sampling и пакетный OTLP/HTTP protobuf — OK", flush=True)


def main():
    if sys.version_info < (3, 12):
        sys.exit("Нужен Python 3.12 или новее")
    versions = available_versions()
    # Временные файлы остаются внутри проекта и удаляются после проверки.
    with tempfile.TemporaryDirectory(prefix=".check-", dir=ROOT) as directory:
        work = Path(directory)
        for version in VERSIONS:
            py_compile.compile(str(ROOT / "versions" / (version + ".py")),
                               cfile=str(work / (version + ".pyc")), doraise=True)
            if version in versions:
                check_version(version, work)
        check_probes(work, versions)
        check_graceful_shutdown(work, versions)
        if "v7.1" in versions:
            check_failure_injection(work)
        tracing_versions = [version for version in versions if version in ("v7", "v7.1")]
        if tracing_versions:
            check_tracing(work, tracing_versions)
    print(f"Проверено {len(versions)} из {len(VERSIONS)} версий, пропущено {len(VERSIONS) - len(versions)}. "
          "PostgreSQL и настоящий Alloy/Tempo не запускались.")


if __name__ == "__main__":
    main()
