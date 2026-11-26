#!/bin/bash
# Read private subscription state without touching the network.
subscriptionRead() {
    [ ! -L "$HIHY_SUB_ETC/state.yaml" ] || return 1
    if [ ! -f "$HIHY_SUB_ETC/state.yaml" ]; then printf '%s\n' "${2:-}"; return 0; fi
    getBackupValueOrDefault "$HIHY_SUB_ETC/state.yaml" "$1" "${2:-}"
}
subscriptionPathOwned() {
    local dir="$1"
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/.hihy-sub-owned" ] && [ ! -L "$dir/.hihy-sub-owned" ] \
        && [ "$(stat -c %u "$dir/.hihy-sub-owned")" = 0 ] \
        && [ "$(cat "$dir/.hihy-sub-owned")" = hihy-subscription-v1 ]
}
subscriptionOwned() { subscriptionPathOwned "$HIHY_SUB_ETC"; }
subscriptionEnabled() { subscriptionOwned && [ "$(subscriptionRead enabled false)" = true ]; }
subscriptionError() { securityError "$(msg "$1")"; }

subscriptionValidatePaths() {
    local dir
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB" "$HIHY_SUB_UNIT"; do
        [[ "$dir" =~ ^/[A-Za-z0-9_./-]+$ ]] && [ "${#dir}" -gt 8 ] || return 1
        case "$dir/" in */../*|*/./*) return 1 ;; esac
        [ ! -L "$dir" ] || return 1
    done
}
subscriptionValidDomain() { isValidDomain "$1" && [[ "$1" = *.* && "$1" =~ [A-Za-z] ]]; }
subscriptionValidToken() { [[ "$1" =~ ^[a-f0-9]{64}$ ]]; }

# 检查当前配置是否能用于三类完整订阅。
subscriptionCheckCompatibility() {
    local source_root="$1" tcp_listen
    [ -s "$source_root/conf/config.yaml" ] && [ -s "$source_root/conf/backup.yaml" ] || return 1
    [ "$(getBackupValueOrDefault "$source_root/conf/backup.yaml" mimic_status false)" != true ] \
        && [ "$(getBackupValueOrDefault "$source_root/conf/config.yaml" mimic.enabled false)" != true ] \
        || { subscriptionError sub_incompatible; return 1; }
    tcp_listen=$(getBackupValueOrDefault "$source_root/conf/config.yaml" masquerade.listenHTTPS '')
    [[ "$tcp_listen" != *:443 ]] || { subscriptionError sub_port_conflict; return 1; }
}

# Render only client-facing credentials into one private, complete generation.
subscriptionRenderSnapshot() (
    local source_root="$1" output="$2" remarks file
    subscriptionCheckCompatibility "$source_root" || return 1
    mkdir -p "$output" || return 1
    [ ! -L "$output" ] || return 1
    HIHY_ROOT_DIR="$source_root"
    HIHY_EXPORT_DIR="$output/files"
    HIHY_CLIENT_ALLOW_LAN=false
    HIHY_CLIENT_QUIET=true
    if ! generate_client_config >"$output/render.log" 2>&1 || ! generateSingboxJson app >>"$output/render.log" 2>&1; then
        subscriptionError sub_render_failed; return 1
    fi
    remarks=$(getYamlValue "$source_root/conf/backup.yaml" remarks) || return 1
    cp -- "$(clientOutputPath "$remarks" v2rayN.yaml)" "$output/hysteria.yaml" || return 1
    cp -- "$(clientOutputPath "$remarks" mihomo.yaml)" "$output/mihomo.yaml" || return 1
    cp -- "$(clientOutputPath "$remarks" singbox.json)" "$output/singbox.json" || return 1
    yq -e '.auth != null and .server != null and .socks5.listen == "127.0.0.1:20808"' "$output/hysteria.yaml" >/dev/null || return 1
    yq -e '.proxies[0].type == "hysteria2" and .allow-lan == false' "$output/mihomo.yaml" >/dev/null || return 1
    yq -e '.inbounds[0].type == "tun" and .outbounds[0].type == "hysteria2" and .outbounds[0].tls.insecure == false' "$output/singbox.json" >/dev/null || return 1
    yq -e '.trafficStats == null and .acme == null and .tls.key == null' "$output/hysteria.yaml" >/dev/null || return 1
    for file in hysteria.yaml mihomo.yaml singbox.json; do
        chmod 600 "$output/$file" || return 1
    done
    rm -rf -- "$output/files"
    rm -f -- "$output/render.log"
)

# Generate an exact-path, format-negotiating Caddy site with no directory listing.
subscriptionWriteCaddyConfig() {
    local domain="$1" token="$2" out="$3" name format file content_type ua
    subscriptionValidatePaths && subscriptionValidDomain "$domain" && subscriptionValidToken "$token" || return 1
    [ ! -L "$out" ] || return 1
    cat >"$out" <<EOF
{
    admin off
    persist_config off
    auto_https disable_redirects
    log {
        output discard
    }
    servers {
        protocols h1 h2
    }
    storage file_system {
        root $HIHY_SUB_STATE/caddy
    }
}
https://$domain {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            disable_http_challenge
        }
    }
    header {
        Cache-Control "private, no-store, max-age=0"
        Vary "User-Agent"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        -Server
        -ETag
        -Last-Modified
    }
    @authorized path /s/$token
    handle @authorized {
        @read method GET HEAD
        handle @read {
            route {
                root * $HIHY_SUB_STATE/content/current
                request_header -If-None-Match
                request_header -If-Modified-Since
                request_header -Range
EOF
    for format in hysteria mihomo singbox; do
        case "$format" in
            hysteria) file=hysteria.yaml; content_type='application/yaml; charset=utf-8' ;;
            mihomo) file=mihomo.yaml; content_type='application/yaml; charset=utf-8' ;;
            singbox) file=singbox.json; content_type='application/json; charset=utf-8' ;;
        esac
        cat >>"$out" <<EOF
                @format_$format query format=$format
                handle @format_$format {
                    rewrite * /$file
                    header Content-Type "$content_type"
                    file_server
                }
EOF
    done
    cat >>"$out" <<'EOF'
                @other_format query format=*
                handle @other_format {
                    respond "Unsupported subscription format." 400
                }
EOF
    for name in hysteria mihomo singbox; do
        case "$name" in
            hysteria) file=hysteria.yaml; content_type='application/yaml; charset=utf-8'; ua='(?i)^v2rayn([/ ]|$)' ;;
            mihomo) file=mihomo.yaml; content_type='application/yaml; charset=utf-8'; ua='(?i)^(clash-verge|clashmeta|mihomo|clash)([/ ]|$)' ;;
            singbox) file=singbox.json; content_type='application/json; charset=utf-8'; ua='(?i)^(SFA|SFI|SFM)([/ ]|$)' ;;
        esac
        cat >>"$out" <<EOF
                @ua_$name header_regexp ua_$name User-Agent "$ua"
                handle @ua_$name {
                    rewrite * /$file
                    header Content-Type "$content_type"
                    file_server
                }
EOF
    done
    cat >>"$out" <<'EOF'
                handle {
                    respond "Unknown client. Specify format=hysteria, mihomo or singbox." 400
                }
            }
        }
        handle {
            respond "Method not allowed." 405
        }
    }
    handle {
        respond "Not found." 404
    }
}
EOF
    chmod 600 "$out"
}

# Publish one immutable generation; Caddy can read but cannot change these files.
subscriptionCommitSnapshot() (
    local source_dir="$1" generation="" tmp="" previous committed=false
    subscriptionPathOwned "$HIHY_SUB_STATE" || return 1
    trap 'if [ "$committed" != true ] && [ -n "$generation" ]; then rm -rf -- "$generation"; fi; [ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
    generation=$(mktemp -d "$HIHY_SUB_STATE/content/generations/g.XXXXXXXX") || return 1
    local file
    for file in hysteria.yaml mihomo.yaml singbox.json; do
        [ -s "$source_dir/$file" ] && [ ! -L "$source_dir/$file" ] || return 1
        cp -- "$source_dir/$file" "$generation/$file" || return 1
    done
    chown -R "root:$HIHY_SUB_USER" "$generation" && chmod 750 "$generation" \
        && chmod 640 "$generation/"* || { rm -rf -- "$generation"; return 1; }
    previous=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null) || previous=""
    if [ -n "$previous" ]; then
        [[ "$previous" =~ ^generations/g\.[A-Za-z0-9]+$ ]] || return 1
        ln -sfn -- "$previous" "$HIHY_SUB_STATE/content/previous" || return 1
    fi
    tmp="$HIHY_SUB_STATE/content/.current.$BASHPID"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    ln -s "generations/$(basename "$generation")" "$tmp" && mv -Tf -- "$tmp" "$HIHY_SUB_STATE/content/current" || return 1
    committed=true
)

subscriptionRestoreSnapshot() {
    local target="$1" temp="$HIHY_SUB_STATE/content/.restore.$BASHPID"
    if [ -z "$target" ]; then rm -f -- "$HIHY_SUB_STATE/content/current"; return; fi
    [[ "$target" =~ ^generations/g\.[A-Za-z0-9]+$ ]] && [ -d "$HIHY_SUB_STATE/content/$target" ] || return 1
    [ ! -e "$temp" ] && [ ! -L "$temp" ] || return 1
    ln -s "$target" "$temp" && mv -Tf -- "$temp" "$HIHY_SUB_STATE/content/current"
}

subscriptionPruneSnapshots() {
    local current previous dir
    subscriptionPathOwned "$HIHY_SUB_STATE" || return 1
    current=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null) || current=""
    previous=$(readlink "$HIHY_SUB_STATE/content/previous" 2>/dev/null) || previous=""
    for dir in "$HIHY_SUB_STATE/content/generations/"g.*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        [ "generations/$(basename "$dir")" = "$current" ] || [ "generations/$(basename "$dir")" = "$previous" ] || rm -rf -- "$dir"
    done
}

subscriptionRefresh() (
    subscriptionEnabled || { subscriptionError sub_not_enabled; return 1; }
    local dir
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    subscriptionRenderSnapshot "$HIHY_ROOT_DIR" "$dir/snapshot" && subscriptionCommitSnapshot "$dir/snapshot" || return 1
    subscriptionPruneSnapshots || return 1
    printf '%s\n' "$(msg sub_refreshed)"
)
