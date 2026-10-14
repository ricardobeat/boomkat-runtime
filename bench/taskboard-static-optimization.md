# Taskboard static response optimization

Baseline: runtime `643b07e`. Real Taskboard JS entry module (207 bytes) with its five normal security/content headers. Same total 128 connections, two wrk threads, 1 second warmup and 4 measured seconds. Two trials per binary, alternating baseline/candidate then candidate/baseline. Values below are medians; request rates are totals across all server workers, including main.

| Workload | 1 worker req/s before → after | 1 worker p50 / p99 ms before → after | 4 workers req/s before → after | 4 workers p50 / p99 ms before → after | Errors | RSS MiB before → after (1 / 4 workers) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JS entry module | 307,326 → 339,438 (+10.4%) | 0.356 / 0.765 → 0.295 / 0.665 | 239,034 → 240,205 (+0.5%, noise) | 0.288 / 0.416 → 0.285 / 0.410 | 0 | 33.7 → 33.6 / 89.0 → 88.6 |

## What changed

Static `Response` routes already snapshot their immutable application headers and body at `serve()` time, bypassing guest execution on every request. We now serialize those headers and the status line at registration instead of scanning newline-delimited headers on every request. One native call writes the entire application header block and ends the response, replacing four buffer writes per individual header. uWebSockets still owns Date, body framing, connection-close state, corking, and backpressure. Dynamic responses are unchanged. Worker shutdown frees the prepared buffers.

## Why multiple workers are still slower here

The server samples show native HTTP parsing, socket sends/receives and `kevent`, with no VM dispatch on the fixed route. A connection stays on its assigned VM; there is no per-request worker handoff. The load generator samples likewise spend most active time in socket read/write calls. This tiny workload has little application CPU work to distribute: one worker uses about 97% CPU, while four use about 270% for less throughput. The extra loops do not make the network path cheaper. Additional scheduling, event delivery and smaller batches are plausible causes; these profiles do not identify an exact kernel lock or isolate their individual costs. `kevent` wait samples are wall time, not CPU time.

Header batching reduces one-worker CPU cost per request, but does not remove the four-worker network bottleneck. Raising client threads from 2 to 8 in a separate diagnostic also worsened throughput (218,775 req/s) and p99 (12.94 ms); that diagnostic is not included in the controlled medians.

## Rejected experiments

- macOS `write` instead of `send`: +0.34% at four workers, noise; reverted.
- Parse headers once but retain per-header native writes: +0.87% at four workers, noise; superseded by serialization.
- Distribute connections in groups of eight rather than individually: +0.30% at four workers, noise; reverted.

Raw trial metrics and diagnostic results: [taskboard-static-optimization.json](taskboard-static-optimization.json).

## Validation

Release and AddressSanitizer checks cover methods, route precedence, custom status text, duplicate Set-Cookie headers, filtering Content-Length/Transfer-Encoding, HEAD/204/304, legacy static routes, headers larger than the cork buffer, large bodies, repeated keep-alive requests, balanced worker distribution, and graceful/forced shutdown. Native C++ response code is also instrumented by AddressSanitizer; C3 runs with GC_VERIFY and POOL_BYPASS.
