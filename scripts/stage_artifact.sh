#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-$ROOT/zig-out}
DEST=${1:?usage: stage_artifact.sh DEST}

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/include"

for f in "$SRC"/bin/*; do
    [ -f "$f" ] || continue
    case "$f" in
        *.pdb) continue ;;
    esac
    cp "$f" "$DEST/bin/"
done

for f in "$SRC"/include/*.h "$SRC"/include/*.modulemap; do
    [ -f "$f" ] && cp "$f" "$DEST/include/"
done

for f in "$SRC"/lib/*; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    case "$f" in
        *.pdb) continue ;;
    esac
    cp "$f" "$DEST/lib/"
done

rmdir "$DEST/bin" "$DEST/lib" "$DEST/include" 2> /dev/null || true

printf 'staged %s\n' "$DEST"
find "$DEST" -type f | sort | while read -r f; do
    printf '  %8s  %s\n' "$(wc -c < "$f" | tr -d ' ')" "${f#"$DEST"/}"
done
