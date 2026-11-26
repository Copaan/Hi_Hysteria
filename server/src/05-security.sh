#!/bin/bash

# Emit security errors on stderr without interpreting terminal escapes.
securityError() { printf 'hihy: %s\n' "$*" >&2; return 1; }

# Validate DNS names before using them in configuration or certificate paths.
isValidDomain() {
    local domain="$1" label
    [ ${#domain} -le 253 ] && [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
    local IFS=.
    for label in $domain; do
        [ ${#label} -le 63 ] && [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

isValidSHA256() { [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]; }
isValidFingerprint() { local fp="${1//:/}"; isValidSHA256 "$fp"; }

# Percent-encode UTF-8 bytes for URI components.
urlEncode() {
    local LC_ALL=C input="$1" char i
    for ((i=0; i<${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in [a-zA-Z0-9.~_-]) printf '%s' "$char" ;; *) printf '%%%02X' "'$char" ;; esac
    done
}

# Return a private output path independent of the display name.
clientOutputPath() {
    local remarks="$1" suffix="$2" name digest
    name=$(printf '%s' "$remarks" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '_' | cut -c1-48)
    digest=$(printf '%s' "$remarks" | sha256sum | cut -c1-12)
    mkdir -p "$HIHY_EXPORT_DIR" || return 1
    [ ! -L "$HIHY_EXPORT_DIR" ] || return 1
    chmod 700 "$HIHY_EXPORT_DIR" || return 1
    printf '%s/Hy2-%s-%s-%s\n' "$HIHY_EXPORT_DIR" "${name:-node}" "$digest" "$suffix"
}

secureTempDir() { mktemp -d "${TMPDIR:-/tmp}/hihy.XXXXXXXX"; }

# Tighten files owned by this installation without following symlinks.
secureInstallPermissions() {
    [ -d "$HIHY_ROOT_DIR" ] && [ ! -L "$HIHY_ROOT_DIR" ] || return 1
    find "$HIHY_ROOT_DIR" -type d -exec chmod 700 {} + || return 1
    find "$HIHY_ROOT_DIR" -type f ! -path "$HIHY_ROOT_DIR/bin/*" -exec chmod 600 {} +
}

# A third-party installer is executable only with a reviewed immutable URL/hash.
installWarpVerified() (
    local mode="$1" temp
    [[ "${HIHY_WARP_URL:-}" =~ ^https://gitlab\.com/fscarmen/warp/-/raw/[0-9a-f]{40}/menu\.sh$ ]] \
        && isValidSHA256 "${HIHY_WARP_SHA256:-}" \
        || { securityError '安装 WARP 需要固定提交地址和 SHA256；也可以先自行安装 WARP。'; return 1; }
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    downloadVerifiedFile "$HIHY_WARP_URL" "$temp/menu.sh" "$HIHY_WARP_SHA256" || return 1
    bash -n "$temp/menu.sh" || return 1
    (cd "$temp" && bash ./menu.sh "$mode")
)

# Insert startup commands before an existing exit without replacing user content.
appendRcLocalCommand() {
    local line="$1" file="$HIHY_RC_LOCAL" temp
    [ ! -L "$file" ] || return 1
    [ -f "$file" ] || printf '#!/bin/sh\n' >"$file" || return 1
    grep -Fxq -- "$line" "$file" && return 0
    temp=$(mktemp "$(dirname "$file")/.rc-local.XXXXXXXX") || return 1
    awk -v cmd="$line" '/^[[:space:]]*exit[[:space:]]+0[[:space:]]*$/ && !done { print cmd; done=1 } {print} END {if(!done) print cmd}' "$file" >"$temp" \
        && chmod 700 "$temp" && mv -- "$temp" "$file"
}

# Identify the executable as well as the PID before signalling a process.
isHysteriaPid() {
    local pid="$1" executable
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    executable=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    [[ "$executable" = "$HIHY_ROOT_DIR/bin/appS" || "$executable" = "$HIHY_ROOT_DIR/bin/appS (deleted)" ]]
}

# Decode percent escapes without evaluating backslashes from user input.
urlDecode() {
    local input="$1" prefix rest hex
    while [[ "$input" = *%* ]]; do
        prefix="${input%%\%*}"; printf '%s' "$prefix"
        rest="${input#*%}"; hex="${rest:0:2}"
        [[ "$hex" =~ ^[[:xdigit:]]{2}$ ]] || return 1
        printf '%b' "\x$hex"
        input="${rest:2}"
    done
    printf '%s' "$input"
}

# Remove only the exact scheduled entry installed by hihy.
removeHihyCron() (
    local temp
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    if crontab -l >"$temp/before" 2>/dev/null; then
        grep -Fxv -e "15 4 * * 1 $HIHY_BIN_LINK cronTask" -e '15 4 * * 1 hihy cronTask' "$temp/before" >"$temp/after" || [ $? -eq 1 ] || return 1
        crontab "$temp/after"
    fi
)

# Stage the pinned default masquerade site; extract only reviewed regular files.
prepareMasqueradeFiles() (
    local destination="$1" temp prefix='mikutap-fb292bc1c3b3a29d80feaac2dbe93fca981776ee/' name
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    downloadVerifiedFile 'https://codeload.github.com/HFIProgramming/mikutap/tar.gz/fb292bc1c3b3a29d80feaac2dbe93fca981776ee' "$temp/site.tar.gz" d3fab27fbc3de256d50aea4325094fefbf6bdaa4c693f4a16619dc1c74df355d || return 1
    tar -tzf "$temp/site.tar.gz" >"$temp/names" || return 1
    while IFS= read -r name; do
        case "$name" in "$prefix"*) ;; *) return 1 ;; esac
        case "/$name/" in */../*|*/./*) return 1 ;; esac
    done <"$temp/names"
    tar -tvzf "$temp/site.tar.gz" >"$temp/types" || return 1
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' "$temp/types" || return 1
    mkdir -p "$destination" && [ ! -L "$destination" ] || return 1
    tar -xzf "$temp/site.tar.gz" -C "$destination" --strip-components=1 --no-same-owner --no-same-permissions || return 1
    find "$destination" -type f -exec chmod 600 {} +
    find "$destination" -type d -exec chmod 700 {} +
)
