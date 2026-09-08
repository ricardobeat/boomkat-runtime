#!/usr/bin/env bash
# Reconstructs the parts of vendor/ that are not committed, and re-applies the
# one local edit this project needs. Safe to re-run.
#
# Not committed: the uWebSockets checkout (~1.3 GB with submodules), the
# libwebsockets source tree (~119 MB with its build), and libwebsockets.c3l
# (carries its own .git, so it cannot be committed as plain files).
set -euo pipefail
cd "$(dirname "$0")/.."

# --- uWebSockets ---------------------------------------------------------
if [[ ! -d vendor/uWebSockets/uSockets/src ]]; then
    echo "cloning uWebSockets v20.80.0..."
    git clone --depth 1 --branch v20.80.0 --recurse-submodules -j4 \
        https://github.com/uNetworking/uWebSockets.git vendor/uWebSockets
fi

# --- libwebsockets source, for the SMP-enabled build ---------------------
if [[ ! -d vendor/lws-src/lib ]]; then
    echo "cloning libwebsockets v5.0.0..."
    git clone --depth 1 --branch v5.0.0 \
        https://github.com/warmcat/libwebsockets.git vendor/lws-src
fi

# --- libwebsockets.c3l ---------------------------------------------------
# This one cannot be fetched here: it is a local C3 binding, not a public
# dependency of this project. Copy it in from wherever it lives.
if [[ ! -f vendor/libwebsockets.c3l/manifest.json ]]; then
    echo "ERROR: vendor/libwebsockets.c3l is missing." >&2
    echo "  It is the C3 binding for libwebsockets and is not fetched here." >&2
    echo "  Copy it into vendor/ before continuing." >&2
    exit 1
fi

# The manifest ships pointing at the homebrew static library, which is built
# with LWS_MAX_SMP 1 and silently clamps count_threads to 1. Point it at the
# SMP-enabled build instead. Idempotent.
if grep -q '/opt/homebrew/lib/libwebsockets.a' vendor/libwebsockets.c3l/manifest.json; then
    echo "pointing libwebsockets.c3l manifest at the SMP build..."
    sed -i '' 's|/opt/homebrew/lib/libwebsockets.a|vendor/lws-src/build/lib/libwebsockets.a|g' \
        vendor/libwebsockets.c3l/manifest.json
fi

./scripts/build_lws.sh
./scripts/build_uws.sh

echo
echo "vendor/ ready. Now:  c3c build test-server && c3c build test-server-uws"
