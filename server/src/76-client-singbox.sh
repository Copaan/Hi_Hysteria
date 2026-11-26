#!/bin/bash
# Generate a sing-box 1.14+ configuration with structured value encoding.
generateSingboxJson() (
    local profile="${1:-desktop}"
    case "$profile" in desktop|app) ;; *) return 1 ;; esac
    loadClientParams || return 1
    [ "$HIHY_CP_mimicStatus" != true ] || { securityError 'sing-box does not support Mimic.'; return 1; }
    local destination outFile json_file root="$HIHY_ROOT_DIR" mirror="$HIHY_RULESET_MIRROR" ca_file n up_num down_num
    destination=$(clientOutputPath "$HIHY_CP_remarks" singbox.json) || return 1
    outFile=$(mktemp "$HIHY_EXPORT_DIR/.singbox.XXXXXXXX") || return 1
    json_file=$(mktemp "$HIHY_EXPORT_DIR/.json.XXXXXXXX") || { rm -f "$outFile"; return 1; }
    trap 'rm -f -- "$outFile" "$json_file"' EXIT
    cat >"$outFile" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "dns": {
    "servers": [
      {"type": "tls", "tag": "google", "server": "8.8.8.8", "detour": "PROXY"},
      {"type": "https", "tag": "local", "server": "223.5.5.5"}
    ],
    "rules": [{"rule_set": "geosite-cn", "server": "local"}],
    "final": "google"
  },
  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 20808}],
  "outbounds": [{"type": "hysteria2", "tag": "PROXY", "tls": {"enabled": true, "insecure": false}}, {"type": "direct", "tag": "direct"}],
  "route": {
    "default_domain_resolver": "local",
    "rule_set": [
      {"type": "remote", "tag": "geosite-cn", "format": "binary", "download_detour": "PROXY"},
      {"type": "remote", "tag": "geoip-cn", "format": "binary", "download_detour": "PROXY"}
    ],
    "rules": [{"ip_is_private": true, "outbound": "direct"}, {"rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct"}],
    "final": "PROXY"
  },
  "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}, "cache_file": {"enabled": true}}
}
JSON
    addOrUpdateYaml "$outFile" route.rule_set[0].url "$mirror/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs" string || return 1
    addOrUpdateYaml "$outFile" route.rule_set[1].url "$mirror/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs" string || return 1
    if [ "$HIHY_CLIENT_ALLOW_LAN" = true ]; then addOrUpdateYaml "$outFile" inbounds[0].listen 0.0.0.0 string || return 1; fi
    addOrUpdateYaml "$outFile" outbounds[0].password "$HIHY_CP_auth" string || return 1
    addOrUpdateYaml "$outFile" outbounds[0].tls.server_name "$HIHY_CP_sni" string || return 1
    if [ -n "$HIHY_CP_pinSHA256" ]; then
        ca_file="$root/result/$HIHY_CP_sni.ca.crt"
        [ -s "$ca_file" ] || { securityError 'CA certificate required for sing-box export.'; return 1; }
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            addOrUpdateYaml "$outFile" "outbounds[0].tls.certificate[$n]" "$line" string || return 1
            n=$((n+1))
        done <"$ca_file"
    fi
    if [ "$HIHY_CP_echStatus" = true ]; then
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.enabled true bool || return 1
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.config[0] '-----BEGIN ECH CONFIGS-----' string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.config[1] "$HIHY_CP_echConfig" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.config[2] '-----END ECH CONFIGS-----' string || return 1
    fi
    if [ "$HIHY_CP_realmMode" = true ]; then
        parseRealmURI "$HIHY_CP_realmURI"
        addOrUpdateYaml "$outFile" outbounds[0].realm.server_url "$HIHY_REALM_SERVER_URL" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.token "$HIHY_REALM_TOKEN" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.realm_id "$HIHY_REALM_ID" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.stun_servers[0] stun.nextcloud.com:3478 string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.stun_servers[1] global.stun.twilio.com:3478 string || return 1
    else
        addOrUpdateYaml "$outFile" outbounds[0].server "$HIHY_CP_serverAddress" string || return 1
        if [ "$HIHY_CP_phStatus" = true ]; then
            addOrUpdateYaml "$outFile" outbounds[0].server_ports[0] "$HIHY_CP_phStart:$HIHY_CP_phEnd" string || return 1
            if [ "$HIHY_CP_phIntervalMode" = random ]; then
                addOrUpdateYaml "$outFile" outbounds[0].hop_interval "$HIHY_CP_phMinHopInterval" string || return 1
                addOrUpdateYaml "$outFile" outbounds[0].hop_interval_max "$HIHY_CP_phMaxHopInterval" string || return 1
            else addOrUpdateYaml "$outFile" outbounds[0].hop_interval "$HIHY_CP_phHopInterval" string || return 1; fi
        else addOrUpdateYaml "$outFile" outbounds[0].server_port "$HIHY_CP_port" number || return 1; fi
    fi
    if [ "$HIHY_CP_congestionMode" = brutal ]; then
        up_num="${HIHY_CP_up%% *}"; down_num="${HIHY_CP_down%% *}"
        up_num="${up_num%mbps}"; down_num="${down_num%mbps}"
        addOrUpdateYaml "$outFile" outbounds[0].up_mbps "$up_num" number || return 1
        addOrUpdateYaml "$outFile" outbounds[0].down_mbps "$down_num" number || return 1
    elif [ "$HIHY_CP_congestionMode" = bbr ] && [ -n "$HIHY_CP_bbrProfile" ]; then
        addOrUpdateYaml "$outFile" outbounds[0].bbr_profile "$HIHY_CP_bbrProfile" string || return 1
    fi
    if [ "$HIHY_CP_obfsStatus" = true ]; then
        addOrUpdateYaml "$outFile" outbounds[0].obfs.type "$HIHY_CP_obfsType" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].obfs.password "$HIHY_CP_obfsPass" string || return 1
    fi
    if [ "$profile" = app ]; then
        yq -i '.inbounds = [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1500, "auto_route": true}] | .route.auto_detect_interface = true | .route.rules = [{"port": 53, "action": "hijack-dns"}] + .route.rules | del(.experimental.clash_api)' "$outFile" || return 1
    fi
    yq -o=json '.' "$outFile" >"$json_file" || return 1
    [ ! -L "$destination" ] || return 1
    chmod 600 "$json_file" && mv -f -- "$json_file" "$destination" || return 1
    printf 'sing-box 1.14+: %s\n' "$destination"
)
