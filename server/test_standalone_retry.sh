#!/bin/bash
set -euo pipefail
umask 077
[ "$(id -u)" = 0 ] && [ -f /etc/hihy-test-environment ] && [ -d /run/systemd/system ] || { echo 'Disposable systemd VM required.' >&2; exit 1; }
[ ! -e /etc/hihy ] && [ ! -e /usr/bin/hihy ] || { echo 'Clean VM required.' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# 从单文件安装器启动真实菜单，恢复尚未创建服务的启动器失败状态。
printf '0\n' | bash "$ROOT/server/install.sh" >"$TMP/fresh.log" 2>&1
cmp -s /usr/bin/hihy "$ROOT/server/hy2.sh"
rm -- /usr/bin/hihy
printf 'phase=launcher\ndetails=failed to install hihy launcher at start\n' >/etc/hihy/result/install.failed
printf '0\n' | bash "$ROOT/server/install.sh" >"$TMP/retry.log" 2>&1
cmp -s /usr/bin/hihy "$ROOT/server/hy2.sh"
[ ! -e /etc/hihy/result/install.failed ]
grep -q '已恢复 hihy 主程序' "$TMP/retry.log"
printf 'PASS: standalone installer restores the missing launcher and clears only the recognized early failure\n'

export HIHY_AUTO_IP=127.0.0.1 HIHY_AUTO_PORT=34567 HIHY_AUTO_PASSWORD=standalone-retry-test
for run in first second; do
    if ! bash "$ROOT/server/install.sh" --auto </dev/null >"$TMP/$run-install.log" 2>&1; then
        tail -30 "$TMP/$run-install.log"; exit 1
    fi
    bash -c 'source "$1"; [ "$(getServiceRunState)" = running ]' -- "$ROOT/server/hy2.sh"
    [ ! -e /etc/hihy/result/install.failed ]
    printf '2\n1\n0\n' | /usr/bin/hihy >"$TMP/$run-uninstall.log" 2>&1
    grep -q 'bash install.sh' "$TMP/$run-uninstall.log"
    [ ! -e /etc/hihy ] && [ ! -e /usr/bin/hihy ]
    [ ! -e /etc/rc.d/hihy ] && [ ! -L /etc/init.d/hihy ]
done
printf 'PASS: real standalone installation starts the core; menu uninstall exits without reinstalling; a second standalone installation succeeds\n'
