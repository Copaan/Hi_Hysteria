#!/bin/bash
hihyUpdate() {
    printf '%s\n' 'Use a reviewed local installation package to update hihy. Remote self-update is disabled.'
}

changeIp64() (
    local config="$HIHY_ROOT_DIR/conf/config.yaml" dir input mode
    [ -f "$config" ] || return 1
    [ "$(getBackupValueOrDefault "$HIHY_ROOT_DIR/conf/backup.yaml" socks5_status false)" != true ] || return 1
    echoColor yellow "$(i18n ip_priority_choice_ipv4)"
    echoColor yellow "$(i18n ip_priority_choice_ipv6)"
    echoColor yellow "$(i18n ip_priority_choice_auto)"
    read -r -p "$(i18n prompt_choose)" input
    case "$input" in 1) mode=46 ;; 2) mode=64 ;; 3) mode=auto ;; 0) return 0 ;; *) return 1 ;; esac
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    cp -- "$config" "$dir/config.yaml" || return 1
    addOrUpdateYaml "$dir/config.yaml" outbounds[0].direct.mode "$mode" string || return 1
    commitServerEdit "$dir/config.yaml" || return 1
    echoColor green "$(i18n switch_success)"
)

changeServerConfig() {
    [ -f "$HIHY_ROOT_DIR/conf/config.yaml" ] || return 1
    setHysteriaConfig || return 1
    generate_client_config || return 1
    echoColor green "$(i18n change_config_success)"
}

aclControl() (
    local live="$HIHY_ROOT_DIR/acl/acl.txt" dir input domain rule prefix matches count
    [ -f "$live" ] || return 1
    echoColor purple "$(i18n acl_action_prompt)"
    echoColor yellow "$(i18n acl_choice_add)"
    echoColor yellow "$(i18n acl_choice_delete)"
    echoColor yellow "$(i18n acl_choice_view)"
    read -r -p "$(i18n menu_prompt_choice)" input
    case "$input" in 0) return 0 ;; 3) cat "$live"; return 0 ;; 1|2) ;; *) return 1 ;; esac
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    cp -- "$live" "$dir/acl.txt" && cp -- "$HIHY_ROOT_DIR/conf/config.yaml" "$dir/config.yaml" || return 1
    if [ "$input" = 1 ]; then
        echoColor yellow "$(i18n acl_choice_v4_suffix)"
        echoColor yellow "$(i18n acl_choice_v6_suffix)"
        echoColor yellow "$(i18n acl_choice_reject_suffix)"
        read -r input
        case "$input" in 1) prefix=v4_only ;; 2) prefix=v6_only ;; 3) prefix=reject ;; *) return 1 ;; esac
        read -r -p "$(i18n acl_v4_domain_prompt)" domain
        domain="${domain,,}"
        isValidDomain "$domain" || return 1
        rule="$prefix(suffix:$domain)"
        grep -Fxq -- "$rule" "$live" && return 0
        printf '%s\n' "$rule" >>"$dir/acl.txt"
    else
        read -r -p "$(i18n acl_delete_rule_prompt)" domain
        if isValidDomain "$domain"; then
            matches=""; count=0
            for prefix in v4_only v6_only reject; do
                rule="$prefix(suffix:${domain,,})"
                if grep -Fxq -- "$rule" "$live"; then matches="$rule"; count=$((count+1)); fi
            done
            [ "$count" = 1 ] || { securityError 'Enter the complete rule when a domain has zero or multiple matches.'; return 1; }
            rule="$matches"
        else
            rule="$domain"
            [[ "$rule" != *$'\n'* ]] && grep -Fxq -- "$rule" "$live" || return 1
        fi
        grep -Fxv -- "$rule" "$live" >"$dir/acl.txt" || [ $? -eq 1 ] || return 1
    fi
    commitServerEdit "$dir/config.yaml" "$dir/acl.txt"
)

addSocks5Outbound() (
    local config="$HIHY_ROOT_DIR/conf/config.yaml" dir choice addr user pass port name status=true
    [ -f "$config" ] || return 1
    echoColor yellow "$(i18n socks5_warp_choice)"
    echoColor yellow "$(i18n socks5_custom_choice)"
    echoColor yellow "$(i18n socks5_remove_choice)"
    read -r -p "$(i18n menu_prompt_choice)" choice
    case "$choice" in 1|2|3) ;; *) return 0 ;; esac
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    if [ "$choice" = 3 ]; then
        name=$(getYamlValue "$config" outbounds[0].name) || return 1
        [[ "$name" = warp || "$name" = custom ]] || return 1
        yq 'del(.outbounds[0])' "$config" >"$dir/config.yaml" || return 1
        status=false
    else
        [ "$(getBackupValueOrDefault "$HIHY_ROOT_DIR/conf/backup.yaml" socks5_status false)" != true ] || return 1
        if [ "$choice" = 1 ]; then
            [ -f /etc/wireguard/proxy.conf ] || installWarpVerified w || return 1
            [ -f /etc/wireguard/proxy.conf ] || return 1
            port=$(awk -F: '/^[[:space:]]*BindAddress[[:space:]]*=/ {gsub(/[[:space:]]/, "", $NF); print $NF}' /etc/wireguard/proxy.conf)
            isValidPort "$port" || return 1
            name=warp; addr="127.0.0.1:$port"; user=""; pass=""
        else
            name=custom
            read -r -p "$(i18n socks5_addr_prompt)" addr
            [[ "$addr" =~ ^(\[[A-Za-z0-9:.%]+\]|[A-Za-z0-9.-]+):[0-9]+$ ]] && isValidPort "${addr##*:}" || return 1
            read -r -p "$(i18n socks5_user_prompt)" user
            pass=""
            if [ -n "$user" ]; then read -rs -p "$(i18n socks5_pass_prompt)" pass; printf '\n'; [ -n "$pass" ] || return 1; fi
        fi
        addOrUpdateYaml "$dir/outbound.yaml" name "$name" string || return 1
        addOrUpdateYaml "$dir/outbound.yaml" type socks5 string || return 1
        addOrUpdateYaml "$dir/outbound.yaml" socks5.addr "$addr" string || return 1
        if [ -n "$user" ]; then
            addOrUpdateYaml "$dir/outbound.yaml" socks5.username "$user" string || return 1
            addOrUpdateYaml "$dir/outbound.yaml" socks5.password "$pass" string || return 1
        fi
        HIHY_OUTBOUND_FILE="$dir/outbound.yaml" yq '.outbounds = [load(strenv(HIHY_OUTBOUND_FILE))] + .outbounds' "$config" >"$dir/config.yaml" || return 1
    fi
    commitServerEdit "$dir/config.yaml" '' "$status" || return 1
    printf '%s\n' 'SOCKS5 configuration updated.'
)
