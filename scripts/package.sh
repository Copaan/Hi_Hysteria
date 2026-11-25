#!/bin/bash
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
bash scripts/build.sh
bash server/test_build.sh
version=$(sed -n 's/^hihyV="\([^"]*\)"$/\1/p' server/hy2.sh)
[[ "$version" =~ ^ver[0-9]+\.[0-9]+-secure\.[0-9]+$ ]] || { echo 'Unexpected package version.' >&2; exit 1; }
name="hihy-$version"
mkdir -p dist
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/$name/i18n"
cp server/install.sh server/hy2.sh server/SHA256SUMS "$stage/$name/"
cp server/i18n/{en,zh,fa,ru}.json "$stage/$name/i18n/"
cp LICENSE "$stage/$name/"
cp md/security-install.md "$stage/$name/SECURITY_INSTALL.md"
cp md/security-test-report.md "$stage/$name/TEST_REPORT.md"
(cd "$stage/$name" && sha256sum --strict --check SHA256SUMS)
epoch=1795622400
tar --sort=name --format=ustar --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --mode='u+rwX,go-rwx' -cf - -C "$stage" "$name" | gzip -n >"dist/$name.tar.gz"
(cd dist && sha256sum "$name.tar.gz" | tr -d '\r' | sed 's/ \*/  /' >"$name.tar.gz.sha256")
printf 'Built %s/dist/%s.tar.gz\n' "$ROOT" "$name"
