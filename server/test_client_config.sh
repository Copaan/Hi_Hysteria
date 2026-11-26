#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/server/hy2.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export HIHY_ROOT_DIR="$TMP/root" HIHY_EXPORT_DIR="$TMP/exports"
export HIHY_SUB_ETC="$TMP/sub/etc" HIHY_SUB_STATE="$TMP/sub/state" HIHY_SUB_LIB="$TMP/sub/lib" HIHY_SUB_UNIT="$TMP/sub/service"
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
cp "$singbox" "$TMP/desktop.json"
password='trafficStats acme .key:@/?#% &" with spaces'
addOrUpdateYaml "$conf" auth.password "$password" string
addOrUpdateYaml "$backup" remarks '../../outside/quoted name' string
HIHY_CLIENT_ALLOW_LAN=true subscriptionRenderSnapshot "$HIHY_ROOT_DIR" "$TMP/snapshot" >"$TMP/render.log" 2>&1
[ "$(yq -r '.auth' "$TMP/snapshot/hysteria.yaml")" = "$password" ]
[ "$(yq -r '.proxies[0].password' "$TMP/snapshot/mihomo.yaml")" = "$password" ]
[ "$(yq -r '.outbounds[0].password' "$TMP/snapshot/singbox.json")" = "$password" ]
[ "$(yq -r '.inbounds[0].type' "$TMP/snapshot/singbox.json")" = tun ]
[ "$(yq -r '.route.rules[0].action' "$TMP/snapshot/singbox.json")" = hijack-dns ]
[ "$(yq -r '.experimental.clash_api' "$TMP/snapshot/singbox.json")" = null ]
[ "$(yq -r '.inbounds[0].type' "$TMP/desktop.json")" = mixed ]
[ "$(find "$TMP/snapshot" -type f | wc -l)" -eq 3 ]
[ ! -e "$TMP/outside" ]
for file in "$TMP/snapshot/"*; do [ "$(stat -c %a "$file")" = 600 ]; done
subscriptionWriteCaddyConfig sub.example.test "$(printf '%064d' 1)" "$TMP/Caddyfile"
if subscriptionWriteCaddyConfig 'bad.example;exec' "$(printf '%064d' 1)" "$TMP/bad"; then exit 1; fi
if subscriptionWriteCaddyConfig sub.example.test '../secret' "$TMP/bad"; then exit 1; fi
addOrUpdateYaml "$backup" remarks 123 string
printf 'PASS: complete subscription payloads, app TUN/DNS, desktop preservation, private files and hostile input\n'
parseRealmURI 'realm://a%40b@realm.example:443/id%20one'
[ "$HIHY_REALM_TOKEN" = 'a@b' ] && [ "$HIHY_REALM_ID" = 'id one' ]
addOrUpdateYaml "$backup" realmMode true bool
addOrUpdateYaml "$backup" realmURI 'realm://a%40b@realm.example:443/id%20one' string
generateMihomoYaml >/dev/null; generateSingboxJson >/dev/null
[ "$(yq -r '.outbounds[0].realm.token' "$singbox")" = 'a@b' ]
addOrUpdateYaml "$backup" mimic_status true bool
if subscriptionRenderSnapshot "$HIHY_ROOT_DIR" "$TMP/unsupported" >/dev/null 2>&1; then echo 'FAIL: incompatible subscription accepted'; exit 1; fi
if generateMihomoYaml >/dev/null 2>&1; then echo 'FAIL: unsupported Mimic export accepted'; exit 1; fi
if generateSingboxJson >/dev/null 2>&1; then echo 'FAIL: unsupported Mimic export accepted'; exit 1; fi
addOrUpdateYaml "$backup" pinSHA256 '' string
addOrUpdateYaml "$backup" insecure true bool
if loadClientParams >/dev/null 2>&1; then echo 'FAIL: unverified TLS export accepted'; exit 1; fi
printf 'PASS: three exporters, typed names, Gecko/ECH, profiles, hopping, Realm, permissions and fail-closed trust\n'
