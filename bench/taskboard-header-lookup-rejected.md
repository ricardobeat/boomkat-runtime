# Rejected native Headers lookup experiment

Native Headers.get/has was tested with ASCII normalization, direct Map lookup and fallbacks for cookies, non-ASCII/coerced keys, patched globals/methods, getters and proxies. The draft passed 113 differential cases and full Taskboard/routing tests after correcting an absent-header return from zero to null.

Matched diagnostic: 4 seconds measured, 1 second warmup, 128 connections, 2 wrk threads, same workload order and shared app. Saved baseline binary came from runtime bc649ba and engine 032bbaf7. Native lookup changed only the runtime implementation.

| Workload | Baseline req/s | Candidate req/s | Change | Baseline p50 / p99 ms | Candidate p50 / p99 ms | Errors baseline / candidate | Peak RSS MiB baseline / candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Card update | 17,055 | 17,262 | +1.2% | 7.16 / 9.74 | 7.05 / 9.63 | 0 / 0 | 37.3 / 37.4 |
| Image read (128 KiB) | 23,440 | 24,088 | +2.8% | 5.42 / 5.95 | 5.28 / 5.72 | 0 / 0 | 50.6 / 53.4 |
| Board JSON (200 cards) | 4,476 | 4,392 | -1.9% | 28.55 / 29.32 | 29.05 / 30.06 | 0 / 0 | 48.8 / 49.0 |

The gain did not justify about 100 additional native implementation lines: image gained 2.8%, update 1.2%, and board lost 1.9%. Native lookup code and draft tests were reverted. out/bkr was restored from the saved baseline binary. No change to the app, SQLite settings or benchmark workload was retained.

The unmatched prior image run suggested a much larger gain, but its fresh paired baseline was already faster. That difference was not attributed to the optimization. The next target is the larger SQL row materialization and JSON serialization pipeline.
