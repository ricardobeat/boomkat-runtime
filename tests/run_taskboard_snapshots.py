#!/usr/bin/env python3
"""Exercise snapshot coherence through both runtime SQLite implementations."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="taskboard-snapshots-") as folder:
    path = str(Path(folder) / "db.sqlite")
    for runtime in ("bkr", "bun"):
        command = ([os.environ.get("BKR_BIN", str(ROOT / "out/bkr")), "--no-sandbox", "--no-prompt",
                    f"--allow-read={folder}", f"--allow-write={folder}"] if runtime == "bkr"
                   else [os.environ.get("BUN_BIN", "bun")])
        result = subprocess.run([*command, str(ROOT / "tests/taskboard-snapshots.js"), path + runtime],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, runtime + "\n" + result.stdout + result.stderr
        assert "AddressSanitizer" not in result.stderr, result.stderr
        print(runtime + ": " + result.stdout.strip())
