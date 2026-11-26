#!/bin/bash
# mihomo (Clash.Meta) 客户端配置生成
# 修复说明(对照 wiki.metacubex.one hysteria2 proxy):
#   1. 仅 brutal 模式才输出 up/down;BBR/Reno 省略(=BBR,与原生语义对齐)
#   2. BBR 时输出 bbr-profile(standard 省略)
#   3. 端口跳跃输出 hop-interval(random 模式用 min-max 区间)
#   4. Realm 模式输出 realm-opts(enable/server-url/token/realm-id/stun-servers),并保留 port 占位
#   5. 规则镜像改用 jsdelivr(HIHY_RULESET_MIRROR 可覆盖)
#   6. 删除 GEOIP 规则:LAN 由 lancidr 覆盖;CN 由 cncidr 覆盖,且 GEOIP 会强制下载 MMDB,
#      下载失败会让整份配置启动失败
#   7. Gecko 和 ECH 按 mihomo 1.19.34 的字段输出；Mimic 不受支持
generateMihomoYaml() (
    loadClientParams || return 1
    [ "$HIHY_CP_mimicStatus" != true ] || return 1
    local remarks="$HIHY_CP_remarks"
    local destination metaFile
    destination=$(clientOutputPath "$remarks" mihomo.yaml) || return 1
    metaFile=$(mktemp "$HIHY_EXPORT_DIR/.mihomo.XXXXXXXX") || return 1
    trap 'rm -f -- "$metaFile"' EXIT
    local mirror="$HIHY_RULESET_MIRROR"
    [[ "$mirror" =~ ^https://[A-Za-z0-9./:_@-]+$ ]] || return 1

    # ---------- 静态头: general / dns / rule-providers / rules ----------
    cat >"$metaFile" <<EOF
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: true
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: true
  default-nameserver:
    - 114.114.114.114
    - 223.5.5.5
  enhanced-mode: redir-host
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://223.5.5.5/dns-query
  # 不配置 fallback:mihomo 的默认 fallback-filter 带 geoip,会在启动时强制下载 MMDB
  # (下载失败则整份配置起不来);且原先的 fallback 与 nameserver 同为国内 DNS,本就无意义。
  # proxy-server-nameserver 用于解析节点域名,避免 DNS 请求绕回代理形成环路。
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
rule-providers:
  reject:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/reject.txt"
    path: ./ruleset/reject.yaml
    interval: 86400

  icloud:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/icloud.txt"
    path: ./ruleset/icloud.yaml
    interval: 86400

  apple:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/apple.txt"
    path: ./ruleset/apple.yaml
    interval: 86400

  google:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/google.txt"
    path: ./ruleset/google.yaml
    interval: 86400

  proxy:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/proxy.txt"
    path: ./ruleset/proxy.yaml
    interval: 86400

  direct:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/direct.txt"
    path: ./ruleset/direct.yaml
    interval: 86400

  private:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/private.txt"
    path: ./ruleset/private.yaml
    interval: 86400

  gfw:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/gfw.txt"
    path: ./ruleset/gfw.yaml
    interval: 86400

  greatfire:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/greatfire.txt"
    path: ./ruleset/greatfire.yaml
    interval: 86400

  tld-not-cn:
    type: http
    behavior: domain
    url: "${mirror}/Loyalsoldier/clash-rules@release/tld-not-cn.txt"
    path: ./ruleset/tld-not-cn.yaml
    interval: 86400

  telegramcidr:
    type: http
    behavior: ipcidr
    url: "${mirror}/Loyalsoldier/clash-rules@release/telegramcidr.txt"
    path: ./ruleset/telegramcidr.yaml
    interval: 86400

  cncidr:
    type: http
    behavior: ipcidr
    url: "${mirror}/Loyalsoldier/clash-rules@release/cncidr.txt"
    path: ./ruleset/cncidr.yaml
    interval: 86400

  lancidr:
    type: http
    behavior: ipcidr
    url: "${mirror}/Loyalsoldier/clash-rules@release/lancidr.txt"
    path: ./ruleset/lancidr.yaml
    interval: 86400

  applications:
    type: http
    behavior: classical
    url: "${mirror}/Loyalsoldier/clash-rules@release/applications.txt"
    path: ./ruleset/applications.yaml
    interval: 86400

rules:
  - RULE-SET,applications,DIRECT
  - DOMAIN,clash.razord.top,DIRECT
  - DOMAIN,yacd.haishan.me,DIRECT
  - DOMAIN,services.googleapis.cn,PROXY
  - RULE-SET,private,DIRECT
  - RULE-SET,reject,REJECT
  - RULE-SET,icloud,DIRECT
  - RULE-SET,apple,DIRECT
  - RULE-SET,google,DIRECT
  - RULE-SET,proxy,PROXY
  - RULE-SET,direct,DIRECT
  - RULE-SET,lancidr,DIRECT
  - RULE-SET,cncidr,DIRECT
  - RULE-SET,telegramcidr,PROXY
  - MATCH,PROXY
EOF

    # ---------- 动态 proxies[0] ----------
    addOrUpdateYaml "$metaFile" "proxies[0].name" "${remarks}" || return 1
    addOrUpdateYaml "$metaFile" "proxies[0].type" "hysteria2" || return 1

    if [ "$HIHY_CP_realmMode" = "true" ]; then
        parseRealmURI "$HIHY_CP_realmURI"
        # realm 模式仍必须保留 server + port:mihomo 无条件校验端口,删掉 port 会让整份配置
        # 以 "proxy 0: invalid port" 拒载(已用 mihomo v1.19.29 实测)。实际地址由牵手服务
        # 打洞后确定,这里的 443 只是占位,与官方示例保持同一形状。
        addOrUpdateYaml "$metaFile" "proxies[0].server" "${HIHY_CP_serverAddress}" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].port" "443" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].realm-opts.enable" "true" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].realm-opts.server-url" "${HIHY_REALM_SERVER_URL}" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].realm-opts.token" "${HIHY_REALM_TOKEN}" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].realm-opts.realm-id" "${HIHY_REALM_ID}" "string" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].realm-opts.stun-servers[0]" "stun.nextcloud.com:3478" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].realm-opts.stun-servers[1]" "global.stun.twilio.com:3478" || return 1
    else
        addOrUpdateYaml "$metaFile" "proxies[0].server" "${HIHY_CP_serverAddress}" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].port" "${HIHY_CP_port}" || return 1
        if [ "$HIHY_CP_phStatus" = "true" ]; then
            addOrUpdateYaml "$metaFile" "proxies[0].ports" "${HIHY_CP_phStart}-${HIHY_CP_phEnd}" || return 1
            local hi_num hi_min hi_max
            if [ "$HIHY_CP_phIntervalMode" = "random" ]; then
                hi_min=$(echo "$HIHY_CP_phMinHopInterval" | tr -dc '0-9')
                hi_max=$(echo "$HIHY_CP_phMaxHopInterval" | tr -dc '0-9')
                addOrUpdateYaml "$metaFile" "proxies[0].hop-interval" "${hi_min}-${hi_max}" "string" || return 1
            else
                hi_num=$(echo "$HIHY_CP_phHopInterval" | tr -dc '0-9')
                addOrUpdateYaml "$metaFile" "proxies[0].hop-interval" "${hi_num}" || return 1
            fi
        fi
    fi

    addOrUpdateYaml "$metaFile" "proxies[0].password" "${HIHY_CP_auth}" || return 1

    # 拥塞:仅 brutal 输出 up/down;BBR 输出 bbr-profile(standard 省略,与默认值一致)
    if [ "$HIHY_CP_congestionMode" = "brutal" ]; then
        local up_num down_num
        up_num=$(echo "$HIHY_CP_up" | tr -dc '0-9')
        down_num=$(echo "$HIHY_CP_down" | tr -dc '0-9')
        addOrUpdateYaml "$metaFile" "proxies[0].up" "${up_num} Mbps" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].down" "${down_num} Mbps" || return 1
    else
        yq eval 'del(.proxies[0].up, .proxies[0].down)' -i "$metaFile" || return 1
        if [ "$HIHY_CP_congestionMode" = "bbr" ] && [ "$HIHY_CP_bbrProfile" != "" ] && [ "$HIHY_CP_bbrProfile" != "standard" ]; then
            addOrUpdateYaml "$metaFile" "proxies[0].bbr-profile" "${HIHY_CP_bbrProfile}" || return 1
        fi
    fi

    # 证书
    if [ -n "$HIHY_CP_pinSHA256" ]; then
        addOrUpdateYaml "$metaFile" "proxies[0].skip-cert-verify" "false" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].fingerprint" "${HIHY_CP_pinSHA256}" "string" || return 1
    else
        addOrUpdateYaml "$metaFile" "proxies[0].skip-cert-verify" "${HIHY_CP_insecure}" || return 1
        yq eval 'del(.proxies[0].fingerprint)' -i "$metaFile" || return 1
    fi

    # 混淆:输出用户选择的 salamander 或 gecko 参数
    if [ "$HIHY_CP_obfsStatus" = "true" ]; then
        addOrUpdateYaml "$metaFile" "proxies[0].obfs" "$HIHY_CP_obfsType" "string" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].obfs-password" "${HIHY_CP_obfsPass}" || return 1
    else
        yq eval 'del(.proxies[0].obfs, .proxies[0].obfs-password)' -i "$metaFile" || return 1
    fi

    addOrUpdateYaml "$metaFile" "proxies[0].sni" "${HIHY_CP_sni}" || return 1
    if [ "$HIHY_CP_echStatus" = "true" ]; then
        addOrUpdateYaml "$metaFile" "proxies[0].ech-opts.enable" "true" || return 1
        addOrUpdateYaml "$metaFile" "proxies[0].ech-opts.config" "${HIHY_CP_echConfig}" "string" || return 1
    fi
    addOrUpdateYaml "$metaFile" "proxy-groups[0].name" "PROXY" || return 1
    addOrUpdateYaml "$metaFile" "proxy-groups[0].type" "select" || return 1
    addOrUpdateYaml "$metaFile" "proxy-groups[0].proxies[0]" "${remarks}" "string" || return 1

    if [ "$HIHY_CLIENT_ALLOW_LAN" = true ]; then
        addOrUpdateYaml "$metaFile" allow-lan true bool || return 1
        addOrUpdateYaml "$metaFile" bind-address 0.0.0.0 string || return 1
        addOrUpdateYaml "$metaFile" dns.listen 0.0.0.0:1053 string || return 1
    fi
    [ ! -L "$destination" ] || return 1
    chmod 600 "$metaFile" && mv -f -- "$metaFile" "$destination" || return 1
    printf 'mihomo 1.19.34+: %s\n' "$destination"
)
