#!/usr/bin/env python3
"""Compare observable HTTP layout mutations with a supplied baseline binary."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(binary):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen([str(binary), "--no-sandbox", "--allow-net",
                                 str(ROOT / "tests/http-layout.js"), str(port)]
                                + (["stress"] if os.environ.get("BKR_LAYOUT_GC_STRESS") else []), stderr=log,
                                stdout=log)
        def request(path, method="GET", body=None, headers=None):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            try:
                conn.request(method, path, body=body, headers=headers or {})
                response = conn.getresponse()
                return response.status, response.getheader("content-type"), response.read().decode()
            finally:
                conn.close()
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    log.seek(0)
                    raise AssertionError(log.read().decode())
                try:
                    request("/warm")
                    break
                except OSError:
                    time.sleep(.03)
            else:
                raise AssertionError("server did not start")
            rows = []
            for path in ["/warm", "/status", "/reset", "/warm", "/content-type", "/reset",
                         "/warm", "/accessor", "/accessor-count", "/grow", "/own-accessor",
                         "/prototype", "/used", "/warm", "/churn", "/warm"]:
                rows.append((path, request(path)))
            for method in ["GET", "POST", "GET", "POST"]:
                suffix = str(len(rows))
                marker = "retained-" + method + suffix
                rows.append((method, request("/capture?marker=" + suffix, method,
                                             b"upload" if method == "POST" else None,
                                             {"x-layout": marker, "Host": "changed.example:8080"})))
                request("/warm")
                request("/churn")
                inspected = request("/inspect")
                value = json.loads(inspected[2])
                assert value["header"] == marker and value["method"] == "changed", value
                assert value["search"] == "?marker=" + suffix and value["host"] == "changed.example:8080"
                assert value["currentMethod"] == "GET" and value["currentExtra"] is True
                assert value["keys"] == "method,_id,_url,_headerBlob", value
                rows.append(("inspect-" + method, inspected))
                assert request("/echo", "POST", b"echo")[-1] == "echo"
            assert rows[1][1][0] == 201
            assert rows[4][1][1] == "application/json"
            assert rows[7][1][1] == "application/json"
            return rows
        finally:
            unexpected_exit = proc.poll()
            proc.terminate()
            proc.wait(timeout=5)
            log.seek(0)
            output = log.read().decode()
            if os.environ.get("BKR_HTTP_LOG"):
                Path(os.environ["BKR_HTTP_LOG"]).write_text(output)
            if unexpected_exit is not None or "ERROR: AddressSanitizer" in output:
                raise AssertionError(output)


candidate = run(os.environ.get("BKR_BIN", str(ROOT / "out/bkr-perf")))
baseline = os.environ.get("BKR_BASELINE_BIN")
if baseline:
    expected = run(baseline)
    assert candidate == expected, (candidate, expected)
print("HTTP request/response layout mutations: passed")
