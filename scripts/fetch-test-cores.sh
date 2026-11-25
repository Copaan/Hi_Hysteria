#!/bin/bash
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="${1:?Pass a private test tool directory}"
mkdir -p "$OUT"
source "$ROOT/server/hy2.sh"
[ "$(uname -m)" = x86_64 ] || { echo 'Test downloads target Linux amd64.' >&2; exit 1; }
downloadVerifiedFile 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.34/mihomo-linux-amd64-compatible-v1.19.34.gz' "$OUT/mihomo.gz" 2763f5b414527f7baf6dc57e3f82f3ab561eedf34bfd7c2f2cde1f7e592efe06
gzip -dc "$OUT/mihomo.gz" >"$OUT/mihomo"
downloadVerifiedFile 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz' "$OUT/singbox.tar.gz" 699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968
tar -xOf "$OUT/singbox.tar.gz" sing-box-1.14.4-linux-amd64/sing-box >"$OUT/sing-box"
chmod 700 "$OUT/mihomo" "$OUT/sing-box"
"$OUT/mihomo" -v | head -1
"$OUT/sing-box" version | head -1
