#!/usr/bin/env python3
"""Alternate resource-management binaries and retain elapsed-time samples."""
import argparse, hashlib, json, statistics, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', action='append', required=True, help='label=/absolute/path')
p.add_argument('--rounds', type=int, default=5)
p.add_argument('--count', type=int, default=200000)
p.add_argument('--report', type=Path, required=True)
a = p.parse_args()
binaries = dict(item.split('=', 1) for item in a.binary)
report = {'count': a.count, 'rounds': a.rounds,
          'sha256': {k: hashlib.sha256(Path(v).read_bytes()).hexdigest() for k,v in binaries.items()},
          'script_sha256': hashlib.sha256((ROOT/'bench/using-micro.js').read_bytes()).hexdigest(), 'results': {}}
labels = list(binaries)
for i in range(a.rounds):
    order = labels[i % len(labels):] + labels[:i % len(labels)]
    for label in order:
        output = subprocess.check_output([binaries[label], '--no-sandbox', str(ROOT/'bench/using-micro.js'), str(a.count)], text=True, timeout=90)
        row = json.loads(output)
        assert row['checksum'] == 7 * (a.count + 1000), row
        report['results'].setdefault(label, []).append(row)
        a.report.write_text(json.dumps(report, indent=2)+'\n')
        print(i+1, label, row['ms'], flush=True)
for label, rows in report['results'].items():
    print(label, {name:statistics.median(row['ms'][name] for row in rows) for name in rows[0]['ms']})
