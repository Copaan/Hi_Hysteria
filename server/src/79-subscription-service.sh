#!/bin/bash
subscriptionFirewall() {
    local HIHY_FIREWALL_LEDGER="$HIHY_SUB_ETC/firewall.tsv" HIHY_FIREWALL_OWNER=hihy-subscription
    case "$1" in
        add) allowPort tcp 443 ;;
        remove) delHihyFirewallPort tcp ;;
        restore) firewallRestore ;;
        *) return 1 ;;
    esac
}
subscriptionFirewallRestore() { subscriptionOwned && subscriptionFirewall restore; }
subscriptionUnitOwned() { [ -f "$HIHY_SUB_UNIT" ] && [ ! -L "$HIHY_SUB_UNIT" ] && grep -Fxq '# Managed-by: hihy-subscription-v1' "$HIHY_SUB_UNIT"; }

subscriptionCheckPlatform() {
    [ "$(id -u)" = 0 ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null || { subscriptionError sub_platform; return 1; }
    grep -Eq '^ID=(debian|ubuntu|"debian"|"ubuntu")$' /etc/os-release || { subscriptionError sub_platform; return 1; }
    [ -s "$HIHY_ROOT_DIR/conf/config.yaml" ] && [ -s "$HIHY_ROOT_DIR/conf/backup.yaml" ] || { subscriptionError sub_need_install; return 1; }
    subscriptionValidatePaths || return 1
}

# DNS must resolve before the local, publicly trusted TLS readiness check can succeed.
subscriptionCheckDomain() {
    local name="$1" records
    subscriptionValidDomain "$name" || { subscriptionError sub_bad_domain; return 1; }
    records=$( { dig +time=3 +tries=1 +short A "$name"; dig +time=3 +tries=1 +short AAAA "$name"; } 2>/dev/null)
    printf '%s\n' "$records" | grep -Eq '^([0-9]+\.){3}[0-9]+$|^[[:xdigit:]:]+:[[:xdigit:]:]+$' || { subscriptionError sub_dns_failed; return 1; }
}

subscriptionCheckPort() {
    if lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1; then subscriptionError sub_port_conflict; return 1; fi
}

# Install the official pinned archive into a project-owned binary directory.
subscriptionInstallCaddy() (
    local arch expected temp actual
    arch=$(getArchitecture)
    case "$arch" in
        amd64) expected=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
        arm64) expected=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
        *) subscriptionError sub_arch; return 1 ;;
    esac
    if [ -e "$HIHY_SUB_LIB/caddy" ]; then
        [ ! -L "$HIHY_SUB_LIB/caddy" ] && [ -f "$HIHY_SUB_LIB/caddy.sha256" ] && [ ! -L "$HIHY_SUB_LIB/caddy.sha256" ] || return 1
        actual=$(sha256sum "$HIHY_SUB_LIB/caddy" | cut -d' ' -f1)
        [ "$actual" = "$(cat "$HIHY_SUB_LIB/caddy.sha256")" ] && validateCoreArchitecture "$HIHY_SUB_LIB/caddy" "$arch" \
            && [ "$("$HIHY_SUB_LIB/caddy" version | awk '{print $1}')" = "v$HIHY_CADDY_VERSION" ] || { subscriptionError sub_binary_invalid; return 1; }
        return 0
    fi
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    downloadVerifiedFile "https://github.com/caddyserver/caddy/releases/download/v$HIHY_CADDY_VERSION/caddy_${HIHY_CADDY_VERSION}_linux_$arch.tar.gz" "$temp/caddy.tar.gz" "$expected" || return 1
    tar -xOf "$temp/caddy.tar.gz" caddy >"$temp/caddy" || return 1
    validateCoreArchitecture "$temp/caddy" "$arch" || return 1
    chmod 700 "$temp/caddy" || return 1
    [ "$("$temp/caddy" version | awk '{print $1}')" = "v$HIHY_CADDY_VERSION" ] || return 1
    actual=$(sha256sum "$temp/caddy" | cut -d' ' -f1)
    cp -- "$temp/caddy" "$HIHY_SUB_LIB/.caddy.pending" && chmod 755 "$HIHY_SUB_LIB/.caddy.pending" \
        && mv -f -- "$HIHY_SUB_LIB/.caddy.pending" "$HIHY_SUB_LIB/caddy" || return 1
    printf '%s\n' "$actual" >"$HIHY_SUB_LIB/caddy.sha256"
    chmod 600 "$HIHY_SUB_LIB/caddy.sha256"
)

# Claim only empty project namespaces and a new dedicated account.
subscriptionPreparePaths() {
    local dir
    subscriptionValidatePaths || return 1
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do
        if [ -e "$dir" ] && ! subscriptionPathOwned "$dir"; then subscriptionError sub_unowned; return 1; fi
    done
    if [ -e "$HIHY_SUB_UNIT" ] && ! subscriptionUnitOwned; then subscriptionError sub_unowned; return 1; fi
    if id "$HIHY_SUB_USER" >/dev/null 2>&1 || getent group "$HIHY_SUB_USER" >/dev/null; then
        subscriptionOwned && [ -f "$HIHY_SUB_ETC/account-owned" ] || { subscriptionError sub_unowned; return 1; }
        [ "$(id -u "$HIHY_SUB_USER")" -gt 0 ] && [ "$(id -gn "$HIHY_SUB_USER")" = "$HIHY_SUB_USER" ] \
            && [ -z "$(getent group "$HIHY_SUB_USER" | cut -d: -f4)" ] || return 1
    fi
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do
        if [ ! -e "$dir" ]; then
            mkdir -m 700 -p "$dir" || return 1
            printf '%s\n' hihy-subscription-v1 >"$dir/.hihy-sub-owned" || return 1
        fi
    done
    if ! id "$HIHY_SUB_USER" >/dev/null 2>&1; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$HIHY_SUB_USER" || return 1
        : >"$HIHY_SUB_ETC/account-owned"
    fi
    chown "root:$HIHY_SUB_USER" "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" || return 1
    chmod 750 "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" && chmod 755 "$HIHY_SUB_LIB" || return 1
    for dir in "$HIHY_SUB_STATE/content" "$HIHY_SUB_STATE/content/generations"; do
        [ ! -L "$dir" ] || return 1
        mkdir -p "$dir" && chown "root:$HIHY_SUB_USER" "$dir" && chmod 750 "$dir" || return 1
    done
    [ ! -L "$HIHY_SUB_STATE/caddy" ] || return 1
    mkdir -p "$HIHY_SUB_STATE/caddy" && chown "$HIHY_SUB_USER:$HIHY_SUB_USER" "$HIHY_SUB_STATE/caddy" && chmod 700 "$HIHY_SUB_STATE/caddy"
}

subscriptionWriteUnit() {
    local out="$1"
    subscriptionValidatePaths || return 1
    cat >"$out" <<EOF
# Managed-by: hihy-subscription-v1
[Unit]
Description=Hi Hysteria private subscription HTTPS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HIHY_SUB_USER
Group=$HIHY_SUB_USER
UMask=0077
Environment=HOME=$HIHY_SUB_STATE/caddy
Environment=XDG_DATA_HOME=$HIHY_SUB_STATE/caddy
Environment=XDG_CONFIG_HOME=$HIHY_SUB_STATE/caddy
Environment=HIHY_SUB_ETC=$HIHY_SUB_ETC
ExecStartPre=+$HIHY_BIN_LINK subscription-firewall-restore
ExecStart=$HIHY_SUB_LIB/caddy run --config $HIHY_SUB_ETC/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5s
TimeoutStopSec=15s
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=$HIHY_SUB_STATE/caddy
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$out"
}

# Probe through loopback with public-CA validation, keeping bearer URLs out of argv.
subscriptionProbe() (
    local domain="$1" token="$2" dir format file ok deadline=$((SECONDS + 120))
    subscriptionValidDomain "$domain" && subscriptionValidToken "$token" || return 1
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    while [ "$SECONDS" -lt "$deadline" ]; do
        ok=true
        for format in hysteria mihomo singbox; do
            file="$format.yaml"; [ "$format" != singbox ] || file=singbox.json
            printf 'url = "https://%s/s/%s?format=%s"\nresolve = "%s:443:127.0.0.1"\n' "$domain" "$token" "$format" "$domain" >"$dir/curl.conf"
            if ! curl --proto '=https' --noproxy '*' --fail --silent --show-error --connect-timeout 3 --max-time 10 --config "$dir/curl.conf" -o "$dir/body" 2>"$dir/error" \
                || ! cmp -s "$dir/body" "$HIHY_SUB_STATE/content/current/$file"; then ok=false; break; fi
        done
        [ "$ok" != true ] || return 0
        sleep 2
    done
    subscriptionError sub_tls_failed
)

subscriptionValidateCaddy() (
    local file="$1" dir
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    runuser -u "$HIHY_SUB_USER" -- "$HIHY_SUB_LIB/caddy" validate --config "$file" --adapter caddyfile >"$dir/validation.log" 2>&1 \
        || { subscriptionError sub_caddy_invalid; return 1; }
)

# Commit endpoint changes and restore the previous endpoint on any failed restart.
subscriptionApplyEndpoint() (
    local domain="$1" token="$2" dir previous="" was_active=false was_enabled=false success=false switched=false state_existed=false config_existed=false unit_existed=false
    dir=$(secureTempDir) || return 1
    rollbackSubscription() {
        local rc=$?
        if [ "$success" != true ] && [ "$switched" = true ]; then
            systemctl stop hihy-sub.service >/dev/null 2>&1 || true
            subscriptionRestoreSnapshot "$previous" || rc=1
            subscriptionPruneSnapshots || rc=1
            if [ "$config_existed" = true ]; then cp -p -- "$dir/Caddyfile.old" "$HIHY_SUB_ETC/Caddyfile" || rc=1; else rm -f -- "$HIHY_SUB_ETC/Caddyfile"; fi
            if [ "$state_existed" = true ]; then cp -p -- "$dir/state.old" "$HIHY_SUB_ETC/state.yaml" || rc=1; else rm -f -- "$HIHY_SUB_ETC/state.yaml"; fi
            if [ "$unit_existed" = true ]; then cp -p -- "$dir/unit.old" "$HIHY_SUB_UNIT" || rc=1; else systemctl disable hihy-sub.service >/dev/null 2>&1 || true; rm -f -- "$HIHY_SUB_UNIT"; fi
            systemctl daemon-reload || rc=1
            local HIHY_FIREWALL_LEDGER="$HIHY_SUB_ETC/firewall.tsv" HIHY_FIREWALL_OWNER=hihy-subscription
            restoreFirewallLedger "$dir/firewall.old" || rc=1
            if [ "$was_enabled" = true ]; then systemctl enable hihy-sub.service >/dev/null 2>&1 || rc=1; else systemctl disable hihy-sub.service >/dev/null 2>&1 || true; fi
            if [ "$was_active" = true ]; then systemctl start hihy-sub.service || rc=1; fi
        fi
        rm -f -- "$HIHY_SUB_ETC/.Caddyfile.pending"
        rm -rf -- "$dir"
        return "$rc"
    }
    trap rollbackSubscription EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ ! -f "$HIHY_SUB_ETC/Caddyfile" ] || { cp -p "$HIHY_SUB_ETC/Caddyfile" "$dir/Caddyfile.old" || return 1; config_existed=true; }
    [ ! -f "$HIHY_SUB_ETC/state.yaml" ] || { cp -p "$HIHY_SUB_ETC/state.yaml" "$dir/state.old" || return 1; state_existed=true; }
    [ ! -f "$HIHY_SUB_UNIT" ] || { subscriptionUnitOwned && cp -p "$HIHY_SUB_UNIT" "$dir/unit.old" || return 1; unit_existed=true; }
    previous=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null) || previous=""
    systemctl is-active --quiet hihy-sub.service && was_active=true
    systemctl is-enabled --quiet hihy-sub.service 2>/dev/null && was_enabled=true
    HIHY_FIREWALL_LEDGER="$HIHY_SUB_ETC/firewall.tsv" snapshotFirewallLedger "$dir/firewall.old" || return 1
    subscriptionRenderSnapshot "$HIHY_ROOT_DIR" "$dir/snapshot" || return 1
    subscriptionWriteCaddyConfig "$domain" "$token" "$HIHY_SUB_ETC/.Caddyfile.pending" || return 1
    chown "root:$HIHY_SUB_USER" "$HIHY_SUB_ETC/.Caddyfile.pending" && chmod 640 "$HIHY_SUB_ETC/.Caddyfile.pending" || return 1
    subscriptionValidateCaddy "$HIHY_SUB_ETC/.Caddyfile.pending" || return 1
    subscriptionWriteUnit "$dir/hihy-sub.service" || return 1
    systemd-analyze verify "$dir/hihy-sub.service" >"$dir/unit-check.log" 2>&1 || { subscriptionError sub_unit_invalid; return 1; }
    addOrUpdateYaml "$dir/state.yaml" domain "$domain" string && addOrUpdateYaml "$dir/state.yaml" token "$token" string \
        && addOrUpdateYaml "$dir/state.yaml" enabled true bool || return 1
    switched=true
    subscriptionFirewall add || return 1
    subscriptionCommitSnapshot "$dir/snapshot" || return 1
    mv -f -- "$HIHY_SUB_ETC/.Caddyfile.pending" "$HIHY_SUB_ETC/Caddyfile" && cp -p -- "$dir/hihy-sub.service" "$HIHY_SUB_UNIT" || return 1
    systemctl daemon-reload && systemctl restart hihy-sub.service || return 1
    subscriptionProbe "$domain" "$token" || return 1
    systemctl enable hihy-sub.service >/dev/null 2>&1 || return 1
    mv -f -- "$dir/state.yaml" "$HIHY_SUB_ETC/state.yaml" || return 1
    success=true
    subscriptionPruneSnapshots || true
)

subscriptionEnable() {
    local domain="${1:-}" token
    domain="${domain,,}"
    subscriptionCheckPlatform || return 1
    if subscriptionEnabled && systemctl is-active --quiet hihy-sub.service; then
        [ -z "$domain" ] || [ "$domain" = "$(subscriptionRead domain)" ] || { subscriptionError sub_disable_first; return 1; }
        subscriptionProbe "$(subscriptionRead domain)" "$(subscriptionRead token)" || return 1
        subscriptionShow
        return
    fi
    [ -n "$domain" ] || domain=$(subscriptionRead domain '')
    [ -n "$domain" ] || read -r -p "$(i18n sub_domain_prompt)" domain
    domain="${domain,,}"
    subscriptionCheckDomain "$domain" && subscriptionCheckPort || return 1
    subscriptionPreparePaths && subscriptionInstallCaddy || return 1
    token=$(subscriptionRead token '')
    subscriptionValidToken "$token" || token=$(openssl rand -hex 32) || return 1
    printf '%s\n' "$(i18n sub_enabling)"
    subscriptionApplyEndpoint "$domain" "$token" || return 1
    subscriptionShow
}

subscriptionShow() {
    local domain token url format
    subscriptionEnabled || { subscriptionError sub_not_enabled; return 1; }
    domain=$(subscriptionRead domain); token=$(subscriptionRead token)
    subscriptionValidDomain "$domain" && subscriptionValidToken "$token" || return 1
    url="https://$domain/s/$token"
    printf '%s\n%s\n' "$(i18n sub_link)" "$url"
    printf '%s\n' "$(i18n sub_v2rayn_hint)" "$(i18n sub_formats_hint)"
    for format in hysteria mihomo singbox; do printf '%s?format=%s\n' "$url" "$format"; done
    printf 'sing-box://import-remote-profile?url=%s#HiHysteria\n' "$(urlEncode "$url")"
    printf '%s\n' "$(i18n sub_secret_hint)"
}

subscriptionStatus() {
    if ! subscriptionOwned; then printf '%s\n' "$(i18n sub_not_enabled)"; return 0; fi
    printf '%s: %s\n' "$(i18n sub_domain_label)" "$(subscriptionRead domain '-')"
    printf '%s: %s\n' "$(i18n sub_enabled_label)" "$(subscriptionRead enabled false)"
    systemctl is-active hihy-sub.service || true
}

subscriptionDisable() {
    subscriptionOwned || { subscriptionError sub_not_enabled; return 1; }
    if [ -f "$HIHY_SUB_UNIT" ]; then
        subscriptionUnitOwned || return 1
        systemctl stop hihy-sub.service && systemctl disable hihy-sub.service >/dev/null 2>&1 || return 1
    fi
    subscriptionFirewall remove || return 1
    addOrUpdateYaml "$HIHY_SUB_ETC/state.yaml" enabled false bool || return 1
    printf '%s\n' "$(i18n sub_disabled)"
}

subscriptionRotateToken() {
    subscriptionEnabled || { subscriptionError sub_not_enabled; return 1; }
    subscriptionCheckPlatform && subscriptionInstallCaddy || return 1
    subscriptionApplyEndpoint "$(subscriptionRead domain)" "$(openssl rand -hex 32)" || return 1
    printf '%s\n' "$(i18n sub_rotation_hint)"
    subscriptionShow
}

subscriptionUninstall() {
    local dir account_owned=false
    subscriptionOwned || return 0
    subscriptionValidatePaths || return 1
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do subscriptionPathOwned "$dir" || return 1; done
    [ ! -f "$HIHY_SUB_ETC/account-owned" ] || account_owned=true
    subscriptionDisable || return 1
    [ ! -f "$HIHY_SUB_UNIT" ] || { subscriptionUnitOwned && rm -f -- "$HIHY_SUB_UNIT"; } || return 1
    systemctl daemon-reload || return 1
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do rm -rf -- "$dir" || return 1; done
    if [ "$account_owned" = true ] && id "$HIHY_SUB_USER" >/dev/null 2>&1; then userdel "$HIHY_SUB_USER" || return 1; fi
}

subscriptionMenu() {
    local choice
    printf '%s\n' "$(i18n sub_menu_choices)"
    read -r -p "$(i18n menu_prompt_choice)" choice || return 1
    case "$choice" in
        1) subscriptionEnable ;;
        2) subscriptionStatus ;;
        3) subscriptionShow ;;
        4) subscriptionRefresh ;;
        5) subscriptionRotateToken ;;
        6) subscriptionDisable ;;
        0) return 0 ;;
        *) return 1 ;;
    esac
}
subscriptionCommand() {
    case "${1:-menu}" in
        enable) subscriptionEnable "${2:-}" ;;
        status) subscriptionStatus ;;
        show) subscriptionShow ;;
        refresh) subscriptionRefresh ;;
        rotate-token) subscriptionRotateToken ;;
        disable) subscriptionDisable ;;
        menu) subscriptionMenu ;;
        *) printf '%s\n' 'hihy subscription enable|status|show|refresh|rotate-token|disable'; return 2 ;;
    esac
}
