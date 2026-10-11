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

# kqueue reports EV_EOF together with unread data, and uSockets treats it as
# an error, dropping what the peer sent right before closing. Reading to the
# real end (recv returning 0) is the correct behaviour. Idempotent.
sed -i '' 's/flags & (EV_ERROR | EV_EOF);/flags \& EV_ERROR;/' "$UWS/uSockets/src/eventing/epoll_kqueue.c"

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
    open(p, "w").write(s.replace(old, new, 1))
PY

# OpenSSL for TLS sockets (fetch, net); no zlib, since permessage-deflate
# is never negotiated.
SSL=$(brew --prefix openssl@3)
CFLAGS=(-O3 -std=c11 -DLIBUS_USE_OPENSSL -I"$SSL/include" -I"$UWS/uSockets/src")
CXXFLAGS=(-O3 -std=c++20 -DUWS_NO_ZLIB -DLIBUS_USE_OPENSSL -I"$SSL/include"
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

rm -f "$OUT"
ar rcs "$OUT" "$OBJ"/*.o
echo "built $OUT"
