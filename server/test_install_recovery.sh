#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/hihy/bin" "$TMP/hihy/conf"
root="$TMP/hihy"; launcher="$TMP/launcher"; service="$TMP/service"; fallback="$TMP/fallback"
state() { classifyInstallState "$root" "$launcher" "$service" "$fallback" "$root/result/install.failed"; }
[ "$(state)" = not-installed ]
printf '#!/bin/sh\ntrue\n' >"$launcher"; chmod 700 "$launcher"
[ "$(state)" = not-installed ]
printf '#!/bin/sh\ntrue\n' >"$root/bin/appS"; chmod 700 "$root/bin/appS"
printf '#!/bin/sh\ntrue\n' >"$service"; chmod 700 "$service"
[ "$(state)" = partially-installed ]
printf '{}\n' >"$root/conf/config.yaml"
[ "$(state)" = partially-installed ]
printf '{}\n' >"$root/conf/backup.yaml"
[ "$(state)" = installed ]
mkdir -p "$root/result"; printf 'failed\n' >"$root/result/install.failed"
[ "$(state)" = partially-installed ]
printf 'PASS: installation state requires all assets and preserves incomplete installations\n'
