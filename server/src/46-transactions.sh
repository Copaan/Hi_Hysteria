#!/bin/bash

# Start one validation instance and retain its exact child PID.
startInstallValidationProcess() {
    local config="$1" debug="$2" core="${3:-$HIHY_ROOT_DIR/bin/appS}"
    [ ! -L "$debug" ] || return 1
    "$core" --disable-update-check -c "$config" server 9>&- >"$debug" 2>&1 &
    HIHY_VALIDATION_PID=$!
}

waitForValidationOutcome() {
    local debug="$1" timeout="$2" elapsed=0
    [[ "${HIHY_VALIDATION_PID:-}" =~ ^[0-9]+$ ]] || return 1
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ -n "${HIHY_VALIDATION_PID:-}" ] && ! kill -0 "$HIHY_VALIDATION_PID" 2>/dev/null; then return 1; fi
        if grep -q 'failed to get a certificate with ACME' "$debug"; then return 2; fi
        if grep -q 'bind: address already in use' "$debug"; then return 3; fi
        if grep -q 'server up and running' "$debug"; then
            sleep 1
            kill -0 "$HIHY_VALIDATION_PID" 2>/dev/null && return 0
            return 1
        fi
        sleep 1; elapsed=$((elapsed + 1))
    done
    return 1
}

stopValidationProcess() {
    local pid="${HIHY_VALIDATION_PID:-}" n
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for n in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    HIHY_VALIDATION_PID=""
}

# Validate operator input before writing certificate paths or stopping a service.
validateHysteriaInputs() {
    isValidDomain "$domain" || { securityError 'Invalid certificate DNS name.'; return 1; }
    [ -n "$auth_secret" ] || return 1
    [[ "$auth_secret" != *$'\n'* && "$auth_secret" != *$'\r'* ]] || return 1
    if [ "$realmMode" != true ]; then
        isValidPort "$port" || return 1
        if [ "$portHoppingStatus" = true ]; then
            isValidPort "$portHoppingStart" && isValidPort "$portHoppingEnd" \
                && [ "$portHoppingStart" -lt "$portHoppingEnd" ] || return 1
        fi
    fi
    if [ "$ech_status" = true ]; then isValidDomain "$ech_public_name" || return 1; fi
    if [ "$congestion_mode" = brutal ]; then
        isPositiveInt "$delay" && isPositiveInt "$download" && isPositiveInt "$upload" || return 1
        [ "$delay" -gt 0 ] && [ "$delay" -le 10000 ] && [ "$download" -gt 0 ] && [ "$download" -le 100000 ] \
            && [ "$upload" -gt 0 ] && [ "$upload" -le 100000 ] || return 1
    fi
    if [ "$useLocalCert" = true ]; then
        [[ "$local_cert" = /* && "$local_key" = /* ]] && [ -r "$local_cert" ] && [ -r "$local_key" ] || return 1
    fi
    if [ "$masquerade_status" = true ] && [ "$masquerade_type" = proxy ]; then
        [[ "$masquerade_proxy" = https://* || "$masquerade_proxy" = http://* ]] || return 1
    fi
}

# Apply a complete candidate with configuration, certificate and service rollback.
writeHysteriaConfig() (
    local transaction candidate backup dir field value was_running=false stopped=false activated=false success=false timeout=15
    local subscription_previous="" subscription_ready=false subscription_switched=false
    validateHysteriaInputs || return 1
    if subscriptionEnabled; then
        [ "$mimic_status" != true ] || { subscriptionError sub_incompatible; return 1; }
        if [ "$masquerade_tcp" = true ] && [ "$port" = 443 ]; then subscriptionError sub_port_conflict; return 1; fi
        subscription_previous=$(readlink "$HIHY_SUB_STATE/content/current") || return 1
    fi
    mkdir -p "$HIHY_ROOT_DIR" || return 1
    [ ! -L "$HIHY_ROOT_DIR" ] || return 1
    transaction=$(mktemp -d "$HIHY_ROOT_DIR/.config.XXXXXXXX") || return 1
    candidate="$transaction/candidate"; backup="$transaction/previous"
    mkdir -p "$candidate" "$backup" || return 1
    rollbackConfiguration() {
        local rc=$? part
        stopValidationProcess
        if [ "$success" != true ]; then
            if [ "$subscription_switched" = true ]; then
                subscriptionRestoreSnapshot "$subscription_previous" || rc=1
                subscriptionPruneSnapshots || rc=1
            fi
            restoreFirewallLedger "$transaction/firewall.before" || rc=1
            if [ "$activated" = true ]; then
                [ "$was_running" != true ] || stop >/dev/null 2>&1 || true
                for part in conf cert result acl file; do
                    rm -rf -- "$HIHY_ROOT_DIR/$part"
                    [ ! -d "$backup/$part" ] || cp -a -- "$backup/$part" "$HIHY_ROOT_DIR/$part" || rc=1
                done
            fi
            if [ "$stopped" = true ] && [ "$was_running" = true ] && [ "$(getServiceRunState)" != running ]; then start || rc=1; fi
        fi
        rm -rf -- "$transaction"
        return "$rc"
    }
    trap rollbackConfiguration EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    snapshotFirewallLedger "$transaction/firewall.before" || return 1
    for dir in conf cert result acl file; do
        [ ! -L "$HIHY_ROOT_DIR/$dir" ] || return 1
        if [ -d "$HIHY_ROOT_DIR/$dir" ]; then cp -a -- "$HIHY_ROOT_DIR/$dir" "$backup/$dir" || return 1; fi
    done
    HIHY_CONFIG_ROOT="$candidate"
    generateStagedConfig || return 1
    if subscriptionEnabled; then
        subscriptionRenderSnapshot "$candidate" "$transaction/subscription" || return 1
        subscription_ready=true
    fi
    if [ -f "$backup/acl/acl.txt" ]; then
        grep -Fxv 'reject(all, udp/443)' "$backup/acl/acl.txt" >"$candidate/acl/acl.txt" || [ $? -eq 1 ] || return 1
        if [ "$block_http3" = true ]; then printf '%s\n' 'reject(all, udp/443)' >>"$candidate/acl/acl.txt"; fi
    fi
    if [ "$(getServiceRunState)" = running ]; then was_running=true; stopped=true; stop || return 1; fi
    if [ "$useAcme" = true ]; then timeout=60; [ "$useDns" = true ] || allowPort tcp 80 || return 1; fi
    startInstallValidationProcess "$candidate/conf/config.yaml" "$transaction/validation.log" || return 1
    if ! waitForValidationOutcome "$transaction/validation.log" "$timeout"; then
        securityError 'Candidate configuration failed to start; previous configuration is retained.'
        return 1
    fi
    stopValidationProcess
    for field in tls.cert tls.key ech.keyPath acme.dir acl.file masquerade.file.dir; do
        value=$(getYamlValue "$candidate/conf/config.yaml" "$field") || return 1
        case "$value" in "$candidate"/*) addOrUpdateYaml "$candidate/conf/config.yaml" "$field" "$HIHY_ROOT_DIR/${value#"$candidate/"}" string || return 1 ;; esac
    done
    snapshotFirewallLedger "$candidate/conf/firewall.tsv" || return 1
    activated=true
    for dir in conf cert result acl file; do
        if [ "$dir" = file ] && [ ! -d "$candidate/file" ] && [ ! -d "$backup/file" ]; then continue; fi
        mkdir -p "$candidate/$dir" || return 1
        if [ -d "$backup/$dir" ]; then cp -an -- "$backup/$dir/." "$candidate/$dir/" || return 1; fi
        rm -rf -- "$HIHY_ROOT_DIR/$dir"
        mv -- "$candidate/$dir" "$HIHY_ROOT_DIR/$dir" || return 1
    done
    delHihyFirewallPort udp || return 1
    delHihyFirewallPort tcp || return 1
    if [ "$realmMode" != true ]; then
        allowPort udp "$port" || return 1
        [ "$portHoppingStatus" != true ] || allowPort udp "$portHoppingStart:$portHoppingEnd" || return 1
        [ "$masquerade_tcp" != true ] || allowPort tcp "$port" || return 1
    fi
    if [ "$useAcme" = true ] && [ "$useDns" != true ]; then allowPort tcp 80 || return 1; fi
    secureInstallPermissions || return 1
    if [ "$was_running" = true ]; then start && [ "$(getServiceRunState)" = running ] || return 1; fi
    if [ "$subscription_ready" = true ]; then
        subscription_switched=true
        subscriptionCommitSnapshot "$transaction/subscription" || return 1
    fi
    if [ "${max_CRW:-0}" -gt 0 ]; then
        if sysctl -w "net.core.rmem_max=$max_CRW" "net.core.wmem_max=$max_CRW" >/dev/null 2>&1; then
            if [ ! -e /etc/sysctl.d/99-hihy.conf ] || [ -f "$HIHY_ROOT_DIR/conf/sysctl-owned" ]; then
            : >"$HIHY_ROOT_DIR/conf/sysctl-owned"
            printf 'net.core.rmem_max=%s\nnet.core.wmem_max=%s\n' "$max_CRW" "$max_CRW" >/etc/sysctl.d/99-hihy.conf
            fi
        fi
    fi
    success=true
    [ "$subscription_ready" != true ] || subscriptionPruneSnapshots || true
)
