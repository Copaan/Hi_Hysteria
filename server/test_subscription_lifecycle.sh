#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] && [ -f /etc/hihy-test-environment ] && [ -d /run/systemd/system ] || { echo 'Disposable systemd Linux VM required.' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(secureTempDir)
created_system_caddy=false
cleanup() {
    if [ "${HIHY_SUB_TEST_KEEP:-0}" != 1 ]; then subscriptionUninstall >/dev/null 2>&1 || true; fi
    iptables -D INPUT -p tcp --dport 443 -m comment --comment hihy-unrelated-sub-test -j ACCEPT 2>/dev/null || true
    if [ "$created_system_caddy" = true ]; then rm -f /usr/bin/caddy; fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT
cp "$ROOT/server/hy2.sh" /usr/bin/hihy; chmod 700 /usr/bin/hihy
for lang in en zh fa ru; do cp "$ROOT/server/i18n/$lang.json" "/etc/hihy/i18n/hy2.sh.$lang.json"; chmod 600 "/etc/hihy/i18n/hy2.sh.$lang.json"; done
subscriptionPreparePaths
subscriptionInstallCaddy
cp -p "$HIHY_SUB_LIB/caddy" "$TMP/caddy.original"
cp -p "$HIHY_SUB_LIB/caddy.sha256" "$TMP/caddy.sha256.original"
printf '#!/bin/sh\ntouch %s/unexpected-execution\n' "$TMP" >"$HIHY_SUB_LIB/caddy"
if subscriptionInstallCaddy >"$TMP/hash-refusal.log" 2>&1; then exit 1; fi
sha256sum "$HIHY_SUB_LIB/caddy" | cut -d' ' -f1 >"$HIHY_SUB_LIB/caddy.sha256"
if subscriptionInstallCaddy >"$TMP/arch-refusal.log" 2>&1; then exit 1; fi
[ ! -e "$TMP/unexpected-execution" ]
cp -p "$TMP/caddy.original" "$HIHY_SUB_LIB/caddy"
cp -p "$TMP/caddy.sha256.original" "$HIHY_SUB_LIB/caddy.sha256"
printf 'PASS: tampered digest and non-ELF Caddy are rejected before execution\n'
if [ ! -e /usr/bin/caddy ]; then printf '#!/bin/sh\nexit 71\n' >/usr/bin/caddy; chmod 755 /usr/bin/caddy; created_system_caddy=true; fi
system_caddy_hash=$(sha256sum /usr/bin/caddy)
iptables -I INPUT -p tcp --dport 443 -m comment --comment hihy-unrelated-sub-test -j ACCEPT
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=SubscriptionTestCA -keyout "$TMP/ca.key" -out "$TMP/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=sub.example.test -keyout "$HIHY_SUB_STATE/caddy/fixture.key" -out "$TMP/leaf.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:sub.example.test\nextendedKeyUsage=serverAuth\n' >"$TMP/extensions"
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" -CAcreateserial -days 2 -extfile "$TMP/extensions" -out "$HIHY_SUB_STATE/caddy/fixture.crt" >/dev/null 2>&1
cp "$TMP/ca.crt" "$HIHY_SUB_STATE/caddy/test-ca.crt"
chown "$HIHY_SUB_USER:$HIHY_SUB_USER" "$HIHY_SUB_STATE/caddy/fixture."* "$HIHY_SUB_STATE/caddy/test-ca.crt"
chmod 600 "$HIHY_SUB_STATE/caddy/fixture."* "$HIHY_SUB_STATE/caddy/test-ca.crt"
export CURL_CA_BUNDLE="$HIHY_SUB_STATE/caddy/test-ca.crt"
eval "$(declare -f subscriptionWriteCaddyConfig | sed '1s/subscriptionWriteCaddyConfig/subscriptionWriteCaddyProduction/')"
subscriptionWriteCaddyConfig() {
    subscriptionWriteCaddyProduction "$@"
    python3 - "$3" "$HIHY_SUB_STATE" <<'PY'
import pathlib,sys
file=pathlib.Path(sys.argv[1]); text=file.read_text()
start=text.index('    tls {'); end=text.index('    header {',start)
file.write_text(text[:start]+f'    tls {sys.argv[2]}/caddy/fixture.crt {sys.argv[2]}/caddy/fixture.key\n'+text[end:])
PY
}
subscriptionCheckDomain() { [ "$1" = sub.example.test ]; }
core_before=$(sha256sum "$HIHY_ROOT_DIR/conf/config.yaml")
before_pointer=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null || true)
(
    subscriptionProbe() { return 1; }
    if subscriptionEnable sub.example.test >"$TMP/rejected-tls.log" 2>&1; then exit 1; fi
)
! systemctl is-active --quiet hihy-sub.service
! subscriptionEnabled
[ "$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null || true)" = "$before_pointer" ]
[ "$(sha256sum "$HIHY_ROOT_DIR/conf/config.yaml")" = "$core_before" ]
[ "$(find "$HIHY_SUB_STATE/content/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 1 ]
printf 'PASS: failed HTTPS activation restores the stopped endpoint and running core\n'
if ! subscriptionEnable sub.example.test >"$TMP/enable.log" 2>&1; then sed -E 's/[0-9a-f]{64}/[redacted]/g' "$TMP/enable.log"; exit 1; fi
[ "$(systemctl show -p User --value hihy-sub.service)" = hihy-sub ]
pid=$(systemctl show -p MainPID --value hihy-sub.service)
[ "$(ps -o user= -p "$pid" | tr -d ' ')" = hihy-sub ]
if lsof -a -p "$pid" -iUDP:443 >/dev/null 2>&1; then echo 'FAIL: subscription binds UDP 443'; exit 1; fi
if lsof -a -p "$pid" -iTCP:80 -iTCP:2019 >/dev/null 2>&1; then echo 'FAIL: unexpected HTTP/admin listener'; exit 1; fi
if runuser -u nobody -- cat "$HIHY_SUB_STATE/content/current/hysteria.yaml" >/dev/null 2>&1; then exit 1; fi
if runuser -u hihy-sub -- cat /etc/hihy/conf/config.yaml >/dev/null 2>&1; then exit 1; fi
if runuser -u nobody -- cat "$HIHY_SUB_ETC/state.yaml" >/dev/null 2>&1; then exit 1; fi
[ "$(stat -c %a "$HIHY_SUB_STATE/caddy/fixture.key")" = 600 ]
python3 "$ROOT/server/test_subscription_http.py"
printf 'PASS: dedicated account, private files, no admin API, and TCP-only HTTPS\n'
cp -p "$HIHY_SUB_ETC/state.yaml" "$TMP/state-before"
cp -p "$HIHY_SUB_ETC/Caddyfile" "$TMP/caddy-before"
for failure in probe restart; do
    (
        if [ "$failure" = probe ]; then subscriptionProbe() { return 1; }
        else systemctl() { if [ "$1" = restart ]; then return 1; fi; command systemctl "$@"; }; fi
        if subscriptionRotateToken >"$TMP/failed-$failure.log" 2>&1; then exit 1; fi
    )
    cmp -s "$TMP/state-before" "$HIHY_SUB_ETC/state.yaml"
    cmp -s "$TMP/caddy-before" "$HIHY_SUB_ETC/Caddyfile"
    systemctl is-active --quiet hihy-sub.service
    [ "$(find "$HIHY_SUB_STATE/content/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 2 ]
done
subscriptionProbe "$(subscriptionRead domain)" "$(subscriptionRead token)"
printf 'PASS: failed token rotation/restart restores the prior URL, payload and active service\n'
subscriptionRead token >"$TMP/old-token"
subscriptionRotateToken >"$TMP/rotation.log" 2>&1
python3 "$ROOT/server/test_subscription_http.py" "$TMP/old-token"
old_config=$(sha256sum "$HIHY_ROOT_DIR/conf/config.yaml")
old_pointer=$(readlink "$HIHY_SUB_STATE/content/current")
(
    setConfigDefaults; port=34567; ip=127.0.0.1; domain=server.test; auth_secret='new:@/?# test'; remarks='sub/../quoted name'
    writeHysteriaConfig >"$TMP/reconfigure.log" 2>&1
)
[ "$(sha256sum "$HIHY_ROOT_DIR/conf/config.yaml")" != "$old_config" ]
[ "$(readlink "$HIHY_SUB_STATE/content/current")" != "$old_pointer" ]
python3 "$ROOT/server/test_subscription_http.py"
old_config=$(sha256sum "$HIHY_ROOT_DIR/conf/config.yaml")
old_pointer=$(readlink "$HIHY_SUB_STATE/content/current")
(
    eval "$(declare -f subscriptionCommitSnapshot | sed '1s/subscriptionCommitSnapshot/subscriptionCommitOriginal/')"
    subscriptionCommitSnapshot() { subscriptionCommitOriginal "$@"; return 1; }
    setConfigDefaults; port=34567; ip=127.0.0.1; domain=server.test; auth_secret=failed-candidate
    if writeHysteriaConfig >"$TMP/rollback.log" 2>&1; then exit 1; fi
)
[ "$(sha256sum "$HIHY_ROOT_DIR/conf/config.yaml")" = "$old_config" ]
[ "$(readlink "$HIHY_SUB_STATE/content/current")" = "$old_pointer" ]
[ "$(getServiceRunState)" = running ]
(
    installMimic() { touch "$TMP/unexpected-mimic"; }
    setConfigDefaults; port=34567; ip=127.0.0.1; auth_secret=test; mimic_status=true
    if writeHysteriaConfig >"$TMP/mimic-refusal.log" 2>&1; then exit 1; fi
)
[ ! -e "$TMP/unexpected-mimic" ]
printf 'PASS: reconfiguration publishes atomically, publication failure rolls back core and feed, and Mimic fails before installation\n'
iptables -C INPUT -p tcp --dport 443 -m comment --comment 'allow tcp/443(hihy-subscription)' -j ACCEPT
iptables -C INPUT -p tcp --dport 443 -m comment --comment hihy-unrelated-sub-test -j ACCEPT
old_pointer=$(readlink "$HIHY_SUB_STATE/content/current")
subscriptionRefresh >/dev/null
[ "$(readlink "$HIHY_SUB_STATE/content/current")" != "$old_pointer" ]
unshare --net bash -c 'hihy subscription status >/dev/null && hihy subscription show >/dev/null && hihy subscription refresh >/dev/null'
printf 'PASS: status, show and refresh complete with no network interfaces\n'
if [ "${HIHY_SUB_TEST_KEEP:-0}" = 1 ]; then
    printf 'PASS: retained subscription fixture for reboot and transport checks\n'
else
    subscriptionDisable >/dev/null
    ! systemctl is-active --quiet hihy-sub.service
    subscriptionEnable sub.example.test >"$TMP/reenable.log" 2>&1
    python3 "$ROOT/server/test_subscription_http.py"
    subscriptionUninstall >/dev/null
    [ ! -e "$HIHY_SUB_ETC" ] && [ ! -e "$HIHY_SUB_STATE" ] && [ ! -e "$HIHY_SUB_LIB" ] && [ ! -e "$HIHY_SUB_UNIT" ]
    [ "$(sha256sum /usr/bin/caddy)" = "$system_caddy_hash" ]
    iptables -C INPUT -p tcp --dport 443 -m comment --comment hihy-unrelated-sub-test -j ACCEPT
    [ "$(getServiceRunState)" = running ]
    printf 'PASS: disable, re-enable and uninstall preserve the core, unrelated firewall rules and system Caddy\n'
fi
