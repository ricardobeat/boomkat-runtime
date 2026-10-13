# Taskboard

A Trello-like app in TypeScript with a Preact TSX browser UI, user accounts,
shared teams, boards, lists, draggable cards, descriptions, colors, and image
attachments stored as SQLite BLOBs. It runs entirely on Boomkat Runtime.

## Run

From the repository root:

```sh
c3c build bkr
./out/bkr --allow-net=127.0.0.1:8080 \
  --allow-read=examples/taskboard \
  --allow-write=examples/taskboard/data \
  examples/taskboard/server.ts
```

Open **http://127.0.0.1:8080** and create an account. There are no default
credentials. Signup creates a personal workspace and starter board.
Create a team to collaborate; its owner can add existing accounts by email
or remove members. All members can edit that team's boards and cards.
Click a card to edit it, move it with the list selector or drag it between
columns, and attach PNG, JPEG, GIF or WebP images (5 MiB each, 10 per card).
Changes refresh on window focus and every 15 seconds while you are browsing.

No npm, Node, bundler, or TypeScript compiler is needed to run the app.
Boomkat executes `server.ts` directly, then calls the built-in `typescript`
module to compile `app.tsx` and the client modules into browser JavaScript once
at startup. Preact,
hooks, and its JSX runtime are vendored locally with their full upstream
sources and license. If needed, reproduce the download with:

```sh
python3 examples/taskboard/fetch_vendor.py
```

Restart the server after editing the UI: assets and transpilation are cached
in native static routes at startup.

The positional arguments are `port`, `data-directory`, and optional public
`origin`. For example, an alternative port and database directory:

```sh
./out/bkr --allow-net=127.0.0.1:9090 \
  --allow-read=examples/taskboard,/tmp/taskboard \
  --allow-write=/tmp/taskboard \
  examples/taskboard/server.ts 9090 /tmp/taskboard
```

### Optional board snapshot cache

The default path queries and serializes each board request. To enable the shared
snapshot cache on either runtime, pass `--snapshot-cache` after the origin:

```sh
bun examples/taskboard/server.bun.ts 8081 /tmp/taskboard-bun http://127.0.0.1:8081 --snapshot-cache
```

Boomkat accepts the same four application arguments. Authentication and board
membership are checked on every request. The cache holds at most 64 snapshots
and 4 MiB of string payload, invalidates on local or external SQLite writes, and
clears and bypasses stored snapshots during transactions. SQLite builds without
JSON functions use the ordinary row path. Cached results must be reported as a
separate workload; the default load benchmark remains uncached.

System SQLite 3.31+ must be available. Grant read and write permissions for
the database **directory**, including its WAL/SHM sidecars. The default
`examples/taskboard/data/` is gitignored. This sample binds only to loopback.
When using a local reverse proxy, pass its public origin as the third
argument; an HTTPS origin also enables the session cookie's `Secure` flag.

## Bun port

Run the same app on Bun without installing packages:

```sh
bun examples/taskboard/server.bun.ts 8081 /tmp/taskboard-bun
```

Both entry points call the same `server/application.ts` and domain/HTTP modules.
`platform.ts` provides Boomkat's native modules; `bun/platform.ts` adapts
the runtime imports to Bun's native HTTP server, system SQLite, filesystem,
crypto and TypeScript transpiler. It uses the same SQL, prepared statements,
authorization, request limits and WAL/FULL durability. The same vendored
Preact sources render the browser UI.

Both runtimes generate Argon2id hashes with the same profile and a 32-byte salt,
and verify existing hashes with 16-byte salts. Bun uses its native asynchronous
`Bun.password` API, with at most two password jobs in flight. No OpenSSL FFI
password adapter is needed.

Check parity and run the load test from the repository root:

```sh
python3 tests/run_taskboard_parity.py
TASKBOARD_RUNTIME=bun python3 tests/run_taskboard.py
python3 bench/taskboard_load.py --runtime bun --output bench/taskboard-bun-load.json
```

The load test uses the same authenticated fixtures and workloads as the BKR
run. It captures BKR's emitted `/app.js` before measurement and serves those
exact bytes through Bun's native static route, avoiding a payload-size bias
between compilers. BKR is needed for this benchmark preparation; ordinary
Bun operation transpiles the TSX itself and does not need BKR. All database
and API work executes normally on the selected runtime. The harness runs
1, 32 and 128 connections, with one second of warmup and eight seconds of
measurement per case, and records latency, errors, CPU and peak RSS.

## Implementation

- `server.ts` / `server.bun.ts`: small entry points selecting a runtime adapter.
- `platform.ts` / `bun/platform.ts`: runtime-specific HTTP, SQLite, filesystem,
  crypto, and transpiler implementations. Shared code uses `server/platform.ts`.
- `server/application.ts`: configuration, schema loading, and application startup.
- `server/domain/`: account/session, team, board, list, card, and image operations,
  plus membership checks. Domain methods operate on values and return data;
  they do not construct HTTP responses.
- `server/http/`: a declarative native route table, per-method controllers,
  cookies/CSRF, request parsing, response handling, and static assets. Browser
  sources are served from an explicit allowlist. Both runtimes use their native
  route tree; controllers read decoded `request.params` without URL parsing.
- `lib/`: reusable errors, HTTP/JSON helpers, validation, prepared statement
  caching, auth rate limits, and image signature detection.
- `app.tsx`: browser entry point. `client/components/` contains the app shell,
  account form, team members, card editor, columns, and shared UI components.
- `client/lib/`: browser API client, CSRF state, binary uploads, and errors.
- `schema.sql`: foreign keys, indexes, memberships, sessions, and BLOB storage.
- `types.ts`: shared UI data types.

Browser components import their served `.js` routes. Each TS/TSX source is
compiled once at startup; there is no bundling or request-time compilation.
The static route allowlist exposes browser modules without exposing server
sources or database files.

Passwords use C3 stdlib Argon2id, with a random 32-byte salt and a 32-byte
hash (`m=19456 KiB, t=2, p=1`), matching an
[OWASP recommended profile](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
Hashing runs on native workers, with at most two jobs in flight. The app
adds account/global attempt limits. Sessions use random 256-bit tokens;
only their SHA-256 hashes are persisted. Cookies are HttpOnly and SameSite=Lax.
Writes require a session CSRF token, and supplied origins must match the
configured origin. Every board/card/image operation checks team membership.
Images use raw binary uploads, signature checks, fixed MIME types, and no
SVG support. Preact escapes displayed text. The HTML uses a local-only CSP
with a hash for the import map.

This is a sample: there is no email delivery, account recovery, MFA, image
resizing, realtime websocket sync, or automated schema migration framework.
TS transpilation validates syntax but does not type-check or generate source
maps. Native SQLite operations are synchronous. The app permits up to 256 MiB of
read-only database mappings to reduce pager copying; WAL/FULL durability stays
enabled. SQLite falls back to ordinary reads when mapping is unavailable.

## Checks

```sh
python3 tests/run_taskboard.py
TASKBOARD_RUNTIME=bun python3 tests/run_taskboard.py
python3 tests/run_taskboard_parity.py
python3 tests/run_modules.py
python3 tests/run_transpile.py
python3 tests/run_crypto.py
```

The integration check creates temporary databases and verifies accounts,
sessions, CSRF, team isolation, card moves, image bytes, deletion, membership
revocation, and persistence across server restarts. Node is used only by
checks to validate emitted JS, not by the application.

The optional `tests/run_taskboard_ui.mjs` uses Node’s built-in WebSocket
with Chrome’s debugging protocol to exercise the real UI. Start the app
and headless Chrome with `--remote-debugging-port=9223`, then run
`node tests/run_taskboard_ui.mjs`. `TASKBOARD_URL` and `CHROME_CDP_URL`
can override their default loopback URLs. Screenshots go to `/tmp/`.
The included `tsconfig.json` and native module declarations support editor
checking; an existing `tsc` can validate the sample with
`tsc -p examples/taskboard/tsconfig.json`, without emitting any assets.
