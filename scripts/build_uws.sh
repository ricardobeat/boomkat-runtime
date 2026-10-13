#!/usr/bin/env bash
# Builds vendor/libuws_shim.a: the uSockets C library plus the C++ shim that
# gives it an extern "C" surface C3 can bind.
#
# Kept out of project.json because c3c's c-sources drive a C compiler, and the
# shim needs a C++ one. Run this before `c3c build bkr`.
set -euo pipefail
cd "$(dirname "$0")/.."

UWS=vendor/uWebSockets
OBJ=build/uws-obj
OUT=vendor/libuws_shim.a

[[ -d "$UWS/uSockets/src" ]] || { echo "missing $UWS -- clone it with --recurse-submodules" >&2; exit 1; }

mkdir -p "$OBJ"

# A clean FIN can accompany unread data. An EV_EOF with a socket error in
# fflags is a reset: discard its buffered requests before entering handlers.
python3 - "$UWS/uSockets/src/eventing/epoll_kqueue.c" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
replacement = '''const struct kevent *ready = &loop->ready_polls[loop->current_ready_poll];
                int error = (ready->flags & EV_ERROR) || ((ready->flags & EV_EOF) && ready->fflags);'''
for old in [
    'int error = loop->ready_polls[loop->current_ready_poll].flags & (EV_ERROR | EV_EOF);',
    'int error = loop->ready_polls[loop->current_ready_poll].flags & EV_ERROR;',
]:
    s = s.replace(old, replacement)
if replacement not in s:
    raise SystemExit('unrecognized uSockets kqueue error handling')
p.write_text(s)
PY

# macOS coalesces kqueue timers armed with the default leeway, so a 1 ms timer
# often fires a millisecond late. Arm them in microseconds as critical.
sed -i '' 's/EV_ADD | (repeat_ms ? 0 : EV_ONESHOT), 0, ms, internal_cb);/EV_ADD | (repeat_ms ? 0 : EV_ONESHOT), NOTE_USECONDS | NOTE_CRITICAL, (int64_t) ms * 1000, internal_cb);/' "$UWS/uSockets/src/eventing/epoll_kqueue.c"

# A TLS peer that sends close_notify right behind its last records made
# uSockets drop the data decoded in that same call. Emit it before closing.
python3 - "$UWS/uSockets/src/crypto/openssl.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "                // terminate connection here\n                return us_internal_ssl_socket_close(s, 0, NULL);"
new = ("                // terminate connection here\n"
       "                if (read) {\n"
       "                    context = (struct us_internal_ssl_socket_context_t *) us_socket_context(0, &s->s);\n"
       "                    s = context->on_data(s, loop_ssl_data->ssl_read_output + LIBUS_RECV_BUFFER_PADDING, read);\n"
       "                    if (us_socket_is_closed(0, &s->s)) return s;\n"
       "                }\n"
       "                return us_internal_ssl_socket_close(s, 0, NULL);")
if old in s:
    s = s.replace(old, new, 1)

# OpenSSL 3 deprecated the raw DH APIs. Preserve custom parameter files,
# using EVP_PKEY; set0 transfers ownership only when it succeeds.
start = s.index('        /* Set up ephemeral DH parameters')
end = s.index('        /* OWASP Cipher String', start)
new_dh = '''        /* Set up ephemeral DH parameters using OpenSSL 3 EVP APIs. */
        BIO *paramfile = BIO_new_file(options.dh_params_file_name, "r");
        if (!paramfile) {
            free_ssl_context(ssl_context);
            return NULL;
        }

        EVP_PKEY *dh_params = PEM_read_bio_Parameters(paramfile, NULL);
        BIO_free(paramfile);
        if (!dh_params || (!EVP_PKEY_is_a(dh_params, "DH") && !EVP_PKEY_is_a(dh_params, "DHX"))) {
            EVP_PKEY_free(dh_params);
            free_ssl_context(ssl_context);
            return NULL;
        }

        if (SSL_CTX_set0_tmp_dh_pkey(ssl_context, dh_params) != 1) {
            EVP_PKEY_free(dh_params);
            free_ssl_context(ssl_context);
            return NULL;
        }

'''
s = s[:start] + new_dh + s[end:]
open(p, "w").write(s)
PY

# OpenSSL for TLS sockets (fetch, net); no zlib, since permessage-deflate
# is never negotiated.
SSL=$(brew --prefix openssl@3)
# Read the shared deployment target rather than defaulting to the host OS.
DEPLOYMENT_TARGET=$(python3 - <<'PY'
import re
from pathlib import Path
match = re.search(r'"macos-min-version"\s*:\s*"([0-9.]+)"', Path('project.json').read_text())
if not match:
    raise SystemExit('project.json must define macos-min-version')
print(match[1])
PY
)
CFLAGS=(-O3 -mmacosx-version-min="$DEPLOYMENT_TARGET" -std=c11 -DLIBUS_USE_OPENSSL -I"$SSL/include" -I"$UWS/uSockets/src")
CXXFLAGS=(-O3 -mmacosx-version-min="$DEPLOYMENT_TARGET" -std=c++20 -DUWS_NO_ZLIB -DLIBUS_USE_OPENSSL -I"$SSL/include"
          -I"$UWS/src" -I"$UWS/uSockets/src")

# epoll_kqueue.c covers kqueue on macOS and epoll on Linux; the libuv, gcd,
# io_uring and quic backends are not compiled in.
for f in bsd context loop socket udp; do
    clang "${CFLAGS[@]}" -c "$UWS/uSockets/src/$f.c" -o "$OBJ/$f.o"
done
clang "${CFLAGS[@]}" -c "$UWS/uSockets/src/eventing/epoll_kqueue.c" -o "$OBJ/epoll_kqueue.o"
clang "${CFLAGS[@]}" -c "$UWS/uSockets/src/crypto/openssl.c" -o "$OBJ/openssl.o"
clang++ "${CXXFLAGS[@]}" -c "$UWS/uSockets/src/crypto/sni_tree.cpp" -o "$OBJ/sni_tree.o"

clang++ "${CXXFLAGS[@]}" -c shim/uws_shim.cpp -o "$OBJ/uws_shim.o"
clang "${CFLAGS[@]}" -c shim/timer_shim.c -o "$OBJ/timer_shim.o"

rm -f "$OUT"
ar rcs "$OUT" "$OBJ"/*.o
echo "built $OUT"
