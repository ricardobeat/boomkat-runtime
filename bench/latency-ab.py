#!/usr/bin/env python3
"""Interleave saved runtime binaries; record throughput, latency and server RSS."""
import argparse
import hashlib
import http.client
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
parser.add_argument("--binary", action="append", required=True, help="label=/absolute/path")
parser.add_argument("--binary-arg", action="append", default=[], help="label=argument (repeatable)")
parser.add_argument("--engine-revision", action="append", default=[], help="label=engine-revision")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--report", type=Path, required=True)
parser.add_argument("--workloads", default="hello,json,async,timer,echo,stream,file,changing")
parser.add_argument("--server", type=Path, default=ROOT / "bench/servers/bkr.js")
parser.add_argument("--bun", action="store_true", help="Include the established Bun server")
opts = parser.parse_args()
binaries = {label: Path(path) for label, path in (arg.split("=", 1) for arg in opts.binary)}
binary_args = {label: [] for label in binaries}
for arg in opts.binary_arg:
    label, value = arg.split("=", 1)
    binary_args[label].append(value)
if opts.bun:
    binaries["bun"] = Path(shutil.which("bun"))
def command(label):
    if label == "bun" and opts.bun:
        return [str(binaries[label]), str(ROOT / "bench/servers/bun.js"), "18149", str(ROOT / "bench/payload.txt")]
    return [str(binaries[label]), *binary_args[label], "--no-sandbox", "--allow-net", f"--allow-read={ROOT / 'bench'}",
            str(opts.server.resolve()), "18149", str(ROOT / "bench/payload.txt")]
results = {}
metadata = {
    "method": f"{opts.rounds} interleaved rounds; fresh server per workload/binary; "
              "wrk -t2 -c128; 1s warmup, 3s measured; RSS sampled every 100ms",
    "engine": subprocess.check_output(["git", "-C", str(ROOT.parent / "boomkat"), "rev-parse", "HEAD"], text=True).strip(),
    "runtime": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
    "sha256": {label: hashlib.sha256(path.read_bytes()).hexdigest() for label, path in binaries.items()},
    "results": results,
    "binary_args": binary_args,
    "engine_revisions": dict(arg.split("=", 1) for arg in opts.engine_revision),
    "candidate_source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in sorted((ROOT / "runtime").rglob("*")) if path.suffix in [".c3", ".js"]},
    "connection_checks": {},
    "server_sha256": {label: hashlib.sha256(Path(command(label)[-3]).read_bytes()).hexdigest() for label in binaries},
    "bun_version": subprocess.check_output([str(binaries["bun"]), "--version"], text=True).strip() if opts.bun else None,
}

with tempfile.TemporaryDirectory(prefix="native-web-bench-") as temp:
    upload = Path(temp) / "post.lua"
    upload.write_text('wrk.method = "POST"\nwrk.body = string.rep("a", 1024)\n')
    changing = Path(temp) / "changing.lua"
    changing.write_text('''local n = 0
request = function()
    n = (n + 1) % 127
    return wrk.format("GET", "/hello?request=" .. n, { ["Host"] = "example" .. n .. ".test", ["X-Test"] = tostring(n) })
end
''')
    labels = list(binaries)
    for round_index in range(opts.rounds):
        # Rotate the starting binary to distribute drift. Reversing a two-label
        # rotation would accidentally restore the same order every round.
        order = labels[round_index % len(labels):] + labels[:round_index % len(labels)]
        workloads = opts.workloads.split(",")
        workloads = workloads[round_index % len(workloads):] + workloads[:round_index % len(workloads)]
        for workload in workloads:
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
                        if round_index == 0 and workload == "hello":
                            clients = [http.client.HTTPConnection("127.0.0.1", 18149, timeout=2) for _ in range(128)]
                            try:
                                for client in clients: client.request("GET", "/hello")
                                for client in clients:
                                    response = client.getresponse()
                                    assert response.status == 200 and response.read() == b"hello world"
                                metadata["connection_checks"][label] = "128 simultaneous valid responses"
                            finally:
                                for client in clients: client.close()
                        args = ["-s", str(upload)] if workload == "echo" else ["-s", str(changing)] if workload == "changing" else []
                        route = "hello" if workload == "changing" else workload
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
