# 002 — uWebSockets frontend added

`wrk -t4 -c64 -d10s`, two runs.

| server | req/s | p50 | p99 |
|---|---:|---:|---:|
| c3-uws | 190,784 / 173,632 | 254 µs | 1.13 / 1.99 ms |
| bun | 152,646 / 158,266 | 356 µs | 1.28 / 0.86 ms |
| c3-lws | 94,862 / 90,079 | 56 µs | 270 / 304 µs |
| node | 80,561 / 84,793 | 749 µs | 1.90 / 1.51 ms |

Same engine and handler in both C3 servers, so the ~2x gap is purely the HTTP
frontend. uWS overtakes bun.
