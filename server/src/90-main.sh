#!/bin/bash
menu() {
    while true; do
        show_menu
        read -r -p "$(msg menu_prompt_choice)" input || return 0
        case $input in
            1) install ;;
            2) uninstall ;;
            3) start ;;
            4) stop ;;
            5) restart ;;
            6) checkStatus ;;
            7) updateHysteriaCore ;;
            8) generate_client_config ;;
            9) changeServerConfig ;;
            10) changeIp64 ;;
            11) hihyUpdate ;;
            12) aclControl ;;
            13) getHysteriaTrafic ;;
            14) checkLogs ;;
            15) addSocks5Outbound ;;
            16) install auto ;;
            17) subscriptionMenu ;;
            0) exit 0 ;;
            *) echoColor red "$(msg error_input_error)" ;;
        esac
        wait_for_continue
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    checkRoot
    case "${1:-}" in
        firewallRestore|subscription-firewall-restore|cronTask) ;;
        *)
            exec 9>/run/hihy.operation.lock
            flock -n 9 || { securityError "另一个 hihy 操作正在运行。"; exit 1; }
            ;;
    esac
    case "${1:-}" in
        install | 1)
            echoColor purple "$(msg cmd_title_install)"
            install
            ;;
        autoinstall | auto | 16)
            echoColor purple "$(msg cmd_title_autoinstall)"
            install auto
            ;;
        uninstall | 2)
            echoColor purple "$(msg cmd_title_uninstall)"
            uninstall
            ;;
        start | 3)
            echoColor purple "$(msg cmd_title_start)"
            start
            ;;
        stop | 4)
            echoColor purple "$(msg cmd_title_stop)"
            stop
            ;;
        restart | 5)
            echoColor purple "$(msg cmd_title_restart)"
            restart
            ;;
        checkStatus | 6)
            echoColor purple "$(msg cmd_title_status)"
            checkStatus
            ;;
        updateHysteriaCore | 7)
            echoColor purple "$(msg cmd_title_update_core)"
            updateHysteriaCore "${2:-}"
            ;;
        generate_client_config | 8)
            echoColor purple "$(msg cmd_title_view_config)"
            generate_client_config
            ;;
        changeServerConfig | 9)
            echoColor purple "$(msg cmd_title_reconfigure)"
            changeServerConfig
            ;;
        changeIp64 | 10)
            echoColor purple "$(msg cmd_title_switch_ip_priority)"
            changeIp64
            ;;
        hihyUpdate | 11)
            echoColor purple "$(msg cmd_title_update_hihy)"
            hihyUpdate
            ;;
        aclControl | 12)
            echoColor purple "$(msg cmd_title_acl)"
            aclControl
            ;;
        getHysteriaTrafic | 13)
            echoColor purple "$(msg cmd_title_traffic_stats)"
            getHysteriaTrafic
            ;;
        checkLogs | 14)
            echoColor purple "$(msg cmd_title_logs)"
            checkLogs
            ;;
        addSocks5Outbound | 15)
            echoColor purple "$(msg cmd_title_socks5)"
            addSocks5Outbound
            ;;
        firewallRestore) firewallRestore ;;
        subscription-firewall-restore) subscriptionFirewallRestore ;;
        subscription) shift; subscriptionCommand "$@" ;;
        17) subscriptionMenu ;;
        cronTask) cronTask ;;
        *) menu ;;
    esac
fi
