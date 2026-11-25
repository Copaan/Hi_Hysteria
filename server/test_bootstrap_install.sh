#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/install.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/i18n"
printf '#!/bin/bash\ntrue\n' >"$TMP/install.sh"
printf '#!/bin/bash\ntrue\n' >"$TMP/hy2.sh"
for language in en zh fa ru; do printf '{}\n' >"$TMP/i18n/$language.json"; done
manifest() { (cd "$TMP" && sha256sum install.sh hy2.sh i18n/*.json >SHA256SUMS); }
reject() { if "$@" >/dev/null 2>&1; then echo 'FAIL: invalid package accepted' >&2; exit 1; fi; }
manifest
verifyLocalPackage "$TMP" >/dev/null
printf '# tampered\n' >>"$TMP/hy2.sh"
reject verifyLocalPackage "$TMP"
manifest
mv "$TMP/i18n/en.json" "$TMP/en.saved"
reject verifyLocalPackage "$TMP"
mv "$TMP/en.saved" "$TMP/i18n/en.json"
sed -i '/hy2.sh/d' "$TMP/SHA256SUMS"
reject verifyLocalPackage "$TMP"
manifest
mv "$TMP/hy2.sh" "$TMP/real.sh"
ln -s "$TMP/real.sh" "$TMP/hy2.sh"
reject verifyLocalPackage "$TMP"
printf 'PASS: complete, modified, missing, omitted and symlinked package validation\n'
