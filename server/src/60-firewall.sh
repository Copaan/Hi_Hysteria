#!/bin/bash
formatFirewallPortSpec() { printf '%s\n' "${1//-/:}"; }
hasFirewallToken() { tr -s '[:space:]' '\n' | grep -Fxq -- "$1"; }

firewallLedger() { printf '%s\n' "${HIHY_FIREWALL_LEDGER:-$HIHY_ROOT_DIR/conf/firewall.tsv}"; }
snapshotFirewallLedger() {
    local dest="$1" source
    source=$(firewallLedger)
    if [ -f "$source" ]; then cp -- "$source" "$dest"; else : >"$dest"; fi
}

validFirewallPort() {
    local spec="${1//-/:}"
    if [[ "$spec" == *:* ]]; then
        isValidPort "${spec%%:*}" && isValidPort "${spec##*:}" && [ "${spec%%:*}" -le "${spec##*:}" ]
    else isValidPort "$spec"; fi
}

# Mutate one exact rule; no global save/filter/restore operation is used.
firewallRule() {
    local action="$1" backend="$2" proto="$3" port="$4" bin
    [[ "$proto" = udp || "$proto" = tcp ]] && validFirewallPort "$port" || return 1
    case "$backend" in
        iptables|ip6tables)
            bin="$backend"
            if [ "$action" = add ]; then
                "$bin" -C INPUT -p "$proto" --dport "$port" -m comment --comment "allow $proto/$port(${HIHY_FIREWALL_OWNER:-hihysteria})" -j ACCEPT 2>/dev/null \
                    || "$bin" -I INPUT -p "$proto" --dport "$port" -m comment --comment "allow $proto/$port(${HIHY_FIREWALL_OWNER:-hihysteria})" -j ACCEPT
            else
                if "$bin" -C INPUT -p "$proto" --dport "$port" -m comment --comment "allow $proto/$port(${HIHY_FIREWALL_OWNER:-hihysteria})" -j ACCEPT 2>/dev/null; then
                    "$bin" -D INPUT -p "$proto" --dport "$port" -m comment --comment "allow $proto/$port(${HIHY_FIREWALL_OWNER:-hihysteria})" -j ACCEPT
                fi
            fi ;;
        ufw)
            if [ "$action" = add ]; then ufw allow "$port/$proto" comment hihy
            else ufw --force delete allow "$port/$proto"; fi ;;
        firewalld)
            local option=add-port
            [ "$action" = add ] || option=remove-port
            firewall-cmd --zone=public "--$option=${port//:/-}/$proto" --permanent \
                && firewall-cmd --zone=public "--$option=${port//:/-}/$proto" ;;
        *) return 1 ;;
    esac
}

# Record only rules created by this installation.
allowPort() {
    local proto="$1" port="${2//-/:}" backend=iptables ledger record
    [[ "$proto" = udp || "$proto" = tcp ]] && validFirewallPort "$port" || return 1
    ledger=$(firewallLedger)
    mkdir -p "$(dirname "$ledger")" || return 1
    [ ! -L "$ledger" ] || return 1
    touch "$ledger" || return 1
    if command -v ufw >/dev/null 2>&1 && ufw status | hasFirewallToken active; then
        backend=ufw
        if ufw status | hasFirewallToken "$port/$proto"; then return 0; fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        backend=firewalld
        if firewall-cmd --zone=public --query-port="${port//:/-}/$proto" --permanent >/dev/null 2>&1; then return 0; fi
    fi
    record="$backend|$proto|$port"
    if ! grep -Fxq -- "$record" "$ledger"; then
        if [[ "$backend" = iptables ]] && iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment "allow $proto/$port(${HIHY_FIREWALL_OWNER:-hihysteria})" -j ACCEPT 2>/dev/null; then return 0; fi
        printf '%s\n' "$record" >>"$ledger" || return 1
    fi
    firewallRule add "$backend" "$proto" "$port" || return 1
    if [ "$backend" = iptables ] && command -v ip6tables >/dev/null 2>&1 && ip6tables -L INPUT >/dev/null 2>&1; then
        record="ip6tables|$proto|$port"
        if ! grep -Fxq -- "$record" "$ledger"; then
            if ip6tables -C INPUT -p "$proto" --dport "$port" -m comment --comment "allow $proto/$port(${HIHY_FIREWALL_OWNER:-hihysteria})" -j ACCEPT 2>/dev/null; then return 0; fi
            printf '%s\n' "$record" >>"$ledger" || return 1
        fi
        firewallRule add ip6tables "$proto" "$port" || return 1
    fi
}

delHihyFirewallPort() {
    local protocol="$1" ledger temp backend proto port rc=0
    ledger=$(firewallLedger)
    [ -f "$ledger" ] || return 0
    temp=$(mktemp "$(dirname "$ledger")/.firewall.XXXXXXXX") || return 1
    while IFS='|' read -r backend proto port; do
        [ -n "$backend" ] || continue
        if [ "$proto" != "$protocol" ] || ! firewallRule delete "$backend" "$proto" "$port"; then
            printf '%s|%s|%s\n' "$backend" "$proto" "$port" >>"$temp"
            [ "$proto" != "$protocol" ] || rc=1
        fi
    done <"$ledger"
    mv -f -- "$temp" "$ledger" || return 1
    return "$rc"
}

firewallRestore() {
    local backend proto port ledger
    ledger=$(firewallLedger)
    [ -f "$ledger" ] || return 0
    while IFS='|' read -r backend proto port; do
        [ -z "$backend" ] || firewallRule add "$backend" "$proto" "$port" || return 1
    done <"$ledger"
}

restoreFirewallLedger() {
    local saved="$1" ledger
    [ -f "$saved" ] || return 0
    ledger=$(firewallLedger)
    delHihyFirewallPort udp && delHihyFirewallPort tcp || return 1
    mkdir -p "$(dirname "$ledger")" || return 1
    cp -- "$saved" "$ledger" && firewallRestore
}
