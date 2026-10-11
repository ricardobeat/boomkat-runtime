# bkr

A small JavaScript runtime on the [boomkat](../boomkat) engine, uWebSockets and
OpenSSL. ES modules with top-level await, web-standard globals, built-in modules
imported by bare name, and every capability denied until granted.

```js
import { serve } from "http";

serve({ port: 8080, fetch: (req) => new Response("hello") });
```

```sh
c3c build bkr
./out/bkr --allow-net hello.js
```

There is no Node compatibility layer and no npm: a bare specifier is either a
built-in or an error, and remote imports are not supported.

## Modules

| module | surface |
|---|---|
| `http` | `serve({ port, hostname, fetch, onListen })` -> `{ port, finished, stop(force) }` |
| `net` | `connect({ hostname, port, tls })`, `listen({ hostname, port })`, `resolve(host)`; connections expose `read`, `write`, `closeWrite`, `close`, `readable`, `writable` |
| `file` | `body`, `read`, `readText`, `write`, `writeText`, `open`, `stat`, `list`, `mkdir`, `remove`, `rename`, `copy`, `exists` |
| `process` | `args`, `pid`, `exit`, `env`, `stdin`/`stdout`/`stderr`, `spawn`, `run` |
| `path` | `join`, `resolve`, `relative`, `dirname`, `basename`, `extname`, `parse`, `format`, `toFileUrl`, `fromFileUrl` |
| `permissions` | `query`, `request`, `revoke` |

`file.body(path)` creates a lazy response body:

```js
import { serve } from "http";
import { body } from "file";

serve({ port: 8080, fetch: () => new Response(body("./asset.bin")) });
```

The server checks read permission when it sends the body, reads at most 64 KiB
at a time, and pauses reads under socket backpressure. Disconnecting closes the
file after any outstanding read completes. The same body supports `text()`,
`bytes()`, `body`, and cloning through `Response`. Reading the body in JavaScript,
including accessing `response.body`, currently loads the file into memory;
the bounded native path applies when the server sends the untouched descriptor.

Globals: `fetch` (HTTP/1.1 over `net`, TLS with certificate and hostname
verification, redirects re-checked against the net grants), `Request`,
`Response`, `Headers`, `URL`, `URLSearchParams`, streams, `Blob`, `File`,
`AbortController`, `EventTarget`, `TextEncoder`/`TextDecoder`, `crypto`,
`performance`, timers, `structuredClone`, and an `unhandledrejection` event
(unhandled rejections end the process with status 1 unless prevented).

JS timers use nanosecond native re-arms on kqueue/epoll while retaining the
1 ms minimum JS delay. Each batch uses a fixed deadline cutoff so repeating
timers yield to another loop turn.

HTTP streams that close synchronously within a 64 KiB batch finish through
one native response call with a known content length. Larger and asynchronous
streams retain the backpressure path. Native file bodies resolve the working
directory only for relative paths.

`bkr check script.js` lists the built-ins a module graph imports and the
flags it will probably need.

Regression checks:

```sh
bash scripts/build_uws.sh
c3c build bkr-perf
./out/bkr-perf --no-sandbox tests/timers.js
./out/bkr-perf --no-sandbox tests/streams.js
BKR_HTTP_STRESS=1 BKR_BIN="$PWD/out/bkr-perf" python3 tests/run_http.py
c3c build bkr-perf-asan
BKR_BIN="$PWD/out/bkr-perf-asan" python3 tests/run_http.py
```

## Permissions

Deny by default. Grants come from flags, from a `boomkat.toml` beside the
script (or `--config`), and, on a terminal, from `[y/n/A]` prompts. Flags win
over the file. `net` is one permission (no listen/connect split) and takes
allowlists.

```sh
bkr --allow-net=api.example.com,:8080 --allow-read=./data --allow-write=./out app.js
bkr -A app.js                      # everything
bkr --deny-net=169.254.169.254 -A app.js
bkr --no-prompt app.js             # never ask
```

```toml
[permissions]
prompt = false
net = ["api.example.com", "*.cdn.example.com"]
read = ["./data"]
env = ["APP_*"]
run = ["git"]
```

A grant by name covers the public addresses it resolves to; reaching a
loopback or private address needs that address granted, so a hostile DNS answer
cannot turn `example.com` into the local network. Paths are canonicalized
before matching, so symlinks do not escape a grant.

When prompting is off the grants are fixed for the run, and bkr also applies a
Seatbelt sandbox (macOS) that denies the network, exec and writes the grants do
not cover (`--no-sandbox` turns that off).

`--time-limit=ms` interrupts JavaScript that runs longer than the limit; a
request that trips it gets a 500 and the server keeps serving.

## Layout

```
runtime/main.c3      entry, flags, boot
runtime/bridge.c3    the engine bridge: ops settle promises by id
runtime/loop.c3      event loop glue, kernel timer, thread pool
runtime/http.c3      serve on uWebSockets
runtime/net.c3       TCP/TLS sockets, DNS         runtime/tls.c3  client verification
runtime/fs.c3        files                        runtime/proc.c3 env, spawn
runtime/res.c3       resource table (stdio, files, sockets, pipes)
runtime/perms.c3     permission model             runtime/sandbox.c3
runtime/js/*.js      the prelude and the built-in modules
runtime/shim/        C++ shim over uWebSockets
bench/               workloads and the wrk driver
```

`scripts/setup_vendor.sh` fetches uWebSockets and re-applies the three small
patches uSockets needs (kqueue EOF with pending data, and TLS data decoded in
the same read as close_notify).

## Benchmarks

`BKR_BIN="$PWD/out/bkr-perf" python3 bench/run.py [seconds] [connections] [workload]`
starts each runtime on a loopback port and drives it with `wrk -t2`.
The optional workload argument selects a single workload, such as `"stream 8KB"`.

Apple M3, Node v24.13.0, Bun 1.3.13; 2s warm-up and 2s measured per workload,
128 connections. Client and server share the machine. Each runtime reuses one
server process, so peak RSS can reflect earlier workloads. Latencies are in ms.

| Workload | Boomkat req/s | p50 / p99 ms | Node req/s | p50 / p99 ms | Bun req/s | p50 / p99 ms | RSS MiB (Boomkat / Node / Bun) |
|---|---:|---:|---:|---:|---:|---:|---:|
| hello | 217,411 | 0.57 / 1.07 | 123,956 | 1.00 / 1.40 | 223,394 | 0.56 / 0.82 | 12 / 103 / 43 |
| json | 179,223 | 0.69 / 1.21 | 121,119 | 1.07 / 1.19 | 201,612 | 0.62 / 0.98 | 13 / 104 / 44 |
| async immediate | 143,705 | 0.75 / 1.71 | 141,104 | 0.89 / 1.74 | 182,952 | 0.63 / 1.33 | 14 / 186 / 48 |
| async timer | 113,364 | 1.08 / 1.44 | 74,601 | 1.44 / 2.76 | 114,616 | 1.10 / 1.53 | 14 / 186 / 49 |
| echo 1KB | 142,473 | 0.84 / 1.46 | 95,308 | 1.34 / 1.67 | 164,916 | 0.76 / 1.22 | 16 / 203 / 53 |
| stream 8KB | 60,855 | 1.95 / 2.54 | 85,087 | 1.49 / 2.88 | 109,847 | 1.14 / 1.49 | 16 / 204 / 84 |
| file 4KB | 94,738 | 1.18 / 2.75 | 53,928 | 2.31 / 3.07 | 51,511 | 2.45 / 2.85 | 18 / 224 / 86 |

The [full report](bench/server-stream-file-results.txt) includes maximum latency,
CPU usage, implementation differences between runtimes, and the profiling findings.
These are single full-suite samples. The [repeated before/after comparison](bench/stream-file-ablation.json)
uses the same engine and reverses measurement order across two repetitions.

Streaming improved about 4% in the repeated comparison, but still trails Node and
Bun. Remaining streaming costs are mostly VM execution and property access.
File throughput more than doubled after removing an unnecessary working-directory
lookup for absolute paths; p50 fell from 3.00 ms to 1.18 ms in the full-suite runs.
Permission and symlink checks remain in place.

Node precomputes its JSON body; Node/Bun async handlers also await
`Promise.resolve`, while Boomkat uses `.then` after the yield. Bun serves files
with `Bun.file`, and Boomkat uses native `file.body`.
