#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] && [ -f /etc/hihy-test-environment ] || { echo 'Disposable Linux VM required.' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_DIR="${HIHY_TEST_PACKAGE_DIR:-$ROOT/server}"
TMP=$(mktemp -d)
chain="HYSTERIA-T$BASHPID"
created_yq=false
cleanup() {
    iptables -D INPUT -p udp --dport 19999 -m comment --comment hihy-external-test -j ACCEPT 2>/dev/null || true
    iptables -t nat -X "$chain" 2>/dev/null || true
    if [ -f "$TMP/cron.original" ]; then crontab "$TMP/cron.original"; fi
    if [ "$created_yq" = true ]; then rm -f /usr/bin/yq; fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT
if [ ! -e /usr/bin/yq ]; then
    printf '#!/bin/sh\nprintf system-yq\\n\n' >/usr/bin/yq
    chmod 755 /usr/bin/yq
    created_yq=true
fi
yq_before=$(sha256sum /usr/bin/yq)
iptables -I INPUT -p udp --dport 19999 -m comment --comment hihy-external-test -j ACCEPT
iptables -t nat -N "$chain"
crontab -l >"$TMP/cron.original" 2>/dev/null || : >"$TMP/cron.original"
cat "$TMP/cron.original" >"$TMP/cron.test"
printf '0 0 * * * /bin/true # hihy cronTask external-test\n' >>"$TMP/cron.test"
crontab "$TMP/cron.test"
if [ -f /etc/hihy/conf/config.yaml ]; then
    cp "$ROOT/server/hy2.sh" /usr/bin/hihy; chmod 700 /usr/bin/hihy
    hihy uninstall >"$TMP/uninstall.log" 2>&1
fi
[ "$(sha256sum /usr/bin/yq)" = "$yq_before" ]
iptables -C INPUT -p udp --dport 19999 -m comment --comment hihy-external-test -j ACCEPT
iptables -t nat -S "$chain" >/dev/null
crontab -l | grep -Fq 'hihy cronTask external-test'
printf 'PASS: uninstall preserves system yq, unrelated firewall chain and cron\n'
HIHY_AUTO_IP=127.0.0.1 HIHY_AUTO_PORT=34567 HIHY_AUTO_PASSWORD=test-lifecycle bash "$PACKAGE_DIR/install.sh" --auto --lang en >"$TMP/install.log" 2>&1 || { tail -30 "$TMP/install.log"; exit 1; }
[ "$(sha256sum /usr/bin/yq)" = "$yq_before" ]
[ "$(stat -c %a /etc/hihy/conf/config.yaml)" = 600 ]
[ "$(stat -c %a /etc/hihy/cert/www.bing.com.key)" = 600 ]
if runuser -u nobody -- cat /etc/hihy/conf/config.yaml >/dev/null 2>&1; then echo 'FAIL: credential readable by nobody'; exit 1; fi
if runuser -u nobody -- cat /etc/hihy/cert/www.bing.com.key >/dev/null 2>&1; then echo 'FAIL: key readable by nobody'; exit 1; fi
config_before=$(sha256sum /etc/hihy/conf/config.yaml)
if bash "$PACKAGE_DIR/install.sh" --auto >"$TMP/reinstall.log" 2>&1; then echo 'FAIL: existing installation overwritten'; exit 1; fi
[ "$(sha256sum /etc/hihy/conf/config.yaml)" = "$config_before" ]
hihy restart >"$TMP/restart.log" 2>&1
hihy checkStatus >"$TMP/status.log"
grep -q running "$TMP/status.log"
hihy stop >"$TMP/stop.log" 2>&1
[ ! -f /var/run/hihy.pid ]
hihy start >"$TMP/start.log" 2>&1
pid=$(cat /var/run/hihy.pid)
[ "$(readlink /proc/$pid/exe)" = /etc/hihy/bin/appS ]
[ "$(ps -o cls= -p "$pid" | tr -d ' ')" != RR ]
/usr/bin/hihy 11 >"$TMP/disabled-update.log"
grep -q 'self-update is disabled' "$TMP/disabled-update.log"
printf 'PASS: install, private files, existing-install refusal, restart, stop/start and disabled self-update\n'
