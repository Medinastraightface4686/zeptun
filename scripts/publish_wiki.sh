#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-Noisemux/zeptun}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! git -c credential.helper='!gh auth git-credential' clone -q "https://github.com/$REPO.wiki.git" "$WORK/wiki" 2> /dev/null; then
    printf 'zeptun: the wiki of %s does not exist yet\n' "$REPO" >&2
    printf 'zeptun: enable it in Settings, create the first page, then run this script again\n' >&2
    exit 1
fi

find "$WORK/wiki" -maxdepth 1 -name "*.md" -delete
cp "$ROOT"/docs/wiki/*.md "$WORK/wiki/"
mkdir -p "$WORK/wiki/res"
cp "$ROOT"/docs/bench/*.svg "$WORK/wiki/res/"

cd "$WORK/wiki"
git config user.name "$(git -C "$ROOT" config user.name)"
git config user.email "$(git -C "$ROOT" config user.email)"
git add -A
if git diff --cached --quiet; then
    printf 'zeptun: wiki already up to date\n'
    exit 0
fi
TZ=UTC git commit -q -m "documentation and benchmark results"
git -c credential.helper='!gh auth git-credential' push -q origin HEAD
printf 'zeptun: wiki updated at https://github.com/%s/wiki\n' "$REPO"
