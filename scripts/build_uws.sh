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
