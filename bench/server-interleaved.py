#!/usr/bin/env python3
"""Interleave Boomkat, Node and Bun servers; record throughput, latency and RSS."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--bkr", type=Path, default=ROOT / "out/bkr")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--report", type=Path, required=True)
opts = parser.parse_args()
binaries = {"boomkat": opts.bkr.resolve(), "node": Path(shutil.which("node")), "bun": Path(shutil.which("bun"))}
def revision(path):
    return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
def command(label):
    script = {"boomkat": "bkr.js", "node": "node.mjs", "bun": "bun.js"}[label]
    flags = ["--no-sandbox", "--allow-net", f"--allow-read={ROOT / 'bench'}"] if label == "boomkat" else []
    return [str(binaries[label]), *flags, str(ROOT / "bench/servers" / script), "18149", str(ROOT / "bench/payload.txt")]

results = {}
metadata = {
    "method": f"{opts.rounds} interleaved rounds; fresh server per workload/binary; "
              "wrk -t2 -c128; 1s warmup, 3s measured; RSS sampled every 100ms",
    "engine": revision(ROOT.parent / "boomkat"),
    "runtime": revision(ROOT),
    "versions": {label: subprocess.check_output([str(binaries[label]), "--version"], text=True).strip()
                 for label in ["node", "bun"]},
    "server_sha256": {label: hashlib.sha256(Path(command(label)[-3]).read_bytes()).hexdigest() for label in binaries},
    "comparison": "Established server API workloads: Node uses node:http and cached JSON; Bun uses async Bun.serve fetch; Boomkat uses synchronous fetch with deferred results where needed.",
    "sha256": {label: hashlib.sha256(path.read_bytes()).hexdigest() for label, path in binaries.items()},
    "results": results,
}

with tempfile.TemporaryDirectory(prefix="native-web-bench-") as temp:
    upload = Path(temp) / "post.lua"
    upload.write_text('wrk.method = "POST"\nwrk.body = string.rep("a", 1024)\n')
    labels = list(binaries)
    for round_index in range(opts.rounds):
        # Rotate the starting binary and alternate direction to distribute drift.
        order = labels[round_index % len(labels):] + labels[:round_index % len(labels)]
        if round_index % 2:
            order.reverse()
        for workload in ["hello", "json", "async", "timer", "echo", "stream", "file"]:
            for label in order:
                with tempfile.TemporaryFile() as log:
                    server = subprocess.Popen(command(label), stdout=log, stderr=log)
                    try:
                        for _ in range(100):
                            if server.poll() is not None:
                                log.seek(0)
                                raise RuntimeError(log.read().decode())
                            if subprocess.run(["curl", "-fs", "-m", "1", "http://127.0.0.1:18149/hello"],
                                              capture_output=True).returncode == 0:
                                break
                            time.sleep(.03)
                        else:
                            raise RuntimeError("server did not start")
                        args = ["-s", str(upload)] if workload == "echo" else []
                        route = workload
                        url = f"http://127.0.0.1:18149/{route}"
                        warm = subprocess.run(["wrk", "-t2", "-c128", "-d1s", *args, url],
                                              capture_output=True, text=True, check=True)
                        if "Socket errors" in warm.stdout or "Non-2xx" in warm.stdout:
                            raise RuntimeError(warm.stdout)
                        load = subprocess.Popen(["wrk", "-t2", "-c128", "-d3s", "--latency", *args, url],
                                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                        rss = 0.0
                        while load.poll() is None:
                            rss = max(rss, int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(server.pid)])) / 1024)
                            time.sleep(.1)
                        output, error = load.communicate()
                        if load.returncode or "Socket errors" in output or "Non-2xx" in output:
                            raise RuntimeError(output + error)
                        if server.poll() is not None:
                            log.seek(0)
                            raise RuntimeError(log.read().decode())
                        latency = {}
                        for percentile in ["50", "99"]:
                            value, unit = re.search(rf"{percentile}%\s+([\d.]+)(us|ms|s)", output).groups()
                            latency[percentile] = float(value) * {"us": .001, "ms": 1, "s": 1000}[unit]
                        row = {"req_s": float(re.search(r"Requests/sec:\s+([\d.]+)", output).group(1)),
                               "latency_ms": latency, "peak_rss_mib": rss, "wrk": output}
                        results.setdefault(workload, {}).setdefault(label, []).append(row)
                        opts.report.write_text(json.dumps(metadata, indent=2) + "\n")
                        print(round_index + 1, workload, label, row["req_s"], latency, round(rss, 2), flush=True)
                    finally:
                        server.terminate()
                        server.wait(timeout=5)

for workload, data in results.items():
    medians = {label: statistics.median(row["req_s"] for row in rows) for label, rows in data.items()}
    print(workload, json.dumps(medians), flush=True)
