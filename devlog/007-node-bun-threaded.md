# 007 — node cluster and bun reusePort

Makes the comparison fair against the 2-thread C3 servers.
`wrk -t2 -c512 -d8s`.

| server | req/s | p50 | p99 |
|---|---:|---:|---:|
| node, 1 worker | 77,149 | 6.49 ms | 848.65 ms |
| node, 2 workers | **140,666** | 3.39 ms | 112.56 ms |
| bun, 1 process | 163,265 | 3.05 ms | 3.83 ms |
| bun, 2 processes | 164,598 | 3.01 ms | 4.09 ms |

node +82%: its cluster default SCHED_RR has the primary accept and hand out
connections in userspace, sidestepping the kernel.

bun flat: `reusePort` relies on SO_REUSEPORT, which does not balance on macOS —
the same wall uWS hit in 004.
