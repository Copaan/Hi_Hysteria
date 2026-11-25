#!/bin/bash
getLatestHysteriaVersion() {
    local headers tag

    headers=$(fetchRemoteHeadersFromSources "https://github.com/HyNetworks/hysteria/releases/latest") || return 1
    tag=$(printf '%s\n' "$headers" | grep -i '^location:' | grep -o 'tag/[^[:space:]]*' | sed 's/tag\///;s/\r//;s/ //g' | head -n 1)
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}

getLocalHysteriaVersion() {
    local core_bin="${1:-$HIHY_ROOT_DIR/bin/appS}"

    if [ ! -x "$core_bin" ]; then
        return 1
    fi

    local version
    version=$(echo app/$("$core_bin" version 2>/dev/null | grep Version: | awk '{print $2}' | head -n 1))
    if [ -z "$version" ] || [ "$version" = "app/" ]; then
        return 1
    fi

    printf '%s\n' "$version"
}

# 本地内核是否满足最低版本要求($1,如 "2.10.0")。取不到版本号视为不满足。
localCoreVersionAtLeast() {
    local required="$1"
    local local_version
    local_version=$(getLocalHysteriaVersion 2>/dev/null) || return 1
    local_version="${local_version#app/}"
    local_version="${local_version#v}"
    [ -n "$local_version" ] || return 1
    [ "$(printf '%s\n%s\n' "$required" "$local_version" | sort -V | head -n 1)" = "$required" ]
}

