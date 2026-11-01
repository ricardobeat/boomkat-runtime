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

- [x] `Array.prototype.sort` and `toSorted` freed strings they still needed, and `toSorted` was O(n^2): fixed on engine main (`7ea3ba21`, `e0530118`, `c497f9ae`).
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
- [x] A module's SyntaxError now carries file, line and column (`at file.js:2:11`), for static and dynamic imports: fixed on engine main (`7533520f`).
- [ ] `typescript.transpile()` source maps for browser devtools. No engine change needed: every node has `main_tok`/`end_tok` byte offsets (`ast.tok(n)`) and `Ast.position(offset)` gives a 1-based line and column. `SourceWriter` in `runtime/transpile.c3` has to track its output line and column, record a mapping before each identifier, statement and call, and encode a v3 map (base64 VLQ). `position` counts columns in bytes and source maps count UTF-16 units, so lines with non-ASCII text need converting from `ast.source`.
- [x] `crypto.subtle`: digest, HMAC, AES-GCM/CBC/CTR, PBKDF2, HKDF with raw and JWK secret keys. Open: RSA, ECDSA, ECDH, Ed25519, X25519, AES-KW, `wrapKey`/`unwrapKey`, `spki`/`pkcs8`, and global `CryptoKey`/`SubtleCrypto`.
- [ ] Confirm `Intl` coverage from the engine.
- [ ] TypeScript enums and other syntax needing runtime transforms.

Tooling:
- [x] `bkr test` with the `test` module. Files share one runtime; per-file isolation in workers would need the worker entry to load through `read_module`.
- [x] Move the Python wrappers that only drive bkr to `bkr test`: `tests/modules.test.js` and `tests/workers.test.js` replace `run_modules.py` and `run_workers.py`.
- [ ] `run_sqlite.py` and `run_crypto.py` stay in Python: they also drive `sqlite3`, `cc` or `openssl`.
- [ ] Engine: arrow frames are mostly kept now (`d2e66985`), but an arrow called by another arrow drops the caller's frame: `const outer = () => { const r = inner(); return r }; const mid = () => { const r = outer(); return r }; mid()` shows `inner`, `outer` and the module, not `mid`.
- [x] REPL: `bkr` or `bkr repl` with no script. Declarations persist, entries may use `await`, and `_` holds the last result.
- [ ] REPL regression test and a README section. `process.run` cannot pass stdin to the child yet, so the test needs that first.
- [x] `--watch`: `bkr test --watch` reruns after any file under the paths changes (250 ms poll, fresh process per run).
- [ ] Inspector / debugger protocol.
- [ ] `.d.ts` files for the built-in modules.
- [ ] Single-binary compile.
- [ ] Format and lint.
