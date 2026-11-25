#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] && [ -f /etc/hihy-test-environment ] || { echo 'Disposable Linux VM required.' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(secureTempDir)
trap 'rm -rf -- "$TMP"' EXIT
getLatestHysteriaVersion() { touch "$TMP/unexpected-version-query"; return 1; }
assert_running() { [ "$(getServiceRunState)" = running ]; }
assert_running
acl="$HIHY_ROOT_DIR/acl/acl.txt"
conf="$HIHY_ROOT_DIR/conf/config.yaml"
aclControl <<<'1
3
example.test' >"$TMP/acl-add.log"
aclControl <<<'1
3
child.example.test' >>"$TMP/acl-add.log"
grep -Fxq 'reject(suffix:example.test)' "$acl"
"$HIHY_ROOT_DIR/bin/appS" --disable-update-check acl test -c "$conf" --no-resolve child.example.test:443 >"$TMP/route.log"
grep -qi reject "$TMP/route.log"
aclControl <<<'2
example.test' >"$TMP/acl-delete.log"
if grep -Fxq 'reject(suffix:example.test)' "$acl"; then exit 1; fi
grep -Fxq 'reject(suffix:child.example.test)' "$acl"
before=$(sha256sum "$acl")
if aclControl <<<'1
3
bad);direct(all)' >"$TMP/acl-invalid.log" 2>&1; then exit 1; fi
[ "$(sha256sum "$acl")" = "$before" ]
aclControl <<<'2
reject(suffix:child.example.test)' >/dev/null
assert_running
printf 'PASS: real ACL routing, exact deletion and injection refusal\n'
username='user" : @ # [x]'
password='pass" : @ # [x] $(never-run)'
printf '2\n127.0.0.1:19090\n%s\n%s\n' "$username" "$password" | addSocks5Outbound >"$TMP/socks-add.log"
[ "$(getYamlValue "$conf" outbounds[0].socks5.username)" = "$username" ]
[ "$(getYamlValue "$conf" outbounds[0].socks5.password)" = "$password" ]
addSocks5Outbound <<<'3' >"$TMP/socks-remove.log"
[ "$(getYamlValue "$HIHY_ROOT_DIR/conf/backup.yaml" socks5_status)" = false ]
changeIp64 <<<'1' >"$TMP/ip-change.log"
assert_running
printf 'PASS: real SOCKS credential serialization/removal and IP preference changes\n'
traffic_port=$(getYamlValue "$HIHY_ROOT_DIR/conf/backup.yaml" trafficPort)
secret=$(getYamlValue "$conf" trafficStats.secret)
proxy_pass=$(getYamlValue "$conf" auth.password)
[ "$secret" != "$proxy_pass" ]
printf 'Authorization: %s\n' "$proxy_pass" >"$TMP/header"
[ "$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' -H "@$TMP/header" "http://127.0.0.1:$traffic_port/traffic")" = 401 ]
printf 'Authorization: %s\n' "$secret" >"$TMP/header"
[ "$(curl --silent --max-time 5 -o /dev/null -w '%{http_code}' -H "@$TMP/header" "http://127.0.0.1:$traffic_port/traffic")" = 200 ]
getHysteriaTrafic >"$TMP/stats.log"
generate_client_config >"$TMP/export.log"
if runuser -u nobody -- cat "$HIHY_ROOT_DIR/conf/backup.yaml" >/dev/null 2>&1; then exit 1; fi
find "$HIHY_ROOT_DIR/result" -type f -name 'Hy2-*' -print0 | while IFS= read -r -d '' file; do
    [ "$(stat -c %a "$file")" = 600 ]
    if runuser -u nobody -- cat "$file" >/dev/null 2>&1; then exit 1; fi
done
[ ! -e "$TMP/unexpected-version-query" ]
printf 'PASS: independent loopback statistics secret, private exports and no version queries\n'
core_before=$(sha256sum "$HIHY_ROOT_DIR/bin/appS")
config_before=$(sha256sum "$conf")
(
    getLocalHysteriaVersion() { echo app/v2.13.0; }
    fetchHysteriaCandidate() { cp -p "$HIHY_ROOT_DIR/bin/appS" "$2"; }
    start() {
        if [ ! -e "$TMP/restart-failed" ]; then touch "$TMP/restart-failed"; return 1; fi
        /etc/rc.d/hihy start
    }
    if updateHysteriaCore app/v2.14.0 >"$TMP/upgrade-failure.log" 2>&1; then exit 1; fi
    [ -e "$TMP/restart-failed" ]
    [ "$(sha256sum "$HIHY_ROOT_DIR/bin/appS")" = "$core_before" ]
    [ "$(sha256sum "$conf")" = "$config_before" ]
    assert_running
)
printf 'PASS: injected activation failure restores actual core and running service\n'
stop >"$TMP/stop.log"
(
    getLocalHysteriaVersion() { echo app/v2.13.0; }
    fetchHysteriaCandidate() { cp -p "$HIHY_ROOT_DIR/bin/appS" "$2"; }
    updateHysteriaCore app/v2.14.0 >"$TMP/upgrade-stopped.log" 2>&1
    [ "$(getServiceRunState)" = stopped ]
)
start >"$TMP/start.log"
assert_running
printf 'PASS: stopped-core update validates real configuration and retains stopped state\n'
