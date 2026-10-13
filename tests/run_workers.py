#!/usr/bin/env python3
"""Exercise independent worker VMs and their native-resource ownership."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("BKR_BIN", ROOT / "out/bkr"))


def run(path, *args, flags=("-A",)):
    result = subprocess.run([
        str(BIN), "--no-sandbox", "--no-prompt", *flags, str(path), *map(str, args),
    ], text=True, capture_output=True, timeout=40)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ERROR: AddressSanitizer" not in result.stderr, result.stderr
    return result.stdout


with tempfile.TemporaryDirectory(prefix="bkr-workers-") as directory:
    directory = Path(directory)
    fixture = directory / "data.txt"
    fixture.write_text("worker fixture")
    print(run(ROOT / "tests/workers/main.js", fixture).strip())
    print(run(ROOT / "tests/workers/stress.js", fixture).strip())
    worker = ROOT / "tests/workers/permissions.ts"
    script = directory / "permissions.js"
    script.write_text(
        "const w = new Worker(" + json.dumps(str(worker)) + ");"
        "w.onerror = e => { throw new Error(e.message); };"
        "w.onmessage = e => {"
        "if (e.data.read !== 'PERMISSION_DENIED' || e.data.write !== 'PERMISSION_DENIED')"
        "throw new Error(JSON.stringify(e.data));"
        "console.log('Worker permissions inherited'); };"
        "w.postMessage({path:" + json.dumps(str(fixture)) + "});"
    )
    print(run(script, flags=(f"--allow-read={worker}",)).strip())
    assert fixture.read_text() == "worker fixture"
    script = directory / "denied.js"
    script.write_text(
        "let denied = false; try { new Worker(" + json.dumps(str(worker)) + "); }"
        "catch (e) { denied = e.code === 'PERMISSION_DENIED'; }"
        "if (!denied) throw new Error('worker escaped read permission');"
        "console.log('Worker entry read denied');"
    )
    print(run(script, flags=()).strip())
    worker = ROOT / "tests/workers/import-permissions.ts"
    script = directory / "import-denied.js"
    script.write_text(
        "const w = new Worker(" + json.dumps(str(worker)) + "); let denied = false;"
        "w.onerror = e => { e.preventDefault(); denied = true; };"
        "w.onmessage = () => { throw new Error('worker import escaped read permission'); };"
        "w.addEventListener('close', () => {"
        "if (!denied) throw new Error('missing worker import error');"
        "console.log('Worker dependency read denied'); });"
    )
    print(run(script, flags=(f"--allow-read={worker}",)).strip())
print("Workers: all checks passed")
