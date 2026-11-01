#!/usr/bin/env bash
# Builds vendor/uws.c3l/<platform>/libuws.a: the uSockets C library plus the
# C++ shim that gives it an extern "C" surface C3 can bind.
#
# Kept out of project.json because c3c's c-sources drive a C compiler, and the
# shim needs a C++ one. Run this before `c3c build bkr`.
set -euo pipefail
cd "$(dirname "$0")/.."

UWS=vendor/uWebSockets
# The archive goes into the uws.c3l library, in the directory c3c names
# after the platform it builds for (macos-aarch64, linux-x64, ...).
case "$(uname -m)" in
    arm64|aarch64) ARCH=aarch64 ;;
    x86_64|amd64) ARCH=x64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
if [[ "$(uname -s)" == Darwin ]]; then
    PLATFORM=macos-$ARCH
    CC=${CC:-clang}
    CXX=${CXX:-clang++}
else
    PLATFORM=linux-$ARCH
    CC=${CC:-cc}
    CXX=${CXX:-c++}
fi
OBJ=build/uws-obj-$PLATFORM
OUT=vendor/uws.c3l/$PLATFORM/libuws.a

[[ -d "$UWS/uSockets/src" ]] || { echo "missing $UWS -- clone it with --recurse-submodules" >&2; exit 1; }

mkdir -p "$OBJ" "$(dirname "$OUT")"

# Static responses serialize their immutable headers once. This writes only
# that block; uWS still owns status, Date, framing and socket lifecycle.
python3 - "$UWS/src/HttpResponse.h" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
marker = '    /* Write an HTTP header with string value */'
addition = '''    /* A serialized header block from runtime-owned static responses. */
    HttpResponse *writeHeaders(std::string_view headers) {
        writeStatus(HTTP_200_OK);
        Super::write(headers.data(), (int) headers.length());
        return this;
    }

'''
if addition not in s:
    if marker not in s:
        raise SystemExit('unrecognized uWebSockets header writer')
    s = s.replace(marker, addition + marker, 1)
p.write_text(s)
PY

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
python3 - "$UWS/uSockets/src/eventing/epoll_kqueue.c" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace(
    'EV_ADD | (repeat_ms ? 0 : EV_ONESHOT), 0, ms, internal_cb);',
    'EV_ADD | (repeat_ms ? 0 : EV_ONESHOT), NOTE_USECONDS | NOTE_CRITICAL, (int64_t) ms * 1000, internal_cb);')
p.write_text(s)
PY

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

# OpenSSL for TLS sockets (fetch, net, serve); no zlib, since permessage-deflate
# is never negotiated.
if [[ "$(uname -s)" == Darwin ]]; then
    SSL=$(brew --prefix openssl@3)
    if [ ! -f "$SSL/lib/libssl.3.dylib" ]; then
        echo "openssl@3 is missing; install it with: brew install openssl@3" >&2
        exit 1
    fi
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
    PLATFORM_FLAGS=(-mmacosx-version-min="$DEPLOYMENT_TARGET" -I"$SSL/include")
else
    if [ ! -f /usr/include/openssl/ssl.h ]; then
        echo "OpenSSL headers are missing; install libssl-dev (Debian) or openssl-devel (Fedora)" >&2
        exit 1
    fi
    PLATFORM_FLAGS=(-fPIC)
fi
CFLAGS=(-O3 "${PLATFORM_FLAGS[@]}" -std=c11 -DLIBUS_USE_OPENSSL -I"$UWS/uSockets/src")
CXXFLAGS=(-O3 "${PLATFORM_FLAGS[@]}" -std=c++20 -DUWS_NO_ZLIB -DLIBUS_USE_OPENSSL
          -I"$UWS/src" -I"$UWS/uSockets/src")

# epoll_kqueue.c covers kqueue on macOS and epoll on Linux; the libuv, gcd,
# io_uring and quic backends are not compiled in.
for f in bsd context loop socket udp; do
    "$CC" "${CFLAGS[@]}" -c "$UWS/uSockets/src/$f.c" -o "$OBJ/$f.o"
done
"$CC" "${CFLAGS[@]}" -c "$UWS/uSockets/src/eventing/epoll_kqueue.c" -o "$OBJ/epoll_kqueue.o"
"$CC" "${CFLAGS[@]}" -c "$UWS/uSockets/src/crypto/openssl.c" -o "$OBJ/openssl.o"
"$CXX" "${CXXFLAGS[@]}" -c "$UWS/uSockets/src/crypto/sni_tree.cpp" -o "$OBJ/sni_tree.o"

"$CXX" "${CXXFLAGS[@]}" -c shim/uws_shim.cpp -o "$OBJ/uws_shim.o"
"$CXX" "${CXXFLAGS[@]}" -c shim/process_pool.cpp -o "$OBJ/process_pool.o"
"$CC" "${CFLAGS[@]}" -c shim/timer_shim.c -o "$OBJ/timer_shim.o"
"$CC" "${CFLAGS[@]}" -c shim/tls_probe.c -o "$OBJ/tls_probe.o"

rm -f "$OUT"
ar rcs "$OUT" "$OBJ"/*.o
echo "built $OUT"
