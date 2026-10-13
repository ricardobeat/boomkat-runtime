# Rejected Taskboard serialization experiments

The runtime baseline is `8cd6157`; the saved baseline executable uses engine
`032bbaf7`. Both experiments preserve authorization, queries, response content,
WAL and FULL durability. The fixture contains 200 cards per board. Measurements
use two wrk threads, 128 connections, a one-second warmup and four measured seconds.
These are diagnostic comparisons, not a new full Bun comparison.

## Direct SQLite JSON results

The prototype added `Statement.allJSON()` and composed its serialized arrays in
the board controller. It avoids guest row objects but leaked retained strings in
HTTP use. A collector diagnostic showed completed GC cycles and bounded live
objects, while large strings accumulated with reference count one. Isolated
native queries stayed bounded. Disabling a response-helper tail call isolated a
separate VM ownership bug, fixed in engine commit `f4ca628a` with ASAN and GC
stress coverage. Fixing that bug did not eliminate the prototype's remaining
SQL-array string retention.

The last release run with the tail-call fix produced 4,468 board requests/sec,
28.24/33.12 ms p50/p99 latency, zero errors and 1,494.1 MiB peak RSS. The ordinary
row path remained around 4,313 requests/sec with 49.2 MiB RSS. This is not a useful
tradeoff. All SQLite JSON API and application changes were removed; no leaking
prototype code is committed. Its remaining ownership issue is unresolved.

## Cached successful JSON escape scans

A lazy HString flag skipped subsequent scans of strings requiring no JSON
escaping, invalidating on in-place append. The candidate also contains the
separately validated tail-call fix, so this comparison cannot attribute small
changes exclusively to the flag. Neither measured API workload gained.

| Workload | Baseline req/s | Candidate req/s | Change | Baseline p50/p99 ms | Candidate p50/p99 ms | Errors baseline/candidate | Peak RSS MiB baseline/candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Board JSON | 4,313 | 4,277 | -0.8% | 29.73/30.69 | 29.83/31.91 | 0/0 | 49.2/48.8 |
| Mixed API | 5,562 | 5,552 | -0.2% | 22.89/26.22 | 22.98/26.07 | 0/0 | 51.5/52.1 |

Both fixtures passed integrity, foreign-key, card-count and image-BLOB checks.
Raw results are in `taskboard-json-scan-rejected-before.json` and
`taskboard-json-scan-rejected-after.json`. The cache flag and its implementation
were reverted. The retained engine change is a string-ownership correctness fix,
not a demonstrated Taskboard throughput win. Bun has not been beaten across the
Taskboard suite.
