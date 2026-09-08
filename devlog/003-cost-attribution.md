# 003 — where the per-request time goes

uWS build, 1 thread, `wrk -t3 -c128`.

| path | req/s |
|---|---:|
| HTTP only (`nojs` bypass) | 238,525 |
| HTTP + JS handler | 214,942 |

**The whole JS round-trip costs ~10% of throughput.** Caps what engine-side
tuning can win.

Also landed (free, but below noise): method strings interned once per worker
instead of per request; `as_string` (strict) instead of `to_display_string`
(coerces, runs JS on a value already a string).

## Memory: unbounded interning

Every distinct URL is interned and never reclaimed.

| | RSS |
|---|---:|
| startup | 5.5 MB |
| after 3.8M unique URLs | 317 MB |
| after 10s repeated URLs | 323 MB |

Throughput on unique URLs ~190k vs ~231k repeated. Real leak for unbounded URL
space. Needs a non-interning string path in boomkat.
