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

The current Homebrew OpenSSL archives require macOS 26+. `project.json`
sets that deployment target for C3 and C sources; `scripts/build_uws.sh`
uses the same target for the native shim. After changing the target, rebuild
the shim with `bash scripts/build_uws.sh` before building the runtime.

On Linux, install `c3c`, a C/C++ compiler, and the OpenSSL, zlib and (optionally,
at run time) SQLite development packages (`libssl-dev zlib1g-dev g++` on Debian),
then:

```sh
git clone --depth 1 --branch v20.80.0 --recurse-submodules \
    https://github.com/uNetworking/uWebSockets.git vendor/uWebSockets
bash scripts/build_uws.sh      # writes vendor/libuws_shim-linux.a
c3c build bkr-linux
./out/bkr-linux --allow-net hello.js
```

`bkr-linux` needs `libssl.so.3` to start. It has no OS sandbox yet, so it prints a
warning and enforces permissions in the runtime only (`--no-sandbox` silences it).
`file` opens refuse a symlink as the last path component, where macOS refuses one
anywhere in the path. Verified on aarch64 Debian 13; x86-64 is untested.

There is no Node compatibility layer and no npm: a bare specifier is either a
built-in or an error, and remote imports are not supported.

## Modules

| module | surface |
|---|---|
| `http` | `serve({ port, hostname, tls, routes, fetch, error, onListen })` -> `{ port, finished, stop(force) }`; `upgradeWebSocket(req)` |
| `net` | `connect({ hostname, port, tls })`, `listen({ hostname, port })`, `resolve(host)`; connections expose `read`, `write`, `closeWrite`, `close`, `readable`, `writable` |
| `file` | `body`, `read`, `readText`, `write`, `writeText`, `open`, `stat`, `list`, `mkdir`, `remove`, `rename`, `copy`, `exists` |
| `process` | `args`, `pid`, `execPath`, `exit`, `env`, `stdin`/`stdout`/`stderr`, `spawn`, `run` |
| `path` | `join`, `resolve`, `relative`, `dirname`, `basename`, `extname`, `parse`, `format`, `toFileUrl`, `fromFileUrl` |
| `permissions` | `query`, `request`, `revoke` |
| `sqlite` (optional) | `Database`, `Statement`, `version`; synchronous prepared statements and transactions |
| `crypto` | `randomBytes`, `sha256`, `hex`, `timingSafeEqual`, async `hashPassword` / `verifyPassword` |
| `typescript` | `transpile(source, options)`; native TS type erasure and JSX lowering to JavaScript source |
| `test` | `test`, `describe`, hooks and assertions for `bkr test` |

HTTP servers implement `Symbol.asyncDispose`: inside an async scope,
`await using server = serve(options)` calls and awaits `server.stop()` at scope exit.
Keep that scope alive for the intended server lifetime. Request-scoped resources
must stay alive until their consumers finish, especially streamed response bodies.

### Serving TypeScript and JSX

The `typescript` module uses Boomkat's parser to erase types, lower JSX, validate
syntax and print browser JavaScript. It neither executes the source nor resolves
its imports. No external compiler or package manager is involved.

```ts
import { transpile } from "typescript";
import { readText } from "file";

const js = transpile(await readText("./app.tsx"), {
    filename: "app.tsx",
    jsxImportSource: "preact",
});
const response = new Response(js, {
    headers: { "content-type": "text/javascript; charset=utf-8" },
});
```

Options: `filename` (default `module.ts`, `.tsx`/`.jsx` enables JSX), `module`
(default `true`), `jsx` (`automatic`, the default, or `classic`),
`jsxImportSource` (default `preact`), `jsxFactory` (default `h`), and
`jsxFragmentFactory` (default `Fragment`). JSX pragmas in the source are honored.
Automatic JSX inserts imports from `<jsxImportSource>/jsx-runtime`; browsers
need an import map or resolvable specifiers. Existing imports are preserved:
this API does not bundle or rewrite import paths. It does not type-check,
downlevel JavaScript, preserve comments/formatting, or generate source maps.
Enums and other syntax requiring unsupported TS runtime transforms throw.

The [Taskboard sample](examples/taskboard/README.md) serves a Preact TSX UI this
way, with accounts, shared teams, boards and SQLite BLOB image attachments.
It includes full, pinned Preact sources and browser modules; no npm or build step.

### WebSockets

`upgradeWebSocket(request, { protocol })` from `http` accepts an upgrade inside
any handler, including routes and async handlers, and returns the server end
of the socket with the Response that completes the upgrade:

```js
import { serve, upgradeWebSocket } from "http";

serve({ port: 8080, fetch(req) {
    if (req.headers.get("upgrade") !== "websocket") return new Response("not a socket", { status: 426 });
    const { socket, response } = upgradeWebSocket(req);
    socket.onmessage = (e) => socket.send(e.data);
    return response;
}});
```

Both ends are the standard `WebSocket` class with `open`, `message`, `close` and
`error` events, `send`, `close`, `binaryType`, `protocol` and `bufferedAmount`.
The global `WebSocket` client connects to `ws:` and `wss:` URLs through `net`,
so it needs a net grant. Server sockets run on uWebSockets: 16 MiB message
limit, automatic pings, a 120 s idle timeout, and no compression. Open sockets
keep the process alive.

Validation: `bkr --no-sandbox -A tests/websocket.js`.

### HTTPS

`serve({ tls: { cert, key } })` serves HTTPS. `cert` and `key` are paths to
PEM files, and both are required:

```js
serve({
    port: 8443,
    tls: { cert: "./cert.pem", key: "./key.pem" },
    fetch: () => new Response("secure"),
});
```

`server.url` uses `https:`. Routes, streaming, static responses and
`upgradeWebSocket` (clients connect with `wss:`) work as they do over plain
HTTP. The certificate and key files need read permission.

TLS needs OpenSSL 3 at run time. `bkr` links it weakly and starts without it;
plain HTTP is unaffected, and `serve({ tls })` throws with an install hint.
TLS runs on a single HTTP thread, so `serve({ tls })` is rejected with
`--http-workers` and `--http-processes`: terminate TLS in front of those modes.
There is no HTTP/2, no SNI with several certificates, and no client
certificates yet.

### Testing

`bkr test [flags] [--filter=text] [paths...]` runs every `*.test.*`, `*_test.*`
and `*.spec.*` file (`.js`, `.mjs`, `.jsx`, `.ts`, `.mts`, `.tsx`) under the
given paths, or the working directory. Hidden directories and `node_modules`
are skipped. Discovery needs no grant; tests get the permissions the flags
give, as a script would.

`--watch` keeps the runner going: after each run it waits for any file under
the paths to change (polled every 250 ms) and runs again in a fresh process, so
edited modules reload. Ctrl-C stops it.

```ts
import { test, describe, beforeEach, assertEquals, assertRejects } from "test";

describe("sums", () => {
    test("adds", () => assertEquals(1 + 2, 3));
    test("rejects", () => assertRejects(Promise.reject(new RangeError("no")), RangeError));
});
```

`test`/`it` and `describe` take `.skip` and `.only`; `test.todo(name)` lists
work to do. Hooks: `beforeAll`, `afterAll`, `beforeEach`, `afterEach`, scoped to
the file or the enclosing `describe`. Assertions: `assert`, `assertEquals` (deep:
arrays, plain objects, Maps, Sets, Dates, RegExps, typed arrays),
`assertNotEquals`, `assertStrictEquals`, `assertMatch`, `assertThrows`,
`assertRejects`, `fail`, and the `AssertionError` they throw.

Files are imported one after another into one runtime, then their tests run in
order. An unhandled rejection during a test fails that test. The run exits
with status 1 on any failure or when no test file is found, and does not wait
for servers or timers the tests leave open.

Validation: `bkr --no-sandbox -A tests/test-runner.js`.

### Module workers

`new Worker("./worker.ts", { type: "module", name: "optional" })` creates a
thread with its own VM, heap and event loop. Paths resolve against the spawning
entry module; workers inherit its permissions without interactive prompts.
JavaScript and TypeScript modules, including top-level await, are supported.

Use `postMessage(value, [arrayBuffer])`, `onmessage`/`addEventListener`,
`onerror`, and `terminate()` on the parent. Workers expose `self`, `name`,
`postMessage`, `close()` and the same native modules as the parent. A worker's
`close` event signals that its thread and resources have finished shutting down.
Termination interrupts JavaScript and waits for in-flight native jobs to return.

Messages clone primitives, ordinary records, arrays, Maps, Sets, Dates, RegExps,
Errors, ArrayBuffers and typed views, preserving cycles and shared references
within each message. ArrayBuffer transfers copy bytes and detach the sender;
they are not zero-copy. SharedArrayBuffer and native handles cannot be cloned.
Limits are 64 workers per process, 16 MiB per message, 64 MiB queued per direction,
and 32,768 graph objects/entries. `structuredClone` uses the same codec.

```sh
./out/bkr --allow-read=examples/workers examples/workers/main.ts
./out/bkr test --no-sandbox -A tests/workers.test.js
```

### HTTP server workers

Run an HTTP entry module with `--http-workers=N` (1–64) to use N server VMs
in one process, including the main VM. The runtime owns one listener and
distributes accepted connections round-robin. Keep-alive requests stay on their
connection's worker; handlers and response bodies execute directly in that VM.

```sh
./out/bkr --http-workers=4 --allow-net=127.0.0.1:8080 \
  --allow-read=examples/taskboard --allow-write=examples/taskboard/data \
  examples/taskboard/server.ts 8080 examples/taskboard/data
```

Each replica re-executes the same entry module with the same arguments and
permissions. This mode supports one `serve()` per entry module. Module globals,
caches and in-memory rate limits are per VM. Use a shared store for policies
that must apply across workers. Taskboard opens a SQLite connection in each VM
against one WAL database and waits up to five seconds for write locks.

`server.workers` reports joined server VMs. On the main server,
`await server.ready` waits for the configured count. `stop()` drains active responses and their buffered bytes
before closing replicas; `stop(true)` interrupts them. Replica failures end
the process rather than silently reducing the pool.

Validation: `python3 tests/run_http_workers.py` checks balanced distribution,
request bodies, forced shutdown and graceful completion of large responses.

### HTTP server processes

`--http-processes=N` (1–64) runs N independent processes behind a native
supervisor. The supervisor accepts TCP connections and passes their descriptors
round-robin over Unix sockets with `SCM_RIGHTS`; each worker handles HTTP bodies,
streams and WebSockets directly. Keep-alive requests stay in the same process.
This works on macOS without relying on `SO_REUSEPORT` distribution.

```sh
./out/bkr --http-processes=4 --allow-net=127.0.0.1:8080 \
  --allow-read=examples/taskboard --allow-write=examples/taskboard/data \
  examples/taskboard/server.ts 8080 examples/taskboard/data
```

This is an experimental process pool: one supervisor plus N workers, one
`serve()` per worker, and no combination with `--http-workers`. Each process
re-runs the entry module with the same arguments and permissions; memory and
startup side effects are independent. The supervisor waits for every worker to
announce the same listener before accepting connections, including when port 0
is used. It prints `HTTP processes ready: N (port PORT)` at that point.
`server.ready` and `server.workers` describe the local thread pool, not the
process pool. `stop()` drains that worker's active responses and WebSockets; the supervisor
exits when all workers exit. SIGINT/SIGTERM stop the whole pool. A worker crash
or nonzero exit terminates the pool; automatic respawning is not implemented.

Validation: `python3 tests/run_http_processes.py` checks distinct PIDs,
connection distribution, keep-alive affinity, bodies, streams, WebSockets,
backpressure, graceful drains, permissions and failure cleanup. Benchmark with
`python3 bench/http-processes.py --report bench/http-processes.json`; its RSS
measurement includes the supervisor and all descendant processes.

### Native crypto

`randomBytes(size)` returns a system-random Uint8Array (0–65536 bytes).
`sha256(stringOrBytes)` returns 32 bytes; `hex(bytes)` formats them.
`timingSafeEqual(a, b)` compares byte buffers with OpenSSL's constant-time
comparison for equal-length inputs; unequal lengths return false immediately.

`await hashPassword(password)` returns a salted Argon2id PHC string using C3's
stdlib (`m=19456 KiB, t=2, p=1`, 32-byte salt, 32-byte hash).
Verification also accepts existing 16-byte salts.
`await verifyPassword(password, encoded)` verifies that fixed profile and
returns false for malformed hashes or other profiles. Passwords are bounded
to 4096 UTF-8 bytes. Password hashing runs on worker threads with at most two
jobs in flight; additional requests reject with `code: "BUSY"`. The native
password copy and intermediate digest are wiped after use. This is a password
hashing API, separate from the global Web Crypto random helpers.

Validation: `python3 tests/run_transpile.py`, `python3 tests/run_crypto.py`, and
`python3 tests/run_taskboard.py`. The crypto check compares Argon2id output
against OpenSSL when its ARGON2ID KDF is available.

### HTTP routes

Routes are matched by uWebSockets' native tree. Exact paths take precedence over
`:parameter` paths, followed by terminal `/*` wildcards. Handlers receive decoded
`request.params` and may return a Response or a promise. A fixed buffered Response
is copied at startup and served without entering JavaScript.

```js
import { serve } from "http";
serve({
    port: 8080,
    routes: {
        "/health": new Response("OK"),
        "/users/:id": {
            GET: req => Response.json({ id: req.params.id }),
            POST: async req => Response.json(await req.json()),
        },
        "/api/*": new Response("Not found", { status: 404 }),
    },
    fetch: () => new Response("Not found", { status: 404 }),
});
```

`fetch` is optional with `routes`; unmatched requests default to 404. A route may
also be one handler for every method. Method maps support GET, HEAD, POST, PUT,
PATCH, DELETE, OPTIONS, TRACE and CONNECT; GET supplies HEAD when HEAD is absent.
A route set to `false` delegates to the fallback handler. Static responses must
have unused, buffered bodies; stream and file bodies belong in handlers. The
existing `static` option remains available for fixed GET/HEAD assets.

### Optional SQLite

`sqlite` is registered when a system SQLite shared library (3.31+) and all required
symbols can be loaded. The runtime has no SQLite link dependency and starts normally
without it. macOS searches `/usr/lib/libsqlite3.dylib` and the dynamic loader's
`libsqlite3.dylib`; Linux searches `libsqlite3.so.0` and `libsqlite3.so`.
An unavailable module can be detected with `await import("sqlite").catch(...)`.

```js
import { Database } from "sqlite";

const db = new Database(); // private in-memory database; no file permissions needed
try {
    db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    const insert = db.prepare("INSERT INTO users(name) VALUES (?)");
    insert.run("Ada");
    console.log(db.query("SELECT * FROM users WHERE id = :id").get({ id: 1 }));
} finally {
    db.close();
}
```

`new Database(path, { readonly: true })` opens an existing file for reading.
Writable databases create missing files. File access requires read permission and,
for writable connections, write permission for the database directory, including
SQLite's `-journal`, `-wal`, and `-shm` sidecars. Permissions are checked once when
opening the database, against the absolute, normalized pathname rather than a
symlink's target. An open connection retains its access capability; later grant
changes affect new connections. OS sandbox restrictions still apply. `:memory:`
needs no file grants.

`prepare(sql)` and its alias `query(sql)` each create one reusable statement.
`inTransaction` reports whether the connection has an active transaction, including
explicit SQL transactions and savepoints. Reading it after closing throws.

`all(...values)` returns rows, `get(...values)` returns the first row or `undefined`,
and `run(...values)` returns `{ changes, lastInsertRowid }`. Bindings accept positional
arguments, an array, or an object with named parameters (bare or `:`, `$`, `@` prefixed).
Missing and extra bindings throw. Values may be null, booleans, finite numbers,
signed 64-bit BigInts, strings, ArrayBuffers or views. Rows are dictionaries with a
null prototype; blobs are copied Uint8Arrays. INTEGER results outside the safe Number
range become BigInts, including `lastInsertRowid`.

Use `statement.finalize()` to release a statement. Closing a database finalizes its
outstanding statements; process shutdown closes remaining databases. There is no
implicit GC finalization or statement cache. Both close and finalize are idempotent.
Databases and statements implement `Symbol.dispose`, so `using db = new Database()`
and `using stmt = db.prepare(sql)` release them at scope exit, including throws
and early returns. Keep frequently used statements outside request scopes to reuse
them; `using` does not eliminate preparation costs. Prefer synchronous `using` for
SQLite; `await using` also works through the synchronous disposer fallback.
`db.transaction(fn)` returns a synchronous wrapper using savepoints, including nested
transactions. Exceptions roll back; promise-returning callbacks are rejected.

Operations run on the event-loop thread. Long queries honor `--time-limit` through a
SQLite progress callback. SQL errors carry `code` values such as `SQLITE_2067`.
`exec` accepts multiple statements; `prepare` accepts one, including trailing comments.
SQL/path strings reject embedded NUL bytes; bound text preserves them.

SQL `ATTACH`, `VACUUM INTO`, extension loading and temporary-storage directory changes
are blocked to preserve file permission boundaries. Temporary query storage stays in
memory. The implementation uses SQLite's [authorizer](https://sqlite.org/c3ref/set_authorizer.html)
and [transient bindings](https://sqlite.org/c3ref/bind_blob.html) to copy parameter buffers.

Validation: `python3 tests/run_sqlite.py` (set `BKR_BIN` for an ASAN build). On macOS it
also simulates missing and incomplete SQLite libraries with loader interposition.

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
verification, redirects re-checked against the net grants, gzip and deflate
bodies decoded), `Request`, `Response`, `Headers`, `URL`, `URLSearchParams`,
streams, `CompressionStream`/`DecompressionStream` (gzip, deflate, deflate-raw;
system zlib), `WebSocket`, `Blob`, `File`,
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

Direct stream sources enqueue ordinary byte chunks through a native controller
method with cached state slots and native array growth. Modified methods or
descriptors, conversions and wake callbacks fall back to the original JS method.

`bkr check script.js` lists the built-ins a module graph imports and the
flags it will probably need.

`bkr test` runs test files; see [Testing](#testing).

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
Seatbelt sandbox (macOS only) that denies the network, exec and writes the grants do
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
Absolute rates vary with background load; paired measurements provide the
optimization evidence. This suite uses the native byte-enqueue path.

| Workload | Boomkat req/s | p50 / p99 ms | Node req/s | p50 / p99 ms | Bun req/s | p50 / p99 ms | RSS MiB (Boomkat / Node / Bun) |
|---|---:|---:|---:|---:|---:|---:|---:|
| hello | 207,071 | 0.59 / 1.14 | 122,447 | 1.03 / 1.51 | 201,918 | 0.60 / 1.17 | 12 / 103 / 41 |
| json | 167,716 | 0.71 / 1.41 | 120,749 | 1.05 / 1.45 | 187,158 | 0.66 / 1.25 | 13 / 104 / 42 |
| async immediate | 132,885 | 0.82 / 2.01 | 131,796 | 0.94 / 1.87 | 171,582 | 0.66 / 1.43 | 14 / 185 / 45 |
| async timer | 107,246 | 1.11 / 2.06 | 78,608 | 1.28 / 2.68 | 119,657 | 1.05 / 1.28 | 14 / 186 / 46 |
| echo 1KB | 133,038 | 0.87 / 1.94 | 95,123 | 1.33 / 1.91 | 159,034 | 0.78 / 1.32 | 16 / 202 / 50 |
| stream 8KB | 62,023 | 1.88 / 4.10 | 84,156 | 1.50 / 2.41 | 106,059 | 1.17 / 1.66 | 16 / 202 / 78 |
| file 4KB | 84,844 | 1.31 / 3.10 | 48,432 | 2.56 / 3.98 | 50,855 | 2.48 / 3.08 | 18 / 223 / 81 |

The [native enqueue report](bench/server-stream-native-results.txt) includes maximum
latency, CPU usage, validation and paired measurements. Native byte enqueue removes
19% of VM instructions from the 8-chunk workload (1,159 ->943/request). Final
reversed-order runs gained 8–12% stream throughput; earlier pairs gained 9–13%.
The source pump, controller setup and initial queue still run in JS.

Before native enqueue, the [stream profile](bench/stream-profile-results.txt) attributed
44.5% of main-thread samples to VM handlers, 7.8% to property lookup helpers,
10.4% to heap/GC work and 21.9% to socket system calls. [The diagnostic driver](bench/profile_stream.py)
reproduces CPU sampling, opcode counts and fixed-body chunk/pull ablations.
The [earlier VM report](bench/server-stream-vm-results.txt) records the preceding
3–4% gain from absent-property caches, intrinsic length getters and constant checks.

Node precomputes its JSON body; Node/Bun async handlers also await
`Promise.resolve`, while Boomkat uses `.then` after the yield. Node streams use
direct HTTP writes, while Boomkat and Bun use Web `ReadableStream`. Bun serves
files with `Bun.file`, and Boomkat uses native `file.body`.

Run `python3 tests/run_disposal.py` to check the runtime disposal hooks.
