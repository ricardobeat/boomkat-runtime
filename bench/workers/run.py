#!/usr/bin/env python3
"""Run fixed-work worker scaling trials and sample whole-process peak RSS."""
import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--output", type=Path, default=Path(__file__).with_name("results.json"))
options = parser.parse_args()
assert options.runs > 0
binary = Path(os.environ.get("BKR_BIN", ROOT / "out/bkr")).resolve()
rows = []
for trial in range(options.runs):
    # Alternate order to reduce thermal/order bias.
    for count in ([1, 2, 4] if trial % 2 == 0 else [4, 2, 1]):
        process = subprocess.Popen([
            str(binary), "--no-sandbox", "--allow-read=" + str(ROOT / "bench/workers"),
            str(ROOT / "bench/workers/main.ts"), str(count),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        peak = 0
        try:
            while process.poll() is None:
                rss = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True, text=True).stdout.strip()
                if rss:
                    peak = max(peak, int(rss) / 1024)
                time.sleep(0.04)
            stdout, stderr = process.communicate()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        assert process.returncode == 0, stdout + stderr
        row = json.loads(stdout)
        row.update(trial=trial, peak_rss_mib=peak)
        rows.append(row)
        print(json.dumps(row), flush=True)
summary = []
for count in [1, 2, 4]:
    matching = [row for row in rows if row["workers"] == count]
    summary.append({"workers": count, **{
        key: round(statistics.median(row[key] for row in matching), 2)
        for key in ["startup_ms", "work_ms", "total_ms", "peak_rss_mib"]
    }})
report = {
    "date_utc": datetime.now(timezone.utc).isoformat(),
    "system": platform.platform(), "binary": str(binary),
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "iterations_per_trial": 200_000_000, "runs": rows, "median": summary,
}
options.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(summary, indent=2))
