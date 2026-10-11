# TODO

Runtime build order from PLAN.md, tracked here as it lands.

- [x] ESM entry, built-in modules by bare name (`http`, `path`, `permissions`)
- [x] `serve` on uWS, streaming responses, byte bodies
- [x] Permissions: deny by default, `--allow-*`/`--deny-*`, `boomkat.toml`, TTY prompts
- [x] Uint8Array access from C3 (no engine change needed)
- [ ] Unhandled rejections and CPU-time interrupts (engine hooks landing on boomkat main)
- [ ] Resource table: `read`/`write`/`close` on rids, stdio as rids 0-2
- [ ] `net`: `connect`, `listen`, `resolve`, with the DNS re-check
- [ ] `file`: `open`, `read`/`write`, `readText`/`writeText`, `stat`, `list`, `mkdir`, `remove`, `rename`
- [ ] `process`: `args`, `exit`, `pid`, `spawn`; `env`: `get`, `set`, `all`
- [ ] `fetch` over `connect`, TLS through uSockets + OpenSSL
- [ ] OS sandbox: Seatbelt on macOS
- [ ] `bkr check` listing the built-ins a module graph imports
- [ ] Optimise against node and bun; benchmark table (req/s, latency, memory, CPU)
- [ ] README for the runtime
