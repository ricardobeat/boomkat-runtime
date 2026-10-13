#!/usr/bin/env python3
"""Guard identical app bodies and bidirectional password interoperability."""
import json, os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'examples/taskboard'
BKR = os.environ.get('BKR_BIN', str(ROOT / 'out/bkr'))
BUN = os.environ.get('BUN_BIN') or shutil.which('bun')
# Both entry points load the exact same application; only adapters differ.
for entry, adapter in [('server.ts', './platform.ts'), ('server.bun.ts', './bun/platform.ts')]:
    expected = f'import * as platform from "{adapter}";\nimport {{ startTaskboard }} from "./server/application.ts";\n\nawait startTaskboard(platform);\n'
    assert (APP / entry).read_text() == expected, 'Application implementations diverged'

def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()

password = 'cross runtime password compatibility'
platform = json.dumps(str(APP / 'bun/platform.ts'))
with tempfile.TemporaryDirectory(prefix='taskboard-parity-') as directory:
    script = Path(directory) / 'password.js'
    script.write_text('import {hashPassword} from "crypto"; console.log(await hashPassword(' + json.dumps(password) + '));')
    bkr_hash = run([BKR, '--no-prompt', '--allow-read=' + directory, str(script)])
    bun_hash = run([BUN, '-e', f'import {{hashPassword,verifyPassword}} from {platform}; if (!await verifyPassword({json.dumps(password)},{json.dumps(bkr_hash)})) throw Error("BKR hash rejected"); console.log(await hashPassword({json.dumps(password)})); process.exit(0);'])
    script.write_text('import {verifyPassword} from "crypto"; if (!await verifyPassword(' + json.dumps(password) + ',' + json.dumps(bun_hash) + ')) throw Error("Bun hash rejected"); console.log("passed");')
    assert run([BKR, '--no-prompt', '--allow-read=' + directory, str(script)]) == 'passed'
print('Identical application logic and bidirectional Argon2id compatibility: passed')
