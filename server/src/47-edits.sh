#!/bin/bash
# Commit validated server/ACL edits, retaining the previous running state.
commitServerEdit() (
    local candidate="$1" acl_candidate="${2:-}" socks_status="${3:-}" dir live="$HIHY_ROOT_DIR/conf/config.yaml"
    local was_running=false stopped=false activated=false success=false
    dir=$(mktemp -d "$HIHY_ROOT_DIR/.edit.XXXXXXXX") || return 1
    rollbackEdit() {
        local rc=$?
        stopValidationProcess
        if [ "$success" != true ]; then
            if [ "$activated" = true ]; then
                [ "$was_running" != true ] || stop >/dev/null 2>&1 || true
                cp -p -- "$dir/config.old" "$live" || rc=1
                cp -p -- "$dir/backup.old" "$HIHY_ROOT_DIR/conf/backup.yaml" || rc=1
                [ ! -f "$dir/acl.old" ] || cp -p -- "$dir/acl.old" "$HIHY_ROOT_DIR/acl/acl.txt" || rc=1
            fi
            if [ "$stopped" = true ] && [ "$was_running" = true ]; then start || rc=1; fi
        fi
        rm -rf -- "$dir"
        return "$rc"
    }
    trap rollbackEdit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -p -- "$live" "$dir/config.old" && cp -p -- "$HIHY_ROOT_DIR/conf/backup.yaml" "$dir/backup.old" || return 1
    cp -- "$candidate" "$dir/config.new.yaml" && cp -- "$dir/backup.old" "$dir/backup.new.yaml" || return 1
    if [ -n "$acl_candidate" ]; then
        cp -p -- "$HIHY_ROOT_DIR/acl/acl.txt" "$dir/acl.old" && cp -- "$acl_candidate" "$dir/acl.new" || return 1
        addOrUpdateYaml "$dir/config.new.yaml" acl.file "$dir/acl.new" string || return 1
    fi
    [ -z "$socks_status" ] || addOrUpdateYaml "$dir/backup.new.yaml" socks5_status "$socks_status" bool || return 1
    if localCoreVersionAtLeast 2.14.0; then
        "$HIHY_ROOT_DIR/bin/appS" --disable-update-check acl test -c "$dir/config.new.yaml" --no-resolve example.invalid:443 >"$dir/acl-test.log" 2>&1 || return 1
    fi
    if [ "$(getServiceRunState)" = running ]; then was_running=true; stop || return 1; stopped=true; fi
    startInstallValidationProcess "$dir/config.new.yaml" "$dir/validation.log" || return 1
    waitForValidationOutcome "$dir/validation.log" 15 || return 1
    stopValidationProcess
    if [ -n "$acl_candidate" ]; then addOrUpdateYaml "$dir/config.new.yaml" acl.file "$HIHY_ROOT_DIR/acl/acl.txt" string || return 1; fi
    activated=true
    [ -z "$acl_candidate" ] || mv -f -- "$dir/acl.new" "$HIHY_ROOT_DIR/acl/acl.txt" || return 1
    mv -f -- "$dir/config.new.yaml" "$live" && mv -f -- "$dir/backup.new.yaml" "$HIHY_ROOT_DIR/conf/backup.yaml" || return 1
    if [ "$was_running" = true ]; then start && [ "$(getServiceRunState)" = running ] || return 1; fi
    success=true
)
