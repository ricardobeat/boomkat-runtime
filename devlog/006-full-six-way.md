# 006 — full comparison, both C3 servers threaded

`wrk -t2 -c512 -d10s` (tuned client config from 004).

| server | req/s | p50 | p99 | rss |
|---|---:|---:|---:|---:|
| c3-uws-2t | **254,728** | 1.02 ms | 2.01 ms | 107 MB |
| c3-uws | 237,251 | 2.05 ms | 4.10 ms | 100 MB |
| bun | 162,322 | 2.92 ms | 5.85 ms | 38 MB |
| c3-lws-2t | 149,193 | 74 µs | 229 µs | 49 MB |
| c3-lws | 103,180 | **57 µs** | **118 µs** | 46 MB |
| node | 79,153 | 6.33 ms | 179.76 ms | 131 MB |

- Threading helps both C3 servers: lws +45%, uWS +7%.
- lws keeps a p99 under 250 µs even threaded — ~10-20x better tail than
  anything else here, at ~60% of uWS throughput.
- node's p99 blows out at this concurrency (179 ms); it is far better at -c64.
- RSS is sampled once post-load and is noisy; don't read much into it.
