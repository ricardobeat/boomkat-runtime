# 001 — lws vs node vs bun

`wrk -t4 -c64 -d10s`. First working numbers.

| server | req/s | p50 | p99 | rss |
|---|---:|---:|---:|---:|
| c3-lws | 100,491 | 57 µs | 176 µs | 7.6 MB |
| node | 79,151 | 709 µs | 4.35 ms | 31.9 MB |
| bun | 125,519 | 405 µs | 3.31 ms | 4.5 MB |

Bun fastest, C3 wins latency by ~20x at the tail.
