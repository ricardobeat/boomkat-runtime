#!/usr/bin/env bash
# Builds vendor/lws-src/build/lib/libwebsockets.a with SMP enabled.
#
# Homebrew's libwebsockets ships LWS_MAX_SMP 1, which silently clamps
# count_threads to 1 -- the server's multi-threading is inert against it. This
# builds the same version (5.0.0) with LWS_MAX_SMP 8.
#
# HTTP3 is off because it force-enables GnuTLS (see the FORCE in the upstream
# CMakeLists), which then fails to link. Everything else matches the homebrew
# feature set closely enough that the structs the C3 bindings mirror keep
# identical sizes and offsets -- scripts/check_lws_abi.sh verifies that.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=vendor/lws-src
[[ -d "$SRC" ]] || { echo "missing $SRC -- git clone --depth 1 --branch v5.0.0 https://github.com/warmcat/libwebsockets.git $SRC" >&2; exit 1; }

rm -rf "$SRC/build"
cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLWS_MAX_SMP=8 \
    -DLWS_WITH_STATIC=ON -DLWS_WITH_SHARED=OFF \
    -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON -DLWS_WITHOUT_TEST_CLIENT=ON \
    -DLWS_WITH_SSL=ON -DLWS_WITH_HTTP2=ON \
    -DLWS_WITH_HTTP3=OFF -DLWS_WITH_GNUTLS=OFF -DLWS_WITH_MBEDTLS=OFF \
    -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3 \
    >/dev/null
cmake --build "$SRC/build" -j"$(sysctl -n hw.ncpu)" >/dev/null
grep -q '^#define LWS_MAX_SMP 8' "$SRC/build/lws_config.h" || { echo "LWS_MAX_SMP not 8" >&2; exit 1; }
echo "built $SRC/build/lib/libwebsockets.a (LWS_MAX_SMP 8)"
