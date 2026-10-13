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
module to turn `app.tsx` into browser JavaScript once at startup. Preact,
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

The application body is identical to `server.ts`; `bun/platform.ts` adapts
the runtime imports to Bun's native HTTP server, system SQLite, filesystem,
crypto and TypeScript transpiler. It uses the same SQL, prepared statements,
authorization, request limits and WAL/FULL durability. The same vendored
Preact sources render the browser UI.

Passwords use the identical Argon2id profile, including a 16-byte salt, so
either runtime can open the other's database. Bun's built-in password hasher
fixes its salt at 32 bytes; the adapter instead uses OpenSSL 3.2+ through Bun
FFI on at most two workers. On Apple Silicon it defaults to Homebrew's
`/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib`; set `TASKBOARD_LIBCRYPTO`
to override the library path. Linux defaults to `libcrypto.so.3`.

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

- `server.ts`: JSON API, access checks, prepared statements, native static
  routes, and direct TSX-to-JS transpilation.
- `app.tsx`: Preact components and hooks, responsive board and card editor.
- `schema.sql`: foreign keys, indexes, memberships, sessions, and BLOB storage.
- `types.ts`: shared UI data types.

Passwords use C3 stdlib Argon2id, with a random 16-byte salt and a 32-byte
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
maps. Native SQLite operations are synchronous.

## Checks

```sh
python3 tests/run_taskboard.py
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
