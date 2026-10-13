# Native header record initialization

Ordinary ASCII string records passed to Headers now fill the existing Map in C3.
The initializer preserves lowercase key overwrite order and trims ASCII whitespace.
A private prelude helper checks the intrinsic constructors, enumeration, iterator,
conversion and Map methods before filling any entries. Getters, proxies, cookies,
non-ASCII values, custom iterators and changed dependencies use the existing JS path.
This reduces constructor dispatch; database work, authorization and response content
remain unchanged. Snapshot caching is disabled. JIT is not involved.

## Uncached API results

Sequential runs use two wrk threads, 128 connections, a one-second warmup and eight
measured seconds per workload. The same shared Taskboard application runs on Bun.
The engine source is 4b3708bf. The baseline is the saved pre-experiment executable.
Timings vary across runs, so gains below are measurements of this run, not guarantees.

| Workload | Baseline req/s | BKR req/s | Change | Bun req/s | BKR p50/p99 ms | Bun p50/p99 ms | Errors BKR/Bun | Peak RSS MiB BKR/Bun |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Board JSON | 3,742 | 3,928 | +4.9% | 4,753 | 32.62/35.45 | 26.78/28.66 | 0/379 | 48.8/121.4 |
| Image read | 18,527 | 20,519 | +10.8% | 23,492 | 6.16/7.34 | 5.30/9.42 | 0/0 | 57.7/117.5 |
| Card update | 14,944 | 17,132 | +14.6% | 16,757 | 7.21/10.04 | 7.37/9.52 | 0/0 | 36.8/93.8 |
| Mixed API | 5,096 | 5,213 | +2.3% | 6,113 | 24.44/27.92 | 20.82/24.58 | 0/0 | 50.1/126.0 |
| Image upload + delete | 4,010 | 3,972 | -0.9% | 3,341 | 33.26/50.58 | 38.40/63.93 | 0/29 | 88.1/132.8 |

Bun errors are socket errors; successful HTTP responses have the expected status.
All fixtures passed SQLite integrity, foreign-key, card-count and image BLOB checks.
BKR leads update and upload/delete in this run, but Bun still leads board, image and
mixed workloads. This is not evidence of beating Bun across the Taskboard suite.
Raw results are stored alongside this report.

## Validation

- 118 differential web API cases against the saved executable, including record
  ordering, Unicode, getters, cookies, replaced globals and iterator mutations.
- AddressSanitizer: web differential cases, the real Taskboard API and concurrent
  native method/path routing all pass.
- Release Taskboard integration passes. The response cache remains opt-in.

## Other experiments removed

- Interning SQLite ASCII results up to the engine threshold reduced board throughput
  from 4,356 to 3,347 req/s (-23.2%); image was flat. The 64-byte bypass remains.
- Seeded word-at-a-time hashing was flat overall: board 4,356 to 4,304 req/s and
  image 20,804 to 21,122 req/s. The engine hashing change was removed.
- Replacing C3 SHA-256 with OpenSSL was flat for image reads (18,749 to 18,763 req/s)
  and only +1.5% for updates (15,845 to 16,080 req/s). C3 stdlib SHA-256 remains.
