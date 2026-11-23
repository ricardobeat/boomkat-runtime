#!/usr/bin/env python3
"""Directory routes: MIME types, TS/TSX transpilation, linked and inline
source maps, ETags, path-traversal rejection and the in-memory cache."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("BKR_BIN", ROOT / "out/bkr"))

with tempfile.TemporaryDirectory(prefix="bkr-http-dir-") as directory:
    base = Path(directory)
    served = base / "public"
    served.mkdir()
    (served / "index.html").write_text("<!doctype html><title>dir</title>\n")
    (served / "main.tsx").write_text("const n: number = 1;\nexport const view = <main>{n}</main>;\n")
    (served / "lib.ts").write_text("export const answer: number = 42;\n")
    (served / "style.css").write_text("body { color: #333 }\n")
    (base / "secret.txt").write_text("secret")

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]

    with open(base / "server.log", "w+") as log:
        proc = subprocess.Popen(
            [str(BIN), "--no-prompt", f"--allow-net=127.0.0.1:{port}",
             f"--allow-read={ROOT}/tests", f"--allow-read={served}",
             str(ROOT / "tests/http-dir.js"), str(served), str(port)],
            stdout=log, stderr=log,
        )
        try:
            for _ in range(100):
                try:
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
                    conn.request("GET", "/app/index.html")
                    conn.getresponse().read()
                    conn.close()
                    break
                except OSError:
                    if proc.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    time.sleep(0.02)
            else:
                raise AssertionError("server did not start")

            def call(path, method="GET", headers=None):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request(method, path, headers=headers or {})
                response = conn.getresponse()
                body = response.read()
                result = response.status, {k.lower(): v for k, v in response.getheaders()}, body
                conn.close()
                return result

            status, headers, body = call("/app/index.html")
            assert status == 200 and headers["content-type"].startswith("text/html"), (status, headers)
            assert b"<title>dir</title>" in body

            status, headers, body = call("/app/")
            assert status == 200 and b"<title>dir</title>" in body

            status, headers, body = call("/app/main.js")
            assert status == 200, (status, body)
            assert headers["content-type"].startswith("text/javascript"), headers
            assert b": number" not in body and b"const n" in body, body
            assert body.endswith(b"//# sourceMappingURL=/app/main.js.map"), body[-80:]
            etag = headers["etag"]

            status, headers, body = call("/app/main.js.map")
            assert status == 200 and headers["content-type"].startswith("application/json"), (status, headers)
            source_map = json.loads(body)
            assert source_map["version"] == 3 and source_map["sources"] == ["main.tsx"], source_map
            assert "const n" in source_map["sourcesContent"][0]

            status, headers, body = call("/app/lib.js")
            assert status == 200 and b": number" not in body and b"answer" in body, body
            status, headers, body = call("/app/lib.js.map")
            assert status == 200 and json.loads(body)["sources"] == ["lib.ts"], body

            status, headers, body = call("/app/lib.ts")
            assert status == 200 and body.endswith(b"//# sourceMappingURL=/app/lib.ts.map"), body[-80:]
            status, headers, body = call("/app/lib.ts.map")
            assert status == 200 and json.loads(body)["sources"] == ["lib.ts"], body

            status, headers, body = call("/raw/lib.ts")
            assert status == 200 and b": number" in body, body
            assert headers["content-type"].startswith("text/plain"), headers

            status, headers, body = call("/app/style.css")
            assert status == 200 and headers["content-type"].startswith("text/css"), headers

            status, headers, body = call("/inline/main.js")
            assert status == 200 and b"sourceMappingURL=data:application/json;base64," in body, body[-80:]
            status, headers, body = call("/inline/main.js.map")
            assert status == 404, (status, body)

            status, headers, body = call("/app/main.js", headers={"if-none-match": etag})
            assert status == 304 and body == b"", (status, body)

            status, headers, body = call("/app/main.js", method="HEAD")
            assert status == 200 and body == b"" and headers["content-type"].startswith("text/javascript"), headers

            status, headers, body = call("/app")
            assert status == 308 and headers["location"] == "/app/", (status, headers)

            status, headers, body = call("/app/missing.js")
            assert status == 404, status
            status, headers, body = call("/app/%2e%2e/secret.txt")
            assert status in (400, 404) and b"secret" not in body, (status, body)

            # The cache serves from memory while the source's size and mtime are
            # unchanged: make the file unreadable and request it again.
            os.chmod(served / "main.tsx", 0)
            status, headers, body = call("/app/main.js")
            assert status == 200 and headers["etag"] == etag and b"const n" in body, (status, headers, body)
            status, headers, body = call("/app/main.js.map")
            assert status == 200 and json.loads(body)["sources"] == ["main.tsx"], (status, body)
            os.chmod(served / "main.tsx", 0o644)

            (served / "main.tsx").write_text("const n: number = 2;\nexport const view = <main>{n}</main>;\n")
            time.sleep(0.02)
            status, headers, body = call("/app/main.js")
            assert status == 200 and b"const n=(2)" in body, body
            assert headers["etag"] != etag, headers

            assert proc.poll() is None
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            log.seek(0)
            output = log.read()
            assert "AddressSanitizer" not in output, output

print("Directory routes: MIME, transpile, linked/inline maps, ETag, traversal, cache: passed")
