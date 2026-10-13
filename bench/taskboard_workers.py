#!/usr/bin/env python3
"""Measure total Taskboard throughput using runtime-owned server workers."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seconds", type=int, default=6)
parser.add_argument("--connections", type=int, default=128)
parser.add_argument("--workloads", default="asset,board,image,update,mixed,upload_delete")
parser.add_argument("--output", type=Path, default=ROOT / "bench/taskboard-workers.json")
options = parser.parse_args()
reports = []
for workers in [1, 2, 4]:
    output = options.output.with_name(options.output.stem + f"-{workers}.json")
    subprocess.run([
        sys.executable, str(ROOT / "bench/taskboard_load.py"),
        f"--http-workers={workers}", f"--seconds={options.seconds}",
        f"--connections={options.connections}", f"--workloads={options.workloads}",
        "--warmup=1", "--output=" + str(output),
    ], check=True)
    reports.append(json.loads(output.read_text()))
    options.output.write_text(json.dumps({"runs": reports}, indent=2) + "\n")

labels = {
    "asset": "JS entry module", "board": "Board JSON (200 cards)",
    "image": "Image read (128 KiB)", "update": "Card update (250 B)",
    "mixed": "Mixed 70% board / 20% image / 10% update",
    "upload_delete": "Image upload + delete (128 KiB)",
}
lines = [
    "| Workload | req/s: 1 worker | req/s: 2 workers | req/s: 4 workers | p50 / p99 ms: 1 worker | p50 / p99 ms: 2 workers | p50 / p99 ms: 4 workers | Errors: 1 / 2 / 4 | Peak RSS MiB: 1 / 2 / 4 |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
]
for workload in options.workloads.split(","):
    rows = [next(row for row in report["results"] if row["workload"] == workload) for report in reports]
    throughput = " | ".join(f"{row['rps']:,.0f}" for row in rows)
    latency = " | ".join(f"{row['p50_ms']:.2f} / {row['p99_ms']:.2f}" for row in rows)
    errors = " / ".join(str(row["errors"]) for row in rows)
    memory = " / ".join(f"{row['peak_rss_mib']:.1f}" for row in rows)
    lines.append(f"| {labels[workload]} | {throughput} | {latency} | {errors} | {memory} |")
markdown = "\n".join(lines)
options.output.with_suffix(".md").write_text(
    "# Taskboard HTTP worker scaling\n\n" + markdown + "\n\n"
    f"Total process throughput, {options.connections} total keep-alive connections, two wrk threads, "
    f"{options.seconds} measured seconds and one warmup second per case. One listener distributes connections "
    "round-robin across server VMs, including the main VM. Each VM opens its own connection to the same "
    "SQLite WAL database with FULL durability and a 5-second busy timeout. Authentication and membership "
    "checks run on every request; response snapshot caching is disabled. Upload/delete counts both operations. "
    "RSS covers the whole process. These are single trials; in-memory auth rate limits are per VM.\n"
)
print(markdown)
