# Native SQLite statement dispatch

Statement `.all()`, `.get()` and `.run()` use native receivers and bind positional arguments directly. Explicit arrays and named objects retain the JavaScript validation path. Receivers store stable IDs; finalization or database close invalidates future calls. No implicit SQLite finalization was added to GC.

SQLite and Taskboard regression tests passed in release and AddressSanitizer builds, including borrowed/invalid receivers, binding getters, error identity, method overrides, close and finalize.

A paired 4-second diagnostic on the same shared app measured baseline → candidate: board 4,033 → 4,111 req/s (+1.9%); image 18,279 → 18,977 (+3.8%); update 14,712 → 15,286 (+3.9%). All had zero errors. These are modest gains; short-run noise still applies.

The table below uses 8 seconds measured plus 1 second warmup per workload, 128 connections and 2 wrk threads. Fresh servers and disposable fixtures use identical shared app logic, authentication, authorization, CSRF checks, SQLite mmap settings and WAL/FULL durability. Peak RSS is sampled every 200 ms. Upload/delete counts both HTTP operations. Runs were sequential.

| Workload | Boomkat req/s | Bun req/s | Boomkat p50 / p99 ms | Bun p50 / p99 ms | Errors Boomkat / Bun | Peak RSS MiB Boomkat / Bun |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Board JSON (200 cards) | 4,020 | 5,052 | 31.85 / 32.73 | 25.22 / 25.88 | 0 / 0 | 49.8 / 125.7 |
| Image read (128 KiB) | 18,959 | 25,598 | 6.51 / 7.80 | 4.94 / 5.59 | 0 / 0 | 104.9 / 118.9 |
| Card update (250 B) | 15,387 | 17,449 | 7.98 / 10.46 | 7.14 / 8.59 | 0 / 0 | 37.2 / 95.7 |
| Mixed 70% board / 20% image / 10% update | 5,284 | 6,632 | 24.11 / 27.57 | 19.22 / 20.48 | 0 / 168 | 52.4 / 124.9 |
| Image upload + delete (128 KiB) | 3,963 | 3,391 | 33.03 / 52.01 | 38.15 / 62.57 | 0 / 1 | 94.2 / 134.7 |

Both passed database integrity, foreign-key, fixture-count and BLOB-length checks. Bun errors were socket errors, not failed HTTP statuses. Boomkat has not yet beaten Bun across the API workloads. Image peak memory is higher than the prior wrapper baseline (about 95 MiB); reduced transient allocation can change the GC cadence.

Raw reports: [Boomkat](taskboard-native-statements-bkr.json), [Bun](taskboard-native-statements-bun.json). Reports record the source base commit and dirty candidate status because these measurements preceded the candidate commit.
