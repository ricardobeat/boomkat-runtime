# test-server

A tiny JS-backed HTTP server in C3: **libwebsockets** accepts the request,
the **boomkat** JS engine runs the handler, and whatever the handler returns
becomes the response body. Built to be compared against equivalent node and
bun servers.

There are two C3 servers, built as separate binaries, differing only in the
HTTP frontend. The JS half is identical in both.

```
src/main.c3          C3 server on libwebsockets  -> out/test-server
src-uws/main.c3      C3 server on uWebSockets    -> out/test-server-uws
shim/uws_shim.cpp    extern "C" shim over uWebSockets (C++)
scripts/build_uws.sh builds vendor/libuws_shim.a (uSockets + shim)
bench/server.node.js node equivalent
bench/server.bun.js  bun equivalent
bench/run.sh         runs all four under wrk and prints a summary
```

The handler is the same three lines in all four servers:

```js
function handler(method, url) {
    return method + " " + url;
}
```

## Build and run

```sh
# libwebsockets version
c3c build test-server
./out/test-server 8080

# uWebSockets version -- build the C++ shim first
./scripts/build_uws.sh
c3c build test-server-uws
./out/test-server-uws 8080

curl localhost:8080/hello      # -> GET /hello  (either binary)
```

## How it works

boomkat is embedded through its **native C3 binding**
(`bindings/c3/boomkat.c3`), not the C ABI, so values stay typed and no string
is copied across an ABI boundary.

The handler is compiled **once** at startup. `BOOTSTRAP`'s trailing expression
is `handler`, so `eval` hands back the function object itself, which is kept
as a rooted `JsValue` for the life of the process. Each request is then a
direct call on that value — nothing in the hot path compiles JS.

That required adding a top-level call API to the binding; see below.

Per request the server does: read the URI token from lws, intern two JS
strings, call the handler, read the result back, write headers and body. The
two argument values and the result are released each request, and the whole
step runs inside a `@pool()` so the temp arena is reset per request rather
than growing for the life of the process.

## The uWebSockets version

uWebSockets is header-only C++ templated on the SSL flag, so C3 cannot bind it
directly. `shim/uws_shim.cpp` wraps it in a single `extern "C"` entry point:

```c
int uws_serve(int port, uws_req_cb cb, void *user, size_t max_body);
```

The shim owns the accept loop and calls back once per request with the method
and URL, taking the body, length and status back through out-parameters. The
callback runs on the loop thread, one request at a time, which is what the
single-threaded JS runtime needs anyway.

`scripts/build_uws.sh` compiles uSockets (`bsd`, `context`, `loop`, `socket`,
`udp`, `epoll_kqueue`) plus the shim into `vendor/libuws_shim.a`. It is a
script rather than part of `project.json` because c3c's `c-sources` drive a C
compiler and the shim needs a C++ one. Built with `LIBUS_NO_SSL` and
`UWS_NO_ZLIB`: this server speaks plain HTTP and never negotiates
permessage-deflate, so neither dependency is pulled in.

uWebSockets is vendored as a real checkout at `vendor/uWebSockets` (v20.80.0,
shallow clone with submodules), unlike boomkat.

Both binaries return byte-identical bodies on every path tested, including the
query-string behaviour: `lws_hdr_copy(WSI_TOKEN_GET_URI)` and uWS's
`req->getUrl()` both give the path without the query.

## Changes made to boomkat

The native binding had no way to call a JS function from host code — its
README says as much: *"There is no top-level call API. You cannot use
`rt.call(fn, args)` from outside a callback; wrap the call in JS source and
`eval` it."* Doing that would have compiled a source string on every request,
which would have measured the compiler rather than the engine.

The engine already supported it — the C ABI's `bk_call` handles the
outside-a-callback case via `heap.call_fn`. It was only missing from the
native binding. Added to `bindings/c3/boomkat.c3`:

| Added | Purpose |
|---|---|
| `JsRuntime.call(func, args, this_value)` | call a JS function from host code |
| `JsRuntime.string/number/boolean/null_value` | build rooted values to pass as arguments |

`JsRuntime.call` mirrors `bk_call`'s top-level branch, including separating an
interrupt from an ordinary throw the way `vm_fault` does. The `JsCtx` versions
of these already existed but are scoped to a callback, so they are unusable
here.

**The boomkat source tree is linked in place**, not vendored: `project.json`
points absolute paths at `/Users/rtomasi/Projects/boomkat`. `vendor/libboomkat.dylib`
is currently unused — it is the C ABI build, and the native binding compiles
the engine from source instead. This is the open question from the start of
the session and is worth settling: the project won't build on another machine
as it stands, and the benchmark isn't pinned to a known engine revision.

## Benchmark

```sh
./bench/run.sh [duration] [connections] [threads]   # defaults: 10s 64 4
```

All three servers are single-threaded event loops on loopback, warmed up, then
measured by `wrk`. The script checks all three return the identical body before
timing them.

### Results

macOS arm64 (Darwin 24.6.0, 4 performance + 4 efficiency cores), c3c 0.8.3
`-O3`, node v26.0.0, bun 1.0.25, libwebsockets 5.0.0 (rebuilt with
`LWS_MAX_SMP=8`), uWebSockets v20.80.0. `wrk -t2 -c512 -d10s` — see Tuning for
why those client settings.

`-2t` is the two-thread configuration of the same binary. node and bun run
single-threaded, so compare them against the single-threaded C3 rows.

| server | req/sec | p50 | p99 |
|---|---:|---:|---:|
| c3 + uWebSockets, 2 threads | **254,728** | 1.02 ms | 2.01 ms |
| c3 + uWebSockets | 237,251 | 2.05 ms | 4.10 ms |
| bun | 162,322 | 2.92 ms | 5.85 ms |
| c3 + libwebsockets, 2 threads | 149,193 | 74 µs | 229 µs |
| c3 + libwebsockets | 103,180 | **57 µs** | **118 µs** |
| node | 79,153 | 6.33 ms | 179.76 ms |

Same JS engine, same handler, same per-request work in both C3 servers — the
whole difference between them is the HTTP frontend.

The uWebSockets build wins throughput: ~2.3x the libwebsockets build and ~1.5x
bun single-threaded. The libwebsockets build inverts the trade completely: a
p99 of 118 µs against everyone else's milliseconds — **one to three orders of
magnitude better at the tail**, held at 512 concurrent connections, for about
60% of the throughput. It writes each response synchronously inside the
callback instead of queueing it.

Threading helps both: libwebsockets +45%, uWebSockets +7%, and lws still holds
a 229 µs p99 with two threads.

node's p99 of 180 ms at this concurrency is its own story; it is far better
behaved at `-c64`.

### Caveats, read these before quoting the numbers

- **Two runs, not averaged.** Both are shown above. Run it a few more times
  before believing a difference under ~10%.
- **The tail gap is partly a buffering difference, not just speed.** lws
  writes the response synchronously inside the callback; the others queue
  through their own output paths. The throughput and latency columns are not
  measuring quite the same thing.
- **Response bytes differ.** node, bun and uWS all add headers this
  libwebsockets server does not (`Date`, `Connection`, and uWS adds
  `uWebSockets: 20`), so transfer/sec is not comparable across the four even
  though the bodies are identical.
- **Loopback only**, so no real network, NIC or TLS cost is included.

## Tuning

Measured, not guessed. All on the uWebSockets build, `wrk -t3 -c128`, one
8-core machine (4 performance + 4 efficiency cores) shared with the load
generator.

### Where the time actually goes

`./out/test-server-uws <port> <threads> nojs` skips the JS engine and formats
the same response in C3. It exists only to attribute cost:

| path | req/sec |
|---|---:|
| HTTP only (`nojs`) | 238,525 |
| HTTP + JS handler | 214,942 |

**The whole JS round-trip — interning two strings, calling the handler, reading
the result back, rooting and releasing three values — costs about 10% of
throughput.** The HTTP frontend dominates. That caps what engine-side tuning
can win, and it is the main thing to know before optimising anything here.

Two JS-side changes are in anyway, since they are free:

- Method strings (`GET`, `POST`, …) are interned and rooted **once per worker**
  instead of per request, so the hot path interns only the URL.
- The result is read with `as_string` (strict) rather than `to_display_string`
  (coerces, which means running JS on a value that is already a string).
  `to_display_string` remains the fallback if a handler returns a non-string.

Neither moved the number outside noise, which is what the 10% ceiling predicts.

### Client settings, and why they changed the answer

`wrk` and the server contend for the same 4 performance cores, so the client
configuration is not neutral — it decides what you are measuring. Sweeping it:

| server threads | wrk -t1 | -t2 | -t3 | -t4 |
|---:|---:|---:|---:|---:|
| 1 | 184,663 | **239,988** | 234,695 | 215,802 |
| 2 | 171,924 | 230,330 | 230,100 | 210,237 |
| 4 | 166,286 | 219,452 | 201,803 | 187,919 |

Two client threads win everywhere: one cannot saturate the server, and three
or four start stealing cores from it.

### Threads

Both servers run one event loop **and one boomkat runtime** per thread. Nothing
is shared: the engine has no locking, but separate runtimes share no state, and
every runtime is opened and bootstrapped on the main thread before any worker
starts, so engine init and the compiler are never touched concurrently. C3 owns
the threads in both, because each needs `@pool_init` around its whole loop —
the temp allocator is thread-local and only created implicitly on the main
thread.

The two frontends need completely different machinery to get there.

**libwebsockets has SMP built in** — `count_threads` plus one
`lws_service_tsi(ctx, 0, tsi)` loop per thread, and lws distributes accepted
connections across them itself. No socket handoff needed. But the homebrew
build ships `LWS_MAX_SMP 1`, which silently clamps `count_threads` to 1 and
makes the whole API inert. `scripts/build_lws.sh` rebuilds v5.0.0 with
`LWS_MAX_SMP=8` (and `LWS_WITH_HTTP3=OFF`, since HTTP3 force-enables GnuTLS,
which then fails to link). The rebuilt library's structs are byte-identical to
homebrew's — `context_info` 880, `protocols` 56, `client_info` 264, and every
offset the bindings use — so the vendored C3 bindings stay valid. The server
also calls `lws_get_count_threads` after creating the context and warns if the
library gave it fewer threads than asked.

| lws threads | req/sec | p50 | p99 |
|---:|---:|---:|---:|
| 1 | 103,959 | 60 µs | 127 µs |
| **2** | **157,057** | 72 µs | 194 µs |
| 4 | 132,342 | 161 µs | 501 µs |
| 8 | 99,806 | 323 µs | 2.65 ms |

**uWebSockets has no equivalent, and `SO_REUSEPORT` alone does not work on
macOS.** With four threads, `ps -M` showed one thread at 98.4% and the other
three at 0.0%: the Darwin kernel delivers every connection to a single socket
instead of balancing across them, unlike Linux. The fix is the technique in
uWebSockets' own `LocalCluster.h` — hook `preOpen` and hand each accepted
socket to another loop with `adoptSocket`, round-robin, which does not depend
on kernel behaviour.

The shim reimplements that rather than including `LocalCluster.h`, which owns
its own threads (incompatible with the per-thread `@pool_init` a C3 worker
needs), is hardcoded to `SSLApp` and `hardware_concurrency`, uses a non-atomic
round-robin counter, and is marked "highly experimental" in its own header.

Whether threading *helps* depends on the connection count, which is what made
this easy to get wrong. At `-c128` a second uWS thread looks useless. At `-c32`
and `-c512` it is clearly worth having (`wrk -t2`, two runs each):

| config | req/sec | p50 | p99 |
|---|---:|---:|---:|
| 1 thread, c=512 | 219,487 / 229,256 | 2.04 ms | 4.69 / 6.76 ms |
| **2 threads, c=512** | **253,262 / 255,410** | **1.02 ms** | 2.07 / 1.96 ms |
| 3 threads, c=512 | 235,253 / 231,865 | 1.11 ms | 1.70 / 1.95 ms |
| 1 thread, c=32 | 218,378 / 217,875 | 112 µs | 394 / 352 µs |
| 2 threads, c=32 | 209,025 / 207,001 | **89 µs** | 419 / 428 µs |

**Two threads is the sweet spot for both frontends.** Two server threads plus
two client threads is exactly the four performance cores; a third server thread
makes it worse.

#### Cores cannot be split explicitly on this machine

The tidier fix would be to give the server 4 cores and the client the other 4.
That is not available on Apple Silicon:

- **There is no CPU pinning.** `thread_policy_set` with
  `THREAD_AFFINITY_POLICY` returns 46, `KERN_NOT_SUPPORTED` — the affinity API
  is gone on arm64, with no `sched_setaffinity` equivalent.
- **The only split is QoS, and it is badly asymmetric.** `taskpolicy -b`
  clamps a process to the 4 efficiency cores, but they cannot generate the
  load: an E-core-clamped `wrk` produces ~16k req/s against a server that
  handles 235k, about 15x too slow to be the measuring instrument.

| | req/sec |
|---|---:|
| 1 server thread, E-core client | 15,946 |
| 4 server threads, E-core client | 29,318 |
| 1 server thread, normal client | 235,099 |
| 4 server threads, normal client | 201,831 |

So the client settings above are the available lever, and tuning them is what
surfaced the two-thread win. Measuring scaling beyond ~2 threads still needs
the client on a separate machine.

### Unbounded interning — the one real problem found

Every distinct URL is interned into the engine's string table, and interned
strings are not reclaimed. Driving 3.8M unique paths:

| | RSS |
|---|---:|
| at startup | 5.5 MB |
| after 3.8M unique URLs | 317 MB |
| after 10s of repeated URLs | 323 MB |

**Memory does not come back.** Throughput on unique URLs also drops to ~190k
from ~231k on a repeated one, as the intern table grows. For a benchmark
hitting one path this is invisible; for a real server with unbounded URL
space it is a leak. Fixing it means either a non-interning string constructor
in boomkat, or passing the URL to JS some way that does not mint a permanent
heap string.

## Known limitations

- **The query string is dropped.** `lws_hdr_copy(WSI_TOKEN_GET_URI)` returns
  the path only, so `/a/b?q=1` reaches the handler as `/a/b`. The arguments
  live in `WSI_TOKEN_HTTP_URI_ARGS` and are not read yet.
- **Only GET, POST and OPTIONS are recognised by the libwebsockets build.**
  Those are the URI tokens it is verified to expose; anything else reports as
  `GET /`. The uWebSockets build has no such limit — it reports whatever
  method arrived.
- **Response bodies cap at 8 KB** in both servers, and are dropped with a
  fault (libwebsockets) or silently truncated (uWebSockets) above that rather
  than chunked.
- **One request at a time.** The runtime is single-threaded, which boomkat
  requires — the engine keeps process-global state and refuses a second
  `open`.
