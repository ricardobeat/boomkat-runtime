#!/usr/bin/env python3
"""Compare HAProxy TCP mode, native FD dispatch, and direct bkr on one host."""
import argparse
import csv
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def cpu_seconds(text):
    days = 0
    if "-" in text:
        day, text = text.split("-", 1)
        days = int(day)
    total = days * 86400.0
    parts = text.split(":")
    return total + sum(float(value) * 60 ** index for index, value in enumerate(reversed(parts)))


def snapshot():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time="], text=True)
    rows = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4:
            pid, parent, rss = map(int, fields[:3])
            rows[pid] = {"parent": parent, "rss_mib": rss / 1024, "cpu_s": cpu_seconds(fields[3])}
    return rows


def descendants(rows, roots):
    found = set(roots)
    while True:
        expanded = found | {pid for pid, row in rows.items() if row["parent"] in found}
        if expanded == found:
            return found
        found = expanded


def reserve_ports(count):
    sockets = []
    try:
        for _ in range(count):
            probe = socket.socket()
            probe.bind(("127.0.0.1", 0))
            sockets.append(probe)
        return [probe.getsockname()[1] for probe in sockets]
    finally:
        for probe in sockets:
            probe.close()


def http_request(port, workload="hello", connection=None):
    own = connection is None
    connection = connection or http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    payload = b"a" * 1024 if workload == "echo" else None
    try:
        connection.request("POST" if payload else "GET", "/" + workload, payload)
        response = connection.getresponse()
        body = response.read()
        assert response.status == 200, (response.status, body)
        if workload == "hello":
            assert body == b"hello world", body
        elif workload == "echo":
            assert body == payload, body
        elif workload == "async":
            assert json.loads(body) == {"ok": True}, body
        elif workload == "cpu":
            value = 1
            for i in range(10000):
                value = ((value ^ i) * 1664525 + 1013904223) & 0xffffffff
            if value >= 0x80000000:
                value -= 0x100000000
            assert json.loads(body) == {"value": value}, body
    finally:
        if own:
            connection.close()


def read_stats(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(str(path))
        client.sendall(b"show stat\n")
        client.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    text = b"".join(chunks).decode()
    rows = list(csv.DictReader(io.StringIO(text.lstrip("# "))))
    return [row for row in rows if row.get("pxname") == "bkr" and row.get("svname", "").startswith("worker")]


def config_text(front_port, back_ports, threads, stats_path):
    lines = ["global", f"    nbthread {threads}", "    maxconn 4096",
             f"    stats socket {stats_path} mode 600 level admin", "",
             "defaults", "    mode tcp", "    timeout connect 5s", "    timeout client 30s", "    timeout server 30s", "",
             "frontend incoming", f"    bind 127.0.0.1:{front_port}", "    default_backend bkr", "",
             "backend bkr", "    balance roundrobin"]
    lines += [f"    server worker{i + 1} 127.0.0.1:{port}" for i, port in enumerate(back_ports)]
    return "\n".join(lines) + "\n"


class Services:
    def __init__(self, args, case, workload, temp):
        self.args, self.case, self.temp = args, case, temp
        self.server = ROOT / "bench/servers" / ("process-cpu.js" if workload == "cpu" else "bkr.js")
        self.processes = []
        self.backend_roots = []
        self.frontend = None
        self.config = None
        self.stats_path = temp / "stats.sock"
        self.port = None

    def launch(self, label, command):
        log = tempfile.TemporaryFile(mode="w+")
        proc = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
        self.processes.append((label, proc, log))
        return proc

    def logs(self):
        chunks = []
        for label, proc, log in self.processes:
            log.seek(0)
            chunks.append(f"{label} pid={proc.pid} exit={proc.poll()}\n" + log.read())
        return "\n".join(chunks)

    def alive(self):
        assert all(proc.poll() is None for _, proc, _ in self.processes), self.logs()

    def ready(self, port):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            self.alive()
            try:
                http_request(port)
                return
            except (OSError, http.client.HTTPException):
                time.sleep(.025)
        raise RuntimeError("readiness timed out\n" + self.logs())

    def bkr_command(self, port, dispatch=False):
        command = [str(self.args.binary), "--no-sandbox", "--no-prompt", "--allow-net=127.0.0.1",
                   f"--allow-read={ROOT / 'bench'}"]
        if dispatch:
            command += [f"--http-processes={self.case['workers']}"]
        return [*command, str(self.server), str(port), str(ROOT / "bench/payload.txt")]

    def start(self):
        case = self.case
        ports = reserve_ports(case["workers"] + 1)
        self.port = ports[0]
        if case["mode"] == "direct":
            self.backend_roots = [self.launch("bkr", self.bkr_command(self.port)).pid]
        elif case["mode"] == "dispatch":
            self.frontend = self.launch("dispatcher", self.bkr_command(self.port, dispatch=True)).pid
        else:
            back_ports = ports[1:]
            for i, port in enumerate(back_ports):
                self.backend_roots.append(self.launch(f"bkr-{i + 1}", self.bkr_command(port)).pid)
                self.ready(port)
            self.config = config_text(self.port, back_ports, case["threads"], self.stats_path)
            cfg = self.temp / "haproxy.cfg"
            cfg.write_text(self.config)
            subprocess.run([str(self.args.haproxy), "-c", "-f", str(cfg)], capture_output=True, text=True, check=True)
            self.frontend = self.launch("haproxy", [str(self.args.haproxy), "-db", "-f", str(cfg)]).pid
        self.ready(self.port)
        if case["mode"] == "dispatch":
            rows = snapshot()
            self.backend_roots = [pid for pid, row in rows.items() if row["parent"] == self.frontend]
            assert len(self.backend_roots) == case["workers"], self.logs()
        assert len(self.backend_roots) == case["workers"]
        return self

    def verify(self, workload):
        for _ in range(self.case["workers"]):
            http_request(self.port, workload)
        # Multiple requests on each of these persistent connections also verify
        # transparent bidirectional forwarding, including POST body handling.
        clients = [http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
                   for _ in range(max(8, self.case["workers"] * 4))]
        try:
            for client in clients:
                http_request(self.port, workload, client)
                http_request(self.port, workload, client)
            if self.case["mode"] == "haproxy":
                rows = read_stats(self.stats_path)
                assert len(rows) == self.case["workers"], rows
                assert all(int(row["scur"]) > 0 for row in rows), rows
                return [{key: row[key] for key in ("svname", "scur", "stot")} for row in rows]
        finally:
            for client in clients:
                client.close()
        return None

    def metrics(self, rows):
        backend = descendants(rows, self.backend_roots)
        frontend = set() if self.frontend is None else {self.frontend}
        return {role: {"rss_mib": sum(rows[pid]["rss_mib"] for pid in pids if pid in rows),
                       "cpu_s": sum(rows[pid]["cpu_s"] for pid in pids if pid in rows),
                       "pids": sorted(pids)}
                for role, pids in (("frontend", frontend), ("backends", backend))}

    def close(self):
        for _, proc, _ in reversed(self.processes):
            if proc.poll() is None:
                proc.terminate()
        for _, proc, log in reversed(self.processes):
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=3)
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            log.close()


def validate_wrk(output):
    assert "Socket errors" not in output and "Non-2xx" not in output, output
    assert re.search(r"Requests/sec:\s+[\d.]+", output), output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", type=Path, default=ROOT / "out/bkr")
    p.add_argument("--haproxy", type=Path, default=shutil.which("haproxy"))
    p.add_argument("--workers", default="1,2,4")
    p.add_argument("--strategies", default="direct,dispatch,haproxy")
    p.add_argument("--haproxy-threads", default="2", help="Comma-separated thread counts for a tuning sweep")
    p.add_argument("--workloads", default="hello,async,echo,cpu")
    p.add_argument("--client-threads", type=int, default=2)
    p.add_argument("--connections", type=int, default=128)
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--seconds", type=int, default=5)
    p.add_argument("--verify-only", action="store_true")
    p.add_argument("--report", type=Path, required=True)
    a = p.parse_args()
    a.binary = a.binary.resolve()
    if not a.haproxy:
        p.error("haproxy is not installed; supply --haproxy")
    a.haproxy = a.haproxy.resolve()
    counts = [int(n) for n in a.workers.split(",")]
    threads = [int(n) for n in a.haproxy_threads.split(",")]
    strategies = a.strategies.split(",")
    workloads = a.workloads.split(",")
    assert set(strategies) <= {"direct", "dispatch", "haproxy"}
    assert set(workloads) <= {"hello", "async", "echo", "cpu"}
    assert all(1 <= n <= 64 for n in counts + threads)
    assert min(a.connections, a.client_threads, a.rounds, a.seconds) > 0
    cases = []
    if "direct" in strategies:
        cases.append({"label": "direct", "mode": "direct", "workers": 1, "threads": 0})
    for count in counts:
        if "dispatch" in strategies:
            cases.append({"label": f"dispatch-{count}", "mode": "dispatch", "workers": count, "threads": 1})
        if "haproxy" in strategies:
            for n in threads:
                cases.append({"label": f"haproxy-{count}-t{n}", "mode": "haproxy", "workers": count, "threads": n})
    binary_hash = hashlib.sha256(a.binary.read_bytes()).hexdigest()
    report = {
        "method": "Rotating case and workload order; fresh services per sample; HTTP/1.1 keep-alive; 1s warmup",
        "seconds": a.seconds, "rounds": a.rounds, "connections": a.connections, "client_threads": a.client_threads,
        "binary": str(a.binary), "binary_sha256": binary_hash,
        "haproxy": str(a.haproxy), "haproxy_sha256": hashlib.sha256(a.haproxy.read_bytes()).hexdigest(),
        "haproxy_version": subprocess.check_output([str(a.haproxy), "-vv"], text=True, stderr=subprocess.STDOUT),
        "runtime_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "engine_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT.parent / "boomkat", text=True).strip(),
        "hardware": subprocess.check_output(["sysctl", "hw.physicalcpu", "hw.perflevel0.physicalcpu", "hw.perflevel1.physicalcpu", "machdep.cpu.brand_string"], text=True),
        "os": platform.platform(), "cases": cases, "verify_only": a.verify_only, "results": {}, "failures": [],
        "server_sha256": {name: hashlib.sha256((ROOT / "bench/servers" / name).read_bytes()).hexdigest()
                          for name in ("bkr.js", "process-cpu.js")},
        "cpu_units": "percent of one logical CPU, summed per role; service CPU sampled with ps time deltas",
        "rss_units": "peak summed process RSS MiB per role; total includes frontend and every backend/descendant",
        "argv": os.sys.argv,
    }
    with tempfile.TemporaryDirectory(prefix="bkr-haproxy-", dir="/tmp") as temp_name:
        temp = Path(temp_name)
        post = temp / "post.lua"
        post.write_text('wrk.method = "POST"\nwrk.body = string.rep("a", 1024)\n')
        for round_index in range(1 if a.verify_only else a.rounds):
            order = cases[round_index % len(cases):] + cases[:round_index % len(cases)]
            routes = workloads[round_index % len(workloads):] + workloads[:round_index % len(workloads)]
            for workload in routes:
                for case in order:
                    service = Services(a, case, workload, temp)
                    try:
                        service.start()
                        validation = service.verify(workload)
                        if a.verify_only:
                            row = {"verified": True, "backend_connections": validation}
                        else:
                            options = ["wrk", f"-t{a.client_threads}", f"-c{a.connections}"]
                            if workload == "echo":
                                options += ["-s", str(post)]
                            url = f"http://127.0.0.1:{service.port}/{workload}"
                            warm = subprocess.run([*options, "-d1s", url], capture_output=True, text=True, check=True)
                            validate_wrk(warm.stdout)
                            before_at = time.monotonic()
                            before = service.metrics(snapshot())
                            loadavg = os.getloadavg()
                            load = subprocess.Popen(["/usr/bin/time", "-p", *options, f"-d{a.seconds}s", "--latency", url],
                                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                            peaks = {"frontend": 0., "backends": 0., "total": 0.}
                            while load.poll() is None:
                                sample = service.metrics(snapshot())
                                for role in ("frontend", "backends"):
                                    peaks[role] = max(peaks[role], sample[role]["rss_mib"])
                                peaks["total"] = max(peaks["total"], sum(sample[r]["rss_mib"] for r in ("frontend", "backends")))
                                time.sleep(.2)
                            output, error = load.communicate()
                            after = service.metrics(snapshot())
                            elapsed = time.monotonic() - before_at
                            assert load.returncode == 0, output + error
                            validate_wrk(output)
                            service.alive()
                            cpu = {role: (after[role]["cpu_s"] - before[role]["cpu_s"]) / elapsed * 100
                                   for role in ("frontend", "backends")}
                            timing = {key: float(re.search(rf"^{key}\s+([\d.]+)", error, re.M).group(1)) for key in ("real", "user", "sys")}
                            cpu["client"] = (timing["user"] + timing["sys"]) / timing["real"] * 100
                            latency = {}
                            for key in ("50", "99"):
                                value, unit = re.search(rf"{key}%\s+([\d.]+)(us|ms|s)", output).groups()
                                latency[key] = float(value) * {"us": .001, "ms": 1, "s": 1000}[unit]
                            row = {"round": round_index + 1, "req_s": float(re.search(r"Requests/sec:\s+([\d.]+)", output).group(1)),
                                   "latency_ms": latency, "peak_rss_mib": peaks, "cpu_pct": cpu,
                                   "service_cpu_window_s": elapsed, "cpu_before": before, "cpu_after": after,
                                   "client_time": timing, "host_loadavg": loadavg, "wrk": output, "stderr": error,
                                   "backend_connections": validation,
                                   "haproxy_stats_after": read_stats(service.stats_path) if case["mode"] == "haproxy" else None}
                        row["haproxy_config"] = service.config
                        row["frontend_port"] = service.port
                        report["results"].setdefault(workload, {}).setdefault(case["label"], []).append(row)
                        a.report.write_text(json.dumps(report, indent=2) + "\n")
                        print(round_index + 1, workload, case["label"],
                              "verified" if a.verify_only else f'{row["req_s"]:.0f} req/s p99={row["latency_ms"]["99"]:.3f}ms CPU={cpu} RSS={peaks["total"]:.1f}MiB', flush=True)
                    except BaseException as exc:
                        report["failures"].append({"round": round_index + 1, "workload": workload,
                                                   "case": case, "error": repr(exc), "logs": service.logs()})
                        a.report.write_text(json.dumps(report, indent=2) + "\n")
                        raise
                    finally:
                        service.close()
                        if service.stats_path.exists():
                            service.stats_path.unlink()
    assert hashlib.sha256(a.binary.read_bytes()).hexdigest() == binary_hash, "bkr binary changed during the comparison"
    if not a.verify_only:
        for workload, data in report["results"].items():
            print(workload, {label: round(statistics.median(row["req_s"] for row in rows)) for label, rows in data.items()}, flush=True)


if __name__ == "__main__":
    main()
