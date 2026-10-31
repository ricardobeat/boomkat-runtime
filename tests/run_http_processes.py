#!/usr/bin/env python3
"""SCM_RIGHTS handoffs: independent processes, real sockets, and pool lifetime."""
import base64
import hashlib
import concurrent.futures
import contextlib
import http.client
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("BKR_BIN", ROOT / "out/bkr"))


def eventually(predicate, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.025)
    raise AssertionError("condition timed out")


def running(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


@contextlib.contextmanager
def pool(workers, mode="normal", sandbox=False, requested_port=0):
    with tempfile.TemporaryFile(mode="w+") as log:
        process = subprocess.Popen([
            str(BIN), f"--http-processes={workers}", "--no-prompt",
            *([] if sandbox else ["--no-sandbox"]), "--allow-net=127.0.0.1",
            str(ROOT / "tests/http-processes.js"), str(requested_port), mode,
        ], stdout=log, stderr=log, start_new_session=True)
        def output():
            log.seek(0)
            return log.read()
        try:
            port = None
            if mode == "normal":
                def ready():
                    nonlocal port
                    text = output()
                    assert process.poll() is None, text
                    match = re.search(rf"HTTP processes ready: {workers} \(port (\d+)\)", text)
                    if match:
                        port = int(match[1])
                    return bool(match)
                eventually(ready)
            yield process, port, output
        except BaseException:
            print("pool failure:", process.poll(), output(), flush=True)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
            # Also catch orphan grandchildren after intentionally killing the parent.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            assert "ERROR: AddressSanitizer" not in output(), output()


def request(port, i=0, path="/", body=None):
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        client.request("POST" if body is not None else "GET", path, body)
        response = client.getresponse()
        data = response.read()
        assert response.status in (200, 201), (response.status, data)
        return data, dict(response.getheaders())
    finally:
        client.close()


def websocket(port, pids, keep_open=False):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n").encode())
        headers = b""
        while not headers.endswith(b"\r\n\r\n"):
            headers += sock.recv(1)
        assert headers.startswith(b"HTTP/1.1 101"), headers
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert expected in headers
        identity = None
        for message in (b"hello", b"again"):
            mask = os.urandom(4)
            sock.sendall(bytes([0x81, 0x80 | len(message)]) + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(message)))
            frame = sock.recv(2)
            assert len(frame) == 2 and frame[0] == 0x81 and frame[1] < 126, frame
            data = b""
            while len(data) < frame[1]: data += sock.recv(frame[1] - len(data))
            pid, text = data.split(b":", 1)
            assert int(pid) in pids and text == message
            if identity is not None: assert identity == pid
            identity = pid
    except BaseException:
        sock.close()
        raise
    if keep_open:
        return sock
    sock.close()


for workers in (1, 2, 4):
    with pool(workers, sandbox=workers == 2) as (process, port, output):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            rows = list(executor.map(lambda i: json.loads(request(port, i, body=f"body-{i}")[0]), range(64)))
        pids = {row["pid"] for row in rows}
        assert len(pids) == workers and process.pid not in pids, (workers, pids)
        assert all(row["body"] == f"body-{i}" and row["port"] == port for i, row in enumerate(rows))
        counts = [sum(row["pid"] == pid for row in rows) for pid in pids]
        assert max(counts) - min(counts) <= 1, counts
        client = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        kept = []
        for i in range(4):
            client.request("GET", "/")
            kept.append(json.loads(client.getresponse().read()))
        client.close()
        assert len({row["pid"] for row in kept}) == 1
        assert [row["count"] for row in kept] == list(range(kept[0]["count"], kept[0]["count"] + 4))
        held_websocket = websocket(port, pids, keep_open=True)
        assert request(port, path="/stream")[0] == b"chunk" * 3
        data, headers = request(port, path="/static")
        assert data == b"static" and int(headers["x-pid"]) in pids
        # Stop accepting in every worker while existing async responses drain.
        slow = [http.client.HTTPConnection("127.0.0.1", port, timeout=5) for _ in range(workers)]
        for client in slow:
            client.request("GET", "/slow")
        active = set()
        def all_active():
            row = json.loads(request(port, path="/active")[0])
            if row["active"]: active.add(row["pid"])
            return active == pids
        eventually(all_active)
        for _ in range(workers):
            request(port, path="/stop")
        for client in slow:
            assert client.getresponse().read() == bytes([7]) * (1024 * 1024)
            client.close()
        # Graceful stop also waits for upgraded sockets; they must not be
        # mistaken for their freed HTTP response allocations.
        assert process.poll() is None, output()
        held_websocket.close()
        assert process.wait(timeout=6) == 0, output()
        eventually(lambda: not any(running(pid) for pid in pids))
    print(f"HTTP processes {workers}: distribution, keep-alive, bodies, streams, WebSockets and graceful drain passed", flush=True)

# A full handoff queue must pause acceptance without losing accepted sockets.
with pool(1) as (process, port, output):
    busy = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    busy.request("GET", "/busy")
    clients = [http.client.HTTPConnection("127.0.0.1", port, timeout=5) for _ in range(64)]
    for client in clients:
        client.request("GET", "/")
    assert busy.getresponse().status == 200
    busy.close()
    for client in clients:
        response = client.getresponse()
        assert response.status == 200 and json.loads(response.read())["pid"] != process.pid
        client.close()
print("HTTP processes: handoff backpressure passed", flush=True)

for target in ("worker", "supervisor"):
    with pool(2) as (process, port, output):
        pids = {json.loads(request(port)[0])["pid"] for _ in range(2)}
        assert len(pids) == 2
        if target == "worker":
            os.kill(next(iter(pids)), signal.SIGKILL)
            assert process.wait(timeout=5) == 1, output()
        else:
            spin = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            spin.request("GET", "/spin")
            eventually(lambda: "PROCESS_SPIN" in output())
            process.kill()
            process.wait(timeout=3)
            spin.close()
        eventually(lambda: not any(running(pid) for pid in pids))
    print(f"HTTP processes: {target} failure cleanup passed", flush=True)

with pool(4, "fail") as (process, port, output):
    assert process.wait(timeout=6) == 1
with pool(2, "idle") as (process, port, output):
    time.sleep(.2)
    process.terminate()
    assert process.wait(timeout=5) in (143, -signal.SIGTERM)
print("HTTP processes: startup failure and startup cancellation passed", flush=True)

with socket.socket() as occupied:
    occupied.bind(("127.0.0.1", 0))
    occupied.listen()
    with pool(2, "bound", requested_port=occupied.getsockname()[1]) as (process, port, output):
        assert process.wait(timeout=5) == 1
        assert "HTTP process listener" in output(), output()
for flags in (["--http-processes=0"], ["--http-processes=65"], ["--http-processes=abc"],
              ["--http-processes=2", "--http-workers=2"]):
    result = subprocess.run([str(BIN), *flags, str(ROOT / "tests/http-processes.js"), "0"],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 2, result.stdout + result.stderr
result = subprocess.run([str(BIN), "--http-processes=1", "--no-sandbox", "--no-prompt",
                         str(ROOT / "tests/http-processes.js"), "0"], capture_output=True, text=True, timeout=5)
assert result.returncode == 1 and "net access" in result.stderr, result.stdout + result.stderr
print("HTTP processes: bind failure, flag validation and network permissions passed", flush=True)
