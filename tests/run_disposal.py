#!/usr/bin/env python3
"""Runtime disposal protocols, native TypeScript and async scope lifetime."""
import os
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
subprocess.run([os.environ.get("BKR_BIN", str(ROOT / "out/bkr")),
                "--no-sandbox", "--no-prompt", "--allow-net",
                str(ROOT / "tests/disposal.ts")], check=True, timeout=20)
