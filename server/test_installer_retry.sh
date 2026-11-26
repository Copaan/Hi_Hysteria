#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/install.sh"
source "$ROOT/server/hy2.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
reject() { if "$@" >"$TMP/rejected.log" 2>&1; then echo 'FAIL: unsafe recovery accepted'; exit 1; fi; }

(
    cp "$ROOT/server/hy2.sh" "$TMP/deleted-runtime"
    source "$TMP/deleted-runtime"
    HIHY_BIN_LINK="$TMP/deleted-runtime"
    rm -- "$HIHY_BIN_LINK"
    classifyInstallState() { echo not-installed; }
    mkdir() { :; }
    markInstallFailed() { touch "$TMP/unexpected-marker"; }
    if install >"$TMP/deleted.log" 2>&1; then exit 1; fi
    [ ! -e "$TMP/unexpected-marker" ]
)
grep -q '本地主程序缺失' "$TMP/deleted.log"
printf 'PASS: deleted running script fails before creating installation state\n'

(
    show_menu() { :; }
    wait_for_continue() { :; }
    uninstall() { return "${TEST_UNINSTALL_RESULT:-0}"; }
    install() { touch "$TMP/unexpected-install"; }
    printf '2\n1\n0\n' | menu >"$TMP/menu.log"
    [ ! -e "$TMP/unexpected-install" ]
    grep -q 'bash install.sh' "$TMP/menu.log"
    TEST_UNINSTALL_RESULT=1
    printf '2\n1\n0\n' | menu >/dev/null
    [ -f "$TMP/unexpected-install" ]
)
printf 'PASS: successful uninstall leaves the menu; failed uninstall keeps it available\n'

root="$TMP/root"; launcher="$TMP/launcher"
mkdir -p "$root"/{bin,conf,cert,result,logs}
getHihyServiceScriptPrimary() { echo "$TMP/primary"; }
getHihyServiceScriptFallback() { echo "$TMP/fallback"; }
marker="$root/result/install.failed"
printf 'phase=launcher\ndetails=failed to install hihy launcher at start\n' >"$marker"
cp "$marker" "$TMP/marker-before"
installerRequireFresh "$root" "$launcher"
cmp -s "$marker" "$TMP/marker-before"
printf 'private tool\n' >"$root/bin/yq"
installerCanRetryLauncherFailure "$root"
for path in "$root/bin/appS" "$root/conf/config.yaml" "$root/conf/backup.yaml" \
    "$root/cert/private.key" "$root/result/client.yaml" "$TMP/primary" "$TMP/fallback"; do
    printf 'preserve\n' >"$path"
    reject installerRequireFresh "$root" "$launcher"
    [ "$(cat "$path")" = preserve ]
    cmp -s "$marker" "$TMP/marker-before"
    rm -- "$path"
done
for path in "$root/conf/config.yaml" "$root/cert/link" "$TMP/primary" "$TMP/fallback"; do
    ln -s "$TMP/nonexistent" "$path"
    reject installerRequireFresh "$root" "$launcher"
    rm -- "$path"
done
rm -- "$root/bin/yq"
ln -s "$TMP/nonexistent" "$root/bin/yq"
reject installerRequireFresh "$root" "$launcher"
rm -- "$root/bin/yq"
printf 'phase=core-download\ndetails=failed\n' >"$marker"
reject installerRequireFresh "$root" "$launcher"
grep -q '主程序缺失' "$TMP/rejected.log"
printf 'PASS: only exact launcher-only failures can retry; configurations, certificates, services, symlinks and other failures are preserved\n'
