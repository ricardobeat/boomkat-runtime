#!/usr/bin/env python3
"""Runs each workload against bkr, node and bun with wrk and prints a table.

  bench/run.py [seconds] [connections] [workload]

Per run: req/s and latency from wrk, CPU as server cpu-seconds over wall
seconds (100% is one core), memory as peak RSS sampled during the run.
"""
import os, re, subprocess, sys, time, signal

SECS = sys.argv[1] if len(sys.argv) > 1 else "3"
CONNS = sys.argv[2] if len(sys.argv) > 2 else "128"
ROOT = os.path.dirname(os.path.abspath(__file__))
PAYLOAD = os.path.join(ROOT, "payload.txt")
PORT = {"bkr": 18001, "node": 18002, "bun": 18003}
CMD = {
    "bkr": lambda p: [os.environ.get("BKR_BIN", os.path.join(ROOT, "..", "out", "bkr")), "--allow-net", f"--allow-read={ROOT}", os.path.join(ROOT, "servers/bkr.js"), str(p), PAYLOAD],
    "node": lambda p: ["node", os.path.join(ROOT, "servers/node.mjs"), str(p), PAYLOAD],
    "bun": lambda p: ["bun", os.path.join(ROOT, "servers/bun.js"), str(p), PAYLOAD],
}
WORKLOADS = [
    ("hello", "/hello", None),
    ("json", "/json", None),
    ("async immediate", "/async", None),
    ("async timer", "/timer", None),
    ("echo 1KB", "/echo", "POST"),
    ("stream 8KB", "/stream", None),
    ("file 4KB", "/file", None),
]
if len(sys.argv) > 3:
    WORKLOADS = [w for w in WORKLOADS if w[0] == sys.argv[3]]
    if not WORKLOADS:
        raise SystemExit(f"unknown workload: {sys.argv[3]}")
LUA = os.path.join(ROOT, "post.lua")
open(LUA, "w").write('wrk.method = "POST"\nwrk.body = string.rep("a", 1024)\n')

def ps(pid, field):
    out = subprocess.run(["ps", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return out

def cpu_seconds(pid):
    t = ps(pid, "time")
    m = re.match(r"(?:(\d+):)?(\d+):([\d.]+)", t)
    h, mi, s = m.groups()
    return int(h or 0) * 3600 + int(mi) * 60 + float(s)

def ms(v, unit):
    return float(v) * {"us": 0.001, "ms": 1, "s": 1000}[unit]

def wrk(port, path, method):
    cmd = ["wrk", "-t2", f"-c{CONNS}", f"-d{SECS}s", "--latency"]
    if method == "POST": cmd += ["-s", LUA]
    cmd.append(f"http://127.0.0.1:{port}{path}")
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def parse(out):
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
    lat = {}
    for p in ("50", "99"):
        v, u = re.search(rf"{p}%\s+([\d.]+)(us|ms|s)", out).groups()
        lat[p] = ms(v, u)
    v, u = re.search(r"Latency\s+[\d.]+\w+\s+[\d.]+\w+\s+([\d.]+)(us|ms|s)", out).groups()
    lat["max"] = ms(v, u)
    errs = re.search(r"Non-2xx or 3xx responses: (\d+)", out)
    socket_errs = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", out)
    errors = (int(errs.group(1)) if errs else 0) + (sum(map(int, socket_errs.groups())) if socket_errs else 0)
    return rps, lat, errors

results = {}
for name in CMD:
    port = PORT[name]
    proc = subprocess.Popen(CMD[name](port), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(100):
        if subprocess.run(["curl", "-fs", "-m", "1", f"http://127.0.0.1:{port}/hello"], capture_output=True).returncode == 0: break
        time.sleep(0.1)
    else:
        print(name, "failed to start:", proc.stderr.read().decode()[:300]); proc.kill(); continue
    for label, path, method in WORKLOADS:
        print(f"Running {name}: {label}", file=sys.stderr, flush=True)
        wrk(port, path, method)
        c0, t0 = cpu_seconds(proc.pid), time.time()
        peak = 0
        w = subprocess.Popen(["wrk", "-t2", f"-c{CONNS}", f"-d{SECS}s", "--latency"] + (["-s", LUA] if method else []) + [f"http://127.0.0.1:{port}{path}"], stdout=subprocess.PIPE, text=True)
        while w.poll() is None:
            r = ps(proc.pid, "rss")
            if r: peak = max(peak, int(r))
            time.sleep(0.2)
        out = w.stdout.read()
        cpu = (cpu_seconds(proc.pid) - c0) / (time.time() - t0) * 100
        rps, lat, errs = parse(out)
        results[(label, name)] = (rps, lat, cpu, peak / 1024, errs)
    proc.terminate(); proc.wait()

print(f"\nwrk -t2 -c{CONNS} -d{SECS}s, loopback, one server process each\n")
print("Values in each cell: Boomkat / Node / Bun. Error counts include socket and HTTP errors.\n")
print("| workload | req/s | p50 ms | p99 ms | max ms | CPU % | peak RSS MiB |")
print("|---|---:|---:|---:|---:|---:|---:|")
for label, _, _ in WORKLOADS:
    cells = [[] for _ in range(6)]
    for name in CMD:
        if (label, name) not in results:
            for cell in cells: cell.append("—")
            continue
        rps, lat, cpu, rss, errs = results[(label, name)]
        flag = f" ({errs} errors)" if errs else ""
        values = [f"{rps:,.0f}{flag}", f"{lat['50']:.2f}", f"{lat['99']:.2f}", f"{lat['max']:.1f}", f"{cpu:.0f}", f"{rss:.0f}"]
        for cell, value in zip(cells, values): cell.append(value)
    print(f"| {label} | " + " | ".join(" / ".join(cell) for cell in cells) + " |")
