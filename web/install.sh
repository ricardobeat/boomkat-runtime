#!/bin/sh
# Installs the bkr JavaScript runtime.
#
#   curl https://boomkat.run/install | sh
#
# Environment:
#   BKR_INSTALL   install directory (default: $HOME/.local/bin)
#   BKR_VERSION   release tag to install, e.g. v0.1.0 (default: latest)
set -eu

REPO=ricardobeat/boomkat-runtime
DIR=${BKR_INSTALL:-$HOME/.local/bin}

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)                target=macos-aarch64 ;;
    Linux/x86_64|Linux/amd64)    target=linux-x86_64 ;;
    Linux/aarch64|Linux/arm64)   target=linux-aarch64 ;;
    *) die "no bkr build for $(uname -s) $(uname -m); available: macOS arm64, Linux x86-64 and arm64" ;;
esac

if [ "$(uname -s)" = Darwin ]; then
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 26 ] || die "bkr needs macOS 26 or later (this is $(sw_vers -productVersion))"
fi

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q "$1" -O "$2"; }
else
    die "curl or wget is required"
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum "$1" | cut -d' ' -f1; }
else
    sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

if [ -n "${BKR_VERSION:-}" ]; then
    base=https://github.com/$REPO/releases/download/$BKR_VERSION
else
    base=https://github.com/$REPO/releases/latest/download
fi
name=bkr-$target.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading $name"
fetch "$base/$name" "$tmp/$name" || die "download failed: $base/$name"
fetch "$base/$name.sha256" "$tmp/$name.sha256" || die "checksum download failed"

want=$(cut -d' ' -f1 "$tmp/$name.sha256")
got=$(sha "$tmp/$name")
[ "$want" = "$got" ] || die "checksum mismatch (expected $want, got $got)"

tar -xzf "$tmp/$name" -C "$tmp"
mkdir -p "$DIR"
mv "$tmp/bkr" "$DIR/bkr.new"
chmod 755 "$DIR/bkr.new"
mv "$DIR/bkr.new" "$DIR/bkr"

say "installed $DIR/bkr"

case ":$PATH:" in
    *":$DIR:"*) ;;
    *) say "add it to your PATH:  export PATH=\"$DIR:\$PATH\"" ;;
esac

# bkr loads OpenSSL at run time.
if [ "$(uname -s)" = Darwin ]; then
    [ -e /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib ] ||
        say "note: bkr needs OpenSSL 3; install it with: brew install openssl@3"
elif ! { ldconfig -p 2>/dev/null | grep -q 'libssl\.so\.3'; }; then
    say "note: bkr needs libssl.so.3; install it with your package manager (libssl3 on Debian/Ubuntu)"
fi
