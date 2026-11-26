#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/server/hy2.sh"
TEST_ROOT=$(secureTempDir)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export HIHY_ROOT_DIR="$TEST_ROOT/hihy" HIHY_EXPORT_DIR="$TEST_ROOT/exports"
mkdir -p "$HIHY_ROOT_DIR/bin" "$HIHY_ROOT_DIR/conf"
assert() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
reject() { if "$@"; then printf 'FAIL: unexpectedly accepted %s\n' "$*" >&2; exit 1; fi; }
value=$(printf 'quote \042 backslash \134 newline\ntrue: null; $(printf unsafe)')
addOrUpdateYaml "$TEST_ROOT/data.yaml" auth.password "$value" string
assert test "$(getYamlValue "$TEST_ROOT/data.yaml" auth.password)" = "$value"
for value in -n -e true false null 00123 '[x, y]' '#comment'; do
    addOrUpdateYaml "$TEST_ROOT/data.yaml" auth.password "$value"
    assert test "$(yq '.auth.password | tag' "$TEST_ROOT/data.yaml")" = '!!str'
    assert test "$(getYamlValue "$TEST_ROOT/data.yaml" auth.password)" = "$value"
done
assert test "$(stat -c %a "$TEST_ROOT/data.yaml")" = 600
reject addOrUpdateYaml "$TEST_ROOT/data.yaml" 'x | load(env(HOME))' bad
reject addOrUpdateYaml "$TEST_ROOT/data.yaml" port '1 | .auth = null' number
ln -s "$TEST_ROOT/data.yaml" "$TEST_ROOT/symlink.yaml"
reject addOrUpdateYaml "$TEST_ROOT/symlink.yaml" auth.password changed
assert test "$(urlEncode 'a@b:/ ?#&=+%')" = 'a%40b%3A%2F%20%3F%23%26%3D%2B%25'
for domain in ../root example.com/../../root '-bad.example' 'bad..example' 'bad name' 'a;id'; do reject isValidDomain "$domain"; done
assert isValidDomain valid.example.com
reject isValidPort 08
assert isValidPort 65535
reject isValidPort 65536
output=$(clientOutputPath '../../escaped/name' mihomo.yaml)
[[ "$output" = "$HIHY_EXPORT_DIR/"* ]]
[[ "${output#"$HIHY_EXPORT_DIR/"}" != */* ]]
assert test "$(stat -c %a "$HIHY_EXPORT_DIR")" = 700
(
    curl() { printf '%s\n' "$*" >>"$TEST_ROOT/curl.log"; return 60; }
    export HIHY_DOWNLOAD_RETRIES=1
    printf old >"$TEST_ROOT/artifact"
    reject downloadToFile https://example.invalid/artifact "$TEST_ROOT/artifact"
    assert test "$(cat "$TEST_ROOT/artifact")" = old
    assert test "$(wc -l <"$TEST_ROOT/curl.log")" = 2
    assert grep -Fq -- '--proto =https --proto-redir =https' "$TEST_ROOT/curl.log"
    reject downloadToFile http://example.invalid/artifact "$TEST_ROOT/artifact"
)
(
    downloadToFile() { printf malicious >"$2"; }
    printf old >"$TEST_ROOT/artifact"
    reject downloadVerifiedFile https://example.invalid/artifact "$TEST_ROOT/artifact" $(printf good | sha256sum | cut -d' ' -f1)
    assert test "$(cat "$TEST_ROOT/artifact")" = old
    reject fetchHysteriaCandidate 'app/v2.14.0/../../evil' "$TEST_ROOT/artifact"
    getHysteriaCoreArch() { echo unknown; }
    reject fetchHysteriaCandidate app/v9.9.9 "$TEST_ROOT/artifact"
    assert test "$(cat "$TEST_ROOT/artifact")" = old
)
(
    curl() { touch "$TEST_ROOT/unexpected-network"; return 1; }
    wget() { touch "$TEST_ROOT/unexpected-network"; return 1; }
    getServiceRunState() { echo none; }
    show_menu >/dev/null
    hihyUpdate >/dev/null
    assert test ! -e "$TEST_ROOT/unexpected-network"
    reject installWarpVerified w
    assert test ! -e "$TEST_ROOT/unexpected-network"
)
(
    printf old >"$HIHY_ROOT_DIR/bin/appS"
    getLocalHysteriaVersion() { echo app/v2.13.0; }
    getServiceRunState() { echo running; }
    stop() { printf stop >>"$TEST_ROOT/stopped"; }
    start() { [ "$(cat "$HIHY_ROOT_DIR/bin/appS")" = old ]; }
    fetchHysteriaCandidate() { return 1; }
    reject updateHysteriaCore app/v2.14.0
    assert test ! -e "$TEST_ROOT/stopped"
    fetchHysteriaCandidate() { printf broken >"$2"; }
    reject updateHysteriaCore app/v2.14.0
    assert test "$(cat "$HIHY_ROOT_DIR/bin/appS")" = old
    assert test -e "$TEST_ROOT/stopped"
)
(
    ledger=$(firewallLedger)
    printf 'iptables|udp|34567\nip6tables|udp|34567\niptables|tcp|80\n' >"$ledger"
    firewallRule() { printf '%s\n' "$*" >>"$TEST_ROOT/firewall.log"; }
    delHihyFirewallPort udp
    assert test "$(cat "$ledger")" = 'iptables|tcp|80'
    assert test "$(wc -l <"$TEST_ROOT/firewall.log")" = 2
    reject grep -q 'tcp 80' "$TEST_ROOT/firewall.log"
)
printf 'PASS: security, serialization, offline menu, upgrade rollback and firewall ownership\n'

(
    for curl_error in 18 28 60; do
        curl() { printf partial >"$TEST_ROOT/partial-output"; return "$curl_error"; }
        export HIHY_DOWNLOAD_RETRIES=0
        printf old >"$TEST_ROOT/download-destination"
        reject downloadToFile https://example.invalid/core "$TEST_ROOT/download-destination"
        assert test "$(cat "$TEST_ROOT/download-destination")" = old
    done
)
python3 - "$TEST_ROOT/arm64.elf" <<'PY'
import pathlib, sys
header = bytearray(64)
header[:6] = b'\x7fELF\x02\x01'
header[18:20] = b'\xb7\x00'
pathlib.Path(sys.argv[1]).write_bytes(header)
PY
assert validateCoreArchitecture "$TEST_ROOT/arm64.elf" arm64
reject validateCoreArchitecture "$TEST_ROOT/arm64.elf" amd64
(
    getHysteriaCoreArch() { echo amd64; }
    downloadVerifiedFile() {
        if [[ "$1" = */hashes.txt ]]; then
            printf '%064d  build/hysteria-linux-amd64\n' 0 >"$2"
        else cp "$TEST_ROOT/arm64.elf" "$2"; fi
    }
    getLocalHysteriaVersion() { touch "$TEST_ROOT/executed-wrong-architecture"; echo app/v2.14.0; }
    reject fetchHysteriaCandidate app/v2.14.0 "$TEST_ROOT/destination-core"
    assert test ! -e "$TEST_ROOT/executed-wrong-architecture"
    assert test ! -e "$TEST_ROOT/destination-core"
)
printf 'PASS: interrupted downloads and wrong ELF architecture fail before execution\n'

(
    printf old >"$HIHY_ROOT_DIR/bin/appS"
    printf running >"$TEST_ROOT/service-state"
    getLocalHysteriaVersion() { echo app/v2.13.0; }
    getServiceRunState() { cat "$TEST_ROOT/service-state"; }
    fetchHysteriaCandidate() { printf candidate >"$2"; }
    stop() { printf stopped >"$TEST_ROOT/service-state"; return 1; }
    start() { printf running >"$TEST_ROOT/service-state"; }
    reject updateHysteriaCore app/v2.14.0
    assert test "$(cat "$TEST_ROOT/service-state")" = running
    assert test "$(cat "$HIHY_ROOT_DIR/bin/appS")" = old
)
printf 'PASS: a failed stop operation also restores the previous running state\n'
