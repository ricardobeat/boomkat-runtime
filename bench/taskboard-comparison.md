# Taskboard: Boomkat / Bun

Each cell lists **Boomkat / Bun**. Bun 1.3.13 versus the preceding Boomkat run; both ran on this machine. Eight seconds of measurement after one second of warmup, two wrk threads (one at concurrency 1), fresh server per case. These are single closed-loop saturation runs, not confidence intervals.

Identical application body, SQL, authentication, permissions, limits and prepared-statement cache. System SQLite 3.54.0, WAL with FULL synchronization; ten authenticated accounts, four boards with 200 cards each, sixteen 128 KiB images. Both serve the same 26,575-byte frontend artifact for the asset workload; normal Bun startup uses its own TSX transpiler.

| Workload | req/s @1 | req/s @32 | req/s @128 | p50 ms @128 | p99 ms @128 | Errors @128 | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| JS asset | 42,427 / 39,493 | 177,419 / 111,530 | 164,253 / 102,049 | 0.62 / 0.85 | 1.65 / 2.80 | 0 / 0 | 32.8 / 71.1 |
| Board JSON, 200 cards | 1,873 / 3,578 | 2,337 / 4,352 | 2,245 / 4,413 | 56.19 / 28.54 | 60.19 / 37.62 | 142 / 0 | 44.3 / 135.1 |
| Image read, 128 KiB | 7,353 / 12,021 | 9,414 / 17,055 | 9,104 / 16,431 | 13.96 / 6.49 | 16.96 / 30.77 | 0 / 0 | 79.6 / 133.3 |
| Card update, 250 B | 6,641 / 12,090 | 7,968 / 16,444 | 7,533 / 16,630 | 15.67 / 7.31 | 32.75 / 10.91 | 0 / 0 | 44.4 / 97.9 |
| Mixed (70/20/10) | 2,390 / 4,401 | 2,885 / 5,575 | 2,723 / 6,025 | 44.53 / 21.04 | 81.66 / 24.30 | 34 / 0 | 47.3 / 146.5 |
| Image upload + delete, 128 KiB | 3,158 / 3,850 | 3,217 / 3,582 | 2,196 / 2,998 | 50.60 / 43.67 | 884.29 / 68.72 | 0 / 0 | 63.0 / 105.6 |

Errors were socket read/write errors in the Boomkat board/mixed cases; all completed workload responses in both runs were HTTP 200/201. Bun recorded zero errors at every tested concurrency.

Upload/delete throughput counts both API operations, roughly two requests per completed image cycle. Latency is wrk-reported request latency; RSS is sampled every 200 ms.

Both runtimes produced the same login protections: a 32-request burst at concurrency 8 returned 2 successes and 30 HTTP 429s; 45 sequential attempts returned 30 successes and 15 HTTP 429s. Database integrity, foreign keys, fixture card count and BLOB sizes passed after load.

Raw results: [Boomkat](taskboard-load.json), [Bun](taskboard-bun-load.json). Bun application: [server.bun.ts](../examples/taskboard/server.bun.ts). API/persistence, source parity and bidirectional password compatibility checks passed. The browser UI also passed with Bun's own emitted JavaScript: signup, boards, card edits/moves, image uploads, lists, teams, responsive navigation and logout.
