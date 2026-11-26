#!/bin/bash
# ---------- 输入校验辅助 ----------
isPositiveInt() { [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]; }

isValidPort() {
    isPositiveInt "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

getUdpPortPid() {
    lsof -i "udp:${1}" 2>/dev/null | grep -v "PID" | awk '{print $2}' | head -n 1
}

isUdpPortFree() {
    [ -z "$(getUdpPortPid "$1")" ]
}

getRandomFreeUdpPort() {
    local candidate tries=0
    while [ "$tries" -lt 20 ]; do
        candidate=$(($(od -An -N2 -i /dev/urandom) % (65534 - 10001) + 10001))
        if isUdpPortFree "$candidate"; then
            echo "$candidate"
            return 0
        fi
        tries=$((tries + 1))
    done
    return 1
}

# ---------- 配置默认值:向导/一键共用的唯一基线,保证 write 阶段引用的变量全部有值 ----------
setConfigDefaults() {
    realmMode="false"
    realmName=""
    realmURI=""
    useAcme=false
    useLocalCert=false
    useDns=false
    dns=""
    domain="www.bing.com"
    ip=""
    local_cert=""
    local_key=""
    cloudflare_api_token=""
    duckdns_api_token=""
    duckdns_override_domain=""
    gandi_api_token=""
    godaddy_api_token=""
    vultr_api_token=""
    port=""
    portHoppingStatus="false"
    portHoppingStart=""
    portHoppingEnd=""
    portHoppingIntervalMode=""
    portHoppingHopInterval=""
    portHoppingMinHopInterval=""
    portHoppingMaxHopInterval=""
    congestion_mode="bbr"
    congestion_type="bbr"
    congestion_bbr_profile="standard"
    ignore_client_bandwidth="true"
    delay=""
    download=""
    upload=""
    auth_secret=""
    obfs_status="false"
    obfs_type=""
    obfs_pass=""
    ech_status="false"
    mimic_status="false"
    ech_public_name=""
    ech_config=""
    brutal_disable_loss_comp="false"
    masquerade_status="false"
    masquerade_type=""
    masquerade_string=""
    masquerade_stuff=""
    masquerade_proxy=""
    masquerade_xforwarded="false"
    masquerade_file=""
    masquerade_tcp="false"
    block_http3="false"
    remarks=""
    pinSHA256=""
    insecure="0"
}

# ---------- 交互式配置收集(原 setHysteriaConfig 前半段,只读输入、只设变量) ----------
collectHysteriaConfig() {
    echoColor yellowBlack "$(msg config_start_title)"
    echoColor green "$(msg realm_prompt_title)"
    echo -e "$(msg realm_intro_line1)"
    echo -e "$(msg realm_intro_line2)"
    echo -e "$(msg realm_intro_line3)"
    echo -e "$(msg realm_intro_line4)"
    echoColor yellow "$(msg realm_warning_core_only)"
    echoColor yellow "$(msg realm_choice_disable_default)"
    echoColor yellow "$(msg realm_choice_enable)"
    echoColor green "$(msg prompt_enter_number)"
    read -r realmChoice
    if [ -z "${realmChoice}" ] || [ "${realmChoice}" == "1" ]; then
        realmMode="false"
    else
        realmMode="true"
        realmName=$(generate_uuid)
        echo -e "\n->$(msg realm_name_label)$(echoColor red "${realmName}")\n"
        echoColor green "$(msg realm_server_prompt)"
        echo -e "$(msg realm_server_official_hint)"
        echoColor yellow "$(msg realm_server_choice_official)"
        echoColor yellow "$(msg realm_server_choice_custom)"
        echoColor green "$(msg prompt_enter_number)"
        read -r realmServerChoice
        if [ -z "${realmServerChoice}" ] || [ "${realmServerChoice}" == "1" ]; then
            realmAddress="realm.hy2.io"
            realmPassword="public"
        else
            echoColor green "$(msg realm_address_prompt)"
            read -r realmAddressInput
            while [ -z "${realmAddressInput}" ]; do
                echoColor red "$(msg realm_address_empty)"
                read -r realmAddressInput
            done
            realmAddress="${realmAddressInput}"
            echoColor green "$(msg realm_password_prompt)"
            read -r realmPasswordInput
            if [ -z "${realmPasswordInput}" ]; then
                realmPassword="public"
            else
                realmPassword="${realmPasswordInput}"
            fi
        fi
        realmURI="realm://$(urlEncode "$realmPassword")@${realmAddress}/$(urlEncode "$realmName")"
        echo -e "\n->$(msg realm_uri_label)$(echoColor red "${realmURI}")\n"
        if command -v warp >/dev/null 2>&1 && [ -f "/etc/wireguard/warp.conf" ]; then
            echoColor purple "$(msg warp_installed_hint)"
        fi
        echoColor green "$(msg warp_install_prompt)"
        echoColor white "$(msg warp_principle_line1)"
        echoColor white "$(msg warp_principle_line2)"
        echoColor white "$(msg warp_principle_line3)"
        echoColor white "$(msg warp_principle_line4)"
        echoColor yellow "$(msg warp_choice_skip)"
        echoColor yellow "$(msg warp_choice_install)"
        echoColor green "$(msg prompt_enter_number)"
        read -r warpChoice
        if [ "${warpChoice}" == "2" ]; then
            echoColor purple "$(msg warp_installing)"
            echoColor purple "$(msg warp_select_global_mode)"
            installWarpVerified d || return 1
            if [ -f "/etc/wireguard/warp.conf" ]; then
                current_mtu=$(grep -oP '^MTU = \K\d+' /etc/wireguard/warp.conf)
                if [ -n "${current_mtu}" ] && [ "${current_mtu}" -lt 1320 ]; then
                    sed -i "s/^MTU = ${current_mtu}/MTU = 1320/g" /etc/wireguard/warp.conf
                    echoColor purple "\n->$(msg warp_mtu_adjusted ${current_mtu})"
                elif [ -n "${current_mtu}" ]; then
                    echoColor purple "\n->$(msg warp_mtu_no_adjust ${current_mtu})"
                fi
                echoColor purple "$(msg warp_enabling)"
                warp o
                sleep 3
                echoColor purple "$(msg warp_reenabling)"
                warp o
                echoColor purple "$(msg warp_install_done)"
            else
                echoColor red "$(msg warp_install_fail)"
                echoColor red "$(msg warp_manual_cmd)"
                echoColor red "$(msg warp_install_fail_exit)"
                exit 1
            fi
        else
            echoColor purple "$(msg warp_skip)"
        fi
    fi
    echoColor green "$(msg cert_prompt_title)"
    echoColor yellow "$(msg cert_choice_acme)"
    echoColor yellow "$(msg cert_choice_local)"
    echoColor yellow "$(msg cert_choice_selfsigned)"
    echoColor yellow "$(msg cert_choice_dns)"
    echoColor green "$(msg prompt_enter_number_or_default)"
    read -r certNum
    useAcme=false
    useLocalCert=false

    if [ -z "${certNum}" ] || [ "${certNum}" == "3" ]; then
        echoColor green "$(msg selfsigned_domain_prompt)"
        read -r domain
        if [ -z "${domain}" ]; then
            domain="helloworld.com"
        fi
        echo -e "->$(msg selfsigned_domain_label)$(echoColor red "${domain}")\n"
        if [ "${realmMode}" == "true" ]; then
            ip=""
            echo -e "\n->$(msg realm_uri_label_with_cert)$(echoColor red "${realmURI}")\n"
        else
            ip=$(detectPublicIP || true)
            echoColor green "$(msg public_ip_check)$(echoColor red "${ip}")\n"
            while true; do
                echoColor green "$(msg prompt_choose)"
                echoColor yellow "$(msg ip_correct_default)"
                echoColor yellow "$(msg ip_incorrect)"
                echoColor green "$(msg prompt_enter_number)"
                read -r ipNum
                if [ -z "${ipNum}" ] || [ "${ipNum}" == "1" ]; then
                    break
                elif [ "${ipNum}" == "2" ]; then
                    echoColor green "$(msg ip_prompt)"
                    read -r ip
                    if [ -z "${ip}" ]; then
                        echoColor red "$(msg input_error_retry)"
                        continue
                    fi
                    break
                else
                    echoColor red "$(msg input_error_please_retry)"
                fi
            done
        fi
        useAcme=false
        if [ "${realmMode}" == "true" ]; then
            echoColor purple "\n\n->$(msg selfsigned_cert_summary_realm ${domain})$(echoColor red "${realmURI}")\n"
        else
            echoColor purple "\n\n->$(msg selfsigned_cert_summary_ip ${domain})$(echoColor red "${ip}")\n"
        fi
        echo -e "\n"

    elif [ "${certNum}" == "2" ]; then
        echoColor green "$(msg local_cert_path_prompt)"
        read -r local_cert
        while :; do
            if [ ! -f "${local_cert}" ]; then
                echoColor red "\n\n->$(msg path_not_exist)"
                echoColor green "$(msg local_cert_path_prompt)"
                read -r local_cert
            else
                break
            fi
        done
        echo -e "\n\n->$(msg local_cert_label)$(echoColor red "${local_cert}")\n"
        echoColor green "$(msg local_key_path_prompt)"
        read -r local_key
        while :; do
            if [ ! -f "${local_key}" ]; then
                echoColor red "\n\n->$(msg path_not_exist)"
                echoColor green "$(msg local_key_path_prompt)"
                read -r local_key
            else
                break
            fi
        done
        echo -e "\n\n->$(msg local_key_label)$(echoColor red "${local_key}")\n"
        echoColor green "$(msg local_cert_domain_prompt)"
        read -r domain
        while :; do
            if [ -z "${domain}" ]; then
                echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                echoColor green "$(msg local_cert_domain_prompt)"
                read -r domain
            else
                break
            fi
        done
        useAcme=false
        useLocalCert=true
        echoColor purple "\n\n->$(msg local_cert_summary)$(echoColor red "${domain}")\n"
    elif [ "${certNum}" == "4" ]; then
        echoColor green "$(msg domain_prompt) $(msg domain_requirement)"
        read -r domain
        while :; do
            if [ -z "${domain}" ]; then
                echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                echoColor green "$(msg domain_prompt) $(msg domain_requirement)"
                read -r domain
            else
                break
            fi
        done
        echo -e "\n\n->$(msg domain_label)$(echoColor red "${domain}")\n"
        echoColor green "$(msg dns_provider_prompt)"
        echoColor yellow "$(msg dns_choice_cloudflare)"
        echoColor yellow "$(msg dns_choice_duckdns)"
        echoColor yellow "$(msg dns_choice_gandi)"
        echoColor yellow "$(msg dns_choice_godaddy)"
        echoColor yellow "$(msg dns_choice_vultr)"
        echoColor green "$(msg prompt_enter_number)"
        read -r dnsNum
        if [ -z "${dnsNum}" ] || [ "${dnsNum}" == "1" ]; then
            dns="cloudflare"
            echo -e "\n\n->$(msg dns_selected_cloudflare)\n"
            echoColor green "$(msg cloudflare_token_prompt)"
            while :; do
                read -r cloudflare_api_token
                if [ -z "${cloudflare_api_token}" ]; then
                    echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                    echoColor green "$(msg cloudflare_token_prompt)"
                else
                    break
                fi
            done
        elif [ "${dnsNum}" == "2" ]; then
            dns="duckdns"
            echo -e "\n\n->$(msg dns_selected_duckdns)\n"
            echoColor green "$(msg duckdns_token_prompt)"
            while :; do
                read -r duckdns_api_token
                if [ -z "${duckdns_api_token}" ]; then
                    echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                    echoColor green "$(msg duckdns_token_prompt)"
                else
                    break
                fi
            done
            echoColor green "$(msg duckdns_override_prompt)"
            while :; do
                read -r duckdns_override_domain
                if [ -z "${duckdns_override_domain}" ]; then
                    echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                    echoColor green "$(msg duckdns_override_prompt)"
                else
                    break
                fi
            done
        elif [ "${dnsNum}" == "3" ]; then
            dns="gandi"
            echo -e "\n\n->$(msg dns_selected_gandi)\n"
            echoColor green "$(msg gandi_token_prompt)"
            while :; do
                read -r gandi_api_token
                if [ -z "${gandi_api_token}" ]; then
                    echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                    echoColor green "$(msg gandi_token_prompt)"
                else
                    break
                fi
            done
        elif [ "${dnsNum}" == "4" ]; then
            dns="godaddy"
            echo -e "\n\n->$(msg dns_selected_godaddy)\n"
            echoColor green "$(msg godaddy_token_prompt)"
            while :; do
                read -r godaddy_api_token
                if [ -z "${godaddy_api_token}" ]; then
                    echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                    echoColor green "$(msg godaddy_token_prompt)"
                else
                    break
                fi
            done
        elif [ "${dnsNum}" == "5" ]; then
            dns="vultr"
            echo -e "\n\n->$(msg dns_selected_vultr)\n"
            echoColor green "$(msg vultr_token_prompt)"
            while :; do
                read -r vultr_api_token
                if [ -z "${vultr_api_token}" ]; then
                    echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                    echoColor green "$(msg vultr_token_prompt)"
                else
                    break
                fi
            done
        else
            echoColor red "$(msg input_error_please_retry)"
        fi
        ip=$(detectPublicIP || true)
        echoColor green "$(msg public_ip_check)$(echoColor red "${ip}")\n"
        while true; do
            echoColor green "$(msg prompt_choose)"
            echoColor yellow "$(msg ip_correct_default)"
            echoColor yellow "$(msg ip_incorrect)"
            echoColor green "$(msg prompt_enter_number)"
            read -r ipNum
            if [ -z "${ipNum}" ] || [ "${ipNum}" == "1" ]; then
                break
            elif [ "${ipNum}" == "2" ]; then
                echoColor green "$(msg ip_prompt)"
                read -r ip
                if [ -z "${ip}" ]; then
                    echoColor red "$(msg input_error_retry)"
                    continue
                fi
                break
            else
                echoColor red "$(msg input_error_please_retry)"
            fi
        done
        echo -e "\n\n->$(msg dns_acme_summary)$(echoColor red "${domain}")\n"
        echo -e "\n ->$(msg dns_method_label)$(echoColor red "${dns}")\n"
        echo -e "\n ->$(msg public_ip_label)$(echoColor red "${ip}")\n"
        useAcme=true
        useDns=true
    else
        echoColor green "$(msg domain_prompt) $(msg domain_requirement)"
        read -r domain
        while :; do
            if [ -z "${domain}" ]; then
                echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                echoColor green "$(msg domain_prompt) $(msg domain_requirement)"
                read -r domain
            else
                break
            fi
        done
        while :; do
            echoColor purple "\n->$(msg detecting_domain_dns ${domain})"
            ip_resolv=$(dig +short ${domain} A)
            if [ -z "${ip_resolv}" ]; then
                ip_resolv=$(dig +short ${domain} AAAA)
            fi
            if [ -z "${ip_resolv}" ]; then
                echoColor red "\n\n->$(msg dns_resolution_failed)"
                echoColor green "$(msg domain_prompt) $(msg domain_requirement)"
                read -r domain
                continue
            fi
            remoteip=$(echo ${ip_resolv} | awk -F " " '{print $1}')
            v6str=":"
            result=$(echo ${remoteip} | grep ${v6str})
            if [ "${result}" != "" ]; then
                localip=$(getPublicIP -6 || true)
            else
                localip=$(getPublicIP -4 || true)
            fi
            if [ -z "${localip}" ]; then
                localip=$(getPublicIP "" || true)
                if [ -z "${localip}" ]; then
                    echoColor red "\n\n->$(msg local_ip_fetch_failed)"
                    exit 1
                fi
            fi
            if [ "${localip}" != "${remoteip}" ]; then
                echo -e " \n\n->$(msg local_ip_label)$(echoColor red "${localip}") \n\n->$(msg domain_ip_label)$(echoColor red "${remoteip}")\n"
                echoColor green "$(msg self_assign_ip_prompt)"
                read -r isLocalip
                if [ "${isLocalip}" == "y" ]; then
                    echoColor green "$(msg enter_local_ip)"
                    read -r localip
                    while :; do
                        if [ -z "${localip}" ]; then
                            echoColor red "\n\n->$(msg this_option_cannot_be_empty)"
                            echoColor green "$(msg enter_local_ip)"
                            read -r localip
                        else
                            break
                        fi
                    done
                fi
                if [ "${localip}" != "${remoteip}" ]; then
                    echoColor red "\n\n->$(msg domain_ip_mismatch)"
                    echoColor green "$(msg domain_prompt) $(msg domain_requirement)"
                    read -r domain
                    continue
                else
                    break
                fi
            else
                break
            fi
        done
        useAcme=true
        useDns=false
        echoColor purple "\n\n->$(msg acme_summary)$(echoColor red "${domain}")\n"
    fi

    if [ "${1:-}" = install ]; then
        if ! subscriptionCollectInstallChoice "$useAcme" "$useLocalCert" "$domain"; then
            printf '%s\n' "$(msg sub_install_skipped)" >&2
        fi
    fi

    if [ "${realmMode}" == "true" ]; then
        port=""
        echoColor purple "\n->$(msg realm_skip_port)\n"
    else
        while :; do
            echoColor green "\n$(msg port_prompt)"
            echo "$(msg port_hint)"
            read -r port
            if [ -z "${port}" ]; then
                port=$(getRandomFreeUdpPort)
                if [ -z "${port}" ]; then
                    echoColor red "$(msg auto_port_busy)"
                    continue
                fi
                echo -e "\n->$(msg random_port_label)$(echoColor red "udp/${port}")\n"
                break
            fi
            if ! isValidPort "${port}"; then
                echoColor red "$(msg port_invalid_error)"
                continue
            fi
            echo -e "\n->$(msg entered_port_label)$(echoColor red "udp/${port}")\n"
            pIDa=$(getUdpPortPid "${port}")
            if [ "$pIDa" != "" ]; then
                echoColor red "\n->$(msg port_in_use ${port} ${pIDa} ${pIDa})"
            else
                break
            fi
        done
    fi

    if [ "${realmMode}" != "true" ]; then
        # Mimic(hysteria v2.12.0+):eBPF 把 UDP 伪装成 TCP。两端都要 Linux+root+mimic,且不能与端口跳跃同开。
        echoColor green "\n$(msg mimic_prompt)"
        echoColor white "$(msg mimic_hint1)"
        echoColor white "$(msg mimic_hint2)"
        echoColor white "$(msg mimic_hint3)"
        echoColor yellow "$(msg mimic_choice_disable_default)"
        echoColor yellow "$(msg mimic_choice_enable)"
        echoColor green "$(msg prompt_enter_number_or_default)"
        read -r mimic_num
        if [ "${mimic_num}" == "2" ]; then
            mimic_status="true"
            portHoppingStatus="false"
            portHoppingIntervalMode=""
            portHoppingHopInterval=""
            portHoppingMinHopInterval=""
            portHoppingMaxHopInterval=""
            portHoppingStart=""
            portHoppingEnd=""
            echo -e "\n->$(msg mimic_enabled_label)\n"
            echoColor purple "$(msg mimic_skip_port_hopping)"
        else
            mimic_status="false"
            echo -e "\n->$(msg mimic_disabled_label)\n"
            echoColor green "\n$(msg port_hopping_prompt)"
            echoColor white "$(msg port_hopping_intro)"
            echoColor white "$(msg port_hopping_detail_url)"
            echoColor green "$(msg prompt_choose)"
            echoColor yellow "$(msg port_hopping_choice_enable)"
            echoColor yellow "$(msg port_hopping_choice_skip)"
            echoColor green "$(msg prompt_enter_number)"
            read -r portHoppingStatus
            if [ -z "${portHoppingStatus}" ] || [ "${portHoppingStatus}" == "1" ]; then
                portHoppingStatus="true"
                echoColor purple "$(msg port_hopping_enabled)"
                echoColor white "$(msg port_hopping_range_hint)"
                while :; do
                    echoColor green "$(msg port_hopping_start)"
                    read -r portHoppingStart
                    if [ -z "${portHoppingStart}" ]; then
                        portHoppingStart=47000
                    fi
                    if ! isValidPort "${portHoppingStart}"; then
                        echoColor red "$(msg port_invalid_error)"
                        continue
                    fi
                    echo -e "\n->$(msg start_port_label)$(echoColor red "${portHoppingStart}")\n"
                    echoColor green "$(msg port_hopping_end)"
                    read -r portHoppingEnd
                    if [ -z "${portHoppingEnd}" ]; then
                        portHoppingEnd=48000
                    fi
                    if ! isValidPort "${portHoppingEnd}"; then
                        echoColor red "$(msg port_invalid_error)"
                        continue
                    fi
                    echo -e "\n->$(msg end_port_label)$(echoColor red "${portHoppingEnd}")\n"
                    if [ ${portHoppingStart} -ge ${portHoppingEnd} ]; then
                        echoColor red "$(msg start_port_greater_error)"
                    else
                        break
                    fi
                done
                echoColor green "$(msg port_hopping_mode_prompt)"
                echoColor yellow "$(msg port_hopping_mode_fixed)"
                echoColor yellow "$(msg port_hopping_mode_random)"
                echoColor green "$(msg prompt_enter_number)"
                read -r portHoppingIntervalModeNum
                if [ -z "${portHoppingIntervalModeNum}" ] || [ "${portHoppingIntervalModeNum}" == "1" ]; then
                    portHoppingIntervalMode="fixed"
                    while :; do
                        echoColor green "$(msg fixed_hop_interval_prompt)"
                        read -r portHoppingHopInterval
                        if [ -z "${portHoppingHopInterval}" ]; then
                            portHoppingHopInterval="30s"
                        fi
                        echo -e "\n->$(msg fixed_hop_interval_label)$(echoColor red "${portHoppingHopInterval}")\n"
                        hopSeconds=$(echo "${portHoppingHopInterval}" | sed 's/s$//')
                        if ! isPositiveInt "${hopSeconds}" || [ "${hopSeconds}" -lt 5 ]; then
                            echoColor red "$(msg fixed_hop_interval_error)"
                            continue
                        fi
                        portHoppingHopInterval="${hopSeconds}s"
                        break
                    done
                    portHoppingMinHopInterval=""
                    portHoppingMaxHopInterval=""
                else
                    portHoppingIntervalMode="random"
                    portHoppingHopInterval=""
                    while :; do
                        echoColor green "$(msg min_hop_interval_prompt)"
                        read -r portHoppingMinHopInterval
                        if [ -z "${portHoppingMinHopInterval}" ]; then
                            portHoppingMinHopInterval="10s"
                        fi
                        echo -e "\n->$(msg min_hop_interval_label)$(echoColor red "${portHoppingMinHopInterval}")\n"
                        minHopSeconds=$(echo "${portHoppingMinHopInterval}" | sed 's/s$//')
                        if ! isPositiveInt "${minHopSeconds}" || [ "${minHopSeconds}" -lt 5 ]; then
                            echoColor red "$(msg min_hop_interval_error)"
                            continue
                        fi
                        portHoppingMinHopInterval="${minHopSeconds}s"
                        echoColor green "$(msg max_hop_interval_prompt)"
                        read -r portHoppingMaxHopInterval
                        if [ -z "${portHoppingMaxHopInterval}" ]; then
                            portHoppingMaxHopInterval="30s"
                        fi
                        echo -e "\n->$(msg max_hop_interval_label)$(echoColor red "${portHoppingMaxHopInterval}")\n"
                        maxHopSeconds=$(echo "${portHoppingMaxHopInterval}" | sed 's/s$//')
                        if ! isPositiveInt "${maxHopSeconds}" || [ "${maxHopSeconds}" -lt "${minHopSeconds}" ]; then
                            echoColor red "$(msg max_hop_interval_error)"
                            continue
                        fi
                        portHoppingMaxHopInterval="${maxHopSeconds}s"
                        break
                    done
                fi
                echo -e "\n->$(msg port_hopping_range_label)$(echoColor red "${portHoppingStart}-${portHoppingEnd}")\n"
                if [ "${portHoppingIntervalMode}" == "fixed" ]; then
                    echo -e "\n->$(msg fixed_hop_interval_summary)$(echoColor red "${portHoppingHopInterval}")\n"
                else
                    echo -e "\n->$(msg random_hop_interval_summary)$(echoColor red "${portHoppingMinHopInterval}~${portHoppingMaxHopInterval}")\n"
                fi
            else
                portHoppingStatus="false"
                portHoppingIntervalMode=""
                portHoppingHopInterval=""
                portHoppingMinHopInterval=""
                portHoppingMaxHopInterval=""
                echoColor red "$(msg port_hopping_disabled)"
            fi
        fi
    else
        mimic_status="false"
        portHoppingStatus="false"
        echoColor purple "\n->$(msg realm_skip_port_hopping)\n"
    fi

    echoColor green "$(msg congestion_title)"
    echoColor white "$(msg congestion_reno_hint)"
    echoColor white "$(msg congestion_bbr_hint)"
    echoColor white "$(msg congestion_brutal_hint)"
    echoColor green "$(msg prompt_choose)"
    echoColor yellow "$(msg congestion_choice_reno)"
    echoColor yellow "$(msg congestion_choice_bbr)"
    echoColor yellow "$(msg congestion_choice_brutal)"
    echoColor green "$(msg prompt_enter_number)"
    read -r congestion_num
    if [ "${congestion_num}" == "1" ]; then
        congestion_mode="reno"
        congestion_type="reno"
        congestion_bbr_profile=""
        ignore_client_bandwidth="true"
        echo -e "\n->$(msg congestion_selected_reno)\n"
    elif [ "${congestion_num}" == "2" ]; then
        congestion_mode="bbr"
        congestion_type="bbr"
        ignore_client_bandwidth="true"
        echoColor green "$(msg bbr_profile_title)"
        echoColor white "$(msg bbr_profile_conservative)"
        echoColor white "$(msg bbr_profile_standard)"
        echoColor white "$(msg bbr_profile_aggressive)"
        echoColor green "$(msg bbr_profile_prompt)"
        echoColor yellow "$(msg bbr_choice_conservative)"
        echoColor yellow "$(msg bbr_choice_standard)"
        echoColor yellow "$(msg bbr_choice_aggressive)"
        echoColor green "$(msg prompt_enter_number)"
        read -r bbr_profile_num
        case ${bbr_profile_num} in
            2) congestion_bbr_profile="conservative" ;;
            3) congestion_bbr_profile="aggressive" ;;
            *) congestion_bbr_profile="standard" ;;
        esac
        echo -e "\n->$(msg congestion_selected_bbr)$(echoColor red "${congestion_bbr_profile}")\n"
    else
        congestion_mode="brutal"
        congestion_type=""
        congestion_bbr_profile=""
        ignore_client_bandwidth="false"
        echo -e "\n->$(msg congestion_selected_brutal)\n"
    fi

    if [ "${congestion_mode}" == "brutal" ]; then
        while :; do
            echoColor green "$(msg delay_prompt)"
            read -r delay
            if [ -z "${delay}" ]; then
                delay=200
            fi
            if ! isPositiveInt "${delay}" || [ "${delay}" -eq 0 ]; then
                echoColor red "$(msg bandwidth_invalid_error)"
                continue
            fi
            break
        done
        echo -e "\n->$(msg delay_label)$(echoColor red "${delay}")ms\n"
        echo -e "\n$(msg bandwidth_expectation)$(echoColor red "Tips:")"
        while :; do
            echoColor green "$(msg download_prompt)"
            read -r download
            if [ -z "${download}" ]; then
                download=50
            fi
            if ! isPositiveInt "${download}" || [ "${download}" -eq 0 ]; then
                echoColor red "$(msg bandwidth_invalid_error)"
                continue
            fi
            break
        done
        echo -e "\n->$(msg download_label)$(echoColor red "${download}")mbps\n"
        while :; do
            echoColor green "$(msg upload_prompt)"
            read -r upload
            if [ -z "${upload}" ]; then
                upload=10
            fi
            if ! isPositiveInt "${upload}" || [ "${upload}" -eq 0 ]; then
                echoColor red "$(msg bandwidth_invalid_error)"
                continue
            fi
            break
        done
        echo -e "\n->$(msg upload_label)$(echoColor red "${upload}")mbps\n"
        # Brutal 速率补偿开关(hysteria v2.10.0+):默认保持开启
        echoColor green "$(msg losscomp_prompt)"
        echoColor white "$(msg losscomp_hint)"
        echoColor yellow "$(msg losscomp_choice_keep_default)"
        echoColor yellow "$(msg losscomp_choice_disable)"
        echoColor green "$(msg prompt_enter_number)"
        read -r losscomp_num
        if [ "${losscomp_num}" == "2" ]; then
            brutal_disable_loss_comp="true"
            echo -e "\n->$(msg losscomp_disabled_label)\n"
        else
            brutal_disable_loss_comp="false"
            echo -e "\n->$(msg losscomp_kept_label)\n"
        fi
    else
        delay=""
        download=""
        upload=""
        echoColor lightYellow "$(msg non_brutal_skip)"
    fi
    echoColor green "$(msg auth_secret_prompt)"
    read -r auth_secret
    if [ -z "${auth_secret}" ]; then
        auth_secret=$(generate_uuid)
    fi
    echo -e "\n->$(msg auth_secret_label)$(echoColor red "${auth_secret}")\n"
    echoColor white "$(msg obfs_hint)"
    echoColor green "$(msg obfs_prompt)"
    echoColor yellow "$(msg obfs_choice_disable)"
    echoColor yellow "$(msg obfs_choice_salamander)"
    echoColor yellow "$(msg obfs_choice_gecko)"
    echoColor green "$(msg prompt_enter_number)"
    read -r obfs_num
    if [ -z "${obfs_num}" ] || [ "${obfs_num}" == "1" ]; then
        obfs_status="false"
        obfs_type=""
    elif [ "${obfs_num}" == "2" ]; then
        obfs_status="true"
        obfs_type="salamander"
        obfs_pass=${auth_secret}
    else
        obfs_status="true"
        obfs_type="gecko"
        obfs_pass=${auth_secret}
    fi
    if [ "${obfs_status}" == "true" ]; then
        echo -e "\n->$(msg obfs_enabled ${obfs_type})\n"
    else
        echo -e "\n->$(msg obfs_disabled)\n"
    fi
    if [ "${realmMode}" != "true" ]; then
        # ECH(hysteria v2.10.0+):加密 ClientHello 中的 SNI,中间设备只能看到幌子域名
        echoColor green "$(msg ech_prompt)"
        echoColor white "$(msg ech_hint1)"
        echoColor white "$(msg ech_hint2)"
        echoColor yellow "$(msg ech_choice_disable_default)"
        echoColor yellow "$(msg ech_choice_enable)"
        echoColor green "$(msg prompt_enter_number_or_default)"
        read -r ech_num
        if [ "${ech_num}" == "2" ]; then
            ech_status="true"
            echoColor green "$(msg ech_public_name_prompt)"
            read -r ech_public_name
            if [ -z "${ech_public_name}" ]; then
                ech_public_name="www.microsoft.com"
            fi
            echo -e "\n->$(msg ech_public_name_label)$(echoColor red "${ech_public_name}")\n"
        else
            ech_status="false"
            echo -e "\n->$(msg ech_disabled_label)\n"
        fi
        echoColor green "$(msg masquerade_prompt)"
        echoColor yellow "$(msg masquerade_choice_disable)"
        echoColor yellow "$(msg masquerade_choice_string)"
        echoColor yellow "$(msg masquerade_choice_proxy)"
        echoColor yellow "$(msg masquerade_choice_file)"
        echoColor green "$(msg prompt_enter_number_or_default)"
        read -r masquerade_choice
        case "${masquerade_choice}" in
            2)
                masquerade_status="true"
                masquerade_type="string"
                echoColor green "$(msg masquerade_string_prompt)"
                read -r masquerade_string
                if [ -z "${masquerade_string}" ]; then
                    masquerade_string="HelloWorld"
                fi
                echo -e "\n->$(msg masquerade_string_label)$(echoColor red "${masquerade_string}")\n"
                echoColor green "$(msg masquerade_stuff_prompt)"
                read -r masquerade_stuff
                if [ -z "${masquerade_stuff}" ]; then
                    masquerade_stuff="HelloWorld"
                fi
                echo -e "\n->$(msg masquerade_stuff_label)$(echoColor red "${masquerade_stuff}")\n"
                ;;
            3)
                masquerade_status="true"
                masquerade_type="proxy"
                echoColor green "$(msg masquerade_proxy_prompt)"
                echoColor white "$(msg masquerade_proxy_hint)"
                read -r masquerade_proxy
                if [ -z "${masquerade_proxy}" ]; then
                    masquerade_proxy="https://www.helloworld.org"
                fi
                echo -e "\n->$(msg masquerade_proxy_label)$(echoColor red "${masquerade_proxy}")\n"
                echoColor green "$(msg xforwarded_prompt)"
                echoColor yellow "$(msg xforwarded_choice_enable)"
                echoColor yellow "$(msg xforwarded_choice_disable)"
                echoColor green "$(msg prompt_enter_number)"
                read -r masquerade_xforwarded
                if [ -z "${masquerade_xforwarded}" ] || [ "${masquerade_xforwarded}" == "1" ]; then
                    masquerade_xforwarded="true"
                else
                    masquerade_xforwarded="false"
                fi
                echo -e "\n->$(msg xforwarded_label)$(echoColor red "${masquerade_xforwarded}")\n"
                ;;
            4)
                masquerade_status="true"
                masquerade_type="file"
                echoColor green "$(msg masquerade_file_prompt)"
                echoColor white "$(msg masquerade_file_hint)"
                read -r masquerade_file
                if [ -z "${masquerade_file}" ]; then
                    masquerade_file="/etc/hihy/file"
                fi
                echo -e "\n->$(msg masquerade_file_label)$(echoColor red "${masquerade_file}")\n"
                ;;
            *)
                masquerade_status="false"
                masquerade_type=""
                echo -e "\n->$(msg masquerade_disabled_selected)\n"
                ;;
        esac
        if [ "${masquerade_type}" != "proxy" ]; then
            masquerade_xforwarded="false"
        fi
        if [ "${masquerade_status}" == "true" ]; then
            echoColor green "$(msg masquerade_tcp_prompt ${port})"
            echoColor lightYellow "$(msg masquerade_tcp_hint1)"
            echoColor white "$(msg masquerade_tcp_hint2)"
            echoColor green "$(msg prompt_choose)"
            echoColor yellow "$(msg masquerade_tcp_choice_enable)"
            echoColor yellow "$(msg masquerade_tcp_choice_skip)"
            echoColor green "$(msg prompt_enter_number)"
            read -r masquerade_tcp
            if [ -z "${masquerade_tcp}" ] || [ "${masquerade_tcp}" == "1" ]; then
                masquerade_tcp="true"
                echo -e "\n->$(msg masquerade_tcp_enabled ${port})\n"
            else
                masquerade_tcp="false"
                echo -e "\n->$(msg masquerade_tcp_disabled ${port})\n"
            fi
        else
            masquerade_tcp="false"
        fi
    fi
    echoColor green "$(msg block_http3_prompt)"
    echoColor lightYellow "$(msg block_http3_hint1)"
    echoColor white "$(msg block_http3_hint2)"
    echoColor green "$(msg prompt_choose)"
    echoColor yellow "$(msg block_http3_choice_enable)"
    echoColor yellow "$(msg block_http3_choice_skip)"
    echoColor green "$(msg prompt_enter_number)"
    read -r block_http3
    if [ -z "${block_http3}" ] || [ "${block_http3}" == "2" ]; then
        block_http3="false"
        echo -e "\n->$(msg block_http3_disabled)\n"
        echoColor lightYellow "$(msg client_only_block_http3_tip)"
    else
        block_http3="true"
        echoColor red "$(msg block_http3_enabled)"
    fi
    echoColor green "$(msg remarks_prompt)"
    read -r remarks
    echoColor green "$(msg config_input_done)"
}

# ---------- 一键模式:环境变量覆盖默认值 ----------
applyAutoOverrides() {
    if [ -n "${HIHY_AUTO_PORT:-}" ]; then
        if ! isValidPort "${HIHY_AUTO_PORT}"; then
            echoColor red "$(msg auto_port_invalid "${HIHY_AUTO_PORT}")"
            return 1
        fi
        port="${HIHY_AUTO_PORT}"
    fi
    [ -n "${HIHY_AUTO_PASSWORD:-}" ] && auth_secret="${HIHY_AUTO_PASSWORD}"
    [ -n "${HIHY_AUTO_DOMAIN:-}" ] && domain="${HIHY_AUTO_DOMAIN}"
    [ -n "${HIHY_AUTO_IP:-}" ] && ip="${HIHY_AUTO_IP}"
    [ -n "${HIHY_AUTO_REMARKS:-}" ] && remarks="${HIHY_AUTO_REMARKS}"
    if [ -n "${HIHY_AUTO_MASQUERADE:-}" ]; then
        masquerade_status="true"
        masquerade_type="proxy"
        masquerade_proxy="${HIHY_AUTO_MASQUERADE}"
        masquerade_xforwarded="true"
    fi
    if [ "${HIHY_AUTO_ECH:-}" = "true" ] || [ "${HIHY_AUTO_ECH:-}" = "1" ]; then
        ech_status="true"
        ech_public_name="${HIHY_AUTO_ECH_PUBLIC_NAME:-www.microsoft.com}"
    fi
    if [ "${HIHY_AUTO_MIMIC:-}" = "true" ] || [ "${HIHY_AUTO_MIMIC:-}" = "1" ]; then
        mimic_status="true"
        # mimic 与端口跳跃互斥;一键开 mimic 时强制关 hopping
        portHoppingStatus="false"
        portHoppingStart=""
        portHoppingEnd=""
        portHoppingIntervalMode=""
        portHoppingHopInterval=""
        portHoppingMinHopInterval=""
        portHoppingMaxHopInterval=""
    fi
    if [ "${mimic_status}" != "true" ]; then
        if [ "${HIHY_AUTO_PORT_HOPPING:-}" = "true" ] || [ "${HIHY_AUTO_PORT_HOPPING:-}" = "1" ]; then
            portHoppingStatus="true"
            portHoppingStart="${HIHY_AUTO_HOP_START:-47000}"
            portHoppingEnd="${HIHY_AUTO_HOP_END:-48000}"
            portHoppingIntervalMode="fixed"
            portHoppingHopInterval="30s"
            if ! isValidPort "${portHoppingStart}" || ! isValidPort "${portHoppingEnd}" \
                || [ "${portHoppingStart}" -ge "${portHoppingEnd}" ]; then
                echoColor red "$(msg auto_hop_invalid "${portHoppingStart}" "${portHoppingEnd}")"
                return 1
            fi
        fi
    fi
    return 0
}

# ---------- 一键模式:零交互收集(默认值 + 环境变量 + 自动探测) ----------
autoHysteriaConfig() {
    setConfigDefaults
    echoColor yellowBlack "$(msg auto_install_title)"
    echoColor gray "$(msg auto_env_hint)"
    if ! applyAutoOverrides; then
        exit 1
    fi

    if [ -z "${ip}" ]; then
        ip=$(detectPublicIP || true)
        if [ -z "${ip}" ]; then
            echoColor red "$(msg auto_ip_detect_failed)"
            exit 1
        fi
    fi

    if [ -z "${port}" ]; then
        port=$(getRandomFreeUdpPort)
        if [ -z "${port}" ]; then
            echoColor red "$(msg auto_port_busy "random")"
            exit 1
        fi
    elif ! isUdpPortFree "${port}"; then
        echoColor red "$(msg auto_port_busy "${port}")"
        exit 1
    fi

    [ -z "${auth_secret}" ] && auth_secret=$(generate_uuid)
    [ -z "${remarks}" ] && remarks="auto-${port}"

    echo -e ""
    echoColor purple "$(msg auto_summary_title)"
    echo -e "  $(msg auto_summary_port "$(echoColor red "udp/${port}")")"
    echo -e "  $(msg auto_summary_password "$(echoColor red "${auth_secret}")")"
    echo -e "  $(msg auto_summary_sni "$(echoColor red "${domain}")")"
    echo -e "  $(msg auto_summary_cert)"
    echo -e "  $(msg auto_summary_congestion)"
    if [ "${masquerade_status}" == "true" ]; then
        echo -e "  $(msg auto_summary_masquerade_on "$(echoColor red "${masquerade_proxy}")")"
    else
        echo -e "  $(msg auto_summary_masquerade_off)"
    fi
    if [ "${mimic_status}" == "true" ]; then
        echo -e "  $(msg auto_summary_mimic_on)"
        echo -e "  $(msg auto_summary_hopping_off)"
    elif [ "${portHoppingStatus}" == "true" ]; then
        echo -e "  $(msg auto_summary_mimic_off)"
        echo -e "  $(msg auto_summary_hopping_on "$(echoColor red "${portHoppingStart}-${portHoppingEnd}")")"
    else
        echo -e "  $(msg auto_summary_mimic_off)"
        echo -e "  $(msg auto_summary_hopping_off)"
    fi
    if [ "${ech_status}" == "true" ]; then
        echo -e "  $(msg auto_summary_ech_on "$(echoColor red "${ech_public_name}")")"
    else
        echo -e "  $(msg auto_summary_ech_off)"
    fi
    echo -e ""

    writeHysteriaConfig
}

# ---------- 配置校验:轮询 debug 文件,返回 0=成功 1=超时 2=ACME失败 3=端口占用 ----------
# ---------- 配置写入 + 校验 + 收尾(原 setHysteriaConfig 后半段,向导/一键共用) ----------
generateStagedConfig() {
    mkdir -p ${HIHY_CONFIG_ROOT}/bin ${HIHY_CONFIG_ROOT}/conf ${HIHY_CONFIG_ROOT}/cert ${HIHY_CONFIG_ROOT}/result ${HIHY_CONFIG_ROOT}/acl/ || return 1
    acl_file="${HIHY_CONFIG_ROOT}/acl/acl.txt"
    rm -f "${acl_file}"
    touch "${acl_file}" || return 1
    yaml_file="${HIHY_CONFIG_ROOT}/conf/config.yaml"
    rm -f "${yaml_file}"
    touch "${yaml_file}" || return 1

    echoColor yellowBlack "$(msg config_executing)"
    max_CRW=0
    if [ "${congestion_mode}" == "brutal" ]; then
        download=$(($download + $download / 10))
        upload=$(($upload + $upload / 10))
        CRW=$(($delay * $download * 1000000 / 1000 * 2))
        SRW=$(($CRW / 5 * 2))
        max_CRW=$(($CRW * 3 / 2))
        max_SRW=$(($SRW * 3 / 2))
        server_upload=${download}
        server_download=${upload}
    fi

    if [ "${realmMode}" == "true" ]; then
        addOrUpdateYaml "$yaml_file" "listen" "${realmURI}" || return 1
    elif [ "${portHoppingStatus}" == "true" ]; then
        addOrUpdateYaml "$yaml_file" "listen" ":${port},${portHoppingStart}-${portHoppingEnd}" || return 1
    else
        addOrUpdateYaml "$yaml_file" "listen" ":${port}" || return 1
    fi
    if [ "${realmMode}" == "true" ]; then
        addOrUpdateYaml "$yaml_file" "realm.stunServers[0]" "stun.nextcloud.com:3478" || return 1
        addOrUpdateYaml "$yaml_file" "realm.stunServers[1]" "global.stun.twilio.com:3478" || return 1
        addOrUpdateYaml "$yaml_file" "realm.stunTimeout" "5s" || return 1
        addOrUpdateYaml "$yaml_file" "realm.punchTimeout" "5s" || return 1
        addOrUpdateYaml "$yaml_file" "realm.heartbeatInterval" "30s" || return 1
        addOrUpdateYaml "$yaml_file" "realm.insecure" "false" || return 1
        addOrUpdateYaml "$yaml_file" "realm.ipMode" "dual" || return 1
        addOrUpdateYaml "$yaml_file" "realm.portMapping.enabled" "true" || return 1
        addOrUpdateYaml "$yaml_file" "realm.portMapping.timeout" "30s" || return 1
        addOrUpdateYaml "$yaml_file" "realm.portMapping.lifetime" "10m" || return 1
    fi
    addOrUpdateYaml "$yaml_file" "auth.type" "password" || return 1
    addOrUpdateYaml "$yaml_file" "auth.password" "${auth_secret}" || return 1
    addOrUpdateYaml "$yaml_file" "ignoreClientBandwidth" "${ignore_client_bandwidth}" || return 1
    if [ "${congestion_mode}" != "brutal" ]; then
        addOrUpdateYaml "$yaml_file" "congestion.type" "${congestion_type}" || return 1
    fi
    if [ "${congestion_type}" == "bbr" ]; then
        addOrUpdateYaml "$yaml_file" "congestion.bbrProfile" "${congestion_bbr_profile}" || return 1
    fi
    if [ "${obfs_status}" == "true" ]; then
        addOrUpdateYaml "$yaml_file" "obfs.type" "${obfs_type}" || return 1
        addOrUpdateYaml "$yaml_file" "obfs.${obfs_type}.password" "${obfs_pass}" || return 1
    fi
    if [ "${mimic_status}" = true ]; then
        localCoreVersionAtLeast "2.12.0" && installMimic || return 1
        addOrUpdateYaml "$yaml_file" "mimic.enabled" true bool || return 1
    fi
    if [ "${congestion_mode}" == "brutal" ]; then
        addOrUpdateYaml "$yaml_file" "quic.initStreamReceiveWindow" "${SRW}" || return 1
        addOrUpdateYaml "$yaml_file" "quic.maxStreamReceiveWindow" "${max_SRW}" || return 1
        addOrUpdateYaml "$yaml_file" "quic.initConnReceiveWindow" "${CRW}" || return 1
        addOrUpdateYaml "$yaml_file" "quic.maxConnReceiveWindow" "${max_CRW}" || return 1
    fi
    addOrUpdateYaml "$yaml_file" "quic.maxIdleTimeout" "30s" || return 1
    addOrUpdateYaml "$yaml_file" "quic.maxIncomingStreams" "1024" || return 1
    addOrUpdateYaml "$yaml_file" "quic.disablePathMTUDiscovery" "false" || return 1
    if [ "${congestion_mode}" == "brutal" ]; then
        addOrUpdateYaml "$yaml_file" "bandwidth.up" "${server_upload}mbps" || return 1
        addOrUpdateYaml "$yaml_file" "bandwidth.down" "${server_download}mbps" || return 1
        # 仅显式关闭时写入。旧内核(mapstructure)会静默忽略该未知字段:不会崩溃,但也不生效,
        # 所以这里提示用户先更新内核,免得以为已经关闭了补偿。
        if [ "${brutal_disable_loss_comp}" == "true" ]; then
            addOrUpdateYaml "$yaml_file" "bandwidth.disableLossCompensation" "true" "bool" || return 1
            if ! localCoreVersionAtLeast "2.10.0"; then
                echoColor yellow "$(msg losscomp_core_too_old "$(getLocalHysteriaVersion 2>/dev/null || echo unknown)")"
            fi
        fi
    fi
    addOrUpdateYaml "$yaml_file" "acl.file" "${acl_file}" || return 1
    if [ "${masquerade_status}" == "true" ]; then
        case ${masquerade_type} in
            "string")
                addOrUpdateYaml "$yaml_file" "masquerade.type" "string" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.string.content" "${masquerade_string}" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.string.headers.content-type" "text/plain" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.string.headers.custom-stuff" "${masquerade_stuff}" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.string.statusCode" "200" || return 1
                ;;
            "proxy")
                addOrUpdateYaml "$yaml_file" "masquerade.type" "proxy" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.proxy.url" "${masquerade_proxy}" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.proxy.rewriteHost" "true" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.proxy.insecure" "false" || return 1
                addOrUpdateYaml "$yaml_file" "masquerade.proxy.xForwarded" "${masquerade_xforwarded}" || return 1
                ;;
            "file")
                addOrUpdateYaml "$yaml_file" "masquerade.type" "file" || return 1
                [ ! -L "$masquerade_file" ] || return 1
                if [ "$masquerade_file" = "$HIHY_ROOT_DIR/file" ] && { [ ! -d "$masquerade_file" ] || [ -z "$(find "$masquerade_file" -mindepth 1 -maxdepth 1 -print -quit)" ]; }; then
                    prepareMasqueradeFiles "$HIHY_CONFIG_ROOT/file" || return 1
                    addOrUpdateYaml "$yaml_file" masquerade.file.dir "$HIHY_CONFIG_ROOT/file" string || return 1
                else
                    [[ "$masquerade_file" = /* ]] && [ -d "$masquerade_file" ] && [ ! -L "$masquerade_file" ] || return 1
                    addOrUpdateYaml "$yaml_file" masquerade.file.dir "$masquerade_file" string || return 1
                fi
                ;;
        esac
        if [ "${realmMode}" != "true" ] && [ "${masquerade_tcp}" == "true" ]; then
            addOrUpdateYaml "$yaml_file" "masquerade.listenHTTPS" ":${port}" || return 1
        fi
    fi
    addOrUpdateYaml "$yaml_file" "speedTest" "true" || return 1
    pinSHA256=""
    if echo "${useAcme}" | grep -q "false"; then
        if echo "${useLocalCert}" | grep -q "false"; then
            v6str=":"
            result=$(echo ${ip} | grep ${v6str})
            if [ "${result}" != "" ]; then
                ip="[${ip}]"
            fi
            u_host=${ip}
            u_domain=${domain}
            if [ -z "${remarks}" ]; then
                remarks="${ip}"
            fi
            insecure="0"
            days=3650
            mail="no-reply@qq.com"
            echoColor purple "$(msg cert_generating_start)"
            echoColor green "$(msg cert_ca_key)"
            openssl genrsa -out ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.key 2048 || return 1
            echoColor green "$(msg cert_ca_cert)"
            openssl req -new -x509 -days ${days} -key ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.key -subj "/C=CN/ST=GuangDong/L=ShenZhen/O=PonyMa/OU=Tecent/emailAddress=${mail}/CN=Tencent Root CA" -out ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.crt || return 1
            echoColor green "$(msg cert_server_key_csr)"
            openssl req -newkey rsa:2048 -nodes -keyout ${HIHY_CONFIG_ROOT}/cert/${domain}.key -subj "/C=CN/ST=GuangDong/L=ShenZhen/O=PonyMa/OU=Tecent/emailAddress=${mail}/CN=${domain}" -out ${HIHY_CONFIG_ROOT}/cert/${domain}.csr || return 1
            echoColor green "$(msg cert_sign_server)"
            openssl x509 -req -extfile <(printf "subjectAltName=DNS:${domain},DNS:${domain}") -days ${days} -in ${HIHY_CONFIG_ROOT}/cert/${domain}.csr -CA ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.crt -CAkey ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.key -CAcreateserial -out ${HIHY_CONFIG_ROOT}/cert/${domain}.crt || return 1
            echoColor green "$(msg cert_cleanup)"
            rm -f ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.key ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.srl ${HIHY_CONFIG_ROOT}/cert/${domain}.csr
            echoColor green "$(msg cert_move_ca)"
            mv ${HIHY_CONFIG_ROOT}/cert/${domain}.ca.crt ${HIHY_CONFIG_ROOT}/result || return 1
            echoColor purple "$(msg cert_success)"
            pinSHA256=$(openssl x509 -noout -fingerprint -sha256 -in ${HIHY_CONFIG_ROOT}/cert/${domain}.crt 2>/dev/null | sed 's/^.*=//')
            if isValidFingerprint "${pinSHA256}"; then
                echoColor green "$(msg cert_sha256_label)$(echoColor red "${pinSHA256}")"
                echoColor purple "$(msg cert_pinsha256_hint)"
            else
                echoColor yellow "$(msg cert_fingerprint_fail)"
                return 1
            fi
            addOrUpdateYaml "$yaml_file" "tls.cert" "${HIHY_CONFIG_ROOT}/cert/${domain}.crt" || return 1
            addOrUpdateYaml "$yaml_file" "tls.key" "${HIHY_CONFIG_ROOT}/cert/${domain}.key" || return 1
            if [ "${realmMode}" == "true" ]; then
                addOrUpdateYaml "$yaml_file" "tls.sniGuard" "disable" || return 1
            else
                addOrUpdateYaml "$yaml_file" "tls.sniGuard" "strict" || return 1
            fi
        else
            u_host=${domain}
            u_domain=${domain}
            if [ -z "${remarks}" ]; then
                remarks="${domain}"
            fi
            insecure="0"
            addOrUpdateYaml "$yaml_file" "tls.cert" "${local_cert}" || return 1
            addOrUpdateYaml "$yaml_file" "tls.key" "${local_key}" || return 1
            if [ "${realmMode}" == "true" ]; then
                addOrUpdateYaml "$yaml_file" "tls.sniGuard" "disable" || return 1
            else
                addOrUpdateYaml "$yaml_file" "tls.sniGuard" "strict" || return 1
            fi
        fi
    else
        u_host=${domain}
        u_domain=${domain}
        insecure="0"
        if [ -z "${remarks}" ]; then
            remarks="${domain}"
        fi
        addOrUpdateYaml "$yaml_file" "acme.domains[0]" "${domain}" || return 1
        addOrUpdateYaml "$yaml_file" "acme.email" "pekora@${domain}" || return 1
        addOrUpdateYaml "$yaml_file" "acme.ca" "letsencrypt" || return 1
        addOrUpdateYaml "$yaml_file" "acme.dir" "${HIHY_CONFIG_ROOT}/cert" || return 1
        if [ "${useDns}" == "true" ]; then
            u_host=${ip}
            addOrUpdateYaml "$yaml_file" "acme.type" "dns" || return 1
            case ${dns} in
                "cloudflare")
                    addOrUpdateYaml "$yaml_file" "acme.dns.name" "cloudflare" || return 1
                    addOrUpdateYaml "$yaml_file" "acme.dns.config.cloudflare_api_token" "${cloudflare_api_token}" || return 1
                    ;;
                "duckdns")
                    addOrUpdateYaml "$yaml_file" "acme.dns.name" "duckdns" || return 1
                    addOrUpdateYaml "$yaml_file" "acme.dns.config.duckdns_api_token" "${duckdns_api_token}" || return 1
                    addOrUpdateYaml "$yaml_file" "acme.dns.config.duckdns_override_domain" "${duckdns_override_domain}" || return 1
                    ;;
                "gandi")
                    addOrUpdateYaml "$yaml_file" "acme.dns.name" "gandi" || return 1
                    addOrUpdateYaml "$yaml_file" "acme.dns.config.gandi_api_token" "${gandi_api_token}" || return 1
                    ;;
                "godaddy")
                    addOrUpdateYaml "$yaml_file" "acme.dns.name" "godaddy" || return 1
                    addOrUpdateYaml "$yaml_file" "acme.dns.config.godaddy_api_token" "${godaddy_api_token}" || return 1
                    ;;
                "vultr")
                    addOrUpdateYaml "$yaml_file" "acme.dns.name" "vultr" || return 1
                    addOrUpdateYaml "$yaml_file" "acme.dns.config.vultr_api_token" "${vultr_api_token}" || return 1
                    ;;
            esac
        else
            addOrUpdateYaml "$yaml_file" "acme.type" "http" || return 1
            addOrUpdateYaml "$yaml_file" "acme.listenHost" "0.0.0.0" || return 1
        fi
    fi
    if [ "${realmMode}" == "true" ]; then
        u_host="${realmURI}"
    fi

    # ECH:内核 >= v2.10.0 才支持;老内核会忽略 ech 块导致客户端 fail-closed,必须硬性拦截
    if [ "${ech_status}" == "true" ]; then
        if ! localCoreVersionAtLeast "2.10.0"; then
            echoColor yellow "$(msg ech_core_too_old "$(getLocalHysteriaVersion 2>/dev/null || echo unknown)")"
            return 1
        elif generateEchKeypair "${HIHY_CONFIG_ROOT}/cert/ech.pem" "${ech_public_name}"; then
            addOrUpdateYaml "$yaml_file" "ech.keyPath" "${HIHY_CONFIG_ROOT}/cert/ech.pem" || return 1
            echoColor green "$(msg ech_keygen_success "$(echoColor red "${ech_public_name}")")"
        else
            echoColor yellow "$(msg ech_keygen_failed)"
            return 1
        fi
    fi

    addOrUpdateYaml "$yaml_file" "sniff.enable" "true" || return 1
    addOrUpdateYaml "$yaml_file" "sniff.timeout" "2s" || return 1
    addOrUpdateYaml "$yaml_file" "sniff.rewriteDomain" "false" || return 1
    addOrUpdateYaml "$yaml_file" "sniff.tcpPorts" "80,443" || return 1
    addOrUpdateYaml "$yaml_file" "sniff.udpPorts" "80,443" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[0].name" "hihy" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[0].type" "direct" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[0].direct.mode" "auto" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[0].direct.fastOpen" "false" "bool" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[1].name" "v4_only" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[1].type" "direct" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[1].direct.mode" "4" "number" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[1].direct.fastOpen" "false" "bool" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[2].name" "v6_only" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[2].type" "direct" "string" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[2].direct.mode" "6" "number" || return 1
    addOrUpdateYaml "$yaml_file" "outbounds[2].direct.fastOpen" "false" "bool" || return 1
    trafficPort=$(($(od -An -N2 -i /dev/urandom) % (65534 - 10001) + 10001))
    if [ "$trafficPort" == "${port}" ]; then
        trafficPort=$((${port} + 1))
    fi
    addOrUpdateYaml "$yaml_file" "trafficStats.listen" "127.0.0.1:${trafficPort}" || return 1
    addOrUpdateYaml "$yaml_file" "trafficStats.secret" "$(generate_uuid)" "string" || return 1
    if [ "${block_http3}" == "true" ]; then
        echo -e "reject(all, udp/443)" >${acl_file}
    fi
    backup_file="${HIHY_CONFIG_ROOT}/conf/backup.yaml"
    rm -f "${backup_file}"
    touch "${backup_file}" || return 1
    addOrUpdateYaml ${backup_file} "remarks" "${remarks}" || return 1
    addOrUpdateYaml ${backup_file} "serverAddress" "${u_host}" "string" || return 1
    addOrUpdateYaml ${backup_file} "serverPort" "${port}" || return 1
    addOrUpdateYaml ${backup_file} "congestionMode" "${congestion_mode}" || return 1
    addOrUpdateYaml ${backup_file} "congestionType" "${congestion_type}" || return 1
    addOrUpdateYaml ${backup_file} "ignoreClientBandwidth" "${ignore_client_bandwidth}" || return 1
    if [ "${congestion_type}" == "bbr" ]; then
        addOrUpdateYaml ${backup_file} "congestionBbrProfile" "${congestion_bbr_profile}" || return 1
    fi
    addOrUpdateYaml ${backup_file} "portHoppingStatus" "${portHoppingStatus}" || return 1
    addOrUpdateYaml ${backup_file} "portHoppingStart" "${portHoppingStart}" || return 1
    addOrUpdateYaml ${backup_file} "portHoppingEnd" "${portHoppingEnd}" || return 1
    addOrUpdateYaml ${backup_file} "portHoppingIntervalMode" "${portHoppingIntervalMode}" || return 1
    addOrUpdateYaml ${backup_file} "portHoppingHopInterval" "${portHoppingHopInterval}" || return 1
    addOrUpdateYaml ${backup_file} "portHoppingMinHopInterval" "${portHoppingMinHopInterval}" || return 1
    addOrUpdateYaml ${backup_file} "portHoppingMaxHopInterval" "${portHoppingMaxHopInterval}" || return 1
    addOrUpdateYaml ${backup_file} "domain" "${domain}" || return 1
    addOrUpdateYaml ${backup_file} "trafficPort" "${trafficPort}" || return 1
    addOrUpdateYaml ${backup_file} "socks5_status" "false" || return 1
    addOrUpdateYaml ${backup_file} "realmMode" "${realmMode}" || return 1
    if [ "${realmMode}" == "true" ]; then
        addOrUpdateYaml ${backup_file} "realmURI" "${realmURI}" || return 1
        addOrUpdateYaml ${backup_file} "realmName" "${realmName}" || return 1
    fi
    addOrUpdateYaml ${backup_file} "masquerade_status" "${masquerade_status}" || return 1
    addOrUpdateYaml ${backup_file} "masquerade_xforwarded" "${masquerade_xforwarded}" || return 1
    addOrUpdateYaml ${backup_file} "masquerade_tcp" "${masquerade_tcp}" || return 1
    addOrUpdateYaml ${backup_file} "ech_status" "${ech_status}" || return 1
    addOrUpdateYaml ${backup_file} "mimic_status" "${mimic_status}" || return 1
    if [ "${ech_status}" == "true" ]; then
        addOrUpdateYaml ${backup_file} "ech_public_name" "${ech_public_name}" || return 1
        addOrUpdateYaml ${backup_file} "ech_config" "${ech_config}" "string" || return 1
    fi
    if [ "${congestion_mode}" == "brutal" ]; then
        addOrUpdateYaml ${backup_file} "disable_loss_compensation" "${brutal_disable_loss_comp}" || return 1
    fi
    if [ "${insecure}" == "1" ]; then
        addOrUpdateYaml ${backup_file} "insecure" "true" || return 1
    else
        addOrUpdateYaml ${backup_file} "insecure" "false" || return 1
    fi
    if [ -n "${pinSHA256}" ]; then
        addOrUpdateYaml ${backup_file} "pinSHA256" "${pinSHA256}" "string" || return 1
    fi
    return 0
}

setHysteriaConfig() {
    setConfigDefaults
    collectHysteriaConfig "${1:-}" || return 1
    writeHysteriaConfig
}
