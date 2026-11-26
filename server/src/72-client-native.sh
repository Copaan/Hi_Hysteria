#!/bin/bash
generate_client_config() (
    [ -f "$HIHY_ROOT_DIR/conf/config.yaml" ] || return 1
    # 统一从公共层读取所有参数(消除三个生成器的重复读取)
    loadClientParams || return 1
    local remarks="$HIHY_CP_remarks" serverAddress="$HIHY_CP_serverAddress"
    local realmMode="$HIHY_CP_realmMode" realmURI="$HIHY_CP_realmURI"
    local port="$HIHY_CP_port" auth_secret="$HIHY_CP_auth" tls_sni="$HIHY_CP_sni"
    local insecure="$HIHY_CP_insecure" pinSHA256="$HIHY_CP_pinSHA256"
    local obfs_status="$HIHY_CP_obfsStatus" obfs_type="$HIHY_CP_obfsType" obfs_pass="$HIHY_CP_obfsPass"
    local SRW="$HIHY_CP_srw" CRW="$HIHY_CP_crw" max_CRW="$HIHY_CP_maxCrw" max_SRW="$HIHY_CP_maxSrw"
    local congestion_mode="$HIHY_CP_congestionMode" congestion_type="$HIHY_CP_congestionType" congestion_bbr_profile="$HIHY_CP_bbrProfile"
    local download="$HIHY_CP_down" upload="$HIHY_CP_up"
    local portHoppingStatus="$HIHY_CP_phStatus"
    local portHoppingStart="$HIHY_CP_phStart" portHoppingEnd="$HIHY_CP_phEnd"
    local portHoppingIntervalMode="$HIHY_CP_phIntervalMode"
    local portHoppingHopInterval="$HIHY_CP_phHopInterval"
    local portHoppingMinHopInterval="$HIHY_CP_phMinHopInterval"
    local portHoppingMaxHopInterval="$HIHY_CP_phMaxHopInterval"
    local serverPortRange=""
    if [ "${portHoppingStatus}" == "true" ]; then
        serverPortRange="${portHoppingStart}-${portHoppingEnd}"
    fi
    local destination client_configfile encoded_auth encoded_obfs encoded_sni encoded_remarks
    encoded_auth=$(urlEncode "$auth_secret"); encoded_obfs=$(urlEncode "$obfs_pass")
    encoded_sni=$(urlEncode "$tls_sni"); encoded_remarks=$(urlEncode "$remarks")
    [[ "$serverAddress" != *:* ]] || serverAddress="[$serverAddress]"
    destination=$(clientOutputPath "$remarks" v2rayN.yaml) || return 1
    client_configfile=$(mktemp "$HIHY_EXPORT_DIR/.native.XXXXXXXX") || return 1
    trap 'rm -f -- "$client_configfile"' EXIT
    if [ "$realmMode" = true ]; then
        addOrUpdateYaml "$client_configfile" server "$realmURI" string || return 1
    elif [ "$portHoppingStatus" = true ]; then
        addOrUpdateYaml "$client_configfile" server "$serverAddress:$port,$serverPortRange" string || return 1
    else
        addOrUpdateYaml "$client_configfile" server "$serverAddress:$port" string || return 1
    fi
    addOrUpdateYaml "$client_configfile" auth "$auth_secret" string || return 1
    if [ "${realmMode}" == "true" ]; then
        addOrUpdateYaml "$client_configfile" "realm.stunServers[0]" "stun.chat.bilibili.com:3478" || return 1
        addOrUpdateYaml "$client_configfile" "realm.stunServers[1]" "stun.miwifi.com:3478" || return 1
        addOrUpdateYaml "$client_configfile" "realm.stunServers[2]" "stun.nextcloud.com:3478" || return 1
        addOrUpdateYaml "$client_configfile" "realm.stunServers[3]" "global.stun.twilio.com:3478" || return 1
        addOrUpdateYaml "$client_configfile" "realm.stunTimeout" "5s" || return 1
        addOrUpdateYaml "$client_configfile" "realm.punchTimeout" "5s" || return 1
        addOrUpdateYaml "$client_configfile" "realm.heartbeatInterval" "30s" || return 1
        addOrUpdateYaml "$client_configfile" "realm.insecure" "false" || return 1
        addOrUpdateYaml "$client_configfile" "realm.ipMode" "dual" || return 1
        addOrUpdateYaml "$client_configfile" "realm.portMapping.enabled" "true" || return 1
        addOrUpdateYaml "$client_configfile" "realm.portMapping.timeout" "30s" || return 1
        addOrUpdateYaml "$client_configfile" "realm.portMapping.lifetime" "10m" || return 1
    else
        yq eval 'del(.realm)' -i "$client_configfile" || return 1
    fi

    addOrUpdateYaml "$client_configfile" "tls.sni" "${tls_sni}" || return 1
    if [ "${HIHY_CP_echStatus}" == "true" ]; then
        addOrUpdateYaml "$client_configfile" "tls.ech" "${HIHY_CP_echConfig}" "string" || return 1
    fi
    if [ -n "${pinSHA256}" ]; then
        # 证书指纹钉扎(pinning)必须与 insecure: true 同时使用:
        # hysteria 的 pinSHA256 只是追加一个 VerifyPeerCertificate 回调,并不会关闭 Go 的标准
        # 证书链校验 —— 自签证书没有受信任的链,insecure: false 时握手直接失败
        # ("x509: certificate signed by unknown authority")。
        # 这不降低安全性:链校验被跳过后,仍要求对端证书的 SHA-256 与此处的指纹逐字节一致,
        # 攻击者必须持有该证书私钥才能冒充,比信任任意 CA 更严格。
        addOrUpdateYaml "$client_configfile" "tls.pinSHA256" "${pinSHA256}" "string" || return 1
        addOrUpdateYaml "$client_configfile" "tls.insecure" "true" || return 1
    elif [ "${insecure}" == "true" ]; then
        securityError '此客户端需要有效的证书指纹。'; return 1
    elif [ "${insecure}" == "false" ]; then
        addOrUpdateYaml "$client_configfile" "tls.insecure" "false" || return 1
    fi
    addOrUpdateYaml "$client_configfile" "transport.type" "udp" || return 1
    if [ "${portHoppingStatus}" == "true" ]; then
        if [ "${portHoppingIntervalMode}" == "random" ]; then
            addOrUpdateYaml "$client_configfile" "transport.udp.minHopInterval" "${portHoppingMinHopInterval}" || return 1
            addOrUpdateYaml "$client_configfile" "transport.udp.maxHopInterval" "${portHoppingMaxHopInterval}" || return 1
            yq eval 'del(.transport.udp.hopInterval)' -i "$client_configfile" || return 1
        else
            addOrUpdateYaml "$client_configfile" "transport.udp.hopInterval" "${portHoppingHopInterval}" || return 1
            yq eval 'del(.transport.udp.minHopInterval, .transport.udp.maxHopInterval)' -i "$client_configfile" || return 1
        fi
    fi
    if [ "${obfs_status}" == "true" ]; then
        addOrUpdateYaml "$client_configfile" "obfs.type" "${obfs_type}" || return 1
        addOrUpdateYaml "$client_configfile" "obfs.${obfs_type}.password" "${obfs_pass}" || return 1
    else
        yq eval 'del(.obfs)' -i "$client_configfile" || return 1
    fi
    if [ "${HIHY_CP_mimicStatus}" == "true" ]; then
        addOrUpdateYaml "$client_configfile" "mimic.enabled" "true" "bool" || return 1
    else
        yq eval 'del(.mimic)' -i "$client_configfile" || return 1
    fi
    if [ "${congestion_mode}" != "brutal" ]; then
        addOrUpdateYaml "$client_configfile" "congestion.type" "${congestion_type}" || return 1
        if [ "${congestion_type}" == "bbr" ]; then
            addOrUpdateYaml "$client_configfile" "congestion.bbrProfile" "${congestion_bbr_profile}" || return 1
        fi
    fi
    if [ "${congestion_mode}" == "brutal" ]; then
        addOrUpdateYaml "$client_configfile" "quic.initStreamReceiveWindow" "${SRW}" || return 1
        addOrUpdateYaml "$client_configfile" "quic.initConnReceiveWindow" "${CRW}" || return 1
        addOrUpdateYaml "$client_configfile" "quic.maxConnReceiveWindow" "${max_CRW}" || return 1
        addOrUpdateYaml "$client_configfile" "quic.maxStreamReceiveWindow" "${max_SRW}" || return 1
    else
        yq eval 'del(.quic.initStreamReceiveWindow, .quic.initConnReceiveWindow, .quic.maxConnReceiveWindow, .quic.maxStreamReceiveWindow)' -i "$client_configfile" || return 1
    fi
    addOrUpdateYaml "$client_configfile" "quic.keepAlivePeriod" "60s" || return 1
    if [ "${congestion_mode}" == "brutal" ]; then
        addOrUpdateYaml "$client_configfile" "bandwidth.down" "${download}" || return 1
        addOrUpdateYaml "$client_configfile" "bandwidth.up" "${upload}" || return 1
    else
        yq eval 'del(.bandwidth)' -i "$client_configfile" || return 1
    fi
    addOrUpdateYaml "$client_configfile" "fastOpen" "true" || return 1
    addOrUpdateYaml "$client_configfile" "lazy" "false" || return 1
    addOrUpdateYaml "$client_configfile" "socks5.listen" "127.0.0.1:20808" || return 1
    if [ "${realmMode}" == "true" ]; then
        # Realm 分享链接: hysteria2+realm://<token>@<牵手服务器>[:port]/<realm名>?auth=<密码>&...
        # 由存储的 realm:// URI 转换而来: 仅替换协议头,userinfo 是牵手 token,Hysteria 密码放入 auth 参数
        realmShare=$(echo "${realmURI}" | sed -E 's#^realm(\+http)?://#hysteria2+realm\1://#')
        url="${realmShare}?auth=${encoded_auth}"
        if [ -n "${pinSHA256}" ]; then
            url="${url}&pinSHA256=${pinSHA256}&insecure=1"
        elif [ "${insecure}" == "true" ]; then
            url="${url}&insecure=1"
        fi
        if [ "${obfs_status}" == "true" ]; then
            url="${url}&obfs=${obfs_type}&obfs-password=${encoded_obfs}"
        fi
        if [ "${HIHY_CP_echStatus}" == "true" ]; then
            url="${url}&ech=$(echUrlEncodeB64 "${HIHY_CP_echConfig}")"
        fi
        url="${url}&sni=${encoded_sni}#Hy2-${encoded_remarks}"
    else
        url_base="hy2://${encoded_auth}@${serverAddress}"

        if [ "${portHoppingStatus}" == "true" ]; then
            url_base="${url_base}:${port}/?mport=${serverPortRange}&"
        else
            url_base="${url_base}:${port}/?"
        fi

        if [ -n "${pinSHA256}" ]; then
            # 与配置文件同理:指纹钉扎必须带 insecure=1 关闭标准链校验,否则客户端连不上
            url_base="${url_base}pinSHA256=${pinSHA256}&insecure=1"
        elif [ "${insecure}" == "true" ]; then
            url_base="${url_base}insecure=1"
        else
            url_base="${url_base}insecure=0"
        fi

        if [ "${obfs_status}" == "true" ]; then
            url_base="${url_base}&obfs=${obfs_type}&obfs-password=${encoded_obfs}"
        fi

        if [ "${HIHY_CP_echStatus}" == "true" ]; then
            # base64 含 + / = 需百分号编码;hysteria 解析端对 std/url-safe base64 均兼容
            url_base="${url_base}&ech=$(echUrlEncodeB64 "${HIHY_CP_echConfig}")"
        fi
        url="${url_base}&sni=${encoded_sni}#Hy2-${encoded_remarks}"
    fi
    if [ "$HIHY_CLIENT_ALLOW_LAN" = true ]; then
        addOrUpdateYaml "$client_configfile" socks5.listen 0.0.0.0:20808 string || return 1
    fi
    [ ! -L "$destination" ] || return 1
    chmod 600 "$client_configfile" && mv -f -- "$client_configfile" "$destination" || return 1
    client_configfile="$destination"
    trap - EXIT
    if [ "${HIHY_CLIENT_QUIET:-false}" = true ]; then
        generateMihomoYaml && generateSingboxJson
        return $?
    fi
    # 在生成配置前添加分隔线
    echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "$(msg client_config_generating)"

    # 美化输出信息
    echo -e "\n$(msg client_config_info_title)"
    local localV
    localV=$(getLocalHysteriaVersion || true)
    echo -e "\n$(msg client_config_server_version "$(echoColor red ${localV})")"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "${realmMode}" != "true" ]; then
        if [ "$HIHY_CP_masqueradeStatus" == "true" ]; then
            if [ "$HIHY_CP_masqueradeTcp" != "true" ]; then
                echo -e "$(msg client_config_masquerade_tcp_not_listened)"
                echo -e "$(msg client_config_masquerade_h3_hint "$(echoColor red "$(msg client_config_masquerade_h3_action)")")"
            fi
        fi

        if [ -n "${pinSHA256}" ]; then
            echo -e "\n$(msg client_config_security_tip_title)"
            echo -e "$(msg client_config_pinsha256_safe_hint "$(echoColor red pinSHA256)")"
            echo -e "   $(msg client_config_fingerprint_label "$(echoColor red ${pinSHA256})")"
            echo -e "   $(msg client_config_masquerade_trust_hint)"
        elif [ "${insecure}" == "true" ]; then
            echo -e "\n$(msg client_config_security_warning_title)"
            echo -e "$(msg client_config_selfsigned_verify_hint)"
            echo -e "   $(msg client_config_selfsigned_verify_step1)"
            echo -e "   $(msg client_config_selfsigned_verify_step2)"
        fi
        if [ "${HIHY_CP_mimicStatus}" == "true" ]; then
            echoColor red "\n$(msg client_config_mimic_warning_title)"
            echoColor yellow "$(msg client_config_mimic_warning1)"
            echoColor yellow "$(msg client_config_mimic_warning2)"
            echoColor yellow "$(msg client_config_mimic_warning3)"
        fi
        # 伪装地址提示只在启用了伪装且监听 TCP 时才有意义
        if [ "$HIHY_CP_masqueradeStatus" == "true" ] && [ "$HIHY_CP_masqueradeTcp" == "true" ]; then
            echoColor purple "\n$(msg client_config_masquerade_address "$(echoColor red https://${tls_sni}:${port})")"
        fi
    fi

    if [ "${realmMode}" == "true" ]; then
        echoColor purple "\n$(msg client_config_realm_mode_desc)"
        echoColor purple "\n$(msg client_config_realm_rendezvous_label)"
        echoColor green "  ${realmURI}"
        echo -e "\n"
        echoColor yellow "$(msg client_config_realm_client_support_warning)"
        echoColor yellow "$(msg client_config_realm_server_password "$(echoColor red ${auth_secret})")"
        echo -e "\n"
        echoColor purple "\n$(msg client_config_realm_share_link_title)"
        echoColor green "${url}"
        echo -e "\n"
        generate_qr "${url}"
        echo -e "\n"
    else
        echoColor purple "\n$(msg client_config_share_link_title)"
        echoColor green "${url}"
        echo -e "\n"
        generate_qr "${url}"
    fi

    if [ "${realmMode}" == "true" ]; then
        echoColor purple "\n$(msg client_config_native_file_realm "$(echoColor green ${client_configfile})")"
    else
        echoColor purple "\n$(msg client_config_native_file_standard "$(echoColor green ${client_configfile})")"
    fi
    echoColor purple "$(msg client_config_tutorial_link)"
    echoColor green "↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓$(msg client_config_copy_marker)↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓"
    cat "${client_configfile}"
    echoColor green "↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑$(msg client_config_copy_marker)↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑"
    # Mimic 仅由原生客户端导出，其余已选择参数按各客户端能力输出。
    if [ "${HIHY_CP_mimicStatus}" == "true" ]; then
        echoColor yellow "$(msg client_mihomo_mimic_skip)"
        echoColor yellow "$(msg client_singbox_mimic_skip)"
    else
        generateMihomoYaml || return 1
        generateSingboxJson || return 1
    fi
    if subscriptionEnabled; then subscriptionRefresh || return 1; fi
    echo -e "\n$(msg client_config_done)"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
)

