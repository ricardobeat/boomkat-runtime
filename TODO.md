# TODO

Runtime build order from PLAN.md, tracked here as it lands.

- [x] ESM entry, built-in modules by bare name (`http`, `path`, `permissions`)
- [x] `serve` on uWS, streaming responses, byte bodies
- [x] Permissions: deny by default, `--allow-*`/`--deny-*`, `boomkat.toml`, TTY prompts
- [x] Uint8Array access from C3 (no engine change needed)
- [x] Unhandled rejections (`unhandledrejection` event, else exit 1) and `--time-limit` watchdog
- [x] Resource table: `read`/`write`/`close` on rids, stdio as rids 0-2
- [x] `net`: `connect`, `listen`, `resolve`, with the DNS re-check
- [x] `file`: `open`, `read`/`write`, `readText`/`writeText`, `stat`, `list`, `mkdir`, `remove`, `rename`
- [x] `process`: `args`, `exit`, `pid`, `spawn`; `env`: `get`, `set`, `all`
- [x] `fetch` over `connect`, TLS through uSockets + OpenSSL
- [x] OS sandbox: Seatbelt on macOS
- [x] `bkr check` listing the built-ins a module graph imports
- [x] Benchmark table against node and bun (README); first round of optimisation done
- [x] README for the runtime

## Remaining

- [x] Timer fairness, disconnected-upload cleanup, retained Request metadata, empty stream pulls, and stream cancellation.
- [x] Native HTTP promise completion, stream chunk batches, and lazy bounded `file.body` responses.
- [x] Native `file.readText` with owned external strings in the `boomkat-perf` worktree; UTF-8 decoding fallback for the main engine.
- [ ] Merge external-string support from `boomkat-perf` into the engine after reviewing the performance branch. HTTP URL/header buffers and mutable `Uint8Array` storage still require copies.

- [x] `Array.prototype.sort` freeing strings it still needed: fixed on engine main (`7ea3ba21`, `e0530118`). Still check `toSorted` for the same borrowing.
- [ ] Close the gap to node/bun on json, echo, stream and file: the cost is interpreted JS per request (`new Request`, header blobs, promise hops) and `open` on the pool; a per-thread JS worker model (`SO_REUSEPORT`) would multiply throughput past the single-thread ceiling.
- [ ] TLS server in `serve` (cert/key options) and HTTP/2.
- [ ] Remote imports (gated under `import`), `ffi`, `sys`.
- [ ] Linux sandbox (Landlock + seccomp) beside Seatbelt.
- [x] `console` printed builtin-created arrays (`split`, `match`, `Object.entries`) with a `length:` entry: the engine wrote their `length` as enumerable (fixed in boomkat `635d8971`).
- [x] An unread `fetch` body kept the process alive: fetch sockets are unref'd while no read is pending, and bodies pull on demand.

## Toward a Deno/Bun alternative

npm and Node compatibility are a non-goal: bare specifiers stay reserved for built-ins.

Blockers:
- [ ] Linux build: `project.json` targets macOS 26 and Homebrew OpenSSL archives only.
- [ ] Third-party code without npm: URL imports with a lockfile (see remote imports above).

Web APIs:
- [x] WebSocket: `upgradeWebSocket` on uWS and the global client.
- [x] Compression: `CompressionStream`/`DecompressionStream` and gzip/deflate decoding in `fetch`.
- [ ] Automatic response compression in `serve` (opt-in, negotiating `accept-encoding`).
- [x] Source maps for TypeScript stacks: not needed. The engine parses TS and TSX natively, so stack positions are already in the original source. Uncaught errors now print their stack.
- [ ] Engine: a module's SyntaxError has no file, line or stack (`SyntaxError: unexpected token` only). The engine records line/col (`err_line`/`err_col`) but neither the error object nor the embedding API carries the file.
- [ ] `typescript.transpile()` source maps for browser devtools: needs position tracking in the engine's printer.
- [ ] `crypto.subtle`.
- [ ] Confirm `Intl` coverage from the engine.
- [ ] TypeScript enums and other syntax needing runtime transforms.

Tooling:
- [ ] `bkr test`: a built-in test runner, replacing the per-test Python wrappers where possible.
- [ ] REPL.
- [ ] `--watch`.
- [ ] Inspector / debugger protocol.
- [ ] `.d.ts` files for the built-in modules.
- [ ] Single-binary compile.
- [ ] Format and lint.
