#!/usr/bin/env python3
"""SQLite API, filesystem permissions, and native timeout regressions."""
import os
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("BKR_BIN", ROOT / "out/bkr"))
def run(script, flags=(), args=(), expected=0):
    result = subprocess.run([str(BIN), *flags, str(script), *map(str, args)],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == expected, result.stdout + result.stderr
    assert "ERROR: AddressSanitizer" not in result.stderr, result.stderr
    return result

run(ROOT / "tests/sqlite.js", ["--no-sandbox", "--no-prompt"])
with tempfile.TemporaryDirectory(prefix="bkr-sqlite-") as directory:
    path = Path(directory) / "db.sqlite"
    grants = ["--no-sandbox", "--no-prompt", f"--allow-read={directory}", f"--allow-write={directory}"]
    run(ROOT / "tests/sqlite-file.js", grants, [path, "create"])
    run(ROOT / "tests/sqlite-file.js", ["--no-sandbox", "--no-prompt", f"--allow-read={directory}"], [path, "readonly"])
    run(ROOT / "tests/sqlite-file.js", ["--no-sandbox", "--no-prompt"], [path, "deny"])
    # Granting just the main filename must not implicitly authorize sidecars.
    run(ROOT / "tests/sqlite-file.js", ["--no-sandbox", "--no-prompt", f"--allow-read={path}", f"--allow-write={path}"], [path, "deny"])
    run(ROOT / "tests/sqlite-file.js", grants, [Path(directory) / "revoked.sqlite", "revoke"])
    # SQLite grants follow the link's location, not its target. Normalize '..'
    # before checking the location so lexical traversal cannot widen the grant.
    with tempfile.TemporaryDirectory(prefix="bkr-sqlite-outside-") as outside:
        target = Path(outside) / "target.sqlite"
        outside_grants = ["--no-sandbox", "--no-prompt", f"--allow-read={outside}", f"--allow-write={outside}"]
        run(ROOT / "tests/sqlite-file.js", outside_grants, [target, "create"])
        link = Path(directory) / "link.sqlite"
        link.symlink_to(target)
        run(ROOT / "tests/sqlite-file.js", ["--no-sandbox", "--no-prompt", f"--allow-read={directory}"], [link, "readonly"])
        run(ROOT / "tests/sqlite-file.js", ["--no-sandbox", "--no-prompt", f"--allow-read={directory}", f"--deny-read={link}"], [link, "deny"])
        writer = Path(directory) / "linked-write.js"
        writer.write_text('import {Database} from "sqlite"; import {args} from "process"; const db=new Database(args[0]); db.exec("INSERT INTO t VALUES (\'through link\')"); db.close();')
        run(writer, grants, [link])
        import sqlite3
        with sqlite3.connect(target) as connection:
            assert connection.execute("SELECT v FROM t ORDER BY rowid").fetchall() == [("persisted",), ("through link",)]
        run(ROOT / "tests/sqlite-file.js", grants, [Path(directory) / ".." / Path(outside).name / "target.sqlite", "deny"])
    script = Path(directory) / "timeout.js"
    script.write_text('import {Database} from "sqlite"; const db=new Database(); db.query("WITH RECURSIVE t(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM t WHERE n<1000000000) SELECT sum(n) FROM t").get();')
    result = run(script, ["--no-sandbox", "--no-prompt", "--time-limit=10"], expected=1)
    assert "interrupt" in result.stderr.lower() or "time limit" in result.stderr.lower(), result.stderr
print("SQLite API, open-time permissions, symlinks, readonly, retained handles and timeout: passed")

if sys.platform == "darwin":
    with tempfile.TemporaryDirectory(prefix="bkr-sqlite-loader-") as directory:
        for mode in ["missing", "partial"]:
            library = Path(directory) / (mode + ".dylib")
            command = ["cc", "-dynamiclib", str(ROOT / "tests/sqlite-loader.c"), "-o", str(library)]
            if mode == "missing": command.append("-DSQLITE_TEST_MISSING")
            subprocess.run(command, check=True, capture_output=True)
            environment = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library))
            result = subprocess.run([str(BIN), "--no-sandbox", "--no-prompt", str(ROOT / "tests/sqlite-unavailable.js")],
                                    env=environment, capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, mode + ": " + result.stdout + result.stderr
            assert "sqlite unavailable: passed" in result.stdout, result.stdout
    print("Missing/incomplete system SQLite: passed")
