#!/usr/bin/env python3
"""One listener distributes real connections across isolated server VMs."""
import concurrent.futures
import json
import http.client
import os
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("BKR_BIN", ROOT / "out/bkr"))
for workers, mode in [(1, "forced"), (2, "forced"), (4, "forced"), (4, "graceful")]:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with tempfile.TemporaryFile(mode="w+") as log:
        process = subprocess.Popen([
            str(BIN), "--no-sandbox", "--no-prompt", f"--http-workers={workers}",
            f"--allow-net=127.0.0.1:{port}", f"--allow-read={ROOT}/tests",
            str(ROOT / "tests/http-workers.ts"), str(port), mode,
        ], stdout=log, stderr=log)
        try:
            for _ in range(200):
                log.seek(0)
                output = log.read()
                if f"POOL_READY {workers}" in output:
                    break
                assert process.poll() is None, output
                time.sleep(.025)
            else:
                raise AssertionError("Pool startup timed out: " + output)
            ready = time.monotonic()
            def request(i):
                body = f"body-{i}"
                req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=body.encode(), method="POST")
                with urllib.request.urlopen(req, timeout=3) as response:
                    data = json.loads(response.read())
                assert data["body"] == body
                return data["identity"]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(request, range(64)))
            expected = {"main"} | {f"http-{i}" for i in range(1, workers)}
            assert set(results) == expected, (workers, results)
            counts = {identity: results.count(identity) for identity in expected}
            assert max(counts.values()) - min(counts.values()) <= 1, counts
            def static_request(i):
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/static", timeout=3) as response:
                    assert response.status == 201 and response.read() == b"static"
                    return response.headers['x-static']
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                static_results = list(pool.map(static_request, range(64)))
            assert set(static_results) == expected
            if mode == "graceful":
                keep_alive = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                keep_alive.request("GET", "/")
                identity = json.loads(keep_alive.getresponse().read())["identity"]
                assert identity == "main", identity
                time.sleep(max(0, 1.3 - (time.monotonic() - ready)))
                def slow(i):
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/slow", timeout=4) as response:
                        payload = response.read()
                    assert payload == bytes([7]) * (4 * 1024 * 1024)
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    list(pool.map(slow, range(8)))
                assert keep_alive.sock.recv(1) == b"", "main keep-alive socket stayed open"
                keep_alive.close()
            assert process.wait(timeout=5) == 0
            log.seek(0)
            output = log.read()
            assert "POOL_STOPPED" in output, output
            assert "Sanitizer" not in output, output
            print(f"HTTP pool {workers} ({mode}): balanced distribution, bodies and shutdown passed ({counts})")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
