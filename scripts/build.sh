#!/bin/bash
# 从模块生成独立运行脚本、单文件安装器及摘要清单。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${HIHY_BUILD_DIR:-$ROOT/server}"
mkdir -p "$OUT_DIR"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
shopt -s nullglob
modules=("$ROOT/server/src/"*.sh)
[ "${#modules[@]}" -gt 0 ] || { echo '没有可构建的模块。' >&2; exit 1; }
first=true
for module in "${modules[@]}"; do
    if [ "$first" = true ]; then
        head -n 1 "$module" >"$stage/hy2.sh"
        grep '^hihyV=' "$module" >>"$stage/hy2.sh"
        printf '%s\n' '# GENERATED FILE — edit server/src/ and run bash scripts/build.sh.' >>"$stage/hy2.sh"
        tail -n +2 "$module" | grep -v '^hihyV=' >>"$stage/hy2.sh"
        first=false
    else
        printf '\n# ----- %s -----\n' "$(basename "$module")" >>"$stage/hy2.sh"
        if head -n 1 "$module" | grep -q '^#!'; then tail -n +2 "$module" >>"$stage/hy2.sh"; else cat "$module" >>"$stage/hy2.sh"; fi
    fi
done
bash -n "$stage/hy2.sh"
digest=$(sha256sum "$stage/hy2.sh" | cut -d' ' -f1)
marker="__HIHY_RUNTIME_$digest"
! grep -Fxq "$marker" "$stage/hy2.sh"
cp "$ROOT/scripts/install-header.sh" "$stage/install.sh"
printf '\nHIHY_EMBEDDED_SHA256=\x27%s\x27\nextractEmbeddedRuntime() {\n    cat <<\x27%s\x27\n' "$digest" "$marker" >>"$stage/install.sh"
cat "$stage/hy2.sh" >>"$stage/install.sh"
printf '%s\n}\n\n' "$marker" >>"$stage/install.sh"
printf '%s\n' 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then installerMain "$@"; fi' >>"$stage/install.sh"
bash -n "$stage/install.sh"
(cd "$stage" && sha256sum install.sh hy2.sh | tr -d '\r' | sed 's/ \*/  /' >SHA256SUMS)
for file in hy2.sh install.sh SHA256SUMS; do mv -- "$stage/$file" "$OUT_DIR/$file"; done
chmod +x "$OUT_DIR/hy2.sh" "$OUT_DIR/install.sh"
printf '已从 %s 个模块生成主程序、单文件安装器和摘要。\n' "${#modules[@]}"
