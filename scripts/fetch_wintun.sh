#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/third-part/wintun"
VERSION=${WINTUN_VERSION:-0.14.1}
SHA256=${WINTUN_SHA256:-07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51}

download() {
    work=$1
    curl -sSL -o "$work/wintun.zip" "https://www.wintun.net/builds/wintun-$VERSION.zip"
    if command -v sha256sum > /dev/null 2>&1; then
        printf '%s  %s\n' "$SHA256" "$work/wintun.zip" | sha256sum -c - > /dev/null
    elif command -v shasum > /dev/null 2>&1; then
        printf '%s  %s\n' "$SHA256" "$work/wintun.zip" | shasum -a 256 -c - > /dev/null
    else
        printf 'fetch_wintun: no sha256 tool available\n' >&2
        exit 1
    fi
    unzip -q -o "$work/wintun.zip" -d "$work"
}

vendor() {
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    download "$work"
    rm -rf "$VENDOR"
    mkdir -p "$VENDOR/include"
    cp "$work/wintun/LICENSE.txt" "$work/wintun/README.md" "$VENDOR/"
    cp "$work/wintun/include/wintun.h" "$VENDOR/include/"
    for arch in amd64 arm64 x86 arm; do
        mkdir -p "$VENDOR/bin/$arch"
        cp "$work/wintun/bin/$arch/wintun.dll" "$VENDOR/bin/$arch/"
    done
    printf '%s\n' "$VERSION" > "$VENDOR/VERSION"
    printf 'fetch_wintun: vendored wintun %s in %s\n' "$VERSION" "$VENDOR"
}

if [ "${1:-}" = "--vendor" ]; then
    vendor
    exit 0
fi

ARCH=${1:-amd64}
DEST=${2:-zig-out/bin}

case "$ARCH" in
    amd64 | x86_64) ARCH=amd64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    x86 | i686 | i386) ARCH=x86 ;;
    arm | armv7) ARCH=arm ;;
    *)
        printf 'fetch_wintun: unknown architecture %s\n' "$ARCH" >&2
        exit 1
        ;;
esac

mkdir -p "$DEST"

if [ -f "$VENDOR/bin/$ARCH/wintun.dll" ]; then
    cp "$VENDOR/bin/$ARCH/wintun.dll" "$DEST/wintun.dll"
    cp "$VENDOR/LICENSE.txt" "$DEST/wintun-LICENSE.txt"
    printf 'fetch_wintun: wintun %s (%s) from the tree in %s\n' "$(cat "$VENDOR/VERSION")" "$ARCH" "$DEST/wintun.dll"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
download "$work"
cp "$work/wintun/bin/$ARCH/wintun.dll" "$DEST/wintun.dll"
cp "$work/wintun/LICENSE.txt" "$DEST/wintun-LICENSE.txt"
printf 'fetch_wintun: wintun %s (%s) downloaded to %s\n' "$VERSION" "$ARCH" "$DEST/wintun.dll"
