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

- [x] `Array.prototype.sort` freeing strings it still needed: fixed on engine main (`7ea3ba21`, `e0530118`). `toSorted` has the same bug, see below.
- [ ] Engine: `Array.prototype.toSorted` borrows its elements like `sort` did, and a comparefn that shrinks the array frees them: `var a = ["b"+1, "a"+1]; a.toSorted((x, y) => { a.length = 0; return x < y ? -1 : 1 })` returns `[ Symbol(), 'b1' ]`, and the same with 300 elements crashes (SIGBUS). The elements need the rooted holder `sort` got in `7ea3ba21`.
- [ ] Engine: `toSorted` is a bubble sort, so 20000 elements take 6.9 s where `sort` takes 10 ms. It should reuse the merge sort from `sort`.
- [ ] Close the gap to node/bun on json, echo, stream and file: the cost is interpreted JS per request (`new Request`, header blobs, promise hops) and `open` on the pool; a per-thread JS worker model (`SO_REUSEPORT`) would multiply throughput past the single-thread ceiling.
- [x] TLS server in `serve` (`tls: { cert, key }`, single HTTP thread). Still open: HTTP/2, SNI with several certificates, and TLS under `--http-workers`/`--http-processes`.
- [ ] Remote imports (gated under `import`), `ffi`, `sys`.
- [ ] Linux sandbox (Landlock + seccomp) beside Seatbelt.
- [x] `console` printed builtin-created arrays (`split`, `match`, `Object.entries`) with a `length:` entry: the engine wrote their `length` as enumerable (fixed in boomkat `635d8971`).
- [x] An unread `fetch` body kept the process alive: fetch sockets are unref'd while no read is pending, and bodies pull on demand.

## Toward a Deno/Bun alternative

npm and Node compatibility are a non-goal: bare specifiers stay reserved for built-ins.

Blockers:
- [x] Linux build: `c3c build` after `scripts/build_uws.sh`, from the same `project.json` as macOS (per-platform linking lives in `vendor/uws.c3l/manifest.json`) (aarch64 Debian 13 verified; x86-64 untested). Open: CI for it, a Linux install of SQLite/zlib checks, `O_NOFOLLOW_ANY` equivalent (`openat2` with `RESOLVE_NO_SYMLINKS`), and the sandbox below.
- [ ] Third-party code without npm: URL imports with a lockfile (see remote imports above).

Web APIs:
- [x] WebSocket: `upgradeWebSocket` on uWS and the global client.
- [x] Compression: `CompressionStream`/`DecompressionStream` and gzip/deflate decoding in `fetch`.
- [ ] Automatic response compression in `serve` (opt-in, negotiating `accept-encoding`).
- [x] Source maps for TypeScript stacks: not needed. The engine parses TS and TSX natively, so stack positions are already in the original source. Uncaught errors now print their stack.
- [ ] Engine: a module's SyntaxError has no file, line or stack (`SyntaxError: unexpected token` only). The engine records line/col (`err_line`/`err_col`) but neither the error object nor the embedding API carries the file.
- [ ] `typescript.transpile()` source maps for browser devtools: needs position tracking in the engine's printer.
- [x] `crypto.subtle`: digest, HMAC, AES-GCM/CBC/CTR, PBKDF2, HKDF with raw and JWK secret keys. Open: RSA, ECDSA, ECDH, Ed25519, X25519, AES-KW, `wrapKey`/`unwrapKey`, `spki`/`pkcs8`, and global `CryptoKey`/`SubtleCrypto`.
- [ ] Confirm `Intl` coverage from the engine.
- [ ] TypeScript enums and other syntax needing runtime transforms.

Tooling:
- [x] `bkr test` with the `test` module. Files share one runtime; per-file isolation in workers would need the worker entry to load through `read_module`.
- [x] Move the Python wrappers that only drive bkr to `bkr test`: `tests/modules.test.js` and `tests/workers.test.js` replace `run_modules.py` and `run_workers.py`.
- [ ] `run_sqlite.py` and `run_crypto.py` stay in Python: they also drive `sqlite3`, `cc` or `openssl`.
- [ ] Engine: arrow functions are missing from stack traces (`() => inner()` shows only `inner` and the module frame).
- [x] REPL: `bkr` or `bkr repl` with no script. Declarations persist, entries may use `await`, and `_` holds the last result.
- [ ] REPL regression test and a README section. `process.run` cannot pass stdin to the child yet, so the test needs that first.
- [x] `--watch`: `bkr test --watch` reruns after any file under the paths changes (250 ms poll, fresh process per run).
- [ ] Inspector / debugger protocol.
- [ ] `.d.ts` files for the built-in modules.
- [ ] Single-binary compile.
- [ ] Format and lint.
