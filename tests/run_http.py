#!/usr/bin/env python3
"""Bounded HTTP regressions; BKR_BIN selects the runtime build."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = os.environ.get("BKR_BIN", str(ROOT / "out/bkr-perf"))
with tempfile.TemporaryDirectory(prefix="bkr-http-") as temp:
    payload = Path(temp) / "payload"
    data = b"x" * (1024 * 1024)
    payload.write_bytes(data)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    with (Path(temp) / "server.log").open("w+") as log:
        proc = subprocess.Popen([BIN, "--no-sandbox", "--allow-net", f"--allow-read={temp}",
                                 str(ROOT / "tests/http-server.js"), str(port), str(payload)], stdout=log, stderr=log)
        def request(path, method="GET", body=None, headers=None):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                conn.request(method, path, body=body, headers=headers or {})
                response = conn.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                conn.close()
        def disconnect(path, upload=False):
            with socket.create_connection(("127.0.0.1", port), timeout=2) as conn:
                if upload:
                    conn.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n" + b"a" * 4096)
                else:
                    conn.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                    time.sleep(.02)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    log.seek(0)
                    raise AssertionError(log.read())
                try:
                    request("/")
                    break
                except OSError:
                    time.sleep(.03)
            else:
                raise AssertionError("server did not start")
            assert request("/unread", method="PUT", headers={"x-test": "retained"})[2] == b"saved"
            retained = json.loads(request("/inspect")[2])
            assert retained == {"url": f"http://127.0.0.1:{port}/unread", "header": "retained"}, retained
            for path, expected in [("/empty", b"done"), ("/empty-queued", b"done"), ("/pending-data", b"done"), ("/sync-empty", b"done"), ("/promised", b"promised"),
                                   ("/delayed", b"delayed"), ("/subclass", b"subclass"), ("/thenable", b"thenable"), ("/custom-then", b"custom")]:
                assert request(path)[2] == expected, path
            assert request("/rejected")[::2] == (500, b"rejected")
            assert request("/stream-error")[2] == b""
            assert request("/stream-error-state")[2] == b"errored"
            if os.environ.get("BKR_HTTP_STRESS"):
                def rss():
                    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(proc.pid)]))
                before = rss()
                for _ in range(1000):
                    assert request("/promised")[2] == b"promised"
                    assert request("/stream")[2] == b"x" * (128 * 1024)
                growth = rss() - before
                assert growth < 32 * 1024, f"completed response bodies retained {growth / 1024:.1f} MiB"
                print(f"Response retention stress: RSS growth {growth / 1024:.1f} MiB")
            for path in ["/abort", "/abort-queued"]:
                disconnect(path)
            for _ in range(50):
                if request("/canceled")[2] == b"2":
                    break
                time.sleep(.02)
            else:
                raise AssertionError("stream cancellation never ran")
            for path in ["/stream", "/stream-queued"]:
                assert request(path)[2] == b"x" * (128 * 1024), path
                assert request(path, method="HEAD")[2] == b"", "HEAD stream sent a body"
            for path in ["/file", "/file-custom", "/file-consume", "/file-clone"]:
                status, headers, actual = request(path)
                assert actual == data, path
                if path == "/file-custom":
                    assert status == 201 and headers["x-file"] == "yes"
                assert request(path, method="HEAD")[2] == b""
            assert request("/file-missing")[::2] == (500, b"ENOENT")
            assert request("/file-denied")[::2] == (500, b"PERMISSION_DENIED")
            assert request("/echo", method="POST", body=b"hello")[2] == b"hello"
            disconnect("/late")
            assert request("/finish-late")[2] == b"finished", "late completion affected another response"
            # A small receive window forces native file backpressure before draining.
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.connect()
            conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
            conn.request("GET", "/file")
            time.sleep(.1)
            response = conn.getresponse()
            assert response.read() == data, "backpressure dropped file bytes"
            conn.close()
            # Reuse connections after disconnects, including outstanding file reads.
            for _ in range(100):
                disconnect("/", upload=True)
                disconnect("/file")
            for contents in [b"", b"small file", b"x" * 4096]:
                payload.write_bytes(contents)
                assert request("/file")[2] == contents
                assert request("/file", method="HEAD")[2] == b""
            assert request("/")[2] == b"ok"
            assert proc.poll() is None, "server crashed"
            print("HTTP lifecycle and native bodies: passed")
        finally:
            proc.terminate()
            proc.wait(timeout=5)
            log.seek(0)
            output = log.read()
            if "ERROR: AddressSanitizer" in output or "runtime error:" in output:
                raise AssertionError(output)
