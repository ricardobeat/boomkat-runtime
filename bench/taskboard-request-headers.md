# Native request-header parsing and GC pacing

Native ASCII parsing replaces Headers._fromBlob splitting, normalization and map population through JavaScript. It returns an ordinary mutable Headers map with the same duplicate-header joining, value trimming and insertion order. Set-Cookie, non-ASCII input, patched globals/methods and prototype setters use the original implementation. Dependencies are checked without invoking getters.

Engine main commit `032bbaf7` fixes collector pacing: capped slices credit only completed work, and proportional collection covers native multi-property allocation batches. The native parser exposed insufficient GC progress by removing JavaScript loop safepoints. An instrumented board run grew to about 1 GiB and hundreds of thousands of registered strings. Keeping unpaid work alone was insufficient; the stronger proportional allowance restored board memory to about 49 MiB and regular idle phases. The existing 500 microsecond GC slice clock cap remains.

Validation: 100 native-web differential cases, SQLite, Taskboard API/persistence, native routing and HTTP lifecycle checks passed, including under ASAN. Engine incremental GC tests include capped/blocked work and 1,000 native row batches; all passed. All 42 Rosetta cases and 44 GC stress cases with the full marking oracle and pool bypass passed. Native lifetime, nursery-churn and large-container fixtures also passed.

Full comparison: each workload measured for 8 seconds after 1 second warmup, 128 connections and 2 wrk threads; sequential runs with fresh servers and disposable fixtures. Same shared app, real authorization/CSRF, SQLite mmap and WAL/FULL durability. Bun was freshly rerun with identical settings. Diagnostic/profiled timings are excluded.

| Workload | Boomkat before req/s | Boomkat now req/s | Bun req/s | Boomkat p50 / p99 ms | Bun p50 / p99 ms | Errors Boomkat / Bun | Peak RSS MiB Boomkat / Bun |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Board JSON (200 cards) | 4,248 | 4,358 | 4,989 | 29.41 / 30.61 | 25.43 / 26.81 | 0 / 420 | 48.5 / 125.8 |
| Image read (128 KiB) | 19,654 | 20,994 | 24,916 | 6.08 / 6.52 | 5.07 / 5.84 | 0 / 0 | 52.6 / 122.1 |
| Card update (250 B) | 16,041 | 16,982 | 17,348 | 7.17 / 9.78 | 7.17 / 8.70 | 0 / 0 | 36.9 / 96.0 |
| Mixed 70% board / 20% image / 10% update | 5,475 | 5,636 | 6,632 | 22.63 / 25.86 | 19.23 / 20.50 | 0 / 14 | 49.5 / 126.3 |
| Image upload + delete (128 KiB) | 3,924 | 4,053 | 3,408 | 32.88 / 45.58 | 37.89 / 61.78 | 0 / 1 | 83.8 / 134.2 |

Boomkat throughput improved 2.6–6.8% across these workloads against the preceding full run, with zero errors. Both runtimes passed database integrity, foreign-key, fixture-count and BLOB-length checks. Bun errors were socket errors. Upload/delete counts both operations; peak RSS is sampled every 200 ms. Reports record the pre-commit dirty parser candidate and the engine source commit.

The goal remains open: Bun leads board, image, update and mixed throughput. Updates are within about 2.1%; Boomkat leads upload/delete and uses less memory. Static assets and other concurrency levels have not been revalidated in this comparison.

Raw reports: [Boomkat](taskboard-request-headers-bkr.json), [Bun](taskboard-request-headers-bun.json). Previous baseline: [Boomkat](taskboard-native-headers-bkr.json).
