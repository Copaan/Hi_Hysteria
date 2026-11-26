#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] && [ -f /etc/hihy-test-environment ] && [ -d /run/systemd/system ] || { echo 'Disposable systemd Linux VM required.' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
subscriptionEnabled || exit 1
record="$HIHY_SUB_ETC/reboot-test"
case "${1:-}" in
    prepare)
        [ ! -e "$record" ] && [ ! -L "$record" ] || exit 1
        mkdir -m 700 "$record"
        cat /proc/sys/kernel/random/boot_id >"$record/boot-id"
        sha256sum "$HIHY_SUB_STATE/content/current/"{hysteria.yaml,mihomo.yaml,singbox.json} >"$record/content.sha256"
        printf 'PASS: recorded boot identity and published payload digests
'
        ;;
    verify)
        [ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$record/boot-id")" ]
        systemctl is-enabled --quiet hihy-sub.service
        systemctl is-active --quiet hihy-sub.service
        [ "$(getServiceRunState)" = running ]
        pid=$(systemctl show -p MainPID --value hihy-sub.service)
        [ "$(ps -o user= -p "$pid" | tr -d ' ')" = hihy-sub ]
        [ "$(awk '/^CapEff:/ {print $2}' /proc/"$pid"/status)" = 0000000000000400 ]
        ! lsof -a -p "$pid" -iUDP:443 >/dev/null 2>&1
        ! lsof -a -p "$pid" -iTCP:80 -iTCP:2019 >/dev/null 2>&1
        iptables -C INPUT -p tcp --dport 443 -m comment --comment 'allow tcp/443(hihy-subscription)' -j ACCEPT
        ip6tables -C INPUT -p tcp --dport 443 -m comment --comment 'allow tcp/443(hihy-subscription)' -j ACCEPT
        port=$(getListenPrimaryPort "$(getYamlValue "$HIHY_ROOT_DIR/conf/config.yaml" listen)")
        iptables -C INPUT -p udp --dport "$port" -m comment --comment "allow udp/$port(hihysteria)" -j ACCEPT
        sha256sum --check --status "$record/content.sha256"
        export CURL_CA_BUNDLE="$HIHY_SUB_STATE/caddy/test-ca.crt"
        python3 "$ROOT/server/test_subscription_http.py"
        hihy subscription enable SUB.EXAMPLE.TEST >/dev/null
        printf 'PASS: real reboot restores both services, independent firewall rules, non-root capabilities and unchanged HTTPS payloads
'
        rm -rf -- "$record"
        ;;
    *) exit 2 ;;
esac
