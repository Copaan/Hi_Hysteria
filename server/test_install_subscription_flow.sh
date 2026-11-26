#!/bin/bash
set -euo pipefail
umask 077
[ "$(id -u)" = 0 ] && [ -f /etc/hihy-test-environment ] && [ -d /run/systemd/system ] || { echo 'Disposable systemd VM required.' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
if [ -f "$HIHY_ROOT_DIR/conf/config.yaml" ]; then uninstall >"$TMP/cleanup.log" 2>&1; fi

# 用固定的本地证书配置代替前置问答，安装与订阅引导仍运行生产代码。
setHysteriaConfig() {
    setConfigDefaults
    port=34567; ip=127.0.0.1; domain=server.test; auth_secret=wizard-test
    useLocalCert=true
    if [ "${1:-}" = install ]; then
        [ ! -e "$HIHY_ROOT_DIR/conf/config.yaml" ] || return 2
        [ "$(getServiceRunState)" != running ] || return 2
        subscriptionCollectInstallChoice "$useAcme" "$useLocalCert" "$domain" || return 1
        printf '%s\n' "$HIHY_INSTALL_SUBSCRIPTION_DOMAIN" >"$TMP/chosen-before-config"
    fi
    local_cert="$HIHY_ROOT_DIR/cert/wizard.crt"; local_key="$HIHY_ROOT_DIR/cert/wizard.key"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=server.test -addext subjectAltName=DNS:server.test -keyout "$local_key" -out "$local_cert" >"$TMP/cert.log" 2>&1 || return 1
    writeHysteriaConfig
}
subscriptionEnable() {
    [ "$1" = server.test ] || return 2
    [ "$(getServiceRunState)" = running ] || return 2
    [ ! -f "$(getInstallFailureMarker)" ] || return 2
    sha256sum "$HIHY_ROOT_DIR/conf/config.yaml" >"$TMP/core-before-subscription"
    printf '%s\n' "$1" >"$TMP/requested-domain"
    return 1
}
printf '\n\n' | install >"$TMP/manual.log" 2>&1 || { tail -25 "$TMP/manual.log"; exit 1; }
[ "$(cat "$TMP/requested-domain")" = server.test ]
[ "$(cat "$TMP/chosen-before-config")" = server.test ]
[ "$(getServiceRunState)" = running ]
[ ! -f "$(getInstallFailureMarker)" ]
sha256sum --check --status "$TMP/core-before-subscription"
grep -q 'HTTPS 订阅未启用，可在菜单 17 重试' "$TMP/manual.log"
printf 'PASS: selection is collected before configuration; application waits for service startup and failure preserves the running core\n'

uninstall >"$TMP/uninstall.log" 2>&1
subscriptionCollectInstallChoice() { touch "$TMP/unexpected-offer"; return 1; }
subscriptionApplyInstallChoice() { touch "$TMP/unexpected-offer"; return 1; }
HIHY_AUTO_IP=127.0.0.1 HIHY_AUTO_PORT=34567 HIHY_AUTO_PASSWORD=auto-wizard-test HIHY_AUTO_DOMAIN=owned.example.test install auto </dev/null >"$TMP/auto.log" 2>&1 || { tail -25 "$TMP/auto.log"; exit 1; }
[ ! -e "$TMP/unexpected-offer" ]
[ "$(getServiceRunState)" = running ]
changeServerConfig </dev/null >"$TMP/reconfigure.log" 2>&1 || { tail -25 "$TMP/reconfigure.log"; exit 1; }
[ ! -e "$TMP/unexpected-offer" ]
[ "$(getServiceRunState)" = running ]
printf 'PASS: automatic installation with a domain and later reconfiguration do not offer or enable subscriptions\n'
