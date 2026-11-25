#!/bin/bash
set -euo pipefail
umask 077

# Verify completeness and integrity without installing or fetching anything.
verifyLocalPackage() (
    local package_dir="$1" item count
    [ -f "$package_dir/SHA256SUMS" ] && [ ! -L "$package_dir/SHA256SUMS" ] && [ ! -L "$package_dir/i18n" ] || return 1
    for item in install.sh hy2.sh i18n/en.json i18n/zh.json i18n/fa.json i18n/ru.json; do
        [ -f "$package_dir/$item" ] && [ ! -L "$package_dir/$item" ] || return 1
        count=$(awk -v target="$item" '{name=$2; sub(/^\*/, "", name); if(name==target && length($1)==64) n++} END {print n+0}' "$package_dir/SHA256SUMS")
        [ "$count" = 1 ] || return 1
    done
    (cd "$package_dir" && sha256sum --strict --check SHA256SUMS) || return 1
    bash -n "$package_dir/hy2.sh"
)

# Install scripts and translations from one reviewed local package.
main() (
    local package_dir root_dir bin_link lang auto=0 temp lang_file
    package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    root_dir="${HIHY_ROOT_DIR:-/etc/hihy}"
    bin_link="${HIHY_BIN_LINK:-/usr/bin/hihy}"
    lang="${HIHY_LANG:-en}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --lang) [ $# -ge 2 ] || exit 2; lang="$2"; shift 2 ;;
            --lang=*) lang="${1#*=}"; shift ;;
            --auto|-y) auto=1; shift ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    case "$lang" in en|zh|fa|ru) ;; *) printf 'Unsupported language\n' >&2; exit 2 ;; esac
    [ "$(id -u)" -eq 0 ] || { printf 'Run as root.\n' >&2; exit 1; }
    if [ -e "$root_dir/conf/config.yaml" ] || [ -e "$root_dir/bin/appS" ] || [ -e /etc/rc.d/hihy ] || [ -e /etc/init.d/hihy ]; then
        printf 'Existing installation detected; automatic migration is not supported.\n' >&2
        exit 1
    fi
    [ ! -L "$root_dir" ] && [ ! -L "$bin_link" ] || exit 1
    for lang_file in en zh fa ru; do
        [ -f "$package_dir/i18n/$lang_file.json" ] || { printf 'Incomplete local package.\n' >&2; exit 1; }
    done
    [ -f "$package_dir/hy2.sh" ] && [ -f "$package_dir/SHA256SUMS" ] || { printf 'Missing local script or package manifest.\n' >&2; exit 1; }
    verifyLocalPackage "$package_dir" || { printf 'Local package verification failed.\n' >&2; exit 1; }
    mkdir -p "$root_dir/i18n" "$root_dir/conf" "$(dirname "$bin_link")"
    chmod 700 "$root_dir" "$root_dir/i18n" "$root_dir/conf"
    temp=$(mktemp "$(dirname "$bin_link")/.hihy.XXXXXXXX")
    trap 'rm -f -- "$temp"' EXIT
    cp -- "$package_dir/hy2.sh" "$temp"
    chmod 700 "$temp"
    mv -f -- "$temp" "$bin_link"
    for lang_file in en zh fa ru; do
        [ ! -L "$root_dir/i18n/hy2.sh.$lang_file.json" ] || exit 1
        cp -- "$package_dir/i18n/$lang_file.json" "$root_dir/i18n/hy2.sh.$lang_file.json"
        chmod 600 "$root_dir/i18n/hy2.sh.$lang_file.json"
    done
    [ ! -L "$root_dir/conf/i18n.conf" ] || exit 1
    printf 'HIHY_LANG=%s\n' "$lang" >"$root_dir/conf/i18n.conf"
    export HIHY_ROOT_DIR="$root_dir" HIHY_BIN_LINK="$bin_link" HIHY_LANG="$lang"
    export HIHY_I18N_DIR="$root_dir/i18n" HIHY_I18N_CONF="$root_dir/conf/i18n.conf"
    if [ "$auto" -eq 1 ]; then "$bin_link" autoinstall; else "$bin_link"; fi
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
