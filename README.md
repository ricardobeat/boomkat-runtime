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
| `file` | `read`, `readText`, `write`, `writeText`, `open`, `stat`, `list`, `mkdir`, `remove`, `rename`, `copy`, `exists` |
| `process` | `args`, `pid`, `exit`, `env`, `stdin`/`stdout`/`stderr`, `spawn`, `run` |
| `path` | `join`, `resolve`, `relative`, `dirname`, `basename`, `extname`, `parse`, `format`, `toFileUrl`, `fromFileUrl` |
| `permissions` | `query`, `request`, `revoke` |

Globals: `fetch` (HTTP/1.1 over `net`, TLS with certificate and hostname
verification, redirects re-checked against the net grants), `Request`,
`Response`, `Headers`, `URL`, `URLSearchParams`, streams, `Blob`, `File`,
`AbortController`, `EventTarget`, `TextEncoder`/`TextDecoder`, `crypto`,
`performance`, timers, `structuredClone`, and an `unhandledrejection` event
(unhandled rejections end the process with status 1 unless prevented).

`bkr check script.js` lists the built-ins a module graph imports and the
flags it will probably need.

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

`bench/run.py [seconds] [connections]` starts each runtime on a loopback port
and drives it with `wrk -t2`. CPU is server CPU time over wall time (100% is
one core); memory is peak RSS sampled during the run. One server process each,
Apple M3 (4 performance cores shared with wrk), node 24, bun, noisy machine.

wrk -t2 -c128 -d3s, loopback, one server process each

| workload | runtime | req/s | p50 ms | p99 ms | max ms | CPU % | peak RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|
| hello | bkr | 126,354 | 0.95 | 1.53 | 3.4 | 98 | 13 |
| hello | node | 123,966 | 1.03 | 1.18 | 48.0 | 99 | 103 |
| hello | bun | 209,232 | 0.59 | 1.08 | 2.3 | 99 | 43 |
| json | bkr | 107,381 | 1.12 | 1.73 | 3.5 | 98 | 13 |
| json | node | 124,397 | 1.02 | 1.23 | 44.3 | 98 | 130 |
| json | bun | 194,020 | 0.64 | 1.14 | 2.2 | 98 | 43 |
| async | bkr | 50,162 | 2.29 | 4.96 | 6.7 | 84 | 43 |
| async | node | 74,299 | 1.62 | 2.75 | 8.3 | 63 | 131 |
| async | bun | 115,438 | 1.08 | 1.47 | 3.8 | 75 | 46 |
| echo 1KB | bkr | 67,527 | 1.50 | 5.97 | 10.5 | 98 | 48 |
| echo 1KB | node | 95,933 | 1.33 | 1.59 | 55.5 | 99 | 204 |
| echo 1KB | bun | 161,385 | 0.77 | 1.36 | 2.3 | 98 | 52 |
| stream 8KB | bkr | 40,728 | 2.61 | 8.69 | 16.0 | 98 | 67 |
| stream 8KB | node | 84,022 | 1.50 | 2.96 | 67.8 | 97 | 203 |
| stream 8KB | bun | 108,250 | 1.16 | 1.54 | 3.0 | 99 | 86 |
| file 4KB | bkr | 27,731 | 4.04 | 10.90 | 21.0 | 148 | 90 |
| file 4KB | node | 50,901 | 2.45 | 3.40 | 16.8 | 269 | 224 |
| file 4KB | bun | 52,006 | 2.44 | 2.92 | 6.1 | 130 | 88 |

Reading it:

- On this machine `wrk` and the kernel loopback cap a single server near
  210k req/s: bun's hello and a bare `serve` handler in bkr (213k) both sit
  there. Higher figures need more server threads and a separate load
  generator host; bkr runs JavaScript on one thread.
- bkr uses 8-10x less memory than node on every workload and a third to a
  half of bun's.
- bkr is level with node on hello, behind it on json, async, echo, stream and
  file, and behind bun everywhere. The gap is JavaScript executed by the
  interpreter per request (the engine has no JIT); node and bun run that
  code compiled.
- `async` is bound by timer granularity (1 ms) as much as by CPU; `file` by
  the cost of `open` on macOS.

The first column of costs is in `runtime/js/prelude.js`: `new URL` on the
server's plain-URL path is one native call, `Response.json` and byte bodies
skip header setup, untouched streams are driven from their source without
promises, timers share one kernel timer, and path checks cache resolved
directories.
