# 005 — libwebsockets SMP

Homebrew ships `LWS_MAX_SMP 1`, so `count_threads` was silently clamped and the
binding's SMP API was inert. Rebuilt v5.0.0 from source with `LWS_MAX_SMP=8`
(`scripts/build_lws.sh`); `LWS_WITH_HTTP3=OFF` because HTTP3 force-enables
GnuTLS, which then fails to link.

ABI verified identical to homebrew (context_info 880, protocols 56,
client_info 264; port/protocols/count_threads/options/vhost_name offsets all
match), so the C3 bindings stay valid.

Threading uses lws's own SMP: `count_threads` + one `lws_service_tsi` loop per
thread, one boomkat runtime each, `tlocal` Worker. No socket handoff needed —
lws distributes accepts itself.

`wrk -t2 -c512 -d8s`:

| threads | req/s | p50 | p99 |
|---:|---:|---:|---:|
| 1 | 103,959 | 60 µs | 127 µs |
| **2** | **157,057** | 72 µs | 194 µs |
| 4 | 132,342 | 161 µs | 501 µs |
| 8 | 99,806 | 323 µs | 2.65 ms |

**+51% at 2 threads** and the tail stays under 200 µs — still ~16x better than
the uWS build's p99 at its own best config.
