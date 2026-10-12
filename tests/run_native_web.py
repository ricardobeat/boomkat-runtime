#!/usr/bin/env python3
"""Compare native web API behavior with a saved baseline runtime."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def run(binary):
    argv = [str(binary), "--no-sandbox", str(ROOT / "tests/native-web.js")]
    if os.environ.get("BKR_WEB_GC_STRESS"):
        argv.append("stress")
    proc = subprocess.run(argv,
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "ERROR: AddressSanitizer" not in proc.stderr, proc.stderr
    return json.loads(proc.stdout)

actual = run(os.environ.get("BKR_BIN", ROOT / "out/bkr-perf"))
expected = run(os.environ.get("BKR_BASELINE_BIN", "/private/tmp/bkr-native-web-before"))
assert len(actual) == len(expected)
for row, baseline in zip(actual, expected):
    assert row == baseline, (row, baseline)
print(f"Native web API semantics: {len(actual)} differential cases passed")
