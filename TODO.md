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

- [x] Native `file.readText` with owned external strings in the `boomkat-perf` worktree; UTF-8 decoding fallback for the main engine.
- [ ] Merge external-string support from `boomkat-perf` into the engine after reviewing the performance branch. HTTP URL/header buffers and mutable `Uint8Array` storage still require copies.

- [ ] Merge `fix/sort-concat-strings` (boomkat worktree `~/cousas/boomkat-sort-fix`, commit `bb59c1a5`) into the engine's main: `Array.prototype.sort` freed strings it still needed, and bkr compiles the engine from main. Also check `toSorted` for the same borrowing.
- [ ] Close the gap to node/bun on json, echo, stream and file: the cost is interpreted JS per request (`new Request`, header blobs, promise hops) and `open` on the pool; a per-thread JS worker model (`SO_REUSEPORT`) would multiply throughput past the single-thread ceiling.
- [ ] TLS server in `serve` (cert/key options) and HTTP/2.
- [ ] Remote imports (gated under `import`), `ffi`, `sys`.
- [ ] Linux sandbox (Landlock + seccomp) beside Seatbelt.
- [ ] `console` prints arrays returned by `String.prototype.split` with a stray `length:` entry (engine/console quirk).
- [ ] Dropping an unread `fetch` response body leaves its socket open until closed or garbage collected.
