#!/usr/bin/env python3
"""Compare direct, descriptor-passing process pools, and threaded HTTP servers."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--binary", type=Path, default=ROOT / "out/bkr")
p.add_argument("--report", type=Path, required=True)
p.add_argument("--server", type=Path, default=ROOT / "bench/servers/bkr.js")
p.add_argument("--rounds", type=int, default=3)
p.add_argument("--seconds", type=int, default=5)
p.add_argument("--workloads", default="hello,async,echo")
p.add_argument("--processes", default="1,2,4")
p.add_argument("--threads", type=int, default=4)
p.add_argument("--client-threads", type=int, default=4)
p.add_argument("--connections", type=int, default=128)
p.add_argument("--close-connections", action="store_true", help="Use the validated Go HTTP/1.1 client with one request per connection")
p.add_argument("--churn-rate", type=int, default=1000, help="Total connection-rate limit for churn tests; 0 for unrestricted")
a = p.parse_args()
a.binary = a.binary.resolve()
a.server = a.server.resolve()
variants = {"direct": []}
variants.update({f"processes-{n}": [f"--http-processes={n}"] for n in map(int, filter(None, a.processes.split(",")))})
if a.threads:
    variants[f"threads-{a.threads}"] = [f"--http-workers={a.threads}"]
report = {
    "method": f"{a.rounds} rounds; rotating variant and workload order; fresh server; 1s warmup + {a.seconds}s measured",
    "client_threads": a.client_threads, "connections": a.connections,
    "load_generator": "Go net/http HTTP/1.1, graceful close, rate limited" if a.close_connections else "wrk",
    "churn_rate_limit": a.churn_rate if a.close_connections else None,
    "close_connections": a.close_connections, "rss": "peak sum of supervisor and descendant processes, sampled every 100ms",
    "runtime": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "engine": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT.parent / "boomkat", text=True).strip(),
    "binary_sha256": hashlib.sha256(a.binary.read_bytes()).hexdigest(),
    "server": str(a.server), "server_sha256": hashlib.sha256(a.server.read_bytes()).hexdigest(),
    "logical_cpus": os.cpu_count(),
    "source_sha256": {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                      for d in ("runtime", "shim") for f in sorted((ROOT / d).rglob("*")) if f.suffix in (".c3", ".js", ".cpp", ".c")},
    "variants": variants, "results": {},
}


def tree_rss(pid):
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
    rows = [tuple(map(int, line.split())) for line in output.splitlines() if line.strip()]
    descendants = {pid}
    while True:
        expanded = descendants | {child for child, parent, rss in rows if parent in descendants}
        if expanded == descendants:
            return sum(rss for child, parent, rss in rows if child in descendants) / 1024
        descendants = expanded


def command(flags, port):
    return [str(a.binary), "--no-sandbox", "--no-prompt", "--allow-net", f"--allow-read={ROOT / 'bench'}", *flags,
            str(a.server), str(port), str(ROOT / "bench/payload.txt")]


with tempfile.TemporaryDirectory(prefix="bkr-process-bench-") as temp:
    post = Path(temp) / "post.lua"
    post.write_text('wrk.method = "POST"\nwrk.body = string.rep("a", 1024)\n')
    churn_client = Path(temp) / "http-churn"
    if a.close_connections:
        env = dict(os.environ, GOCACHE="/tmp/bkr-bench-go-cache", GOTOOLCHAIN="local", GOPROXY="off")
        subprocess.run(["go", "build", "-o", str(churn_client), str(ROOT / "bench/http-churn.go")], env=env, check=True)
        report["churn_client_sha256"] = hashlib.sha256((ROOT / "bench/http-churn.go").read_bytes()).hexdigest()
    labels = list(variants)
    workloads = a.workloads.split(",")
    for round_index in range(a.rounds):
        order = labels[round_index % len(labels):] + labels[:round_index % len(labels)]
        routes = workloads[round_index % len(workloads):] + workloads[:round_index % len(workloads)]
        for workload in routes:
            for label in order:
                port = 18149
                if a.close_connections:
                    # A new destination tuple keeps prior samples' TCP state
                    # from leaking across fresh server processes.
                    with socket.socket() as probe:
                        probe.bind(("127.0.0.1", 0))
                        port = probe.getsockname()[1]
                with tempfile.TemporaryFile(mode="w+") as log:
                    server = subprocess.Popen(command(variants[label], port), stdout=log, stderr=log, start_new_session=True)
                    try:
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            if server.poll() is not None:
                                log.seek(0)
                                raise RuntimeError(log.read())
                            try:
                                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=.5)
                                conn.request("GET", "/hello")
                                response = conn.getresponse()
                                assert response.status == 200 and response.read() == b"hello world"
                                conn.close()
                                if label.startswith("threads-"):
                                    log.seek(0)
                                    if f"HTTP workers ready: {a.threads}" not in log.read():
                                        time.sleep(.025)
                                        continue
                                break
                            except OSError:
                                time.sleep(.025)
                        else:
                            raise RuntimeError("startup timed out")
                        url = f"http://127.0.0.1:{port}/{workload}"
                        if a.close_connections:
                            if workload != "hello": raise ValueError("churn client requires --workloads hello")
                            options = [str(churn_client), "-url", url, "-concurrency", str(a.connections), "-threads", str(a.client_threads), "-rate", str(a.churn_rate)]
                            warm_command = [*options, "-duration", "1s"]
                            load_command = [*options, "-duration", f"{a.seconds}s"]
                        else:
                            options = ["wrk", f"-t{a.client_threads}", f"-c{a.connections}"]
                            if workload == "echo": options += ["-s", str(post)]
                            warm_command = [*options, "-d1s", url]
                            load_command = [*options, f"-d{a.seconds}s", "--latency", url]
                        def validate(output):
                            if a.close_connections:
                                result = json.loads(output)
                                assert result["failed_requests"] == 0 and result["complete_requests"] > 0, output
                                assert result["connections"] == result["complete_requests"], output
                            else:
                                assert "Socket errors" not in output and "Non-2xx" not in output, output
                        warm = subprocess.run(warm_command, capture_output=True, text=True)
                        if warm.returncode:
                            log.seek(0)
                            raise RuntimeError(warm.stdout + warm.stderr + "\nSERVER:\n" + log.read())
                        validate(warm.stdout)
                        load = subprocess.Popen(load_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                        rss = 0
                        host_load = os.getloadavg()
                        while load.poll() is None:
                            rss = max(rss, tree_rss(server.pid))
                            time.sleep(.1)
                        output, error = load.communicate()
                        assert load.returncode == 0, output + error
                        validate(output)
                        assert server.poll() is None, "server exited during load"
                        if a.close_connections:
                            result = json.loads(output)
                            latency = result["latency_ms"]
                            req_s = result["req_s"]
                        else:
                            latency = {}
                            for k in ("50", "99"):
                                value, unit = re.search(rf"{k}%\s+([\d.]+)(us|ms|s)", output).groups()
                                latency[k] = float(value) * {"us": .001, "ms": 1, "s": 1000}[unit]
                            req_s = float(re.search(r"Requests/sec:\s+([\d.]+)", output).group(1))
                        row = {"round": round_index + 1, "port": port, "req_s": req_s, "latency_ms": latency,
                               "peak_tree_rss_mib": rss, "host_loadavg": host_load, "stderr": error}
                        row["churn" if a.close_connections else "wrk"] = result if a.close_connections else output
                        report["results"].setdefault(workload, {}).setdefault(label, []).append(row)
                        a.report.write_text(json.dumps(report, indent=2) + "\n")
                        print(round_index + 1, workload, label, row["req_s"], latency, round(rss, 2), "load", round(host_load[0], 2), flush=True)
                    finally:
                        server.terminate()
                        try:
                            server.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(server.pid, 9)
                            server.wait(timeout=3)
                        try:
                            os.killpg(server.pid, 9)
                        except ProcessLookupError:
                            pass
for workload, data in report["results"].items():
    print(workload, {label: round(statistics.median(r["req_s"] for r in rows)) for label, rows in data.items()}, flush=True)
