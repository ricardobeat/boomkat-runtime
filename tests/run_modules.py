#!/usr/bin/env python3
"""Equivalent import paths must share module state and class identity."""
import os
import json
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('BKR_BIN', ROOT / 'out/bkr'))
with tempfile.TemporaryDirectory(prefix='bkr-module-paths-') as directory:
    root = Path(directory)
    (root / 'nested').mkdir()
    (root / 'shared.ts').write_text('export class AppError extends Error {}; export const state = { count: 0 };')
    (root / 'nested/a.ts').write_text('import { AppError, state } from "../shared.ts"; export function visit() { state.count++; return new AppError("shared"); }')
    (root / 'nested/b.ts').write_text('export { AppError, state } from ".././shared.ts";')
    (root / 'main.ts').write_text('''
import { AppError, state } from "./shared.ts";
import { visit } from "./nested/a.ts";
import { AppError as Other, state as otherState } from "./nested/../nested/b.ts";
const error = visit();
if (Other !== AppError || !(error instanceof Other) || state !== otherState || state.count !== 1)
    throw new Error("module identity differs across relative paths");
const dynamic = await import("./nested/../shared.ts");
if (dynamic.AppError !== AppError || dynamic.state !== state) throw new Error("dynamic import duplicated module");
console.log("Relative module paths share state and class identity: passed");
''')
    with (root / 'main.ts').open('a') as script:
        script.write('const absolute = await import(' + json.dumps(str(root / 'nested' / '..' / 'shared.ts')) + '); if (absolute.state !== state || absolute.AppError !== AppError) throw new Error("absolute alias duplicated module");\n')
    result = subprocess.run([str(BIN), '--no-sandbox', '--no-prompt', f'--allow-read={root}', str(root / 'main.ts')],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout.strip())
