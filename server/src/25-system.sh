#!/bin/bash
detectVirtualization() {
    local virt_type=""

    # 检查是否为 OpenVZ
    if [ -f "/proc/user_beancounters" ]; then
        virt_type="openvz"
    # 检查是否为 LXC
    elif [ -f "/proc/1/environ" ] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        virt_type="lxc"
    # 检查 systemd-detect-virt（如果可用）
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local detected=$(systemd-detect-virt 2>/dev/null)
        case "$detected" in
            "openvz") virt_type="openvz" ;;
            "lxc") virt_type="lxc" ;;
            "lxc-libvirt") virt_type="lxc" ;;
            *) virt_type="other" ;;
        esac
    # 检查 /proc/cpuinfo 中的虚拟化标识
    elif grep -q "flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        virt_type="other"
    # 检查 cgroup 中的容器标识
    elif [ -f "/proc/1/cgroup" ]; then
        if grep -q ":/lxc/" /proc/1/cgroup 2>/dev/null; then
            virt_type="lxc"
        elif grep -q ":/docker/" /proc/1/cgroup 2>/dev/null; then
            virt_type="docker"
        else
            virt_type="unknown"
        fi
    else
        virt_type="unknown"
    fi

    echo "$virt_type"
}

# 获取普通调度策略下的启动命令前缀
getStartCommand() { printf '%s' ''; }

cronTask() {
    if [ -f "/etc/hihy/logs/hihy.log" ]; then
        echo "" >/etc/hihy/logs/hihy.log
    fi
}
getArchitecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        i386 | i686)
            echo "386"
            ;;
        aarch64 | arm64)
            echo "arm64"
            ;;
        armv7*)
            echo "arm"
            ;;
        s390x)
            echo "s390x"
            ;;
        ppc64le)
            echo "ppc64le"
            ;;
        loongarch64)
            echo "loong64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

ensureSystemDependencies() {
    local DEBIAN_FRONTEND=noninteractive
    export DEBIAN_FRONTEND
    local release=""
    local installType=""
    local updateNeeded=false
    local packageManager=""
    local requiredPackages=("wget" "curl" "lsof" "bash" "iptables" "bc" "openssl")

    # 检测包管理器
    if command -v apt >/dev/null; then
        packageManager="apt"
        installType="apt-get -y -q install"
        upgrade="apt-get update"
    elif command -v yum >/dev/null; then
        packageManager="yum"
        installType="yum -y -q install"
        upgrade="yum makecache"
    elif command -v dnf >/dev/null; then
        packageManager="dnf"
        installType="dnf -y install"
        upgrade="dnf makecache"
    elif command -v pacman >/dev/null; then
        packageManager="pacman"
        installType="pacman -Sy --noconfirm"
        upgrade="pacman -Syy"
    elif command -v apk >/dev/null; then
        packageManager="apk"
        installType="apk add --no-cache"
        upgrade="apk update"
    else
        echoColor red "\n$(msg package_manager_not_supported)"
        echoColor yellow "$(cat /etc/issue 2>/dev/null)"
        echoColor yellow "$(cat /proc/version 2>/dev/null)"
        exit 1
    fi

    # 检查必需的包
    for package in "${requiredPackages[@]}"; do
        if ! command -v "$package" >/dev/null; then
            echoColor green "*$package"
            updateNeeded=true
        fi
    done

    # 检查 dig 命令
    if ! command -v dig >/dev/null; then
        echoColor green "*dnsutils"
        updateNeeded=true
    fi

    # 检查 qrencode 包
    if ! command -v qrencode >/dev/null; then
        echoColor green "*qrencode"
        updateNeeded=true
    fi

    # 检查 qrencode 包
    if ! command -v crontab >/dev/null; then
        echoColor green "*crontab"
        updateNeeded=true
    fi

    # 检查 flock 命令
    if ! command -v flock >/dev/null; then
        echoColor green "*util-linux"
        updateNeeded=true
    fi

    if [ ! -s /etc/ssl/certs/ca-certificates.crt ] || ! command -v pgrep >/dev/null 2>&1; then
        updateNeeded=true
    fi

    # 仅在需要安装包时更新软件源
    if [ "$updateNeeded" = true ]; then
        echoColor purple "\n$(msg package_manager_update_sources)"
        ${upgrade} || return 1

        ${installType} ca-certificates || return 1

        # 安装必需的包
        for package in "${requiredPackages[@]}"; do
            if ! command -v "$package" >/dev/null; then
                ${installType} "$package" || return 1
            fi
        done

        # 安装 dig
        if ! command -v dig >/dev/null; then
            case $packageManager in
                "apt") ${installType} "dnsutils" || return 1 ;;
                "yum" | "dnf") ${installType} "bind-utils" || return 1 ;;
                "pacman") ${installType} "bind-tools" || return 1 ;;
                "apk") ${installType} "bind-tools" || return 1 ;;
            esac
        fi

        # 安装 qrencode
        if ! command -v qrencode >/dev/null; then
            case $packageManager in
                "apt") ${installType} "qrencode" || return 1 ;;
                "yum" | "dnf") ${installType} "qrencode" || return 1 ;;
                "pacman") ${installType} "qrencode" || return 1 ;;
                "apk") ${installType} "libqrencode-tools" || return 1 ;;
            esac
        fi

        # 安装 util-linux
        if ! command -v flock >/dev/null; then
            ${installType} "util-linux" || return 1
        fi

        # 确保有 pgrep 命令
        if ! command -v pgrep >/dev/null 2>&1; then
            case $packageManager in
                "apt") ${installType} "procps" || return 1 ;;
                "yum" | "dnf") ${installType} "procps" || return 1 ;;
                "pacman") ${installType} "procps" || return 1 ;;
                "apk") ${installType} "procps" || return 1 ;;
            esac
        fi

        # 确保有 crontab 命令
        if ! command -v crontab >/dev/null 2>&1; then
            case $packageManager in
                "apt") ${installType} "cron" || return 1 ;;
                "yum" | "dnf") ${installType} "cron" || return 1 ;;
                "pacman") ${installType} "cronie" || return 1 ;;
                "apk") ${installType} "cronie" || return 1 ;;
            esac
        fi

        echoColor purple "\n$(msg package_install_complete)"
    fi

    return 0
}

checkSystemForUpdate() {
    ensureSystemDependencies && installPrivateYq
}
