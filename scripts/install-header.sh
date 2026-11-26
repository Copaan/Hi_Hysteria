#!/bin/bash
# GENERATED FILE — edit scripts/install-header.sh and server/src/, then build.

installerUsage() {
    printf '%s\n' '用法：bash install.sh [--auto|-y|--help]' '默认：自动准备依赖和目录，进入中文菜单。' '--auto / -y：准备环境后自动安装。'
}

# 校验内置运行脚本后，才允许加载或部署。
verifyEmbeddedRuntime() {
    local file="$1" actual
    [ -s "$file" ] && [ ! -L "$file" ] || return 1
    actual=$(sha256sum "$file") || return 1
    [ "${actual%% *}" = "$HIHY_EMBEDDED_SHA256" ] && bash -n "$file"
}

installerValidatePaths() {
    local root_dir="$1" bin_link="$2" item current
    [[ "$root_dir" = /* && "$bin_link" = /* && "$root_dir" != / && "$bin_link" != / ]] || return 1
    for item in "$root_dir" "$root_dir/bin" "$root_dir/conf" "$root_dir/cert" "$root_dir/result" "$root_dir/logs" "$bin_link"; do
        if [ -e "$item" ]; then
            if [ "$item" = "$bin_link" ]; then [ -f "$item" ] || return 1
            else [ -d "$item" ] || return 1; fi
        fi
        current="$item"
        while [ "$current" != / ]; do
            [ ! -L "$current" ] || return 1
            current=$(dirname -- "$current") || return 1
        done
    done
}

installerRequireFresh() {
    [ "$(classifyInstallState "$1" "$2")" = not-installed ] || {
        printf '%s\n' '检测到已有或未完成的安装，已停止覆盖。请运行 hihy 管理现有安装。' >&2
        return 1
    }
}

installerAcquireLock() {
    [ ! -L /run/hihy.operation.lock ] || return 1
    exec 9>/run/hihy.operation.lock
    flock -n 9 || { printf '%s\n' '另一个 hihy 操作正在运行。' >&2; return 1; }
}

installerReleaseLock() { flock -u 9 && exec 9>&-; }

# 自动准备系统依赖与项目目录，部署内置程序后启动菜单或自动安装。
installerMain() (
    set -euo pipefail
    umask 077
    local root_dir="${HIHY_ROOT_DIR:-/etc/hihy}" bin_link="${HIHY_BIN_LINK:-/usr/bin/hihy}" auto=false workdir item
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto|-y) auto=true; shift ;;
            --help|-h) installerUsage; return 0 ;;
            *) printf '不支持的参数：%s\n' "$1" >&2; installerUsage >&2; return 2 ;;
        esac
    done
    [ "$(id -u)" = 0 ] || { printf '%s\n' '请使用 root 或 sudo bash install.sh 运行。' >&2; return 1; }
    grep -Eq '^ID=(debian|ubuntu|"debian"|"ubuntu")$' /etc/os-release || { printf '%s\n' '安装器支持 Debian 和 Ubuntu。' >&2; return 1; }
    installerValidatePaths "$root_dir" "$bin_link" || { printf '%s\n' '目标路径无效或包含符号链接。' >&2; return 1; }
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/hihy-bootstrap.XXXXXXXX") || return 1
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    extractEmbeddedRuntime >"$workdir/hy2.sh" || return 1
    verifyEmbeddedRuntime "$workdir/hy2.sh" || { printf '%s\n' '安装脚本不完整或校验失败，请重新下载。' >&2; return 1; }
    source "$workdir/hy2.sh"
    case "$(getArchitecture)" in amd64|arm64) ;; *) printf '%s\n' '安装器支持 amd64 和 arm64。' >&2; return 1 ;; esac
    installerRequireFresh "$root_dir" "$bin_link" || return 1
    ensureSystemDependencies || return 1
    installerAcquireLock || return 1
    installerRequireFresh "$root_dir" "$bin_link" || return 1
    installerValidatePaths "$root_dir" "$bin_link" || return 1
    for item in "$root_dir" "$root_dir/bin" "$root_dir/conf" "$root_dir/cert" "$root_dir/result" "$root_dir/logs"; do
        mkdir -p -- "$item" && chmod 700 "$item" || return 1
    done
    installPrivateYq || return 1
    installHihyLauncher "$workdir/hy2.sh" "$bin_link" || return 1
    chmod 700 "$bin_link" || return 1
    export HIHY_ROOT_DIR="$root_dir" HIHY_BIN_LINK="$bin_link"
    installerReleaseLock || return 1
    if [ "$auto" = true ]; then "$bin_link" autoinstall; else "$bin_link"; fi
)
