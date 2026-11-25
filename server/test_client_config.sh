#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export HIHY_ROOT_DIR="$TMP/root" HIHY_EXPORT_DIR="$TMP/exports"
mkdir -p "$HIHY_ROOT_DIR/conf" "$HIHY_ROOT_DIR/cert" "$HIHY_ROOT_DIR/result"
getLocalHysteriaVersion() { echo app/v2.14.0; }
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=server.test -addext subjectAltName=DNS:server.test -keyout "$HIHY_ROOT_DIR/cert/server.key" -out "$HIHY_ROOT_DIR/result/server.test.ca.crt" >/dev/null 2>&1
fp=$(openssl x509 -noout -fingerprint -sha256 -in "$HIHY_ROOT_DIR/result/server.test.ca.crt" | cut -d= -f2)
conf="$HIHY_ROOT_DIR/conf/config.yaml"; backup="$HIHY_ROOT_DIR/conf/backup.yaml"
cat >"$conf" <<'YAML'
listen: :34567
auth:
  password: test-password
obfs:
  type: gecko
  gecko:
    password: test-obfs
bandwidth:
  up: 50 mbps
  down: 200 mbps
YAML
cat >"$backup" <<'YAML'
remarks: 123
serverAddress: 127.0.0.1
domain: server.test
realmMode: false
insecure: false
congestionMode: bbr
congestionType: bbr
congestionBbrProfile: aggressive
portHoppingStatus: true
portHoppingStart: 47000
portHoppingEnd: 48000
portHoppingIntervalMode: random
portHoppingMinHopInterval: 10s
portHoppingMaxHopInterval: 30s
YAML
addOrUpdateYaml "$backup" pinSHA256 "$fp" string
generateEchKeypair "$HIHY_ROOT_DIR/cert/ech.pem" public.test
addOrUpdateYaml "$backup" ech_status true bool
addOrUpdateYaml "$backup" ech_config "$ech_config" string
generate_client_config >/dev/null
native=$(clientOutputPath 123 v2rayN.yaml); mihomo=$(clientOutputPath 123 mihomo.yaml); singbox=$(clientOutputPath 123 singbox.json)
[ "$(yq -r '.proxies[0].obfs' "$mihomo")" = gecko ]
[ "$(yq -r '.proxies[0].ech-opts.enable' "$mihomo")" = true ]
[ "$(yq -r '.proxy-groups[0].proxies[0] | tag' "$mihomo")" = '!!str' ]
[ "$(yq -r '.proxies[0].hop-interval' "$mihomo")" = '10-30' ]
[ "$(yq -r '.allow-lan' "$mihomo")" = false ]
[ "$(yq -r '.dns.listen' "$mihomo")" = 127.0.0.1:1053 ]
[ "$(yq -r '.outbounds[0].bbr_profile' "$singbox")" = aggressive ]
[ "$(yq -r '.outbounds[0].obfs.type' "$singbox")" = gecko ]
[ "$(yq -r '.outbounds[0].hop_interval_max' "$singbox")" = 30s ]
[ "$(yq -r '.dns.servers[1].detour' "$singbox")" = null ]
[ "$(yq -r '.tls.pinSHA256' "$native")" = "$fp" ]
[ "$(stat -c %a "$native")" = 600 ]
[ "$(stat -c %a "$mihomo")" = 600 ]
[ "$(stat -c %a "$singbox")" = 600 ]
parseRealmURI 'realm://a%40b@realm.example:443/id%20one'
[ "$HIHY_REALM_TOKEN" = 'a@b' ] && [ "$HIHY_REALM_ID" = 'id one' ]
addOrUpdateYaml "$backup" realmMode true bool
addOrUpdateYaml "$backup" realmURI 'realm://a%40b@realm.example:443/id%20one' string
generateMihomoYaml >/dev/null; generateSingboxJson >/dev/null
[ "$(yq -r '.outbounds[0].realm.token' "$singbox")" = 'a@b' ]
addOrUpdateYaml "$backup" mimic_status true bool
if generateMihomoYaml >/dev/null 2>&1; then echo 'FAIL: unsupported Mimic export accepted'; exit 1; fi
if generateSingboxJson >/dev/null 2>&1; then echo 'FAIL: unsupported Mimic export accepted'; exit 1; fi
addOrUpdateYaml "$backup" pinSHA256 '' string
addOrUpdateYaml "$backup" insecure true bool
if loadClientParams >/dev/null 2>&1; then echo 'FAIL: unverified TLS export accepted'; exit 1; fi
printf 'PASS: three exporters, typed names, Gecko/ECH, profiles, hopping, Realm, permissions and fail-closed trust\n'
