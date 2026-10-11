# Runtime plan

Turning boomkat-runtime from a benchmark harness into a runtime: built-in
modules imported by name, web-standard globals, and a Deno-style permission
model enforced in the C3 ops layer. No Node compatibility.

## Where it stands

- uSockets is the event loop (as in Bun). Files, DNS and subprocesses will run
  on a thread pool that posts results back to the loop with `defer`.
- `src-uws/` has a fetch-style server: `Request`, `Response`, `Headers`, `URL`,
  `URLSearchParams`, `TextEncoder`/`TextDecoder`, timers, `queueMicrotask`,
  `console`. The handler is an eval'd script evaluating to `{ fetch }`.
- The C++ shim is pass-throughs over uWS; everything that decides anything is
  C3 (`src-uws/main.c3`), and the Web API classes are JS (`src-uws/prelude.c3`).
  That C3 layer is the ops boundary where permissions get enforced.
- One runtime and one loop per thread, sharing nothing, which fits Workers.
  The README still claims the engine refuses a second `open`; the server
  opens one per thread and two-thread runs work, so that line is probably
  stale. Not verified against the engine.

## Module design

Web standards stay **globals**: `fetch`, `Request`/`Response`/`Headers`, `URL`,
streams, `TextEncoder`/`TextDecoder`, `crypto.getRandomValues`, `AbortSignal`,
timers, `console`. Built-in **modules** cover only what has no standard.

**Specifiers are bare names:** `import { readText } from "file"`. With no npm
and no Node compatibility nothing else claims bare specifiers, so a bare
specifier is a built-in or an error. User code imports by relative path or URL.
Built-ins are prelude JS registered with `JsRuntime.define_module`.

| module | contents |
|---|---|
| `file` | `open`, `read`/`write` (whole file, bytes), `readText`/`writeText`, `stat`, `list`, `mkdir`, `remove`, `rename` |
| `http` | `serve({ port, fetch })` |
| `net` | `connect`, `listen`, `resolve` |
| `process` | `args`, `exit`, `spawn` (stdio as streams), `pid` |
| `env` | `get`, `set`, `all` |
| `path` | `join`, `resolve`, `dirname`, `basename`, `extname` (pure JS) |
| `permissions` | `query`, `request`, `revoke` |

```js
import { serve } from "http";
import { readText } from "file";

serve({ port: 8080, async fetch(req) {
  return new Response(await readText("./index.html"), { headers: { "content-type": "text/html" } });
}});
```

Conventions:
- Async only, returning Promises. No sync variants for now.
- Bytes are `Uint8Array`; streams are WHATWG `ReadableStream`/`WritableStream`.
  Open files, net connections and process pipes all expose `.readable`/`.writable`.
- Named exports only.
- Errors are `Error` subclasses with a string `code` (`"ENOENT"`, `"EACCES"`,
  `"PERMISSION_DENIED"`).
- Prefer Deno's names where an equivalent exists, to ease porting.

## Native ops (the layer under the modules)

A handle is a capability: permissions are checked only where a handle is
created, never on use.

Byte streams, for every kind of handle:
```
read(rid, u8) -> Promise<n>      // fills the caller's buffer; 0 = EOF
write(rid, u8) -> Promise<n>
close(rid)
```
`rid` indexes a per-Worker resource table; rids are closed when the Worker exits.

Openers, the only permission checkpoints:

| op | permission | returns |
|---|---|---|
| `listen(host, port)` / `accept(lid)` | `net` | listener / conn rid |
| `connect(host, port, {tls})` | `net`, re-checked after DNS | conn rid |
| `resolve(host)` | `net` | addresses |
| `open(path, flags)` | `read` / `write` | file rid |
| `spawn(cmd, args, {env, cwd})` | `run` | pid + stdio rids |
| `env_get` / `env_set` | `env` | string |

One-shot calls: `stat`, `readdir`, `mkdir`, `remove`, `rename` (path checked);
`wait(pid)`, `kill(pid, sig)`.

Ungated: `now`, `timer_start`/`timer_cancel` (exist), `random_bytes(u8)`,
`args`, `exit`, stdio as rids 0-2.

`serve` stays a native op on uWS (that is where the throughput comes from).
`fetch` is JS: HTTP/1.1 over `connect` with TLS, so every redirect hop goes
through `connect` and is re-checked.

## Permission model

- A `Permissions` struct per Worker, held in C3 where JS cannot write it.
  Categories: `net` (host[:port]), `read`/`write` (path prefixes), `env`
  (names), `run` (binaries), `ffi` (libs), `sys` (APIs), `import` (remote hosts).
  Each is deny-all, allow-all or an allowlist, set from `--allow-*` flags.
- One check function per category (`check_net`, `check_read`, ...) that every
  op calls before any syscall. Only the ops module may call the shim or libc
  for I/O; a CI grep keeps it that way.
- Importing a module grants nothing; the check happens when the op runs.
- `permissions.request()` prompts on a TTY and is denied without one;
  `revoke()` only narrows; Workers get a subset of their parent's permissions.
- Static imports show what a program can touch before it runs: a
  `boomkat check main.js` can list "uses file, net" from the module graph.

Pitfalls to design against:
- **Paths:** canonicalize-then-check is racy and symlink-prone. Use WASI-style
  pre-opened directory handles and `openat(dir_rid, relpath)`.
- **Network:** check the name, then the resolved address (DNS rebinding);
  re-check redirects; loopback and private ranges need an explicit grant.
- **Escape hatches:** `run`, `ffi`, and write access to the runtime's own
  config or cache amount to full access. Document them that way.
- **Remote imports** are network access, gated under `import`, not `net`.
- **Resource exhaustion** is outside the model: engine memory cap plus an
  interrupt-based CPU timeout per request or Worker.

Beyond Deno: compile the granted flags into an OS sandbox applied before user
code runs (Seatbelt `sandbox_init` on macOS, Landlock + seccomp-bpf on Linux,
`pledge`/`unveil` on OpenBSD), so a bug in our ops code still cannot reach
anything not granted.

## Decisions (settled)

1. Flags, a `boomkat.toml`, and TTY prompts. The OS sandbox is applied only
   when prompting is off, since a prompt cannot grant what the OS policy
   did not already allow.
2. Deny-all by default.
3. One `net` permission with allowlists; no listen/connect split.

`read` returns chunks (`Uint8Array` or `null` at the end) rather than filling
a caller-supplied BYOB buffer.

## Engine prerequisites (boomkat)

- Typed-array access in the binding: a `Uint8Array`'s backing pointer and
  length, for zero-copy `read`/`write`. The binding only handles strings today.
- Unhandled-rejection reporting hook.
- Interrupt / termination callback for CPU timeouts.
- ESM loading for user code plus `define_module` for built-ins (both exist).

## Build order

1. Typed-array access in the boomkat binding.
2. User code as an ES module; built-in modules via `define_module`; turn the
   current server into `import { serve } from "http"`.
3. `Permissions` struct and flag parsing; gate `listen` behind `--allow-net`.
4. The rid table and `read`/`write`/`close`, on stdio first.
5. `connect`/`listen`/`resolve` on uSockets with `net` checks: TCP echo
   server and client, to exercise the permission model for real.
6. `file`: `open`/`stat`/`readdir`/... on the thread pool, with pre-opened dirs.
7. `process.spawn`.
8. `fetch` in JS over `connect` + TLS (drop `LIBUS_NO_SSL`).
9. OS sandbox layer.

Next concrete step before writing native code: the module surfaces as `.d.ts`
files (`file.d.ts`, `http.d.ts`, ...) to settle signatures.
