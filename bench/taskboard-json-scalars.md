# Compact JSON scalar properties

Engine main commit `b9b230ff` writes scalar properties directly when a shared shape provides cached keys and there is no replacer or indentation. Objects, BigInt, symbols, omitted values and callbacks retain the generic processing path. Primitive serialization uses the same scalar implementation in both paths.

Validation: all local JSON fixtures, all 42 Rosetta cases, and JSON.stringify test262 (64 passed, 2 skipped, no failures). Local JSON fixtures and full Taskboard API tests also passed under AddressSanitizer.

Matched 4-second baseline/candidate diagnostics measured board throughput at 4,085 / 4,254 req/s (+4.1%) and mixed at 5,310 / 5,450 (+2.6%), with zero errors. A bounded SQLite repeated-text cache was also tried and removed: its throughput gain was too small to justify it.

Full validation below: 8 seconds measured, 1 second warmup, 128 connections, 2 client threads, sequential runs, fresh servers and disposable fixtures. Shared application and SQLite settings remain identical between ports: mmap enabled, WAL/FULL durability, real authentication/authorization and CSRF. Bun results are the preceding unchanged-app run from `taskboard-native-statements-bun.json`; Bun was not rerun for an engine-only change.

| Workload | Boomkat before req/s | Boomkat now req/s | Bun req/s | Boomkat p50 / p99 ms | Bun p50 / p99 ms | Errors Boomkat / Bun | Peak RSS MiB Boomkat / Bun |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Board JSON (200 cards) | 4,020 | 4,159 | 5,052 | 30.75 / 31.72 | 25.22 / 25.88 | 0 / 0 | 50.3 / 125.7 |
| Image read (128 KiB) | 18,959 | 18,992 | 25,598 | 6.50 / 7.78 | 4.94 / 5.59 | 0 / 0 | 104.6 / 118.9 |
| Card update (250 B) | 15,387 | 15,466 | 17,449 | 7.94 / 10.40 | 7.14 / 8.59 | 0 / 0 | 37.0 / 95.7 |
| Mixed 70% board / 20% image / 10% update | 5,284 | 5,467 | 6,632 | 23.33 / 26.82 | 19.22 / 20.48 | 0 / 168 | 51.5 / 124.9 |
| Image upload + delete (128 KiB) | 3,963 | 3,988 | 3,391 | 33.13 / 49.37 | 38.15 / 62.57 | 0 / 1 | 94.3 / 134.7 |

Boomkat passed database integrity, foreign-key, fixture-count and BLOB-length checks. Bun socket errors are included in its error count. Upload/delete counts both HTTP operations. Peak memory is sampled every 200 ms. These are saturation measurements; small differences on workloads that serialize tiny responses are within short-run noise.

The goal remains unachieved: Bun leads in board, image, update and mixed throughput. The board profile still points to SQLite stepping/row conversion and serialization; its main-thread self samples included 13.5% SQLite VM, 6.5% memmove, 5.2% JSON string escaping, 3.8% string interning, and 3.4% JSON value serialization. Profiled timings were not used in the table.

Raw current report: [Boomkat](taskboard-json-scalars-bkr.json). Previous reports: [Boomkat](taskboard-native-statements-bkr.json), [Bun](taskboard-native-statements-bun.json).
