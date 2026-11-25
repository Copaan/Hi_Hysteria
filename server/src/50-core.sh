#!/bin/bash
# hysteria release 资产的架构后缀:复用 getArchitecture 单一映射表,
# 仅补充 hysteria 特有的差异项(mips64 板卡多为小端,官方只发 mipsle)
getHysteriaCoreArch() {
    case "$(uname -m)" in
        mips64) echo "mipsle" ;;
        *)
            local mapped
            mapped=$(getArchitecture)
            if [ "$mapped" = "unknown" ]; then
                echo ""
            else
                echo "$mapped"
            fi
            ;;
    esac
}


# Install the pinned private YAML tool without changing the system yq.
installPrivateYq() {
    local arch expected temp actual
    arch=$(getArchitecture)
    case "$arch" in
        amd64) expected=129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973 ;;
        arm64) expected=89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67 ;;
        *) securityError "No pinned yq artifact for $arch."; return 1 ;;
    esac
    mkdir -p "$(dirname "$HIHY_YQ_BIN")" || return 1
    [ ! -L "$HIHY_YQ_BIN" ] || return 1
    actual=""
    [ ! -f "$HIHY_YQ_BIN" ] || actual=$(sha256sum "$HIHY_YQ_BIN" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        temp=$(mktemp "$(dirname "$HIHY_YQ_BIN")/.yq.XXXXXXXX") || return 1
        if ! downloadVerifiedFile "https://github.com/mikefarah/yq/releases/download/${HIHY_YQ_VERSION}/yq_linux_${arch}" "$temp" "$expected"; then
            rm -f -- "$temp"; return 1
        fi
        chmod 700 "$temp" && mv -f -- "$temp" "$HIHY_YQ_BIN" || return 1
    fi
    export PATH="$(dirname "$HIHY_YQ_BIN"):$PATH"
}

validCoreVersion() { [[ "$1" =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Inspect ELF class, byte order and machine before executing a downloaded binary.
validateCoreArchitecture() {
    local file="$1" arch="$2" expected header machine
    case "$arch" in
        amd64) expected=0201:3e00 ;;
        arm64) expected=0201:b700 ;;
        386) expected=0101:0300 ;;
        arm) expected=0101:2800 ;;
        s390x) expected=0202:0016 ;;
        ppc64le) expected=0201:1500 ;;
        loong64) expected=0201:0201 ;;
        mipsle) expected=0101:0800 ;;
        *) return 1 ;;
    esac
    [ "$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || return 1
    header=$(od -An -tx1 -j4 -N2 "$file" | tr -d ' \n')
    machine=$(od -An -tx1 -j18 -N2 "$file" | tr -d ' \n')
    [ "$header:$machine" = "$expected" ]
}

# Fetch a version once, verify its manifest and artifact, then expose the candidate.
fetchHysteriaCandidate() (
    local version="$1" dest="$2" arch base temp expected
    validCoreVersion "$version" || { securityError 'Invalid stable Hysteria version.'; return 1; }
    arch=$(getHysteriaCoreArch)
    [ -n "$arch" ] || return 1
    base="https://github.com/HyNetworks/hysteria/releases/download/$version"
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    if [ "$version" = app/v2.14.0 ]; then
        downloadVerifiedFile "$base/hashes.txt" "$temp/hashes" ab844879a3323b948c2fcd338c4d06a888255e44963b985ac98cd4b32e8a5627 || return 1
    else
        downloadToFile "$base/hashes.txt" "$temp/hashes" || return 1
    fi
    expected=$(awk -v file="hysteria-linux-$arch" '$2 == file || $2 == "build/" file {print $1}' "$temp/hashes")
    isValidSHA256 "$expected" || { securityError "Missing or duplicate checksum for $arch."; return 1; }
    downloadVerifiedFile "$base/hysteria-linux-$arch" "$temp/core" "$expected" || return 1
    validateCoreArchitecture "$temp/core" "$arch" || { securityError 'Downloaded core has the wrong ELF architecture.'; return 1; }
    chmod 700 "$temp/core" || return 1
    [ "$(getLocalHysteriaVersion "$temp/core")" = "$version" ] || { securityError 'Downloaded core version/architecture check failed.'; return 1; }
    [ ! -L "$dest" ] || return 1
    cp -- "$temp/core" "$dest" && chmod 700 "$dest"
)

downloadHysteriaCore() {
    local version="${1:-$HIHY_CORE_VERSION}" temp
    mkdir -p "$HIHY_ROOT_DIR/bin" || return 1
    temp=$(mktemp "$HIHY_ROOT_DIR/bin/.appS.XXXXXXXX") || return 1
    if fetchHysteriaCandidate "$version" "$temp"; then
        mv -f -- "$temp" "$HIHY_ROOT_DIR/bin/appS" && return 0
    fi
    rm -f -- "$temp"
    return 1
}

# Switch the verified core with rollback on any failed restart or interruption.
updateHysteriaCore() (
    local version="${1:-}" core="$HIHY_ROOT_DIR/bin/appS" temp was_running=false stopped=false switched=false success=false
    [ -f "$core" ] || return 1
    [ -n "$version" ] || version=$(getLatestHysteriaVersion) || return 1
    validCoreVersion "$version" || return 1
    [ "$(getLocalHysteriaVersion)" != "$version" ] || { printf '%s\n' 'Core already at requested version.'; return 0; }
    temp=$(mktemp -d "$HIHY_ROOT_DIR/bin/.upgrade.XXXXXXXX") || return 1
    rollbackCore() {
        local rc=$?
        stopValidationProcess
        if [ "$success" != true ]; then
            if [ "$switched" = true ]; then
                stop >/dev/null 2>&1 || true
                mv -f -- "$temp/previous" "$core" || rc=1
            fi
            if [ "$stopped" = true ] && [ "$was_running" = true ] && [ "$(getServiceRunState)" != running ]; then start || rc=1; fi
        fi
        rm -rf -- "$temp"
        return "$rc"
    }
    trap rollbackCore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    fetchHysteriaCandidate "$version" "$temp/candidate" || return 1
    cp -p -- "$core" "$temp/previous" || return 1
    if [ "$(getServiceRunState)" = running ]; then
        was_running=true
        stopped=true
        stop || return 1
    fi
    startInstallValidationProcess "$HIHY_ROOT_DIR/conf/config.yaml" "$temp/validation.log" "$temp/candidate" || return 1
    waitForValidationOutcome "$temp/validation.log" 60 || { securityError 'Candidate core failed configuration validation.'; return 1; }
    stopValidationProcess
    switched=true
    mv -f -- "$temp/candidate" "$core" || return 1
    if [ "$was_running" = true ]; then
        start && [ "$(getServiceRunState)" = running ] || return 1
    fi
    success=true
    printf 'Hysteria core updated to %s\n' "$version"
)
