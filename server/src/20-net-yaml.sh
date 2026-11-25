#!/bin/bash

installHihyLauncher() {
    local source_path="${1:-${BASH_SOURCE[0]}}"
    local bin_link="${2:-$HIHY_BIN_LINK}"
    local bin_dir
    local temp_path

    bin_dir="$(dirname "$bin_link")"
    mkdir -p "$bin_dir"

    if [ -f "$source_path" ] && [ "$source_path" != "$bin_link" ]; then
        # 本地已有脚本文件:同目录临时文件 + mv(rename)落盘,避免原地截断
        temp_path="$(mktemp "$bin_dir/.hihy.tmp.XXXXXX")" || return 1
        if ! cp "$source_path" "$temp_path"; then
            rm -f "$temp_path"
            return 1
        fi
        chmod +x "$temp_path"
        mv "$temp_path" "$bin_link" || {
            rm -f "$temp_path"
            return 1
        }
    elif [ ! -f "$bin_link" ]; then
        securityError 'Local hihy script is missing; reinstall the complete reviewed package.'
        return 1
    fi

    if [ -f "$bin_link" ]; then
        chmod +x "$bin_link"
        return 0
    fi

    return 1
}

downloadToFile() (
    local url="$1"
    local output_path="$2"
    local attempt temp
    [[ "$url" == https://* ]] || { securityError 'Only HTTPS downloads are allowed.'; return 1; }
    [ ! -L "$output_path" ] || return 1
    temp=$(mktemp "$(dirname "$output_path")/.download.XXXXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    for ((attempt=0; attempt<=HIHY_DOWNLOAD_RETRIES; attempt++)); do
        if curl --proto '=https' --proto-redir '=https' -fSL --silent --show-error \
            --connect-timeout "$HIHY_REMOTE_CONNECT_TIMEOUT" --max-time "$HIHY_REMOTE_MAX_TIME" \
            -o "$temp" "$url" && [ -s "$temp" ]; then
            chmod 600 "$temp" && mv -f -- "$temp" "$output_path" && return 0
        fi
    done
    rm -f -- "$temp"
    return 1
)

# Verify a downloaded artifact before making it available to its caller.
downloadVerifiedFile() (
    local url="$1" dest="$2" expected="${3,,}" temp actual
    isValidSHA256 "$expected" && [ ! -L "$dest" ] || return 1
    temp=$(mktemp "$(dirname "$dest")/.verified.XXXXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    if downloadToFile "$url" "$temp"; then
        actual=$(sha256sum "$temp" | awk '{print $1}')
        if [ "$actual" = "$expected" ]; then
            mv -f -- "$temp" "$dest" && return 0
        fi
        securityError 'SHA256 verification failed.'
    fi
    rm -f -- "$temp"
    return 1
)

fetchRemoteBodyFromSources() {
    local url
    local response

    for url in "$@"; do
        if response=$(curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout "$HIHY_REMOTE_CONNECT_TIMEOUT" --max-time "$HIHY_REMOTE_MAX_TIME" "$url" 2>/dev/null); then
            printf '%s' "$response"
            return 0
        fi
    done

    return 1
}

fetchRemoteHeadersFromSources() {
    local url
    local response

    for url in "$@"; do
        # -L: GitHub /releases/latest 可能先 301 到新仓库,再 302 到 tag/;不跟随则 Location 里没有 tag/
        if response=$(curl --proto '=https' --proto-redir '=https' -fsSI -L --connect-timeout "$HIHY_REMOTE_CONNECT_TIMEOUT" --max-time "$HIHY_REMOTE_MAX_TIME" "$url" 2>/dev/null); then
            printf '%s' "$response"
            return 0
        fi
    done

    return 1
}

generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuid=$(uuidgen)
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32 | sed 's/\(.\{8\}\)/\1-/g;s/-$//')
    fi
    echo "$uuid"
}

# 多源探测公网 IP;$1 为 curl 地址族参数(-4/-6/空)
getPublicIP() {
    local family="${1:-}"
    local source detected
    for source in "https://ip.sb" "https://api64.ipify.org" "https://ifconfig.me"; do
        detected=$(curl ${family} -s -m 4 "$source" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$detected" ]; then
            printf '%s\n' "$detected"
            return 0
        fi
    done
    return 1
}

# 常用探测策略:先 IPv4,失败再不限地址族(唯一实现点,勿在调用处复制回退梯子)
detectPublicIP() {
    getPublicIP -4 || getPublicIP ""
}

getListenPrimaryPort() {
    local listen_value="$1"

    if [ -z "$listen_value" ] || [ "$listen_value" = "null" ]; then
        echo ""
        return
    fi

    listen_value=${listen_value#*:}
    listen_value=$(echo "$listen_value" | awk -F',' '{print $1}')
    echo "$listen_value" | awk -F'-' '{print $1}'
}

getListenRangePart() {
    local listen_value="$1"

    if [ -z "$listen_value" ] || [ "$listen_value" = "null" ]; then
        echo ""
        return
    fi

    listen_value=${listen_value#*:}
    if echo "$listen_value" | grep -q ','; then
        echo "$listen_value" | awk -F',' '{print $2}'
    else
        echo ""
    fi
}

addOrUpdateYaml() {
    local file="$1" keyPath="$2" value="$3" valueType="${4:-auto}" temp expression
    [[ "$keyPath" =~ ^[A-Za-z_][A-Za-z0-9_.-]*(\[[0-9]+\])?([.][A-Za-z0-9_-]+(\[[0-9]+\])?)*$ ]] || return 1
    [ ! -L "$file" ] || return 1
    if [ "$valueType" = auto ]; then
        case "$keyPath" in
            *password|*Password|auth|*token*|*secret*|remarks|*name|*Name|domain|*Address|*URI|*sni|*url|*addr|*username|*content|*custom-stuff|*headers.*) valueType=string ;;
            *)
                if [[ "$value" == true || "$value" == false ]]; then valueType=bool
                elif [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then valueType=number
                else valueType=string; fi ;;
        esac
    fi
    case "$valueType" in
        string) expression=".${keyPath} = strenv(HIHY_YAML_VALUE)" ;;
        number) [[ "$value" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] || return 1; expression=".${keyPath} = env(HIHY_YAML_VALUE)" ;;
        bool) [[ "$value" == true || "$value" == false ]] || return 1; expression=".${keyPath} = env(HIHY_YAML_VALUE)" ;;
        *) return 1 ;;
    esac
    [ -f "$file" ] || printf '{}\n' >"$file" || return 1
    temp=$(mktemp "$(dirname "$file")/.yaml.XXXXXXXX") || return 1
    if HIHY_YAML_VALUE="$value" yq eval "$expression" "$file" >"$temp"; then
        chmod 600 "$temp" && mv -f -- "$temp" "$file" && return 0
    fi
    rm -f -- "$temp"
    return 1
}

getYamlValue() {
    local file=$1    # YAML文件路径
    local keyPath=$2 # 键路径，用点号分隔
    local value

    # 检查文件是否存在(错误走 stderr,避免污染调用方捕获的 stdout)
    if [[ ! -f "$file" ]]; then
        echo "getYamlValue: file not found: $file" >&2
        return 1
    fi

    # 使用 yq 读取 YAML 文件中的值
    value=$(yq -r eval ".${keyPath}" "$file")

    # 检查 yq 命令是否成功执行
    if [[ $? -ne 0 ]]; then
        echo "getYamlValue: failed to read $keyPath from $file" >&2
        return 1
    fi

    printf '%s\n' "$value"
}

