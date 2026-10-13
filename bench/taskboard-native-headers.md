# Native response headers and backing-store GC pressure

Commit `26d1974` accounts runtime-owned byte-buffer backing stores in the engine allocation budget. The native header candidate serializes ordinary Headers maps directly and lets ordinary 200 responses reach uWebSockets without the JavaScript send path. It preserves fallbacks for custom methods, getters, proxies, iterators, cookies, non-ASCII wire headers and custom response classification.

Validation: 77 native-web differential cases against the saved baseline, SQLite tests, Taskboard API/persistence tests, routing and HTTP lifecycle checks. ASAN passed these checks. New wire tests cover custom response/header methods, map iterators, duplicate cookies and Symbol.hasInstance getters. Release retention stress grew RSS by 4.9 MiB; ASAN with an 8 MiB quarantine grew 17.7 MiB. The ASAN default quarantine failed the stress RSS limit (349.4 MiB growth); bounding the quarantine distinguishes sanitizer-retained freed allocations from runtime retention.

In 4-second diagnostics the header-dispatch candidate without backing-store accounting measured image reads at 20,235 req/s, p50/p99 6.11/7.53 ms and 128.2 MiB peak RSS. Adding accounting measured 19,820 req/s, 6.42/6.89 ms and 51.3 MiB. Accounting exchanges about 2% throughput for much lower memory and a shorter latency tail. Duplicate SQLite reset/clear calls were also tested; the gain was negligible, so that experiment was reverted.

Full current run: 8 seconds measured plus 1 second warmup, 128 connections and 2 wrk threads per workload; sequential runs with fresh servers and disposable databases. Shared app logic, permissions, authentication/authorization, CSRF, mmap and WAL/FULL durability are unchanged. Bun results are the preceding unchanged-app report; Bun was not rerun for runtime-only changes.

| Workload | Boomkat before req/s | Boomkat now req/s | Bun req/s | Boomkat p50 / p99 ms | Bun p50 / p99 ms | Errors Boomkat / Bun | Peak RSS MiB Boomkat / Bun |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Board JSON (200 cards) | 4,159 | 4,248 | 5,052 | 30.22 / 31.32 | 25.22 / 25.88 | 0 / 0 | 49.8 / 125.7 |
| Image read (128 KiB) | 18,992 | 19,654 | 25,598 | 6.49 / 6.95 | 4.94 / 5.59 | 0 / 0 | 50.9 / 118.9 |
| Card update (250 B) | 15,466 | 16,041 | 17,449 | 7.62 / 10.13 | 7.14 / 8.59 | 0 / 0 | 37.2 / 95.7 |
| Mixed 70% board / 20% image / 10% update | 5,467 | 5,475 | 6,632 | 23.29 / 26.67 | 19.22 / 20.48 | 0 / 168 | 49.6 / 124.9 |
| Image upload + delete (128 KiB) | 3,988 | 3,924 | 3,391 | 33.77 / 52.39 | 38.15 / 62.57 | 0 / 1 | 85.7 / 134.7 |

Image and update throughput gained 3.5% and 3.7% against the prior full run. Image p99 improved 10.7% and memory fell 51%. Mixed was flat; upload/delete throughput fell 1.6%, remains ahead of the Bun reference, and used less memory. Upload/delete counts both operations. Both runtimes passed fixture integrity checks; Bun errors are socket errors. Small throughput differences on other workloads should not be treated as established gains.

The goal remains open: Bun still leads board, image, update and mixed throughput. The next profiling target is request-header parsing through Headers._fromBlob, which still performs split, normalization, append and map operations through JavaScript.

Raw current report: [Boomkat](taskboard-native-headers-bkr.json). References: [previous Boomkat](taskboard-json-scalars-bkr.json), [Bun](taskboard-native-statements-bun.json). The current report records the dirty native-header candidate before its commit.
