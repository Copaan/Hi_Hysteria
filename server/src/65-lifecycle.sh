#!/bin/bash
killHysteriaProcess() {
    local signal="${1:-TERM}"
    local pid_file="${2:-/var/run/hihy.pid}"

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if isHysteriaPid "$pid" && kill -0 "$pid" 2>/dev/null; then
            kill "-${signal}" "$pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$pid_file"
    fi

    local candidate
    for candidate in $(pgrep -f "^$HIHY_ROOT_DIR/bin/appS" 2>/dev/null); do
        isHysteriaPid "$candidate" || continue
        kill "-$signal" "$candidate" 2>/dev/null || true
    done

}

# Port-hopping chains belong to the core and are cleaned up by its shutdown.
cleanupHysteria2Iptables() { return 0; }

checkRoot() {
    if [ "$(id -u)" -ne 0 ]; then
        echoColor red "$(msg error_root_required)"
        exit 1
    fi
}

uninstall() {
    subscriptionUninstall || return 1
    local install_state
    install_state=$(classifyInstallState)
    if [ "$install_state" = "not-installed" ]; then
        echoColor red "$(msg hysteria_not_installed)"
        return 1
    fi

    if [ "$install_state" = "partially-installed" ]; then
        echoColor yellow "$(msg partial_uninstall_cleanup)"
    fi

    # 停止服务
    if [ -f "/etc/alpine-release" ]; then
        if [ -f "/etc/init.d/hihy" ]; then
            rc-service hihy stop >/dev/null 2>&1 || true
            rc-update del hihy default >/dev/null 2>&1 || true
            rm -f /etc/init.d/hihy
        fi
    else
        if [ -f "/etc/rc.d/hihy" ]; then
            /etc/rc.d/hihy stop >/dev/null 2>&1 || true
            rm -f /etc/rc.d/hihy
        fi
        # 清理 install 时创建的 /etc/init.d/hihy 软链(否则卸载后留下悬空链接)
        if [ -L "/etc/init.d/hihy" ] && [ "$(readlink /etc/init.d/hihy)" = "/etc/rc.d/hihy" ]; then
            rm -f /etc/init.d/hihy
        fi
    fi

    killHysteriaProcess TERM

    # 删除定时任务
    removeHihyCron || return 1

    delHihyFirewallPort udp || return 1
    delHihyFirewallPort tcp || return 1

    # 删除相关目录和文件
    if [ -f "$HIHY_ROOT_DIR/conf/sysctl-owned" ]; then rm -f /etc/sysctl.d/99-hihy.conf; fi
    rm -rf /etc/hihy
    rm -f /var/run/hihy.pid
    rm -f "$HIHY_BIN_LINK"

    if [ -f "/etc/rc.local" ]; then
        sed -i '\|^/etc/rc[.]d/hihy start$|d' /etc/rc.local
    fi

    # Shared third-party tools are managed by their own installers.
    clearInstallFailureMarker

    # 删除 Arch Linux 的 rc.local systemd 服务
    uninstall_rc_local_for_arch
    # 检查是否完全删除
    if [ ! -d "/etc/hihy" ]; then
        echoColor green "$(msg uninstall_complete)"
    else
        echoColor red "$(msg uninstall_error)"
        exit 1
    fi
}

