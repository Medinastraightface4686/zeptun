#!/bin/sh
set -eu

VERSION=${WINTUN_VERSION:-0.14.1}
SHA256=${WINTUN_SHA256:-07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51}
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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -sSL -o "$WORK/wintun.zip" "https://www.wintun.net/builds/wintun-$VERSION.zip"

if command -v sha256sum > /dev/null 2>&1; then
    printf '%s  %s\n' "$SHA256" "$WORK/wintun.zip" | sha256sum -c - > /dev/null
elif command -v shasum > /dev/null 2>&1; then
    printf '%s  %s\n' "$SHA256" "$WORK/wintun.zip" | shasum -a 256 -c - > /dev/null
else
    printf 'fetch_wintun: no sha256 tool available\n' >&2
    exit 1
fi

unzip -q -o "$WORK/wintun.zip" -d "$WORK"
mkdir -p "$DEST"
cp "$WORK/wintun/bin/$ARCH/wintun.dll" "$DEST/wintun.dll"
printf 'fetch_wintun: wintun %s (%s) in %s\n' "$VERSION" "$ARCH" "$DEST/wintun.dll"
