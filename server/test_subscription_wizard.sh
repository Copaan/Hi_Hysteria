#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export HIHY_ROOT_DIR="$TMP/core"
mkdir -p "$HIHY_ROOT_DIR/conf"
printf '{}\n' >"$HIHY_ROOT_DIR/conf/config.yaml"
printf '{}\n' >"$HIHY_ROOT_DIR/conf/backup.yaml"
domain=unchanged.example
subscriptionEnabled() { [ "${TEST_ENABLED:-false}" = true ]; }
subscriptionCheckPlatform() { [ "${TEST_PLATFORM:-true}" = true ]; }
subscriptionCheckPort() { [ "${TEST_PORT:-true}" = true ]; }
getBackupValueOrDefault() {
    case "$2" in
        mimic_status) echo "${TEST_MIMIC:-false}" ;;
        mimic.enabled) echo "${TEST_CONFIG_MIMIC:-false}" ;;
        masquerade.listenHTTPS) echo "${TEST_LISTEN:-}" ;;
        *) printf '%s\n' "${3:-}" ;;
    esac
}
subscriptionEnable() { printf '%s\n' "$1" >>"$TMP/enabled"; return "${TEST_ENABLE_RESULT:-0}"; }
run_case() {
    local name="$1" input="$2" acme="$3" local_cert_mode="$4" candidate="$5" expected="$6"
    : >"$TMP/enabled"
    printf '%s' "$input" >"$TMP/input"
    subscriptionOfferAfterInstall "$acme" "$local_cert_mode" "$candidate" <"$TMP/input" >"$TMP/$name.log" 2>&1
    [ "$(cat "$TMP/enabled")" = "$expected" ] || { printf 'FAIL: %s\n' "$name"; exit 1; }
    [ "$domain" = unchanged.example ]
}
run_case acme-default $'\n\n' true false HY.EXAMPLE.COM hy.example.com
useDns=true run_case dns-default $'\n\n' true false dns.example.com dns.example.com
run_case local-default $'\n\n' false true local.example.com local.example.com
run_case override $'yes\nsub.example.com\n' true false hy.example.com sub.example.com
run_case decline $'NO\n' true false hy.example.com ''
run_case eof '' true false hy.example.com ''
run_case eof-after-yes $'y\n' true false hy.example.com ''
run_case invalid-choice $'maybe\nY\n\n' true false hy.example.com hy.example.com
run_case invalid-domain $'\nhttps://wrong/path\n sub.example.net \n' true false hy.example.com sub.example.net
run_case selfsigned-skip $'\n' false false www.bing.com ''
run_case selfsigned-other-sni $'\n' false false helloworld.com ''
run_case selfsigned-domain $'SUB.EXAMPLE.COM\n\n' false false www.bing.com sub.example.com
run_case selfsigned-eof $'sub.example.com\n' false false www.bing.com ''
run_case selfsigned-decline $'sub.example.com\nn\n' false false www.bing.com ''
run_case invalid-candidate $'\n' true false 'https://wrong/path' ''
TEST_ENABLED=true run_case enabled '' true false hy.example.com ''
for block in platform port mimic config-mimic tcp443; do
    (
        case "$block" in
            platform) TEST_PLATFORM=false ;;
            port) TEST_PORT=false ;;
            mimic) TEST_MIMIC=true ;;
            config-mimic) TEST_CONFIG_MIMIC=true ;;
            tcp443) TEST_LISTEN='[::]:443' ;;
        esac
        : >"$TMP/enabled"
        if printf '\n\n' | subscriptionOfferAfterInstall true false hy.example.com >"$TMP/blocked.log" 2>&1; then exit 1; fi
        [ ! -s "$TMP/enabled" ]
    )
done
(
    TEST_ENABLE_RESULT=1
    if printf '\n\n' | subscriptionOfferAfterInstall true false hy.example.com >"$TMP/failed.log" 2>&1; then exit 1; fi
)
for phase in download config; do
    if (
        classifyInstallState() { echo not-installed; }
        mkdir() { :; }
        markInstallFailed() { :; }
        installHihyLauncher() { :; }
        checkSystemForUpdate() { :; }
        downloadHysteriaCore() { [ "$phase" != download ]; }
        setHysteriaConfig() { return 1; }
        subscriptionOfferAfterInstall() { touch "$TMP/unexpected-offer"; }
        install
    ) >"$TMP/early-$phase.log" 2>&1; then exit 1; fi
    [ ! -e "$TMP/unexpected-offer" ]
done
printf 'PASS: domain defaults and override, self-signed SNI isolation, decline/EOF, invalid input, conflicts and failed-core gating\n'
