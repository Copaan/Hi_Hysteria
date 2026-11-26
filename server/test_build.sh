#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
HIHY_BUILD_DIR="$TMP" bash "$ROOT/scripts/build.sh" >/dev/null
for file in hy2.sh install.sh SHA256SUMS; do
    cmp -s "$TMP/$file" "$ROOT/server/$file" || { printf 'FAIL: rebuild %s\n' "$file"; exit 1; }
done
printf 'PASS: runtime, standalone installer and manifest match their sources\n'
