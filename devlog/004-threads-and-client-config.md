# 004 — uWS threading, and the client config that hid it

## SO_REUSEPORT does not balance on macOS

4 threads, `ps -M`: one at 98.4%, three at 0.0%. Darwin delivers every
connection to one socket. Fixed with LocalCluster.h's technique — `preOpen` +
round-robin `adoptSocket` into sibling loops.

## wrk threads matter (c=128)

| srv threads | -t1 | -t2 | -t3 | -t4 |
|---:|---:|---:|---:|---:|
| 1 | 184,663 | **239,988** | 234,695 | 215,802 |
| 2 | 171,924 | 230,330 | 230,100 | 210,237 |
| 4 | 166,286 | 219,452 | 201,803 | 187,919 |

2 client threads win everywhere.

## Connection count changed the answer

Earlier "threads don't help" was an artifact of only testing c=128.
`wrk -t2`, two runs each:

| config | req/s | p50 | p99 |
|---|---:|---:|---:|
| 1 thr, c=512 | 219,487 / 229,256 | 2.04 ms | 4.69 / 6.76 ms |
| **2 thr, c=512** | **253,262 / 255,410** | **1.02 ms** | 2.07 / 1.96 ms |
| 3 thr, c=512 | 235,253 / 231,865 | 1.11 ms | 1.70 / 1.95 ms |
| 1 thr, c=32 | 218,378 / 217,875 | 112 µs | 394 / 352 µs |
| 2 thr, c=32 | 209,025 / 207,001 | **89 µs** | 419 / 428 µs |

2 server + 2 client threads = the 4 performance cores. 3rd makes it worse.

## Cores cannot be split explicitly

- `thread_policy_set(THREAD_AFFINITY_POLICY)` → 46 `KERN_NOT_SUPPORTED`. No
  pinning on arm64.
- `taskpolicy -b` (E-cores) makes wrk 15x too slow to measure with: 15,946 r/s
  vs 235,099 unclamped.
