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
mkdir -p "$stage/$name"
cp server/install.sh server/hy2.sh server/SHA256SUMS "$stage/$name/"
cp LICENSE "$stage/$name/"
cp md/security-install.md "$stage/$name/INSTALL.md"
cp md/subscriptions.md "$stage/$name/SUBSCRIPTIONS.md"
(cd "$stage/$name" && sha256sum --strict --check SHA256SUMS)
epoch=1795651200
tar --sort=name --format=ustar --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --mode='u+rwX,go-rwx' -cf - -C "$stage" "$name" | gzip -n >"dist/$name.tar.gz"
(cd dist && sha256sum "$name.tar.gz" | tr -d '\r' | sed 's/ \*/  /' >"$name.tar.gz.sha256")
cp server/install.sh "dist/install-$version.sh"
(cd dist && sha256sum "install-$version.sh" | tr -d '\r' | sed 's/ \*/  /' >"install-$version.sh.sha256")
printf 'Built %s/dist/%s.tar.gz and install-%s.sh\n' "$ROOT" "$name" "$version"
