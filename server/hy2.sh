#!/bin/bash
hihyV="ver1.22-secure.1"
# GENERATED FILE — edit server/src/ and run bash scripts/build.sh.
umask 077

HIHY_ROOT_DIR="${HIHY_ROOT_DIR:-/etc/hihy}"
HIHY_BIN_LINK="${HIHY_BIN_LINK:-/usr/bin/hihy}"
HIHY_YQ_BIN="${HIHY_YQ_BIN:-$HIHY_ROOT_DIR/bin/yq}"
HIHY_YQ_VERSION="v4.54.3"
HIHY_CORE_VERSION="${HIHY_CORE_VERSION:-app/v2.14.0}"
HIHY_PID_FILE="${HIHY_PID_FILE:-/var/run/hihy.pid}"
HIHY_RC_LOCAL="${HIHY_RC_LOCAL:-/etc/rc.local}"
HIHY_REMOTE_CONNECT_TIMEOUT="${HIHY_REMOTE_CONNECT_TIMEOUT:-10}"
HIHY_REMOTE_MAX_TIME="${HIHY_REMOTE_MAX_TIME:-180}"
HIHY_DOWNLOAD_RETRIES="${HIHY_DOWNLOAD_RETRIES:-2}"
HIHY_EXPORT_DIR="${HIHY_EXPORT_DIR:-$HIHY_ROOT_DIR/result}"
HIHY_CLIENT_ALLOW_LAN="${HIHY_CLIENT_ALLOW_LAN:-false}"
export HYSTERIA_DISABLE_UPDATE_CHECK=1
if [ -x "$HIHY_YQ_BIN" ]; then
    export PATH="$(dirname "$HIHY_YQ_BIN"):$PATH"
fi
HIHY_RULESET_MIRROR="${HIHY_RULESET_MIRROR:-https://cdn.jsdelivr.net/gh}"
HIHY_SUB_ETC="${HIHY_SUB_ETC:-/etc/hihy-sub}"
HIHY_SUB_STATE="${HIHY_SUB_STATE:-/var/lib/hihy-sub}"
HIHY_SUB_LIB="${HIHY_SUB_LIB:-/usr/local/lib/hihy-sub}"
HIHY_SUB_UNIT="${HIHY_SUB_UNIT:-/etc/systemd/system/hihy-sub.service}"
HIHY_SUB_USER="hihy-sub"
HIHY_CADDY_VERSION="2.11.9"

# ----- 05-security.sh -----

# Emit security errors on stderr without interpreting terminal escapes.
securityError() { printf 'hihy: %s\n' "$*" >&2; return 1; }

# Validate DNS names before using them in configuration or certificate paths.
isValidDomain() {
    local domain="$1" label
    [ ${#domain} -le 253 ] && [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
    local IFS=.
    for label in $domain; do
        [ ${#label} -le 63 ] && [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

isValidSHA256() { [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]; }
isValidFingerprint() { local fp="${1//:/}"; isValidSHA256 "$fp"; }

# Percent-encode UTF-8 bytes for URI components.
urlEncode() {
    local LC_ALL=C input="$1" char i
    for ((i=0; i<${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in [a-zA-Z0-9.~_-]) printf '%s' "$char" ;; *) printf '%%%02X' "'$char" ;; esac
    done
}

# Return a private output path independent of the display name.
clientOutputPath() {
    local remarks="$1" suffix="$2" name digest
    name=$(printf '%s' "$remarks" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '_' | cut -c1-48)
    digest=$(printf '%s' "$remarks" | sha256sum | cut -c1-12)
    mkdir -p "$HIHY_EXPORT_DIR" || return 1
    [ ! -L "$HIHY_EXPORT_DIR" ] || return 1
    chmod 700 "$HIHY_EXPORT_DIR" || return 1
    printf '%s/Hy2-%s-%s-%s\n' "$HIHY_EXPORT_DIR" "${name:-node}" "$digest" "$suffix"
}

secureTempDir() { mktemp -d "${TMPDIR:-/tmp}/hihy.XXXXXXXX"; }

# Tighten files owned by this installation without following symlinks.
secureInstallPermissions() {
    [ -d "$HIHY_ROOT_DIR" ] && [ ! -L "$HIHY_ROOT_DIR" ] || return 1
    find "$HIHY_ROOT_DIR" -type d -exec chmod 700 {} + || return 1
    find "$HIHY_ROOT_DIR" -type f ! -path "$HIHY_ROOT_DIR/bin/*" -exec chmod 600 {} +
}

# A third-party installer is executable only with a reviewed immutable URL/hash.
installWarpVerified() (
    local mode="$1" temp
    [[ "${HIHY_WARP_URL:-}" =~ ^https://gitlab\.com/fscarmen/warp/-/raw/[0-9a-f]{40}/menu\.sh$ ]] \
        && isValidSHA256 "${HIHY_WARP_SHA256:-}" \
        || { securityError '安装 WARP 需要固定提交地址和 SHA256；也可以先自行安装 WARP。'; return 1; }
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    downloadVerifiedFile "$HIHY_WARP_URL" "$temp/menu.sh" "$HIHY_WARP_SHA256" || return 1
    bash -n "$temp/menu.sh" || return 1
    (cd "$temp" && bash ./menu.sh "$mode")
)

# Insert startup commands before an existing exit without replacing user content.
appendRcLocalCommand() {
    local line="$1" file="$HIHY_RC_LOCAL" temp
    [ ! -L "$file" ] || return 1
    [ -f "$file" ] || printf '#!/bin/sh\n' >"$file" || return 1
    grep -Fxq -- "$line" "$file" && return 0
    temp=$(mktemp "$(dirname "$file")/.rc-local.XXXXXXXX") || return 1
    awk -v cmd="$line" '/^[[:space:]]*exit[[:space:]]+0[[:space:]]*$/ && !done { print cmd; done=1 } {print} END {if(!done) print cmd}' "$file" >"$temp" \
        && chmod 700 "$temp" && mv -- "$temp" "$file"
}

# Identify the executable as well as the PID before signalling a process.
isHysteriaPid() {
    local pid="$1" executable
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    executable=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    [[ "$executable" = "$HIHY_ROOT_DIR/bin/appS" || "$executable" = "$HIHY_ROOT_DIR/bin/appS (deleted)" ]]
}

# Decode percent escapes without evaluating backslashes from user input.
urlDecode() {
    local input="$1" prefix rest hex
    while [[ "$input" = *%* ]]; do
        prefix="${input%%\%*}"; printf '%s' "$prefix"
        rest="${input#*%}"; hex="${rest:0:2}"
        [[ "$hex" =~ ^[[:xdigit:]]{2}$ ]] || return 1
        printf '%b' "\x$hex"
        input="${rest:2}"
    done
    printf '%s' "$input"
}

# Remove only the exact scheduled entry installed by hihy.
removeHihyCron() (
    local temp
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    if crontab -l >"$temp/before" 2>/dev/null; then
        grep -Fxv -e "15 4 * * 1 $HIHY_BIN_LINK cronTask" -e '15 4 * * 1 hihy cronTask' "$temp/before" >"$temp/after" || [ $? -eq 1 ] || return 1
        crontab "$temp/after"
    fi
)

# Stage the pinned default masquerade site; extract only reviewed regular files.
prepareMasqueradeFiles() (
    local destination="$1" temp prefix='mikutap-fb292bc1c3b3a29d80feaac2dbe93fca981776ee/' name
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    downloadVerifiedFile 'https://codeload.github.com/HFIProgramming/mikutap/tar.gz/fb292bc1c3b3a29d80feaac2dbe93fca981776ee' "$temp/site.tar.gz" d3fab27fbc3de256d50aea4325094fefbf6bdaa4c693f4a16619dc1c74df355d || return 1
    tar -tzf "$temp/site.tar.gz" >"$temp/names" || return 1
    while IFS= read -r name; do
        case "$name" in "$prefix"*) ;; *) return 1 ;; esac
        case "/$name/" in */../*|*/./*) return 1 ;; esac
    done <"$temp/names"
    tar -tvzf "$temp/site.tar.gz" >"$temp/types" || return 1
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' "$temp/types" || return 1
    mkdir -p "$destination" && [ ! -L "$destination" ] || return 1
    tar -xzf "$temp/site.tar.gz" -C "$destination" --strip-components=1 --no-same-owner --no-same-permissions || return 1
    find "$destination" -type f -exec chmod 600 {} +
    find "$destination" -type d -exec chmod 700 {} +
)

# ----- 10-messages.sh -----
# 按固定键读取内置中文文案。
messageTemplate() {
    case "${1:-}" in
        acl_action_prompt) printf '%s' '请选择管理操作:' ;;
        acl_choice_add) printf '%s' '1) 添加' ;;
        acl_choice_delete) printf '%s' '2) 删除' ;;
        acl_choice_reject_suffix) printf '%s' '3) 添加屏蔽域名' ;;
        acl_choice_v4_suffix) printf '%s' '1) 添加域名ipv4分流' ;;
        acl_choice_v6_suffix) printf '%s' '2) 添加域名ipv6分流' ;;
        acl_choice_view) printf '%s' '3) 查看' ;;
        acl_control_method_title) printf '%s' '请选择ACL控制方式' ;;
        acl_current_list) printf '%s' '当前ACL列表:' ;;
        acl_delete_rule_prompt) printf '%s' '请输入要删除的域名规则: ' ;;
        acl_file_not_found) printf '%s' '未找到acl文件' ;;
        acl_reject_domain_prompt) printf '%s' '请输入要屏蔽的域名: ' ;;
        acl_rule_exists) printf '%s' '规则已存在' ;;
        acl_rule_not_exists) printf '%s' '规则不存在' ;;
        acl_v4_domain_prompt) printf '%s' '请输入要分流ipv4的域名: ' ;;
        acl_v6_domain_prompt) printf '%s' '请输入要分流ipv6的域名: ' ;;
        acme_cert_fail) printf '%s' '域名:%s,申请证书失败!请重新安装使用自签证书.' ;;
        acme_incomplete_state) printf '%s' '当前安装处于未完成状态，可修正问题后重新执行安装，或执行卸载进行清理。' ;;
        acme_summary) printf '%s' '解析正确,使用hysteria内置ACME申请证书.域名:' ;;
        add_success) printf '%s' '添加成功' ;;
        addr_cannot_be_empty) printf '%s' '地址不能为空' ;;
        already_installed) printf '%s' '你已经成功安装hysteria,如需修改配置请使用选项9/12' ;;
        already_latest_version) printf '%s' '已经是最新版本,忽略。' ;;
        arch_detected_setup) printf '%s' '检测到 Arch Linux。正在使用 systemd 设置 rc.local...' ;;
        arch_detected_uninstall) printf '%s' '检测到 Arch Linux。正在卸载 rc.local systemd 服务...' ;;
        arch_rc_local_setup_done) printf '%s' 'rc.local 已通过 systemd 设置并启动。' ;;
        arch_rc_local_uninstall_done) printf '%s' 'rc.local systemd 服务已卸载。' ;;
        auth_secret_label) printf '%s' '认证口令:' ;;
        auth_secret_prompt) printf '%s' '(8/13)请输入认证口令(默认随机生成UUID作为密码,建议使用强密码):' ;;
        auto_env_hint) printf '%s' '可选环境变量覆盖：HIHY_AUTO_PORT、HIHY_AUTO_PASSWORD、HIHY_AUTO_DOMAIN、HIHY_AUTO_IP、HIHY_AUTO_MASQUERADE、HIHY_AUTO_PORT_HOPPING、HIHY_AUTO_HOP_START/END、HIHY_AUTO_REMARKS、HIHY_AUTO_ECH、HIHY_AUTO_ECH_PUBLIC_NAME、HIHY_AUTO_MIMIC' ;;
        auto_hop_invalid) printf '%s' '端口跳跃范围无效: %s-%s' ;;
        auto_install_title) printf '%s' '一键安装：自动生成配置（零交互）...' ;;
        auto_ip_detect_failed) printf '%s' '公网 IP 探测失败。请设置 HIHY_AUTO_IP=<你的IP> 后重试。' ;;
        auto_port_busy) printf '%s' 'UDP 端口 %s 不可用（被占用）。请将 HIHY_AUTO_PORT 设置为空闲端口后重试。' ;;
        auto_port_invalid) printf '%s' 'HIHY_AUTO_PORT 无效: %s（需要 1-65535）' ;;
        auto_summary_cert) printf '%s' '证书: 自签（客户端通过 pinSHA256 指纹校验，安全）' ;;
        auto_summary_congestion) printf '%s' '拥塞控制: BBR（标准）' ;;
        auto_summary_ech_off) printf '%s' 'ECH: 未启用' ;;
        auto_summary_ech_on) printf '%s' 'ECH: 启用(公开域名 %s)' ;;
        auto_summary_hopping_off) printf '%s' '端口跳跃: 未启用' ;;
        auto_summary_hopping_on) printf '%s' '端口跳跃: %s' ;;
        auto_summary_masquerade_off) printf '%s' '伪装: 未启用' ;;
        auto_summary_masquerade_on) printf '%s' '伪装: proxy -> %s' ;;
        auto_summary_mimic_off) printf '%s' 'Mimic(伪装 TCP): 未启用' ;;
        auto_summary_mimic_on) printf '%s' 'Mimic(伪装 TCP): 启用(已强制关闭端口跳跃)' ;;
        auto_summary_password) printf '%s' '认证密码: %s' ;;
        auto_summary_port) printf '%s' '端口: %s' ;;
        auto_summary_sni) printf '%s' '自签证书 SNI: %s' ;;
        auto_summary_title) printf '%s' '自动生成的配置：' ;;
        bandwidth_expectation) printf '%s' '期望速度,这是客户端在 Brutal 模式下使用的目标带宽。脚本会自动*1.10做冗余，带宽不要高于真实链路极限，否则反而可能更不稳定!' ;;
        bandwidth_invalid_error) printf '%s' '数值无效：请输入正整数。' ;;
        bbr_choice_aggressive) printf '%s' '3、高级(aggressive)' ;;
        bbr_choice_conservative) printf '%s' '1、初级(conservative)' ;;
        bbr_choice_standard) printf '%s' '2、中级(standard，默认)' ;;
        bbr_profile_aggressive) printf '%s' '3、激进 / aggressive：更激进，更积极抢占带宽，适合链路质量较好、追求更高吞吐的场景，但波动时可能更敏感' ;;
        bbr_profile_conservative) printf '%s' '1、保守 / conservative：更保守，收敛更稳，适合链路波动较大、网络质量一般、优先稳定性的场景' ;;
        bbr_profile_prompt) printf '%s' '请选择 BBR 预设等级:' ;;
        bbr_profile_standard) printf '%s' '2、均衡 / standard(默认)：官方默认预设，速度与稳定性更均衡，适合大多数 VPS 和家庭宽带环境' ;;
        bbr_profile_title) printf '%s' 'BBR 提供三档调节方式，适合不同网络环境：' ;;
        block_http3_choice_enable) printf '%s' '1、启用(推荐)' ;;
        block_http3_choice_skip) printf '%s' '2、跳过(默认)' ;;
        block_http3_disabled) printf '%s' '您选择不屏蔽http3流量，这会导致访问使用QUIC连接的网站无hy2增强效果' ;;
        block_http3_enabled) printf '%s' '您选择屏蔽http3流量，请根据自己使用的客户端，屏蔽QUIC/HTTP3流量，否则会导致对使用QUIC的网站连接失败' ;;
        block_http3_hint1) printf '%s' '如果开启此选项，hysteria2将不会代理udp/443，无法使用QUIC连接访问网站，并且需要在客户端配置中禁用QUIC连接，否则会导致连接失败。' ;;
        block_http3_hint2) printf '%s' '也可以仅在客户端屏蔽QUIC/HTTP3/UDP 443连接，服务器不做屏蔽，效果一样' ;;
        block_http3_prompt) printf '%s' '(12/13)是否在服务器屏蔽http3流量(hysteria对udp流量拥塞控制无增强效果，导致访问youtube等使用QUIC连接的网站效果不佳):' ;;
        cert_ca_cert) printf '%s' '生成 CA 证书...' ;;
        cert_ca_key) printf '%s' '生成 CA 私钥...' ;;
        cert_choice_acme) printf '%s' '1、使用ACME申请(需打开tcp/80端口)' ;;
        cert_choice_dns) printf '%s' '4、dns验证' ;;
        cert_choice_local) printf '%s' '2、使用本地证书文件' ;;
        cert_choice_selfsigned) printf '%s' '3、自签证书(默认,推荐:已通过pinSHA256指纹校验,安全且无需域名/80端口)' ;;
        cert_cleanup) printf '%s' '清理临时文件...' ;;
        cert_fingerprint_fail) printf '%s' '未能计算证书指纹,将回退为不安全连接(insecure=1)模式。' ;;
        cert_generating_start) printf '%s' '开始生成自签名证书...' ;;
        cert_move_ca) printf '%s' '移动 CA 证书到结果目录...' ;;
        cert_pinsha256_hint) printf '%s' '客户端将通过 pinSHA256 校验该指纹,默认不再开启不安全连接(insecure)。' ;;
        cert_prompt_title) printf '%s' '(1/11)请选择证书申请方式:' ;;
        cert_server_key_csr) printf '%s' '生成服务器私钥和 CSR...' ;;
        cert_sha256_label) printf '%s' '证书 SHA-256 指纹: ' ;;
        cert_sign_server) printf '%s' '使用 CA 签署服务器证书...' ;;
        cert_success) printf '%s' '证书生成成功！' ;;
        change_config_install_first) printf '%s' '请先安装hysteria2,再去修改配置...' ;;
        change_config_success) printf '%s' '配置修改成功' ;;
        client_config_copy_marker) printf '%s' 'COPY' ;;
        client_config_done) printf '%s' '✅ 配置生成完成!' ;;
        client_config_fingerprint_label) printf '%s' '   证书指纹: %s' ;;
        client_config_generating) printf '%s' '📝 生成客户端配置文件...' ;;
        client_config_hysteria_not_installed) printf '%s' 'hysteria2 未安装!' ;;
        client_config_info_title) printf '%s' '✨ 配置信息如下:' ;;
        client_config_masquerade_address) printf '%s' '🌐 1、伪装地址: %s' ;;
        client_config_masquerade_h3_action) printf '%s' '手动在浏览器添加h3' ;;
        client_config_masquerade_h3_hint) printf '%s' '💡 您可能需要%s支持才能访问' ;;
        client_config_masquerade_tcp_not_listened) printf '%s' '⚠️  注意: 伪装并未监听tcp端口' ;;
        client_config_masquerade_trust_hint) printf '%s' '   如需在浏览器访问伪装网站,可自行信任证书或设置 hosts 指向该域名。' ;;
        client_config_mimic_warning1) printf '%s' '1. 客户端必须是 Linux 设备(软路由/OpenWrt/Linux 主机)。Windows/macOS/Android/iOS 无法使用 mimic。' ;;
        client_config_mimic_warning2) printf '%s' '2. 客户端必须以 root 运行,PATH 中有 mimic 可执行文件,并已加载 mimic 内核模块(modprobe mimic)。' ;;
        client_config_mimic_warning3) printf '%s' '3. 两端都必须启用 mimic;未启用的客户端收不到任何响应(看起来像网络故障)。端口跳跃已关闭。' ;;
        client_config_mimic_warning_title) printf '%s' '⚠️ 已启用 Mimic(伪装 TCP) — 客户端硬性要求:' ;;
        client_config_native_file_realm) printf '%s' '📄 2、[推荐] [Nekoray/V2rayN/NekoBoxforAndroid]原生配置文件,更新最快、参数最全、效果最好。文件地址: %s' ;;
        client_config_native_file_standard) printf '%s' '📄 3、[推荐] [Nekoray/V2rayN/NekoBoxforAndroid]原生配置文件,更新最快、参数最全、效果最好。文件地址: %s' ;;
        client_config_pinsha256_safe_hint) printf '%s' '🔒 您使用自签证书,客户端已通过 %s 校验证书指纹,连接安全,无需开启不安全连接(insecure)。' ;;
        client_config_realm_client_support_warning) printf '%s' '⚠ 请确保您的客户端支持Hysteria2 Realm模式' ;;
        client_config_realm_mode_desc) printf '%s' '🌐 Realm模式 - 服务器通过P2P打洞连接,无需公网IP和端口' ;;
        client_config_realm_rendezvous_label) printf '%s' '🔗 1、牵手地址:' ;;
        client_config_realm_server_password) printf '%s' '客户端配置中server字段使用上述牵手地址,认证密码为: %s' ;;
        client_config_realm_share_link_title) printf '%s' '🔗 2、[hysteria2+realm 分享链接] 适用于支持 Realm URI 的客户端:
' ;;
        client_config_security_tip_title) printf '%s' '🔐 安全提示:' ;;
        client_config_security_warning_title) printf '%s' '⚠️  安全提示:' ;;
        client_config_selfsigned_verify_hint) printf '%s' '🔒 您使用自签证书,如需要验证伪装网站:' ;;
        client_config_selfsigned_verify_step1) printf '%s' '   1. 自行修改浏览器信任证书' ;;
        client_config_selfsigned_verify_step2) printf '%s' '   2. 设置hosts使IP指向该域名' ;;
        client_config_server_version) printf '%s' '📌 当前hysteria2 server版本: %s' ;;
        client_config_share_link_title) printf '%s' '🔗 2、[v2rayN-Windows/v2rayN-Andriod/nekobox/passwall/Shadowrocket]分享链接:
' ;;
        client_config_tutorial_link) printf '%s' '客户端使用教程: https://github.com/Copaan/Hi_Hysteria/blob/main/md/client.md' ;;
        client_mihomo_file_hint) printf '%s' '📱 [Clash Verge Rev / FlClash / ClashMeta安卓版 / OpenClash] mihomo 配置文件: %s' ;;
        client_mihomo_gecko_skip) printf '%s' '提示: mihomo 不支持 gecko 混淆，请使用原生配置或 sing-box，已跳过 mihomo 配置。' ;;
        client_mihomo_mimic_skip) printf '%s' '提示: mihomo 不支持 mimic,请使用 Linux 上的 Hysteria 原生客户端。已跳过 mihomo 配置。' ;;
        client_only_block_http3_tip) printf '%s' 'Tip: 建议在客户端开启屏蔽QUIC/HTTP3/UDP 443此选项以获得更好的访问体验。' ;;
        client_singbox_bbr_profile_note) printf '%s' 'BBR profile「%s」需要 sing-box 1.14 或更新版本。' ;;
        client_singbox_file_hint) printf '%s' '📦 [sing-box / SFA / SFI / SFM / SFT] sing-box 配置文件: %s' ;;
        client_singbox_mimic_skip) printf '%s' '提示: sing-box 不支持 mimic,请使用 Linux 上的 Hysteria 原生客户端。已跳过 sing-box 配置。' ;;
        client_singbox_realm_beta_warning) printf '%s' 'Realm 需要 sing-box 1.14 或更新版本；本轮兼容验证基线为 1.14.4。' ;;
        client_singbox_version_hint) printf '%s' '兼容验证基线：sing-box 1.14.4；Realm、Gecko 和 BBR profile 需要 1.14+。' ;;
        cloudflare_token_prompt) printf '%s' '请输入cloudflare_api_token:' ;;
        cmd_title_acl) printf '%s' '12) ACL 管理' ;;
        cmd_title_autoinstall) printf '%s' '一键安装 hysteria2（零交互）...' ;;
        cmd_title_install) printf '%s' '1) 安装 hysteria2' ;;
        cmd_title_logs) printf '%s' '14) 查看实时日志' ;;
        cmd_title_reconfigure) printf '%s' '9) 重新配置' ;;
        cmd_title_restart) printf '%s' '5) 重新启动 hysteria' ;;
        cmd_title_socks5) printf '%s' '15) 添加 socks5 出站' ;;
        cmd_title_start) printf '%s' '3) 启动 hysteria' ;;
        cmd_title_status) printf '%s' '6) 运行状态' ;;
        cmd_title_stop) printf '%s' '4) 暂停 hysteria' ;;
        cmd_title_switch_ip_priority) printf '%s' '10) 切换 ipv4/ipv6 优先级' ;;
        cmd_title_traffic_stats) printf '%s' '13) 查看 hysteria 统计信息' ;;
        cmd_title_uninstall) printf '%s' '2) 卸载 hysteria' ;;
        cmd_title_update_core) printf '%s' '7) 更新 Core' ;;
        cmd_title_update_hihy) printf '%s' '11) 更新 hihy' ;;
        cmd_title_view_config) printf '%s' '8) 查看当前配置' ;;
        config_executing) printf '%s' '执行配置...' ;;
        config_file_not_found) printf '%s' '未找到配置文件' ;;
        config_input_done) printf '%s' '配置录入完成!' ;;
        config_start_title) printf '%s' '开始配置:' ;;
        congestion_bbr_hint) printf '%s' 'BBR: 更积极，通常吞吐更高，适合追求速度的场景' ;;
        congestion_brutal_hint) printf '%s' 'Brutal: Hysteria 2 独享特色，固定速率模型，在恶劣网络环境下通常更值得优先尝试，尤其适合已知链路真实带宽、希望获得更强抗抖动和抢带宽能力的场景' ;;
        congestion_choice_bbr) printf '%s' '2、BBR(均衡)' ;;
        congestion_choice_brutal) printf '%s' '3、Brutal(激进,默认)' ;;
        congestion_choice_reno) printf '%s' '1、Reno(保守)' ;;
        congestion_reno_hint) printf '%s' 'Reno: 更保守、更稳，适合优先考虑兼容性和稳定性的场景' ;;
        congestion_selected_bbr) printf '%s' '您选择的拥塞控制模式: BBR / BBR预设: ' ;;
        congestion_selected_brutal) printf '%s' '您选择的拥塞控制模式: Brutal' ;;
        congestion_selected_reno) printf '%s' '您选择的拥塞控制模式: Reno' ;;
        congestion_title) printf '%s' '(4/13)请选择拥塞控制模式:' ;;
        core_download_invalid) printf '%s' '下载的内核不是有效的二进制文件（镜像返回了错误页？）。已保留旧内核，请重试。' ;;
        core_downloading) printf '%s' '下载中...' ;;
        delay_label) printf '%s' '延迟:' ;;
        delay_prompt) printf '%s' '(5/13)请输入您到此服务器的平均延迟,用于 Brutal 模式下估算 QUIC 窗口(默认200,单位:ms):' ;;
        delete_success) printf '%s' '删除成功' ;;
        detecting_domain_dns) printf '%s' '检测%s,DNS解析...' ;;
        dns_acme_summary) printf '%s' '您选择使用acme dns验证申请证书: ' ;;
        dns_choice_cloudflare) printf '%s' '1、Cloudflare(默认)' ;;
        dns_choice_duckdns) printf '%s' '2、Duck DNS' ;;
        dns_choice_gandi) printf '%s' '3、Gandi.net' ;;
        dns_choice_godaddy) printf '%s' '4、Godaddy' ;;
        dns_choice_vultr) printf '%s' '5、Vultr' ;;
        dns_method_label) printf '%s' 'dns验证方式: ' ;;
        dns_provider_prompt) printf '%s' '请选择DNS服务商:' ;;
        dns_resolution_failed) printf '%s' '域名解析失败,没有获得任何dns记录(A/AAAA),请检查域名是否正确解析到本机!' ;;
        dns_selected_cloudflare) printf '%s' '您选择Cloudflare DNS验证' ;;
        dns_selected_duckdns) printf '%s' '您选择Duck DNS DNS验证' ;;
        dns_selected_gandi) printf '%s' '您选择Gandi.net DNS验证' ;;
        dns_selected_godaddy) printf '%s' '您选择Godaddy DNS验证' ;;
        dns_selected_vultr) printf '%s' '您选择Vultr DNS验证' ;;
        domain_cannot_be_empty) printf '%s' '域名不能为空' ;;
        domain_ip_label) printf '%s' '域名ip: ' ;;
        domain_ip_mismatch) printf '%s' '域名解析到的ip与本机ip不一致,请重新输入!' ;;
        domain_label) printf '%s' '域名: ' ;;
        domain_prompt) printf '%s' '请输入域名:' ;;
        domain_requirement) printf '%s' '(需正确解析到本机,关闭CDN)' ;;
        download_completed) printf '%s' '下载完成。' ;;
        download_label) printf '%s' '客户端下行速度：' ;;
        download_prompt) printf '%s' '(6/13)请输入客户端期望的下行速度:(默认50,单位:mbps):' ;;
        download_yq_failed_network) printf '%s' '下载 yq 失败: wget/curl 下载异常。' ;;
        download_yq_failed_no_tool) printf '%s' '下载 yq 失败: 未找到 wget 或 curl。' ;;
        downloading_yq) printf '%s' '正在下载 yq (%s)...' ;;
        duckdns_override_prompt) printf '%s' '请输入Duck DNS duckdns_override_domain:' ;;
        duckdns_token_prompt) printf '%s' '请输入Duck DNS duckdns_api_token:' ;;
        ech_choice_disable_default) printf '%s' '1、不启用(默认)' ;;
        ech_choice_enable) printf '%s' '2、启用' ;;
        ech_core_too_old) printf '%s' '本地 hysteria 内核 %s 不支持 ECH(需 v2.10.0+),将不启用 ECH 继续;可先更新内核(选项7)再重新配置(选项9)开启' ;;
        ech_disabled_label) printf '%s' 'ECH: 不启用' ;;
        ech_hint1) printf '%s' 'Tips: ECH 会加密 TLS 握手中的 SNI,中间设备只能看到用作幌子的公开域名,看不到真实域名' ;;
        ech_hint2) printf '%s' '注意: 开启混淆后整条连接本就无法被识别为 QUIC,ECH 在混淆之上收益不大' ;;
        ech_keygen_failed) printf '%s' 'ECH 密钥生成失败(需要支持 X25519 的 openssl),将不启用 ECH 继续' ;;
        ech_keygen_success) printf '%s' 'ECH 密钥对已生成(公开域名: %s),客户端配置将自动携带 ECH 配置' ;;
        ech_prompt) printf '%s' '是否启用 ECH(加密 ClientHello)? 需要 hysteria 内核 v2.10.0+:' ;;
        ech_public_name_label) printf '%s' 'ECH 公开域名: ' ;;
        ech_public_name_prompt) printf '%s' '请输入 ECH 公开域名(明文出现的幌子 SNI,选一个看起来无害的域名即可,不必是你的域名),回车默认 www.microsoft.com:' ;;
        end_port_label) printf '%s' '结束端口:' ;;
        enter_local_ip) printf '%s' '请自行输入本机ip:' ;;
        entered_port_label) printf '%s' '您输入的端口:' ;;
        error_input_error) printf '%s' '输入错误 !!!' ;;
        error_root_required) printf '%s' '请使用 root 权限运行此脚本!' ;;
        firewall_firewalld_delete) printf '%s' 'FIREWALLD DELETE: %s' ;;
        firewall_firewalld_open) printf '%s' 'FIREWALLD OPEN: %s/%s' ;;
        firewall_firewalld_open_fail) printf '%s' 'FIREWALLD OPEN FAIL: %s/%s' ;;
        firewall_iptables_delete) printf '%s' 'IPTABLES DELETE: %s' ;;
        firewall_iptables_open) printf '%s' 'IPTABLES OPEN: %s/%s' ;;
        firewall_nftables_open) printf '%s' 'NFTABLES OPEN: %s/%s' ;;
        firewall_ufw_delete) printf '%s' 'UFW DELETE: %s' ;;
        firewall_ufw_open) printf '%s' 'UFW OPEN: %s' ;;
        firewall_ufw_open_fail) printf '%s' 'UFW OPEN FAIL: %s' ;;
        fixed_hop_interval_error) printf '%s' '固定跳跃间隔格式错误,请输入不小于5s的秒数,例如30s' ;;
        fixed_hop_interval_label) printf '%s' '固定跳跃间隔:' ;;
        fixed_hop_interval_prompt) printf '%s' '请输入固定跳跃间隔(默认30s, 不能低于5s):' ;;
        fixed_hop_interval_summary) printf '%s' '固定跳跃间隔: ' ;;
        gandi_token_prompt) printf '%s' '请输入Gandi gandi_api_token:' ;;
        generating_config) printf '%s' 'Generating config...' ;;
        godaddy_token_prompt) printf '%s' '请输入Godaddy godaddy_api_token:' ;;
        hihy_cmd_install_fail) printf '%s' 'hihy 命令安装失败,请检查网络或写入权限后重试.' ;;
        hihy_update_complete) printf '%s' 'hihy更新完成。' ;;
        hysteria_core_not_found) printf '%s' 'Hysteria 核心未找到。' ;;
        hysteria_core_update_done) printf '%s' 'Hysteria 核心更新完成。' ;;
        hysteria_not_installed) printf '%s' 'Hysteria 未安装!' ;;
        input_error_please_retry) printf '%s' '输入错误,请重新输入:' ;;
        input_error_retry) printf '%s' '输入错误,请重新输入...' ;;
        install_auto_mode) printf '%s' '自动模式：零交互安装 Hysteria2...' ;;
        install_done) printf '%s' '安装完毕' ;;
        install_downloading_hihy) printf '%s' '正在下载 hihy...' ;;
        install_enter_number) printf '%s' '输入序号:' ;;
        install_hihy_launch_failed) printf '%s' 'hihy 启动失败，请检查下载结果或稍后重试' ;;
        install_hysteria1_option) printf '%s' '2、hysteria1(NLTS,未来无功能更新,但支持faketcp.被UDP QoS可以选择)' ;;
        install_hysteria2_option) printf '%s' '1、hysteria2(推荐,LTS性能更好)' ;;
        install_ready) printf '%s' '准备安装。' ;;
        install_select_hysteria_version) printf '%s' '请选择安装的hysteria版本:' ;;
        install_selected_version) printf '%s' '您选择的hysteria版本为: %s' ;;
        install_success) printf '%s' '安装成功,请查看下方配置详细信息' ;;
        ip_correct_default) printf '%s' '1、正确(默认)' ;;
        ip_incorrect) printf '%s' '2、不正确,手动输入ip' ;;
        ip_priority_already_auto) printf '%s' '当前已经是自动选择模式' ;;
        ip_priority_already_ipv4) printf '%s' '当前已经是ipv4优先模式' ;;
        ip_priority_already_ipv6) printf '%s' '当前已经是ipv6优先模式' ;;
        ip_priority_choice_auto) printf '%s' '3) 自动选择' ;;
        ip_priority_choice_ipv4) printf '%s' '1) ipv4优先' ;;
        ip_priority_choice_ipv6) printf '%s' '2) ipv6优先' ;;
        ip_priority_current_mode) printf '%s' '当前模式: %s' ;;
        ip_priority_socks5_active_error) printf '%s' '当前已经开启socks5转发,不支持修改优先级,如需分流请使用ACL管理' ;;
        ip_prompt) printf '%s' '请输入正确的公网ip(ipv6地址不需要加[]):' ;;
        latest_hysteria_version) printf '%s' '最新 hysteria 版本:' ;;
        local_cert_domain_prompt) printf '%s' '请输入所选证书域名:' ;;
        local_cert_label) printf '%s' 'cert文件路径: ' ;;
        local_cert_path_prompt) printf '%s' '请输入证书cert文件路径(需fullchain cert,提供完整证书链):' ;;
        local_cert_summary) printf '%s' '您已选择本地证书加密.域名:' ;;
        local_core_version) printf '%s' '本地核心版本:' ;;
        local_ip_fetch_failed) printf '%s' '获取本机ip失败,请检查网络连接!curl -s -m 8 ip.sb' ;;
        local_ip_label) printf '%s' '本机ip: ' ;;
        local_key_label) printf '%s' 'key文件路径: ' ;;
        local_key_path_prompt) printf '%s' '请输入证书key文件路径:' ;;
        logs_follow_hint) printf '%s' '正在跟踪日志 — 按 Ctrl+C 返回。' ;;
        logs_not_found) printf '%s' '日志文件不存在!' ;;
        losscomp_choice_disable) printf '%s' '2、关闭速率补偿' ;;
        losscomp_choice_keep_default) printf '%s' '1、保持开启(默认)' ;;
        losscomp_core_too_old) printf '%s' '提示: 本地 hysteria 内核 %s 会忽略 bandwidth.disableLossCompensation(需 v2.10.0+)。配置已写入,但要等更新内核(选项7)后才会生效' ;;
        losscomp_disabled_label) printf '%s' '速率补偿: 已关闭' ;;
        losscomp_hint) printf '%s' 'Tips: Brutal 会根据丢包情况补偿发送速率,某些线路上关闭补偿(bandwidth.disableLossCompensation)可以提升稳定性' ;;
        losscomp_kept_label) printf '%s' '速率补偿: 保持开启(默认)' ;;
        losscomp_prompt) printf '%s' '是否关闭 Brutal 速率补偿机制? (hysteria 内核 v2.10.0+)' ;;
        masquerade_choice_disable) printf '%s' '1、不启用（默认，不伪装网站内容）' ;;
        masquerade_choice_file) printf '%s' '4、file(作为一个静态文件服务器，从一个目录提供内容。目录内必须含有index.html)' ;;
        masquerade_choice_proxy) printf '%s' '3、proxy(作为一个反向代理，从另一个网站提供内容。)' ;;
        masquerade_choice_string) printf '%s' '2、string(返回一个固定的字符串)' ;;
        masquerade_disabled_selected) printf '%s' '已选择：不启用伪装' ;;
        masquerade_file_hint) printf '%s' '默认预览: https://hfiprogramming.github.io/mikutap/' ;;
        masquerade_file_label) printf '%s' '伪装网站文件目录:' ;;
        masquerade_file_prompt) printf '%s' '请输入本地网站目录（默认 /etc/hihy/file：下载固定提交并校验摘要的 mikutap）：' ;;
        masquerade_prompt) printf '%s' '(10/13)伪装网站：将端口伪装成正常的 HTTPS 站点。请选择模式:' ;;
        masquerade_proxy_hint) printf '%s' '反代该网址但不会替换网页内域名' ;;
        masquerade_proxy_label) printf '%s' '伪装代理地址:' ;;
        masquerade_proxy_prompt) printf '%s' '请输入伪装代理地址(默认:https://www.helloworld.org):' ;;
        masquerade_string_label) printf '%s' '伪装字符串:' ;;
        masquerade_string_prompt) printf '%s' '请输入伪装字符串(默认:HelloWorld):' ;;
        masquerade_stuff_label) printf '%s' 'http伪装标头content-stuff:' ;;
        masquerade_stuff_prompt) printf '%s' '请输入http伪装标头content-stuff(默认:HelloWorld):' ;;
        masquerade_tcp_choice_enable) printf '%s' '1、启用(默认)' ;;
        masquerade_tcp_choice_skip) printf '%s' '2、跳过' ;;
        masquerade_tcp_disabled) printf '%s' '您选择不监听tcp/%s端口' ;;
        masquerade_tcp_enabled) printf '%s' '您选择同时监听tcp/%s端口' ;;
        masquerade_tcp_hint1) printf '%s' '通常网站支持 HTTP/3 的只是将其作为一个升级选项' ;;
        masquerade_tcp_hint2) printf '%s' '监听一个tcp端口来提供伪装内容,使伪装更加自然,如果不启用此选项,浏览器将在不启用H3功能下访问不了伪装内容' ;;
        masquerade_tcp_prompt) printf '%s' '(11/13)是否同时监听tcp/%s端口来增强伪装行为(做戏做全套):' ;;
        max_hop_interval_error) printf '%s' '最大跳跃间隔格式错误,请输入大于等于最小间隔的秒数,例如30s' ;;
        max_hop_interval_label) printf '%s' '最大跳跃间隔:' ;;
        max_hop_interval_prompt) printf '%s' '请输入最大跳跃间隔(默认30s, 需大于等于最小间隔):' ;;
        menu_hint_hihy_cmd) printf '%s' '提示: 运行 %s 命令再次执行本脚本.' ;;
        menu_item_acl) printf '%s' 'ACL 域名分流' ;;
        menu_item_autoinstall) printf '%s' '一键安装（零交互）' ;;
        menu_item_exit) printf '%s' '退出' ;;
        menu_item_install) printf '%s' '安装 hysteria2（交互向导）' ;;
        menu_item_logs) printf '%s' '实时日志' ;;
        menu_item_reconfigure) printf '%s' '重新配置' ;;
        menu_item_restart) printf '%s' '重启' ;;
        menu_item_socks5) printf '%s' 'SOCKS5 出站（支持 WARP）' ;;
        menu_item_start) printf '%s' '启动' ;;
        menu_item_status) printf '%s' '运行状态' ;;
        menu_item_stop) printf '%s' '停止' ;;
        menu_item_switch_ip) printf '%s' '切换 IPv4/IPv6 优先级' ;;
        menu_item_traffic) printf '%s' '流量统计' ;;
        menu_item_uninstall) printf '%s' '卸载' ;;
        menu_item_update_core) printf '%s' '更新 Hysteria 内核' ;;
        menu_item_update_hihy) printf '%s' '更新 hihy 脚本' ;;
        menu_item_view_config) printf '%s' '查看客户端配置' ;;
        menu_option_exit) printf '%s' '0) 退出' ;;
        menu_prompt_choice) printf '%s' '请选择: ' ;;
        menu_section_config) printf '%s' '配置' ;;
        menu_section_deploy) printf '%s' '部署' ;;
        menu_section_maintain) printf '%s' '维护' ;;
        menu_section_service) printf '%s' '服务' ;;
        menu_status_core) printf '%s' '内核:' ;;
        menu_status_not_installed) printf '%s' '未安装' ;;
        menu_status_running) printf '%s' '运行中' ;;
        menu_status_stopped) printf '%s' '已停止' ;;
        menu_title) printf '%s' 'Hi Hysteria' ;;
        menu_wait_continue) printf '%s' '按任意键返回主菜单...' ;;
        mimic_choice_disable_default) printf '%s' '1、不启用(默认)' ;;
        mimic_choice_enable) printf '%s' '2、启用' ;;
        mimic_core_too_old) printf '%s' '本地 hysteria 内核 %s 不支持 mimic(需 v2.12.0+),将不启用 mimic 继续;可先更新内核(选项7)再重新配置(选项9)开启' ;;
        mimic_disabled_label) printf '%s' 'Mimic: 不启用' ;;
        mimic_enabled_label) printf '%s' 'Mimic: 启用' ;;
        mimic_hint1) printf '%s' 'Tip: Mimic 通过 eBPF 把 UDP 包改写成 TCP 外观,适合限制/封锁 UDP 的网络。文档: https://v2.hysteria.network/zh/docs/advanced/Mimic/' ;;
        mimic_hint2) printf '%s' '警告: 客户端必须是支持 root 的 Linux 设备(如软路由)。服务端由脚本自动下载安装 mimic;客户端需手动安装,方法见 https://github.com/hack3ric/mimic/blob/master/docs/getting-started.md (完整命令行说明见 mimic(1))。Windows/手机客户端将无法连接。' ;;
        mimic_hint3) printf '%s' '注意: Mimic 不能与端口跳跃同时使用,启用后将跳过端口跳跃。需要 hysteria 内核 v2.12.0+。' ;;
        mimic_module_load_fail) printf '%s' '警告: mimic 内核模块加载失败(modprobe mimic)。请确认内核 >= 6.1 且已安装 mimic 内核模块(DKMS/insmod),否则服务端无法启动' ;;
        mimic_prompt) printf '%s' '(3/13)是否启用 Mimic(伪装 TCP)?默认关闭。仅 Linux+root 客户端可用。' ;;
        mimic_skip_port_hopping) printf '%s' '已启用 Mimic:与端口跳跃不兼容,跳过端口跳跃设置。' ;;
        min_hop_interval_error) printf '%s' '最小跳跃间隔格式错误,请输入不小于5s的秒数,例如10s' ;;
        min_hop_interval_label) printf '%s' '最小跳跃间隔:' ;;
        min_hop_interval_prompt) printf '%s' '请输入最小跳跃间隔(默认10s, 不能低于5s):' ;;
        network_error_cannot_connect_github) printf '%s' '网络错误: 无法连接到 Github!' ;;
        network_error_get_latest_version) printf '%s' '[网络错误]: 在 Github 上获取 hysteria 最新版本失败!' ;;
        no_supported_firewall) printf '%s' '未检测到支持的防火墙工具,请手动开放端口 %s/%s。' ;;
        non_brutal_skip) printf '%s' '(5-7/13)当前选择的是非 Brutal 模式，已跳过延时与上下行带宽输入，改用拥塞控制器本地配置。' ;;
        notify_core_update) printf '%s' '[!] hysteria2 core有更新,version:%s  日志: https://v2.hysteria.network/docs/Changelog/' ;;
        notify_hihy_update) printf '%s' '[☺] hihy需更新,version:%s,建议更新并查看日志: https://github.com/Copaan/Hi_Hysteria/' ;;
        obfs_choice_disable) printf '%s' '1、不使用(推荐)' ;;
        obfs_choice_gecko) printf '%s' '3、gecko(实验性) - 在salamander基础上额外拆分QUIC握手包，抗检测更强' ;;
        obfs_choice_salamander) printf '%s' '2、salamander - 将数据包混淆为无特征随机字节' ;;
        obfs_disabled) printf '%s' '您将不使用混淆' ;;
        obfs_enabled) printf '%s' '您将使用%s混淆加密流量' ;;
        obfs_hint) printf '%s' 'Tips: 如果使用obfs混淆,抗封锁能力更强,能被识别为未知udp流量。但是会增加cpu负载导致峰值速度下降,如果您追求性能且未被针对封锁建议不使用' ;;
        obfs_prompt) printf '%s' '(9/13)是否使用流量混淆:' ;;
        package_install_complete) printf '%s' '软件包安装完成。' ;;
        package_manager_not_supported) printf '%s' '未检测到支持的包管理器,请将以下信息反馈给开发者:' ;;
        package_manager_update_sources) printf '%s' '更新软件源...' ;;
        partial_install_cleanup) printf '%s' '检测到未完成的安装残留,正在清理脚本管理的文件后继续安装...' ;;
        partial_install_recovered) printf '%s' '已完成部分安装状态恢复,继续执行安装。' ;;
        partial_uninstall_cleanup) printf '%s' '检测到未完成的安装残留,正在按部分安装状态执行卸载清理...' ;;
        password_cannot_be_empty) printf '%s' '密码不能为空' ;;
        path_not_exist) printf '%s' '路径不存在,请重新输入!' ;;
        port_bind_alternative_cert_for_80) printf '%s' '如果需求上无法关闭 %s/%s 端口,请使用其他证书获取方式。' ;;
        port_bind_auto_close_prompt) printf '%s' '是否自动关闭端口占用?(y/N)' ;;
        port_bind_close_failed) printf '%s' '端口占用关闭失败,强制杀死进程后进程重启,请查看是否存在守护进程...' ;;
        port_bind_exit) printf '%s' '由于端口被占用,退出安装。请手动关闭或者更换端口...' ;;
        port_bind_fail) printf '%s' '端口被占用,请更换端口!' ;;
        port_bind_in_use) printf '%s' 'Port: %s/%s 已经被 %s(%s) 占用,进程pid为: %s。' ;;
        port_bind_unbinding) printf '%s' '正在解绑...' ;;
        port_bind_unbound) printf '%s' '端口解绑成功...' ;;
        port_hint) printf '%s' '并没有证据表明非udp/443的端口会被阻断,它仅仅是可能有更好的伪装一种措施,如果你使用端口跳跃的话，这里建议使用随机端口' ;;
        port_hopping_choice_enable) printf '%s' '1、启用(默认)' ;;
        port_hopping_choice_skip) printf '%s' '2、跳过' ;;
        port_hopping_detail_url) printf '%s' '更加详细介绍请参考: https://v2.hysteria.network/zh/docs/advanced/Port-Hopping/' ;;
        port_hopping_disabled) printf '%s' '您选择不使用端口跳跃功能' ;;
        port_hopping_enabled) printf '%s' '您选择启用端口跳跃/多端口(Port Hopping)功能' ;;
        port_hopping_end) printf '%s' '请输入结束端口(默认48000):' ;;
        port_hopping_intro) printf '%s' 'Tip: 长时间单端口 UDP 连接容易被运营商封锁/QoS/断流,启动此功能可以有效避免此问题.' ;;
        port_hopping_mode_fixed) printf '%s' '1、固定跳跃时间(默认)' ;;
        port_hopping_mode_prompt) printf '%s' '请选择端口跳跃时间模式:' ;;
        port_hopping_mode_random) printf '%s' '2、随机跳跃时间' ;;
        port_hopping_prompt) printf '%s' '(3/13)是否使用端口跳跃(Port Hopping),推荐使用' ;;
        port_hopping_range_hint) printf '%s' '端口跳跃/多端口(Port Hopping)功能需要占用多个端口,请保证这些端口没有监听其他服务.Tip: 将使用 Hysteria2 原生范围监听,服务端会自动处理范围内端口的转发规则.' ;;
        port_hopping_range_label) printf '%s' '您选择的端口跳跃/多端口(Port Hopping)参数为: ' ;;
        port_hopping_start) printf '%s' '请输入起始端口(默认47000):' ;;
        port_in_use) printf '%s' '端口%s被占用,PID:%s!请重新输入或者运行kill -9 %s后重新安装!' ;;
        port_invalid_error) printf '%s' '端口无效：请输入 1-65535 之间的整数。' ;;
        port_prompt) printf '%s' '(2/11)请输入你想要开启的端口,此端口是server端口,推荐443.(默认随机10000-65535)' ;;
        prompt_choose) printf '%s' '请选择:' ;;
        prompt_enter_number) printf '%s' '输入序号:' ;;
        prompt_enter_number_or_default) printf '%s' '输入序号(直接回车使用默认):' ;;
        prompt_exit) printf '%s' '0) 退出' ;;
        public_ip_check) printf '%s' '判断客户端连接所使用的地址是否正确?公网ip:' ;;
        public_ip_label) printf '%s' '公网ip: ' ;;
        qr_code_generated_failure) printf '%s' 'QR code 生成失败。' ;;
        qr_code_generated_success) printf '%s' 'QR code 生成成功。' ;;
        random_hop_interval_summary) printf '%s' '随机跳跃间隔范围: ' ;;
        random_port_label) printf '%s' '使用随机端口:' ;;
        realm_address_empty) printf '%s' '地址不能为空,请重新输入:' ;;
        realm_address_prompt) printf '%s' '请输入牵手服务器地址(格式: host:port 或 host):' ;;
        realm_choice_disable_default) printf '%s' '1、不使用(默认)' ;;
        realm_choice_enable) printf '%s' '2、使用Realm模式' ;;
        realm_intro_line1) printf '%s' 'Realm是Hysteria2的P2P穿透模式,通过牵手(rendezvous)服务器介绍双方进行UDP打洞,' ;;
        realm_intro_line2) printf '%s' '打洞成功后流量直连,不经过牵手服务器。服务器无需公网IP、无需端口转发即可运行。' ;;
        realm_intro_line3) printf '%s' '适用: NAT/家庭宽带/CGNAT/无公网IP环境。' ;;
        realm_intro_line4) printf '%s' '详情: https://hysteria.network/zh/docs/advanced/Realms/' ;;
        realm_name_label) printf '%s' '您的Realm名(请勿泄露,知道此名称的人可以获得你的服务器ip地址): ' ;;
        realm_password_prompt) printf '%s' '请输入牵手服务器密码(默认: public):' ;;
        realm_prompt_title) printf '%s' '(0/13)是否使用Realm模式(P2P穿透,无需公网IP):' ;;
        realm_server_choice_custom) printf '%s' '2、自建牵手服务器' ;;
        realm_server_choice_official) printf '%s' '1、官方牵手服务器(默认): realm.hy2.io' ;;
        realm_server_official_hint) printf '%s' '官方服务器地址为 realm.hy2.io, 使用默认密码 public 即可,无需修改' ;;
        realm_server_prompt) printf '%s' '请选择牵手(rendezvous)服务器:' ;;
        realm_skip_port) printf '%s' 'Realm模式无需配置端口,跳过端口设置' ;;
        realm_skip_port_hopping) printf '%s' 'Realm模式无需端口跳跃,跳过此设置' ;;
        realm_uri_label) printf '%s' '牵手地址: ' ;;
        realm_uri_label_with_cert) printf '%s' '牵手地址: ' ;;
        realm_warning_core_only) printf '%s' '⚠ 目前仅支持使用hysteria core直接运行' ;;
        remarks_prompt) printf '%s' '(13/13)请输入客户端名称备注(默认使用域名或IP区分,例如输入test,则名称为Hy2-test):' ;;
        remote_core_version) printf '%s' '远程核心版本:' ;;
        self_assign_ip_prompt) printf '%s' '多ip或者dns未生效时可能检测失败,如果你确定正确解析到了本机,是否自己指定本机ip? [y/N]:' ;;
        selfsigned_cert_summary_ip) printf '%s' '您已选择自签%s证书加密.公网ip:' ;;
        selfsigned_cert_summary_realm) printf '%s' '您已选择自签%s证书加密.牵手地址:' ;;
        selfsigned_domain_label) printf '%s' '自签证书域名为:' ;;
        selfsigned_domain_prompt) printf '%s' '请输入自签证书的域名(默认:helloworld.com):' ;;
        service_current_version) printf '%s' '当前版本: %s' ;;
        service_not_running) printf '%s' '%s未运行' ;;
        service_restart_failure) printf '%s' '重启失败!' ;;
        service_restart_success) printf '%s' '重启成功!' ;;
        service_running) printf '%s' '%s正在运行' ;;
        service_script_not_found) printf '%s' '未找到启动脚本!' ;;
        service_start_failure) printf '%s' '启动失败!' ;;
        service_start_success) printf '%s' '启动成功!' ;;
        service_status_failure) printf '%s' '检查状态失败!' ;;
        service_stop_failure) printf '%s' '停止失败!' ;;
        service_stop_success) printf '%s' '停止成功!' ;;
        socks5_add_custom_success) printf '%s' '添加socks5 outbound成功' ;;
        socks5_add_warp_success) printf '%s' '添加warp outbound成功' ;;
        socks5_addr_prompt) printf '%s' '请输入socks5地址(ip:端口): ' ;;
        socks5_already_enabled) printf '%s' '当前已经开启socks5 outbound,请删除后再添加' ;;
        socks5_custom_choice) printf '%s' '2) 自定义socks5地址' ;;
        socks5_local_warp_port) printf '%s' '->本机WireProxy socks5端口: %s' ;;
        socks5_outbound_not_found) printf '%s' '未找到socks5 outbound' ;;
        socks5_pass_prompt) printf '%s' '请输入socks5密码: ' ;;
        socks5_remove_choice) printf '%s' '3) 卸载已配置的outbound' ;;
        socks5_user_prompt) printf '%s' '请输入socks5用户名,如果没有鉴权直接留空: ' ;;
        socks5_warp_choice) printf '%s' '1) 自动添加warp socks5接口作为hysteria2出站(默认,使用fscarmen WireProxy方案)' ;;
        socks5_warp_config_found) printf '%s' '找到WireProxy配置文件,使用当前配置' ;;
        socks5_warp_config_not_found) printf '%s' '未找到WireProxy配置文件,请保证正确安装WireProxy' ;;
        socks5_warp_tip) printf '%s' 'Tip: WireProxy借助cloudflare warp提供免费好用的socks5代理,比起warp全局开销更小,建议性能不好的机器使用.' ;;
        start_port_greater_error) printf '%s' '起始端口必须小于结束端口,请重新输入!' ;;
        start_port_label) printf '%s' '起始端口:' ;;
        stop_test_program) printf '%s' 'Stop test program...' ;;
        switch_success) printf '%s' '切换成功' ;;
        sysctl_apply_failed) printf '%s' '设置 net.core.rmem_max/wmem_max 失败（LXC/OpenVZ 常见），性能可能受限。' ;;
        test_config) printf '%s' 'Test config...' ;;
        test_success) printf '%s' 'Test success!' ;;
        this_option_cannot_be_empty) printf '%s' '此选项不能为空,请重新输入!' ;;
        traffic_active_connections_label) printf '%s' '【活动连接】' ;;
        traffic_api_error) printf '%s' '流量API响应异常: %s' ;;
        traffic_header_alive_time) printf '%s' '存活时间' ;;
        traffic_header_conn_id) printf '%s' '连接ID' ;;
        traffic_header_download) printf '%s' '下载' ;;
        traffic_header_flows) printf '%s' '流数' ;;
        traffic_header_last_active) printf '%s' '最后活动' ;;
        traffic_header_state) printf '%s' '状态' ;;
        traffic_header_target_address) printf '%s' '目标地址' ;;
        traffic_header_upload) printf '%s' '上传' ;;
        traffic_header_user) printf '%s' '用户' ;;
        traffic_no_active_connections) printf '%s' '当前没有活动连接' ;;
        traffic_online_users_label) printf '%s' '【在线用户】' ;;
        traffic_online_users_row) printf '%s' '用户: %-20s 设备数: %d' ;;
        traffic_separator_line) printf '%s' '========================================' ;;
        traffic_server_status_title) printf '%s' '=========== Hysteria 服务器状态 ===========' ;;
        traffic_stats_label) printf '%s' '【流量统计】' ;;
        traffic_stats_row) printf '%s' '用户: %-20s 上传: %8s  下载: %8s' ;;
        traffic_status_closed) printf '%s' '已关闭' ;;
        traffic_status_estab) printf '%s' '已建立' ;;
        uninstall_complete) printf '%s' 'Hysteria 已完全卸载!' ;;
        uninstall_error) printf '%s' '卸载过程中发生错误,请检查是否有残留文件或进程。' ;;
        uninstall_success) printf '%s' '卸载成功' ;;
        unit_byte_literal) printf '%s' 'B' ;;
        unit_bytes) printf '%s' '%sB' ;;
        unit_gigabyte_literal) printf '%s' 'GB' ;;
        unit_gigabytes) printf '%s' '%sGB' ;;
        unit_hour_literal) printf '%s' 'h' ;;
        unit_hours) printf '%s' '%sh' ;;
        unit_kilobyte_literal) printf '%s' 'KB' ;;
        unit_kilobytes) printf '%s' '%sKB' ;;
        unit_megabyte_literal) printf '%s' 'MB' ;;
        unit_megabytes) printf '%s' '%sMB' ;;
        unit_millisecond_literal) printf '%s' 'ms' ;;
        unit_milliseconds) printf '%s' '%sms' ;;
        unit_minute_literal) printf '%s' 'm' ;;
        unit_minutes) printf '%s' '%sm' ;;
        unit_second_literal) printf '%s' 's' ;;
        unit_seconds) printf '%s' '%ss' ;;
        unknown_error) printf '%s' '未知错误: 请查看下方错误信息,并提交issue到github' ;;
        unknown_error_incomplete_state) printf '%s' '已保留未完成安装状态，修正问题后可重新执行安装，或执行卸载进行清理。' ;;
        unsupported_arch) printf '%s' '系统信息:%s\n请在 https://github.com/Copaan/Hi_Hysteria/issues 提交 issue!' ;;
        update_skip_no_remote) printf '%s' '无法获取最新版本号（网络问题？），跳过更新以避免破坏当前安装。' ;;
        upload_label) printf '%s' '客户端上行速度：' ;;
        upload_prompt) printf '%s' '(7/13)请输入客户端期望的上行速度(默认10,单位:mbps):' ;;
        validation_waiting) printf '%s' '等待校验结果（最多 %s 秒）...' ;;
        vultr_token_prompt) printf '%s' '请输入Vultr vultr_api_token:' ;;
        warp_choice_install) printf '%s' '2、安装WARP' ;;
        warp_choice_skip) printf '%s' '1、跳过(默认)' ;;
        warp_detected) printf '%s' '\n->检测到WARP/WireProxy安装' ;;
        warp_enabling) printf '%s' '正在开启WARP...' ;;
        warp_install_done) printf '%s' 'WARP安装完成,Hysteria2将通过Cloudflare WARP IP打洞连接' ;;
        warp_install_fail) printf '%s' 'WARP安装失败: 未找到/etc/wireguard/warp.conf' ;;
        warp_install_fail_exit) printf '%s' 'WARP未成功安装,终止脚本执行' ;;
        warp_install_prompt) printf '%s' '(可选)是否安装服务器全局WARP[fscarmen]通过Cloudflare WARP IP打洞连接Hysteria2?' ;;
        warp_installed_hint) printf '%s' '检测到已安装WARP,可通过 warp d 命令获得双栈WARP IP' ;;
        warp_installing) printf '%s' '开始安装WARP,请稍候...' ;;
        warp_keep_installation) printf '%s' '\n->保留WARP/WireProxy安装' ;;
        warp_manual_cmd) printf '%s' '请手动执行: wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh d' ;;
        warp_mtu_adjusted) printf '%s' 'MTU已从 %s 调整为 1320' ;;
        warp_mtu_no_adjust) printf '%s' '当前MTU=%s,无需调整(≥1320)' ;;
        warp_principle_line1) printf '%s' '原理: WARP通过WireGuard协议接入Cloudflare全球边缘网络,为服务器分配WARP IP。' ;;
        warp_principle_line2) printf '%s' 'Hysteria2利用该WARP IP进行Realm打洞,客户端实际连接到Cloudflare边缘节点,' ;;
        warp_principle_line3) printf '%s' '从而隐藏服务器真实IP,相当于变相在Cloudflare CDN上使用Hysteria2。' ;;
        warp_principle_line4) printf '%s' '注意: 由于cloudflare warp是nat4, 所以客户端必须得是有公网ip或者nat1/2才能使用(一般可以直接用无需担心)' ;;
        warp_reenabling) printf '%s' '正在重新开启WARP以确保连接稳定...' ;;
        warp_select_global_mode) printf '%s' '请在WARP安装菜单中选择 [全局] 工作模式(出现菜单时手动选择全局)' ;;
        warp_skip) printf '%s' '跳过WARP安装,直接使用服务器真实IP' ;;
        warp_uninstall_choice) printf '%s' '1、卸载\n2、保留' ;;
        warp_uninstall_done) printf '%s' '\n->WARP/WireProxy卸载完成' ;;
        warp_uninstall_prompt) printf '%s' '是否卸载WARP/WireProxy?' ;;
        warp_uninstalling) printf '%s' '\n->正在卸载WARP/WireProxy...' ;;
        xforwarded_choice_disable) printf '%s' '2、关闭' ;;
        xforwarded_choice_enable) printf '%s' '1、启用(默认)' ;;
        xforwarded_label) printf '%s' 'X-Forwarded请求头: ' ;;
        xforwarded_prompt) printf '%s' '是否附加 X-Forwarded-For / Host / Proto 请求头:' ;;
        mimic_installing) printf '%s' '正在下载并安装 mimic(独立项目,含内核模块,自动完成)...' ;;
        mimic_installed) printf '%s' 'mimic %s 已安装,内核模块已加载(modprobe mimic),并已配置开机自启' ;;
        mimic_download_fail) printf '%s' 'mimic 下载或校验失败' ;;
        mimic_extract_fail) printf '%s' 'mimic 安装包解包失败' ;;
        mimic_unsupported_arch) printf '%s' 'Mimic 不支持 %s 架构（仅 amd64/arm64）；已中止本次配置。' ;;
        mimic_module_manual_hint) printf '%s' 'mimic 内核模块未能自动编译(缺少 dkms/内核头文件)。请按 Getting Started 手动安装模块后重试: https://github.com/hack3ric/mimic/blob/master/docs/getting-started.md' ;;
        mimic_install_fallback) printf '%s' 'Mimic 安装失败；已中止本次配置并保留现有服务。' ;;
        menu_item_subscription) printf '%s' '订阅管理' ;;
        sub_incompatible) printf '%s' '当前配置不能同时用于三类订阅客户端；启用 Mimic 前请先关闭订阅。' ;;
        sub_port_conflict) printf '%s' 'TCP 443 已被使用或预留；请先明确处理冲突，不会停止其他服务。' ;;
        sub_render_failed) printf '%s' '无法生成完整订阅配置；保留上一代内容。' ;;
        sub_not_enabled) printf '%s' '订阅尚未启用。' ;;
        sub_refreshed) printf '%s' '订阅配置已发布。' ;;
        sub_platform) printf '%s' '订阅功能需要 Debian/Ubuntu、systemd 和 root 权限。' ;;
        sub_need_install) printf '%s' '请先安装并配置 Hysteria，再启用订阅。' ;;
        sub_bad_domain) printf '%s' '请输入你控制的有效域名；此部署方式不使用纯 IP HTTPS。' ;;
        sub_dns_failed) printf '%s' '域名没有可用的 DNS 地址，请先配置解析再重试。' ;;
        sub_arch) printf '%s' '固定校验的 Caddy 二进制目前仅支持 amd64 和 arm64。' ;;
        sub_binary_invalid) printf '%s' '私有 Caddy 校验失败，请检查文件或重新安装。' ;;
        sub_unowned) printf '%s' '已有路径、服务或账户不属于本项目，拒绝覆盖。' ;;
        sub_tls_failed) printf '%s' '受信任 HTTPS 验证失败，请检查 DNS 直连解析、公网 TCP 443 和证书申请；保留原状态。' ;;
        sub_caddy_invalid) printf '%s' '订阅 HTTPS 配置验证失败。' ;;
        sub_unit_invalid) printf '%s' '订阅 systemd 服务配置验证失败。' ;;
        sub_disable_first) printf '%s' '变更订阅域名前，请先关闭当前订阅。' ;;
        sub_domain_prompt) printf '%s' '订阅域名（DNS 直连解析，开放公网 TCP 443）：' ;;
        sub_enabling) printf '%s' '正在准备受信任 HTTPS 和完整配置，证书验证可能需要两分钟。' ;;
        sub_link) printf '%s' '私有订阅地址：' ;;
        sub_v2rayn_hint) printf '%s' 'v2rayN：订阅分组选择自定义配置核心 hysteria2，前置 SOCKS 端口 20808；使用 Hysteria 2.14.0+。' ;;
        sub_formats_hint) printf '%s' '显式格式地址（适用于修改过或无法识别的 User-Agent）：' ;;
        sub_secret_hint) printf '%s' '持有此地址即可读取代理凭据，请勿公开。' ;;
        sub_domain_label) printf '%s' '域名' ;;
        sub_enabled_label) printf '%s' '已启用' ;;
        sub_disabled) printf '%s' '订阅 HTTPS 已停止，私有设置和证书已保留。' ;;
        sub_rotation_hint) printf '%s' '旧订阅地址已撤销；已下载的代理凭据仍有效，撤销连接权限还需更换服务密码。' ;;
        sub_menu_choices) printf '%s' '1) 启用  2) 状态  3) 显示地址  4) 刷新  5) 轮换令牌  6) 关闭  0) 返回' ;;
        *) printf '未知提示：%s' "${1:-}"; return 1 ;;
    esac
}

# 用固定文案格式化参数，不执行传入文本。
msg() {
    local template
    template=$(messageTemplate "${1:-}") || return 1
    shift
    printf -- "$template" "$@"
}

# ----- 15-ui.sh -----
echoColor() {
    local printN="${printN:-}"
    case $1 in
        # 红色
        "red") echo -e "\033[31m${printN}$2 \033[0m" ;;
        # 天蓝色
        "skyBlue") echo -e "\033[1;36m${printN}$2 \033[0m" ;;
        # 绿色
        "green") echo -e "\033[32m${printN}$2 \033[0m" ;;
        # 白色
        "white") echo -e "\033[37m${printN}$2 \033[0m" ;;
        # 洋红色
        "magenta") echo -e "\033[35m${printN}$2 \033[0m" ;;
        # 黄色
        "yellow") echo -e "\033[33m${printN}$2 \033[0m" ;;
        # 紫色
        "purple") echo -e "\033[1;35m${printN}$2 \033[0m" ;;
        # 黑底黄字
        "yellowBlack") echo -e "\033[1;33;40m${printN}$2 \033[0m" ;;
        # 绿底白字
        "greenWhite") echo -e "\033[42;37m${printN}$2 \033[0m" ;;
        # 蓝色
        "blue") echo -e "\033[34m${printN}$2 \033[0m" ;;
        # 青色
        "cyan") echo -e "\033[36m${printN}$2 \033[0m" ;;
        # 黑色
        "black") echo -e "\033[30m${printN}$2 \033[0m" ;;
        # 灰色
        "gray") echo -e "\033[90m${printN}$2 \033[0m" ;;
        # 亮红色
        "lightRed") echo -e "\033[91m${printN}$2 \033[0m" ;;
        # 亮绿色
        "lightGreen") echo -e "\033[92m${printN}$2 \033[0m" ;;
        # 亮黄色
        "lightYellow") echo -e "\033[93m${printN}$2 \033[0m" ;;
        # 亮蓝色
        "lightBlue") echo -e "\033[94m${printN}$2 \033[0m" ;;
        # 亮洋红色
        "lightMagenta") echo -e "\033[95m${printN}$2 \033[0m" ;;
        # 亮青色
        "lightCyan") echo -e "\033[96m${printN}$2 \033[0m" ;;
        # 亮白色
        "lightWhite") echo -e "\033[97m${printN}$2 \033[0m" ;;
    esac
}

generate_qr() {
    local url=$1

    # 使用最小合法尺寸 1
    local qr_size=1
    local margin=1
    local level="L" # 使用最低纠错级别以减小大小
    # 生成并显示 QR 码
    # -l L: 使用最低级别的纠错
    # -m margin: 设置边距
    # -s 1: 使用最小合法尺寸
    printf '%s' "$url" | qrencode -t ANSIUTF8 -o - -l "$level" -m "$margin" -s 1

    if [ $? -eq 0 ]; then
        echoColor green "\n$(msg qr_code_generated_success)"
    else
        echoColor red "\n$(msg qr_code_generated_failure)"
        return 1
    fi
}

# 服务运行状态: running / stopped / none(未安装)
getServiceRunState() {
    local svc=""
    if [ -f "/etc/rc.d/hihy" ]; then
        svc="/etc/rc.d/hihy"
    elif [ -f "/etc/init.d/hihy" ]; then
        svc="/etc/init.d/hihy"
    else
        echo "none"
        return
    fi
    if "$svc" status 2>/dev/null | grep -q "is running"; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 居中打印头部盒子内容行(仅用于 ASCII 文案,宽度按字符数计算)
menuBoxLine() {
    local text="$1"
    local width=43
    local pad=$(((width - ${#text}) / 2))
    [ "$pad" -lt 0 ] && pad=0
    printf " \033[1;36m│\033[0m%*s%s%*s\033[1;36m│\033[0m\n" "$pad" "" "$text" "$((width - pad - ${#text}))" ""
}

menuSection() {
    printf "\n \033[1m%s\033[0m \033[90m────────────────────────\033[0m\n" "$1"
}

menuItem() {
    printf "  \033[32m%2s\033[0m\033[90m)\033[0m %s\n" "$1" "$2"
}

show_menu() {
    if [ -t 1 ]; then clear 2>/dev/null || true; fi
    local state coreV=""
    state=$(getServiceRunState)
    if [ -x "/etc/hihy/bin/appS" ]; then
        coreV=$(getLocalHysteriaVersion 2>/dev/null || true)
        coreV="${coreV#app/}"
    fi

    echo -e " \033[1;36m╭───────────────────────────────────────────╮\033[0m"
    menuBoxLine "$(msg menu_title) ${hihyV}"
    menuBoxLine "https://github.com/Copaan/Hi_Hysteria"
    echo -e " \033[1;36m╰───────────────────────────────────────────╯\033[0m"

    # 状态行:服务状态 + 内核版本
    local status_segment
    case "$state" in
        running) status_segment="\033[32m●\033[0m $(msg menu_status_running)" ;;
        stopped) status_segment="\033[31m●\033[0m $(msg menu_status_stopped)" ;;
        *) status_segment="\033[90m○\033[0m $(msg menu_status_not_installed)" ;;
    esac
    if [ -n "$coreV" ]; then
        echo -e "  ${status_segment} \033[90m│\033[0m $(msg menu_status_core) ${coreV}"
    else
        echo -e "  ${status_segment}"
    fi

    menuSection "$(msg menu_section_deploy)"
    menuItem 1 "$(msg menu_item_install)"
    menuItem 16 "$(msg menu_item_autoinstall)"
    menuItem 2 "$(msg menu_item_uninstall)"

    menuSection "$(msg menu_section_service)"
    menuItem 3 "$(msg menu_item_start)"
    menuItem 4 "$(msg menu_item_stop)"
    menuItem 5 "$(msg menu_item_restart)"
    menuItem 6 "$(msg menu_item_status)"

    menuSection "$(msg menu_section_config)"
    menuItem 8 "$(msg menu_item_view_config)"
    menuItem 9 "$(msg menu_item_reconfigure)"
    menuItem 10 "$(msg menu_item_switch_ip)"
    menuItem 12 "$(msg menu_item_acl)"
    menuItem 15 "$(msg menu_item_socks5)"
    menuItem 17 "$(msg menu_item_subscription)"

    menuSection "$(msg menu_section_maintain)"
    menuItem 7 "$(msg menu_item_update_core)"
    menuItem 13 "$(msg menu_item_traffic)"
    menuItem 14 "$(msg menu_item_logs)"

    echo -e "\n \033[90m─────────────────────────────────────────\033[0m"
    menuItem 0 "$(msg menu_item_exit)"
    echo -e " \033[90m$(msg menu_hint_hihy_cmd "hihy")\033[0m"
    echo ""
}

wait_for_continue() {
    echo -e "\n$(echoColor green "$(msg menu_wait_continue)")"
    read -r -n 1 -s
}


# ----- 20-net-yaml.sh -----

installHihyLauncher() {
    local source_path="${1:-${BASH_SOURCE[0]}}"
    local bin_link="${2:-$HIHY_BIN_LINK}"
    local bin_dir
    local temp_path

    bin_dir="$(dirname "$bin_link")"
    mkdir -p "$bin_dir"

    if [ -f "$source_path" ] && [ "$source_path" != "$bin_link" ]; then
        # 本地已有脚本文件:同目录临时文件 + mv(rename)落盘,避免原地截断
        temp_path="$(mktemp "$bin_dir/.hihy.tmp.XXXXXX")" || return 1
        if ! cp "$source_path" "$temp_path"; then
            rm -f "$temp_path"
            return 1
        fi
        chmod +x "$temp_path"
        mv "$temp_path" "$bin_link" || {
            rm -f "$temp_path"
            return 1
        }
    elif [ ! -f "$bin_link" ]; then
        securityError '本地主程序缺失，请重新下载 install.sh。'
        return 1
    fi

    if [ -f "$bin_link" ]; then
        chmod +x "$bin_link"
        return 0
    fi

    return 1
}

downloadToFile() (
    local url="$1"
    local output_path="$2"
    local attempt temp
    [[ "$url" == https://* ]] || { securityError '下载地址必须使用 HTTPS。'; return 1; }
    [ ! -L "$output_path" ] || return 1
    temp=$(mktemp "$(dirname "$output_path")/.download.XXXXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    for ((attempt=0; attempt<=HIHY_DOWNLOAD_RETRIES; attempt++)); do
        if curl --proto '=https' --proto-redir '=https' -fSL --silent --show-error \
            --connect-timeout "$HIHY_REMOTE_CONNECT_TIMEOUT" --max-time "$HIHY_REMOTE_MAX_TIME" \
            -o "$temp" "$url" && [ -s "$temp" ]; then
            chmod 600 "$temp" && mv -f -- "$temp" "$output_path" && return 0
        fi
    done
    rm -f -- "$temp"
    return 1
)

# Verify a downloaded artifact before making it available to its caller.
downloadVerifiedFile() (
    local url="$1" dest="$2" expected="${3,,}" temp actual
    isValidSHA256 "$expected" && [ ! -L "$dest" ] || return 1
    temp=$(mktemp "$(dirname "$dest")/.verified.XXXXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    if downloadToFile "$url" "$temp"; then
        actual=$(sha256sum "$temp" | awk '{print $1}')
        if [ "$actual" = "$expected" ]; then
            mv -f -- "$temp" "$dest" && return 0
        fi
        securityError 'SHA256 校验失败。'
    fi
    rm -f -- "$temp"
    return 1
)

fetchRemoteBodyFromSources() {
    local url
    local response

    for url in "$@"; do
        if response=$(curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout "$HIHY_REMOTE_CONNECT_TIMEOUT" --max-time "$HIHY_REMOTE_MAX_TIME" "$url" 2>/dev/null); then
            printf '%s' "$response"
            return 0
        fi
    done

    return 1
}

fetchRemoteHeadersFromSources() {
    local url
    local response

    for url in "$@"; do
        # -L: GitHub /releases/latest 可能先 301 到新仓库,再 302 到 tag/;不跟随则 Location 里没有 tag/
        if response=$(curl --proto '=https' --proto-redir '=https' -fsSI -L --connect-timeout "$HIHY_REMOTE_CONNECT_TIMEOUT" --max-time "$HIHY_REMOTE_MAX_TIME" "$url" 2>/dev/null); then
            printf '%s' "$response"
            return 0
        fi
    done

    return 1
}

generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuid=$(uuidgen)
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32 | sed 's/\(.\{8\}\)/\1-/g;s/-$//')
    fi
    echo "$uuid"
}

# 多源探测公网 IP;$1 为 curl 地址族参数(-4/-6/空)
getPublicIP() {
    local family="${1:-}"
    local source detected
    for source in "https://ip.sb" "https://api64.ipify.org" "https://ifconfig.me"; do
        detected=$(curl ${family} -s -m 4 "$source" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$detected" ]; then
            printf '%s\n' "$detected"
            return 0
        fi
    done
    return 1
}

# 常用探测策略:先 IPv4,失败再不限地址族(唯一实现点,勿在调用处复制回退梯子)
detectPublicIP() {
    getPublicIP -4 || getPublicIP ""
}

getListenPrimaryPort() {
    local listen_value="$1"

    if [ -z "$listen_value" ] || [ "$listen_value" = "null" ]; then
        echo ""
        return
    fi

    listen_value=${listen_value#*:}
    listen_value=$(echo "$listen_value" | awk -F',' '{print $1}')
    echo "$listen_value" | awk -F'-' '{print $1}'
}

getListenRangePart() {
    local listen_value="$1"

    if [ -z "$listen_value" ] || [ "$listen_value" = "null" ]; then
        echo ""
        return
    fi

    listen_value=${listen_value#*:}
    if echo "$listen_value" | grep -q ','; then
        echo "$listen_value" | awk -F',' '{print $2}'
    else
        echo ""
    fi
}

addOrUpdateYaml() {
    local file="$1" keyPath="$2" value="$3" valueType="${4:-auto}" temp expression
    [[ "$keyPath" =~ ^[A-Za-z_][A-Za-z0-9_.-]*(\[[0-9]+\])?([.][A-Za-z0-9_-]+(\[[0-9]+\])?)*$ ]] || return 1
    [ ! -L "$file" ] || return 1
    if [ "$valueType" = auto ]; then
        case "$keyPath" in
            *password|*Password|auth|*token*|*secret*|remarks|*name|*Name|domain|*Address|*URI|*sni|*url|*addr|*username|*content|*custom-stuff|*headers.*) valueType=string ;;
            *)
                if [[ "$value" == true || "$value" == false ]]; then valueType=bool
                elif [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then valueType=number
                else valueType=string; fi ;;
        esac
    fi
    case "$valueType" in
        string) expression=".${keyPath} = strenv(HIHY_YAML_VALUE)" ;;
        number) [[ "$value" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]] || return 1; expression=".${keyPath} = env(HIHY_YAML_VALUE)" ;;
        bool) [[ "$value" == true || "$value" == false ]] || return 1; expression=".${keyPath} = env(HIHY_YAML_VALUE)" ;;
        *) return 1 ;;
    esac
    [ -f "$file" ] || printf '{}\n' >"$file" || return 1
    temp=$(mktemp "$(dirname "$file")/.yaml.XXXXXXXX") || return 1
    if HIHY_YAML_VALUE="$value" yq eval "$expression" "$file" >"$temp"; then
        chmod 600 "$temp" && mv -f -- "$temp" "$file" && return 0
    fi
    rm -f -- "$temp"
    return 1
}

getYamlValue() {
    local file=$1    # YAML文件路径
    local keyPath=$2 # 键路径，用点号分隔
    local value

    # 检查文件是否存在(错误走 stderr,避免污染调用方捕获的 stdout)
    if [[ ! -f "$file" ]]; then
        echo "getYamlValue: file not found: $file" >&2
        return 1
    fi

    # 使用 yq 读取 YAML 文件中的值
    value=$(yq -r eval ".${keyPath}" "$file")

    # 检查 yq 命令是否成功执行
    if [[ $? -ne 0 ]]; then
        echo "getYamlValue: failed to read $keyPath from $file" >&2
        return 1
    fi

    printf '%s\n' "$value"
}


# ----- 22-ech.sh -----
# ECH (Encrypted Client Hello) 密钥对生成 —— 纯 openssl + od + printf 实现,
# 与 `sing-box generate ech-keypair <public_name>` 输出等价,无需额外下载任何二进制。
#
# 结构规范(hysteria app/internal/utils/ech.go 的解析逻辑即权威):
#   "ECH KEYS"    PEM = u16len|X25519私钥(32B) + u16len|ECHConfig     (服务端持有)
#   "ECH CONFIGS" PEM = ECHConfigList = u16len( ECHConfig... )        (发给客户端)
#   ECHConfig  = 版本 0xfe0d + u16len(contents)
#   contents   = config_id(1B) + kem_id 0x0020(X25519-HKDF-SHA256)
#              + u16len+公钥(32B) + u16len+HPKE套件列表
#              + max_name_length(1B=0) + u8len+public_name + 扩展 u16len=0
# 已用真实 hysteria v2.10.0 内核验证:服务端加载成功,派生 configList 与本实现逐字节一致,
# 客户端携带该 configList 可完成 ECH 握手。

echHexLen2() { printf '%04x' $(( ${#1} / 2 )); }
echHexToBin() { printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }

# 生成 ECH 密钥对文件并导出客户端配置。
# $1 = 输出 pem 路径(0600)  $2 = public_name(明文幌子域名)
# 成功: 返回 0,并设置全局 ech_config 为 ECHConfigList 的 base64(客户端 tls.ech 取值)
generateEchKeypair() {
    local out_path="$1" public_name="$2"
    local priv_pem priv_hex pub_hex config_id name_hex suites contents config config_list keys_blob

    if ! command -v openssl >/dev/null 2>&1; then
        return 1
    fi
    priv_pem=$(openssl genpkey -algorithm X25519 2>/dev/null) || return 1
    priv_hex=$(printf '%s\n' "$priv_pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')
    pub_hex=$(printf '%s\n' "$priv_pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')
    # X25519 原始密钥固定 32 字节;取不到说明 openssl 过旧(<1.1.1)或输出异常
    if [ ${#priv_hex} -ne 64 ] || [ ${#pub_hex} -ne 64 ]; then
        return 1
    fi

    config_id=$(printf '%02x' "$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')")
    name_hex=$(printf '%s' "$public_name" | od -An -tx1 | tr -d ' \n')
    # HPKE 套件:HKDF-SHA256 × (AES-128-GCM / AES-256-GCM / ChaCha20-Poly1305),Go 标准库支持的全集
    suites="000100010001000200010003"

    contents="${config_id}0020$(echHexLen2 "$pub_hex")${pub_hex}$(echHexLen2 "$suites")${suites}00$(printf '%02x' $(( ${#name_hex} / 2 )))${name_hex}0000"
    config="fe0d$(echHexLen2 "$contents")${contents}"
    config_list="$(echHexLen2 "$config")${config}"
    keys_blob="0020${priv_hex}$(echHexLen2 "$config")${config}"

    mkdir -p "$(dirname "$out_path")"
    {
        echo "-----BEGIN ECH KEYS-----"
        echHexToBin "$keys_blob" | openssl base64
        echo "-----END ECH KEYS-----"
        echo "-----BEGIN ECH CONFIGS-----"
        echHexToBin "$config_list" | openssl base64
        echo "-----END ECH CONFIGS-----"
    } >"$out_path"
    chmod 600 "$out_path"

    ech_config=$(echHexToBin "$config_list" | openssl base64 -A)
    [ -n "$ech_config" ]
}

# base64 值用于 URL 查询参数时的百分号编码(+ / = 三个字符)
echUrlEncodeB64() {
    local s="$1"
    s="${s//+/%2B}"
    s="${s//\//%2F}"
    s="${s//=/%3D}"
    printf '%s' "$s"
}

# ----- 23-mimic.sh -----
# Mimic(hack3ric/mimic)自动下载安装。
# 官方 release 只发 Debian 系 .deb(bookworm/noble/trixie × amd64/arm64):
#   mimic.deb      -> /usr/sbin/mimic(纯 Go 静态二进制,零依赖)
#   mimic-dkms.deb -> /usr/src/mimic-<ver>/(内核模块源码,DKMS 编译,内核 >= 6.1)
# 策略:
#   1. Debian/Ubuntu(有 apt-get):apt 整装,自动拉 dkms/linux-headers 依赖并触发 DKMS 编译
#   2. 其他发行版:解包 .deb 提取静态二进制;有 dkms 命令则手动 add/build/install 编译模块
#   3. 模块最终必须 modprobe 成功;任一步失败 -> 返回非零,终止本次配置
# 装好后 hysteria 会自动启动并管理 mimic,无需 systemd 服务或手动配置文件。
HIHY_MIMIC_BIN_DIR="${HIHY_MIMIC_BIN_DIR:-/usr/sbin}"
HIHY_DKMS_SRC_DIR="${HIHY_DKMS_SRC_DIR:-/usr/src}"
MIMIC_RELEASE_URL="${MIMIC_RELEASE_URL:-https://github.com/hack3ric/mimic/releases/latest}"
# 三套 deb 的二进制同源(纯 Go),bookworm 兼容面最广;dkms 包是源码,与发行版无关
MIMIC_DEB_SUITE="${MIMIC_DEB_SUITE:-bookworm}"

getLatestMimicVersion() {
    local headers
    headers=$(fetchRemoteHeadersFromSources "$MIMIC_RELEASE_URL") || return 1
    printf '%s\n' "$headers" | grep -i '^location:' | grep -o 'tag/[^[:space:]]*' | sed 's/tag\///;s/\r//;s/ //g' | head -n 1
}

# 下载 deb 与 sha256 校验文件并比对;失败清理残留
downloadMimicDeb() {
    local url="$1" out="$2"
    if ! downloadToFile "$url" "$out" || [ ! -s "$out" ]; then
        rm -f "$out"
        return 1
    fi
    if ! downloadToFile "${url}.sha256" "${out}.sha256" || [ ! -s "${out}.sha256" ]; then
        rm -f "$out" "${out}.sha256"
        return 1
    fi
    # 期望格式:两列 "<hash>  <filename>"
    local expect actual
    expect=$(awk '{print $1}' "${out}.sha256" | head -n 1)
    actual=$(sha256sum "$out" | awk '{print $1}')
    if ! isValidSHA256 "$expect" || [ "${expect,,}" != "$actual" ]; then
        echoColor red "$(msg mimic_download_fail)"
        rm -f "$out" "${out}.sha256"
        return 1
    fi
    rm -f "${out}.sha256"
    return 0
}

# 解包 deb 到 $2 目录:dpkg-deb 优先,回退 ar + tar
extractMimicDeb() {
    local deb="$1" dest="$2"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb" "$dest"
    elif command -v ar >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp -d) || return 1
        (cd "$tmp" && ar x "$deb" && tar xf data.tar.* -C "$dest")
        local rc=$?
        rm -rf "$tmp"
        return $rc
    else
        return 1
    fi
}

# Debian/Ubuntu 整装路径:apt 解析依赖(dkms/linux-headers)并触发 DKMS 自动编译
installMimicViaApt() {
    command -v apt-get >/dev/null 2>&1 || return 1
    echo -e "$(msg mimic_installing)"
    if apt-get install -y --no-install-recommends "$1" "$2" >/dev/null 2>&1; then
        return 0
    fi
    # apt 失败(源不可用/锁)时清掉半装状态,走手动路径
    dpkg -r mimic mimic-dkms >/dev/null 2>&1 || true
    return 1
}

# 通用路径:解包静态二进制;有 dkms 则编译内核模块
installMimicManual() {
    local tmpdir="$1" ver="$2"
    local root="$tmpdir/root"
    mkdir -p "$root"
    if ! extractMimicDeb "$tmpdir/mimic.deb" "$root" || [ ! -f "$root/usr/sbin/mimic" ]; then
        echoColor yellow "$(msg mimic_extract_fail)"
        return 1
    fi
    # 注意:不能用 install 命令——脚本内已有 install() 函数,同名函数优先于外部命令
    cp "$root/usr/sbin/mimic" "$HIHY_MIMIC_BIN_DIR/mimic"
    chmod 755 "$HIHY_MIMIC_BIN_DIR/mimic"
    if ! command -v dkms >/dev/null 2>&1; then
        echoColor yellow "$(msg mimic_module_manual_hint)"
        return 1
    fi
    if ! extractMimicDeb "$tmpdir/mimic-dkms.deb" "$root" || [ ! -d "$root/usr/src/mimic-${ver}" ]; then
        echoColor yellow "$(msg mimic_module_manual_hint)"
        return 1
    fi
    local src_dir="$HIHY_DKMS_SRC_DIR/mimic-${ver}"
    rm -rf "$src_dir"
    mkdir -p "$HIHY_DKMS_SRC_DIR"
    cp -r "$root/usr/src/mimic-${ver}" "$src_dir"
    if dkms add -m mimic -v "$ver" >/dev/null 2>&1 \
        && dkms build -m mimic -v "$ver" >/dev/null 2>&1 \
        && dkms install -m mimic -v "$ver" >/dev/null 2>&1; then
        return 0
    fi
    dkms remove -m mimic -v "$ver" --all >/dev/null 2>&1 || true
    rm -rf "$src_dir"
    echoColor yellow "$(msg mimic_module_manual_hint)"
    return 1
}

enableMimicBootModule() {
    local modules_dir="$1"
    if [ ! -f "$modules_dir/mimic.conf" ]; then
        mkdir -p "$modules_dir"
        echo 'mimic' > "$modules_dir/mimic.conf" 2>/dev/null || true
    fi
}

# 自动下载安装 mimic(程序 + 内核模块);失败返回非零,终止本次配置
installMimic() {
    local modules_dir="${HIHY_MODULES_LOAD_DIR:-/etc/modules-load.d}"
    # 已装且可用:直接复用
    if command -v mimic >/dev/null 2>&1 && modprobe mimic 2>/dev/null; then
        enableMimicBootModule "$modules_dir"
        return 0
    fi
    local arch
    arch=$(getArchitecture)
    case "$arch" in
        amd64 | arm64) ;;
        *)
            echoColor yellow "$(msg mimic_unsupported_arch "$(uname -m)")"
            return 1
            ;;
    esac
    local tag ver base tmpdir
    tag=$(getLatestMimicVersion || true)
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    case "$MIMIC_DEB_SUITE" in bookworm|noble|trixie) ;; *) return 1 ;; esac
    ver="${tag#v}"
    base="https://github.com/hack3ric/mimic/releases/download/${tag}"
    tmpdir=$(mktemp -d) || return 1
    local ok=1
    if downloadMimicDeb "${base}/${MIMIC_DEB_SUITE}_mimic_${ver}-1_${arch}.deb" "$tmpdir/mimic.deb" \
        && downloadMimicDeb "${base}/${MIMIC_DEB_SUITE}_mimic-dkms_${ver}-1_${arch}.deb" "$tmpdir/mimic-dkms.deb"; then
        if installMimicViaApt "$tmpdir/mimic.deb" "$tmpdir/mimic-dkms.deb" \
            || installMimicManual "$tmpdir" "$ver"; then
            ok=0
        fi
    fi
    rm -rf "$tmpdir"
    [ "$ok" -ne 0 ] && return 1
    if ! modprobe mimic 2>/dev/null; then
        echoColor yellow "$(msg mimic_module_load_fail)"
        return 1
    fi
    echoColor green "$(msg mimic_installed "$tag")"
    enableMimicBootModule "$modules_dir"
    return 0
}

# ----- 25-system.sh -----
detectVirtualization() {
    local virt_type=""

    # 检查是否为 OpenVZ
    if [ -f "/proc/user_beancounters" ]; then
        virt_type="openvz"
    # 检查是否为 LXC
    elif [ -f "/proc/1/environ" ] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        virt_type="lxc"
    # 检查 systemd-detect-virt（如果可用）
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local detected=$(systemd-detect-virt 2>/dev/null)
        case "$detected" in
            "openvz") virt_type="openvz" ;;
            "lxc") virt_type="lxc" ;;
            "lxc-libvirt") virt_type="lxc" ;;
            *) virt_type="other" ;;
        esac
    # 检查 /proc/cpuinfo 中的虚拟化标识
    elif grep -q "flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        virt_type="other"
    # 检查 cgroup 中的容器标识
    elif [ -f "/proc/1/cgroup" ]; then
        if grep -q ":/lxc/" /proc/1/cgroup 2>/dev/null; then
            virt_type="lxc"
        elif grep -q ":/docker/" /proc/1/cgroup 2>/dev/null; then
            virt_type="docker"
        else
            virt_type="unknown"
        fi
    else
        virt_type="unknown"
    fi

    echo "$virt_type"
}

# 获取普通调度策略下的启动命令前缀
getStartCommand() { printf '%s' ''; }

cronTask() {
    if [ -f "/etc/hihy/logs/hihy.log" ]; then
        echo "" >/etc/hihy/logs/hihy.log
    fi
}
getArchitecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        i386 | i686)
            echo "386"
            ;;
        aarch64 | arm64)
            echo "arm64"
            ;;
        armv7*)
            echo "arm"
            ;;
        s390x)
            echo "s390x"
            ;;
        ppc64le)
            echo "ppc64le"
            ;;
        loongarch64)
            echo "loong64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

ensureSystemDependencies() {
    local DEBIAN_FRONTEND=noninteractive
    export DEBIAN_FRONTEND
    local release=""
    local installType=""
    local updateNeeded=false
    local packageManager=""
    local requiredPackages=("wget" "curl" "lsof" "bash" "iptables" "bc" "openssl")

    # 检测包管理器
    if command -v apt >/dev/null; then
        packageManager="apt"
        installType="apt-get -y -q install"
        upgrade="apt-get update"
    elif command -v yum >/dev/null; then
        packageManager="yum"
        installType="yum -y -q install"
        upgrade="yum makecache"
    elif command -v dnf >/dev/null; then
        packageManager="dnf"
        installType="dnf -y install"
        upgrade="dnf makecache"
    elif command -v pacman >/dev/null; then
        packageManager="pacman"
        installType="pacman -Sy --noconfirm"
        upgrade="pacman -Syy"
    elif command -v apk >/dev/null; then
        packageManager="apk"
        installType="apk add --no-cache"
        upgrade="apk update"
    else
        echoColor red "\n$(msg package_manager_not_supported)"
        echoColor yellow "$(cat /etc/issue 2>/dev/null)"
        echoColor yellow "$(cat /proc/version 2>/dev/null)"
        exit 1
    fi

    # 检查必需的包
    for package in "${requiredPackages[@]}"; do
        if ! command -v "$package" >/dev/null; then
            echoColor green "*$package"
            updateNeeded=true
        fi
    done

    # 检查 dig 命令
    if ! command -v dig >/dev/null; then
        echoColor green "*dnsutils"
        updateNeeded=true
    fi

    # 检查 qrencode 包
    if ! command -v qrencode >/dev/null; then
        echoColor green "*qrencode"
        updateNeeded=true
    fi

    # 检查 qrencode 包
    if ! command -v crontab >/dev/null; then
        echoColor green "*crontab"
        updateNeeded=true
    fi

    # 检查 flock 命令
    if ! command -v flock >/dev/null; then
        echoColor green "*util-linux"
        updateNeeded=true
    fi

    if [ ! -s /etc/ssl/certs/ca-certificates.crt ] || ! command -v pgrep >/dev/null 2>&1; then
        updateNeeded=true
    fi

    # 仅在需要安装包时更新软件源
    if [ "$updateNeeded" = true ]; then
        echoColor purple "\n$(msg package_manager_update_sources)"
        ${upgrade} || return 1

        ${installType} ca-certificates || return 1

        # 安装必需的包
        for package in "${requiredPackages[@]}"; do
            if ! command -v "$package" >/dev/null; then
                ${installType} "$package" || return 1
            fi
        done

        # 安装 dig
        if ! command -v dig >/dev/null; then
            case $packageManager in
                "apt") ${installType} "dnsutils" || return 1 ;;
                "yum" | "dnf") ${installType} "bind-utils" || return 1 ;;
                "pacman") ${installType} "bind-tools" || return 1 ;;
                "apk") ${installType} "bind-tools" || return 1 ;;
            esac
        fi

        # 安装 qrencode
        if ! command -v qrencode >/dev/null; then
            case $packageManager in
                "apt") ${installType} "qrencode" || return 1 ;;
                "yum" | "dnf") ${installType} "qrencode" || return 1 ;;
                "pacman") ${installType} "qrencode" || return 1 ;;
                "apk") ${installType} "libqrencode-tools" || return 1 ;;
            esac
        fi

        # 安装 util-linux
        if ! command -v flock >/dev/null; then
            ${installType} "util-linux" || return 1
        fi

        # 确保有 pgrep 命令
        if ! command -v pgrep >/dev/null 2>&1; then
            case $packageManager in
                "apt") ${installType} "procps" || return 1 ;;
                "yum" | "dnf") ${installType} "procps" || return 1 ;;
                "pacman") ${installType} "procps" || return 1 ;;
                "apk") ${installType} "procps" || return 1 ;;
            esac
        fi

        # 确保有 crontab 命令
        if ! command -v crontab >/dev/null 2>&1; then
            case $packageManager in
                "apt") ${installType} "cron" || return 1 ;;
                "yum" | "dnf") ${installType} "cron" || return 1 ;;
                "pacman") ${installType} "cronie" || return 1 ;;
                "apk") ${installType} "cronie" || return 1 ;;
            esac
        fi

        echoColor purple "\n$(msg package_install_complete)"
    fi

    return 0
}

checkSystemForUpdate() {
    ensureSystemDependencies && installPrivateYq
}

# ----- 30-version.sh -----
getLatestHysteriaVersion() {
    local headers tag

    headers=$(fetchRemoteHeadersFromSources "https://github.com/HyNetworks/hysteria/releases/latest") || return 1
    tag=$(printf '%s\n' "$headers" | grep -i '^location:' | grep -o 'tag/[^[:space:]]*' | sed 's/tag\///;s/\r//;s/ //g' | head -n 1)
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}

getLocalHysteriaVersion() {
    local core_bin="${1:-$HIHY_ROOT_DIR/bin/appS}"

    if [ ! -x "$core_bin" ]; then
        return 1
    fi

    local version
    version=$(echo app/$("$core_bin" version 2>/dev/null | grep Version: | awk '{print $2}' | head -n 1))
    if [ -z "$version" ] || [ "$version" = "app/" ]; then
        return 1
    fi

    printf '%s\n' "$version"
}

# 本地内核是否满足最低版本要求($1,如 "2.10.0")。取不到版本号视为不满足。
localCoreVersionAtLeast() {
    local required="$1"
    local local_version
    local_version=$(getLocalHysteriaVersion 2>/dev/null) || return 1
    local_version="${local_version#app/}"
    local_version="${local_version#v}"
    [ -n "$local_version" ] || return 1
    [ "$(printf '%s\n%s\n' "$required" "$local_version" | sort -V | head -n 1)" = "$required" ]
}


# ----- 35-state.sh -----
getBackupValueOrDefault() {
    local file=$1
    local key=$2
    local default_value=$3
    local value

    value=$(getYamlValue "$file" "$key" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$value" ] || [ "$value" = "null" ]; then
        printf '%s\n' "$default_value"
    else
        printf '%s\n' "$value"
    fi
}

getInstallFailureMarker() {
    local root_dir="${1:-$HIHY_ROOT_DIR}"
    echo "${root_dir}/result/install.failed"
}

getHihyServiceScriptPrimary() {
    echo "${1:-/etc/init.d/hihy}"
}

getHihyServiceScriptFallback() {
    echo "${1:-/etc/rc.d/hihy}"
}

classifyInstallState() {
    local root_dir="${1:-$HIHY_ROOT_DIR}"
    local bin_link="${2:-$HIHY_BIN_LINK}"
    local service_primary="${3:-$(getHihyServiceScriptPrimary)}"
    local service_fallback="${4:-$(getHihyServiceScriptFallback)}"
    local failure_marker="${5:-$(getInstallFailureMarker "$root_dir")}"
    # bin_link(hihy 启动器)不参与残留判定:bootstrap(install.sh)在 install 运行前就会
    # 先落好启动器,仅有启动器 = 全新安装;把它算作痕迹会让官方安装路径每次都误报残留
    local owned_paths=(
        "$root_dir/bin/appS"
        "$root_dir/conf/config.yaml"
        "$root_dir/conf/backup.yaml"
        "$service_primary"
        "$service_fallback"
    )
    local has_any_artifact="false"
    local has_core_assets="false"
    local has_service_assets="false"
    local path

    for path in "${owned_paths[@]}"; do
        if [ -e "$path" ]; then
            has_any_artifact="true"
            case "$path" in
                "$root_dir/bin/appS" | "$root_dir/conf/config.yaml" | "$root_dir/conf/backup.yaml")
                    has_core_assets="true"
                    ;;
                "$service_primary" | "$service_fallback")
                    has_service_assets="true"
                    ;;
            esac
        fi
    done

    if [ -f "$failure_marker" ]; then
        echo "partially-installed"
        return
    fi

    if [ "$has_core_assets" = "true" ] && [ "$has_service_assets" = "true" ] && [ -x "$bin_link" ] \
        && [ -s "$root_dir/bin/appS" ] && [ -x "$root_dir/bin/appS" ] \
        && [ -s "$root_dir/conf/config.yaml" ] && [ -s "$root_dir/conf/backup.yaml" ]; then
        echo "installed"
        return
    fi

    if [ "$has_any_artifact" = "true" ]; then
        echo "partially-installed"
        return
    fi

    echo "not-installed"
}

markInstallFailed() {
    local phase="$1"
    local details="$2"
    local failure_marker

    failure_marker="$(getInstallFailureMarker)"
    mkdir -p "$(dirname "$failure_marker")"
    printf 'phase=%s\ndetails=%s\n' "$phase" "$details" >"$failure_marker"
}

clearInstallFailureMarker() {
    local failure_marker
    failure_marker="$(getInstallFailureMarker)"
    rm -f "$failure_marker"
}


# ----- 45-wizard.sh -----
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
    collectHysteriaConfig || return 1
    writeHysteriaConfig
}

# ----- 46-transactions.sh -----

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
    isValidDomain "$domain" || { securityError '证书域名无效。'; return 1; }
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
        securityError '新配置启动失败，已保留原配置。'
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

# ----- 47-edits.sh -----
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
            if [ "$stopped" = true ] && [ "$was_running" = true ] && [ "$(getServiceRunState)" != running ]; then start || rc=1; fi
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
    if [ "$(getServiceRunState)" = running ]; then was_running=true; stopped=true; stop || return 1; fi
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

# ----- 50-core.sh -----
# hysteria release 资产的架构后缀:复用 getArchitecture 单一映射表,
# 仅补充 hysteria 特有的差异项(mips64 板卡多为小端,官方只发 mipsle)
getHysteriaCoreArch() {
    case "$(uname -m)" in
        mips64) echo "mipsle" ;;
        *)
            local mapped
            mapped=$(getArchitecture)
            if [ "$mapped" = "unknown" ]; then
                echo ""
            else
                echo "$mapped"
            fi
            ;;
    esac
}


# Install the pinned private YAML tool without changing the system yq.
installPrivateYq() {
    local arch expected temp actual
    arch=$(getArchitecture)
    case "$arch" in
        amd64) expected=129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973 ;;
        arm64) expected=89f69310b61b68d1245065a1241d1fc843f7a36cd6103ffd77ad987613bd1b67 ;;
        *) securityError "当前架构 $arch 没有对应的 yq 下载文件。"; return 1 ;;
    esac
    mkdir -p "$(dirname "$HIHY_YQ_BIN")" || return 1
    [ ! -L "$HIHY_YQ_BIN" ] || return 1
    actual=""
    [ ! -f "$HIHY_YQ_BIN" ] || actual=$(sha256sum "$HIHY_YQ_BIN" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        temp=$(mktemp "$(dirname "$HIHY_YQ_BIN")/.yq.XXXXXXXX") || return 1
        if ! downloadVerifiedFile "https://github.com/mikefarah/yq/releases/download/${HIHY_YQ_VERSION}/yq_linux_${arch}" "$temp" "$expected"; then
            rm -f -- "$temp"; return 1
        fi
        chmod 700 "$temp" && mv -f -- "$temp" "$HIHY_YQ_BIN" || return 1
    fi
    export PATH="$(dirname "$HIHY_YQ_BIN"):$PATH"
}

validCoreVersion() { [[ "$1" =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Inspect ELF class, byte order and machine before executing a downloaded binary.
validateCoreArchitecture() {
    local file="$1" arch="$2" expected header machine
    case "$arch" in
        amd64) expected=0201:3e00 ;;
        arm64) expected=0201:b700 ;;
        386) expected=0101:0300 ;;
        arm) expected=0101:2800 ;;
        s390x) expected=0202:0016 ;;
        ppc64le) expected=0201:1500 ;;
        loong64) expected=0201:0201 ;;
        mipsle) expected=0101:0800 ;;
        *) return 1 ;;
    esac
    [ "$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || return 1
    header=$(od -An -tx1 -j4 -N2 "$file" | tr -d ' \n')
    machine=$(od -An -tx1 -j18 -N2 "$file" | tr -d ' \n')
    [ "$header:$machine" = "$expected" ]
}

# Fetch a version once, verify its manifest and artifact, then expose the candidate.
fetchHysteriaCandidate() (
    local version="$1" dest="$2" arch base temp expected
    validCoreVersion "$version" || { securityError 'Hysteria 版本格式无效。'; return 1; }
    arch=$(getHysteriaCoreArch)
    [ -n "$arch" ] || return 1
    base="https://github.com/HyNetworks/hysteria/releases/download/$version"
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    if [ "$version" = app/v2.14.0 ]; then
        downloadVerifiedFile "$base/hashes.txt" "$temp/hashes" ab844879a3323b948c2fcd338c4d06a888255e44963b985ac98cd4b32e8a5627 || return 1
    else
        downloadToFile "$base/hashes.txt" "$temp/hashes" || return 1
    fi
    expected=$(awk -v file="hysteria-linux-$arch" '$2 == file || $2 == "build/" file {print $1}' "$temp/hashes")
    isValidSHA256 "$expected" || { securityError "架构 $arch 的校验值缺失或重复。"; return 1; }
    downloadVerifiedFile "$base/hysteria-linux-$arch" "$temp/core" "$expected" || return 1
    validateCoreArchitecture "$temp/core" "$arch" || { securityError '下载的内核架构不匹配。'; return 1; }
    chmod 700 "$temp/core" || return 1
    [ "$(getLocalHysteriaVersion "$temp/core")" = "$version" ] || { securityError '下载的内核版本或架构校验失败。'; return 1; }
    [ ! -L "$dest" ] || return 1
    cp -- "$temp/core" "$dest" && chmod 700 "$dest"
)

downloadHysteriaCore() {
    local version="${1:-$HIHY_CORE_VERSION}" temp
    mkdir -p "$HIHY_ROOT_DIR/bin" || return 1
    temp=$(mktemp "$HIHY_ROOT_DIR/bin/.appS.XXXXXXXX") || return 1
    if fetchHysteriaCandidate "$version" "$temp"; then
        mv -f -- "$temp" "$HIHY_ROOT_DIR/bin/appS" && return 0
    fi
    rm -f -- "$temp"
    return 1
}

# Switch the verified core with rollback on any failed restart or interruption.
updateHysteriaCore() (
    local version="${1:-}" core="$HIHY_ROOT_DIR/bin/appS" temp was_running=false stopped=false switched=false success=false
    [ -f "$core" ] || return 1
    [ -n "$version" ] || version=$(getLatestHysteriaVersion) || return 1
    validCoreVersion "$version" || return 1
    [ "$(getLocalHysteriaVersion)" != "$version" ] || { printf '%s\n' 'Core already at requested version.'; return 0; }
    temp=$(mktemp -d "$HIHY_ROOT_DIR/bin/.upgrade.XXXXXXXX") || return 1
    rollbackCore() {
        local rc=$?
        stopValidationProcess
        if [ "$success" != true ]; then
            if [ "$switched" = true ]; then
                stop >/dev/null 2>&1 || true
                mv -f -- "$temp/previous" "$core" || rc=1
            fi
            if [ "$stopped" = true ] && [ "$was_running" = true ] && [ "$(getServiceRunState)" != running ]; then start || rc=1; fi
        fi
        rm -rf -- "$temp"
        return "$rc"
    }
    trap rollbackCore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    fetchHysteriaCandidate "$version" "$temp/candidate" || return 1
    cp -p -- "$core" "$temp/previous" || return 1
    if [ "$(getServiceRunState)" = running ]; then
        was_running=true
        stopped=true
        stop || return 1
    fi
    startInstallValidationProcess "$HIHY_ROOT_DIR/conf/config.yaml" "$temp/validation.log" "$temp/candidate" || return 1
    waitForValidationOutcome "$temp/validation.log" 60 || { securityError '新内核未通过配置验证。'; return 1; }
    stopValidationProcess
    switched=true
    mv -f -- "$temp/candidate" "$core" || return 1
    if [ "$was_running" = true ]; then
        start && [ "$(getServiceRunState)" = running ] || return 1
    fi
    success=true
    printf 'Hysteria core updated to %s\n' "$version"
)

# ----- 55-service.sh -----
setup_rc_local_for_arch() {
    # 检测是否为 Arch Linux
    if grep -q "Arch Linux" /etc/os-release; then
        echo "$(msg arch_detected_setup)"

        # 创建 /etc/systemd/system/rc-local.service 文件
        cat <<EOF | tee /etc/systemd/system/rc-local.service
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local

[Service]
Type=forking
ExecStart=/etc/rc.local
TimeoutSec=0
RemainAfterExit=yes
GuessMainPID=no

[Install]
WantedBy=multi-user.target
EOF
        # 启用 rc-local 服务
        systemctl enable rc-local

        echo "$(msg arch_rc_local_setup_done)"
    fi
}

uninstall_rc_local_for_arch() {
    # 检测是否为 Arch Linux
    if grep -q "Arch Linux" /etc/os-release; then
        echo "$(msg arch_detected_uninstall)"

        # 停止并禁用 rc-local 服务
        systemctl stop rc-local
        systemctl disable rc-local

        # 删除 /etc/systemd/system/rc-local.service 文件
        rm /etc/systemd/system/rc-local.service

        # 重新加载 systemd 配置
        systemctl daemon-reload

        echo "$(msg arch_rc_local_uninstall_done)"
    fi
}

# 写入服务管理脚本(OpenRC 或传统 rc.d)并接好开机自启。
# 关键点:
#   1. setsid 让服务进程脱离调用者的会话/前台进程组 —— 否则从菜单启动的服务会留在
#      终端前台进程组里,用户按 Ctrl+C 退出菜单时 SIGINT 广播会连带杀死刚启动的服务
#      (nohup 只挡 SIGHUP;hysteria 通过 signal.Notify 接管 SIGINT,bash 的后台 SIG_IGN 挡不住)
#   2. stop 等待进程真正退出(最多 5s,兜底 kill -9),避免 restart 时新进程抢不到端口
#   3. start 后校验进程存活 1s,启动失败立即报错而不是假装成功
#   4. rc.local 无条件补执行位:RHEL 系 /etc/rc.local 默认无执行位,rc-local.service
#      的 ConditionFileIsExecutable 不满足,开机自启会静默失效
installServiceScript() {
    local start_cmd_prefix
    start_cmd_prefix=$(getStartCommand)

    if [ -f "/etc/alpine-release" ]; then
        # 使用 OpenRC
        mkdir -p /etc/init.d
        cat >/etc/init.d/hihy <<EOF
#!/sbin/openrc-run
umask 077
exec 9>&-

name="hihy"
description="Hysteria Proxy Service"
command="${start_cmd_prefix} /etc/hihy/bin/appS"
command_args="--disable-update-check --log-level info -c /etc/hihy/conf/config.yaml server"
pidfile="/var/run/hihy.pid"
output_log="/etc/hihy/logs/hihy.log"
error_log="/etc/hihy/logs/hihy.log"

extra_started_commands="log"

is_running() {
    [ -f "\$1" ] || return 1
    PID=\$(cat "\$1")
    case "\$PID" in ''|*[!0-9]*) return 1 ;; esac
    [ "\$PID" -gt 1 ] || return 1
    case "\$(readlink "/proc/\$PID/exe" 2>/dev/null)" in /etc/hihy/bin/appS|"/etc/hihy/bin/appS (deleted)") ;; *) return 1 ;; esac
    kill -0 "\$PID" 2>/dev/null
}

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0700 /etc/hihy/logs
}

start() {
    if is_running "\$pidfile"; then
        eerror "hihy is already running"
        return 1
    fi

    ebegin "Starting hihy"
    mkdir -p \$(dirname "\$output_log")
    "$HIHY_BIN_LINK" firewallRestore || return 1
    DAEMON_WRAP=""
    if command -v setsid >/dev/null 2>&1; then
        DAEMON_WRAP="setsid"
    fi
    nohup \$DAEMON_WRAP \$command \$command_args > "\$output_log" 2>&1 &
    echo \$! > "\$pidfile"
    sleep 1
    if ! kill -0 \$(cat "\$pidfile") 2>/dev/null; then
        rm -f "\$pidfile"
        eend 1 "hihy failed to start, check \$output_log"
        return 1
    fi
    eend 0
}

stop() {
    if [ ! -f "\$pidfile" ]; then
        eerror "hihy is not running"
        return 1
    fi

    PID=\$(cat "\$pidfile")
    case "\$(readlink "/proc/\$PID/exe" 2>/dev/null)" in /etc/hihy/bin/appS|"/etc/hihy/bin/appS (deleted)") ;; *) rm -f "\$pidfile"; return 1 ;; esac
    ebegin "Stopping hihy"
    kill "\$PID" 2>/dev/null
    n=0
    while [ \$n -lt 5 ]; do
        if ! kill -0 "\$PID" 2>/dev/null; then
            break
        fi
        sleep 1
        n=\$((n + 1))
    done
    if kill -0 "\$PID" 2>/dev/null; then
        kill -9 "\$PID" 2>/dev/null
    fi
    rm -f "\$pidfile"
    eend 0
}

restart() {
    stop
    start
}

status() {
    if is_running "\$pidfile"; then
        einfo "hihy is running"
    else
        einfo "hihy is not running"
    fi
}

log() {
    tail -f "\$output_log"
}
EOF
        chmod +x /etc/init.d/hihy
        rc-update add hihy default >/dev/null 2>&1 || true
    else
        # 使用传统启动脚本
        mkdir -p /etc/rc.d
        cat >/etc/rc.d/hihy <<EOF
#!/bin/sh
umask 077
exec 9>&-

HIHY_PATH="/etc/hihy"
PID_FILE="/var/run/hihy.pid"
LOG_FILE="\$HIHY_PATH/logs/hihy.log"
START_CMD_PREFIX="${start_cmd_prefix}"

is_running() {
    [ -f "\$1" ] || return 1
    PID=\$(cat "\$1")
    case "\$PID" in ''|*[!0-9]*) return 1 ;; esac
    [ "\$PID" -gt 1 ] || return 1
    case "\$(readlink "/proc/\$PID/exe" 2>/dev/null)" in /etc/hihy/bin/appS|"/etc/hihy/bin/appS (deleted)") ;; *) return 1 ;; esac
    kill -0 "\$PID" 2>/dev/null
}

start() {
    if is_running "\$PID_FILE"; then
        echo "hihy is already running"
        return 1
    fi

    echo "Starting hihy..."
    "$HIHY_BIN_LINK" firewallRestore || return 1
    DAEMON_WRAP=""
    if command -v setsid >/dev/null 2>&1; then
        DAEMON_WRAP="setsid"
    fi
    if [ -n "\$START_CMD_PREFIX" ]; then
        nohup \$DAEMON_WRAP \$START_CMD_PREFIX \$HIHY_PATH/bin/appS --disable-update-check --log-level info -c \$HIHY_PATH/conf/config.yaml server > "\$LOG_FILE" 2>&1 &
    else
        nohup \$DAEMON_WRAP \$HIHY_PATH/bin/appS --disable-update-check --log-level info -c \$HIHY_PATH/conf/config.yaml server > "\$LOG_FILE" 2>&1 &
    fi
    echo \$! > "\$PID_FILE"
    sleep 1
    if ! kill -0 \$(cat "\$PID_FILE") 2>/dev/null; then
        echo "hihy failed to start, check \$LOG_FILE"
        rm -f "\$PID_FILE"
        return 1
    fi
}

stop() {
    if [ ! -f "\$PID_FILE" ]; then
        echo "hihy is not running"
        return 1
    fi

    PID=\$(cat "\$PID_FILE")
    case "\$(readlink "/proc/\$PID/exe" 2>/dev/null)" in /etc/hihy/bin/appS|"/etc/hihy/bin/appS (deleted)") ;; *) rm -f "\$PID_FILE"; return 1 ;; esac
    echo "Stopping hihy..."
    kill "\$PID" 2>/dev/null
    n=0
    while [ \$n -lt 5 ]; do
        if ! kill -0 "\$PID" 2>/dev/null; then
            break
        fi
        sleep 1
        n=\$((n + 1))
    done
    if kill -0 "\$PID" 2>/dev/null; then
        kill -9 "\$PID" 2>/dev/null
    fi
    rm -f "\$PID_FILE"
}

restart() {
    stop
    start
}

status() {
    if is_running "\$PID_FILE"; then
        echo "hihy is running"
    else
        echo "hihy is not running"
    fi
}

log() {
    tail -f "\$LOG_FILE"
}

case "\$1" in
    start|stop|restart|status|log)
        \$1
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|log}"
        exit 1
        ;;
esac
EOF
        chmod +x /etc/rc.d/hihy

        # 尝试添加到现有的启动配置
        if [ -d "/etc/init.d" ]; then
            ln -sf /etc/rc.d/hihy /etc/init.d/hihy
        fi

        if [ ! -f "/etc/rc.local" ]; then
            touch /etc/rc.local
            echo "#!/bin/bash" >/etc/rc.local
        fi
        chmod +x /etc/rc.local 2>/dev/null || true
        if ! grep -q "/etc/rc.d/hihy start" /etc/rc.local; then
            appendRcLocalCommand "/etc/rc.d/hihy start" || return 1
        fi
    fi
}

install() {
    local mode="${1:-}"
    local install_state
    install_state=$(classifyInstallState)

    if [ "$install_state" = "installed" ]; then
        echoColor green "$(msg already_installed)"
        return 0
    fi

    if [ "$install_state" = "partially-installed" ]; then
        securityError "检测到未完成的安装，请先检查并卸载后重试。"
        return 1
    fi

    # 创建必要目录
    mkdir -p /etc/hihy/{bin,conf,cert,result,logs}
    markInstallFailed "install-start" "installation started but not completed"
    echoColor purple "$(msg install_ready)"

    # 尽早安装 hihy 启动器，确保即使后续步骤失败，用户仍可用 hihy 命令重试
    if ! installHihyLauncher; then
        markInstallFailed "launcher" "failed to install hihy launcher at start"
        echoColor red "$(msg hihy_cmd_install_fail)"
        exit 1
    fi

    checkSystemForUpdate || return 1
    if ! downloadHysteriaCore; then
        markInstallFailed "core-download" "failed to download hysteria core"
        exit 1
    fi
    if [ "$mode" = "auto" ]; then
        autoHysteriaConfig || return 1
    else
        setHysteriaConfig || return 1
    fi

    # 写入服务脚本并启动(独立函数,重新配置时也会刷新服务脚本)
    installServiceScript || return 1
    if [ -f "/etc/alpine-release" ]; then
        rc-service hihy start || return 1
    else
        /etc/rc.d/hihy start || return 1
    fi

    local cron_tmp
    cron_tmp=$(mktemp) || return 1
    crontab -l >"$cron_tmp" 2>/dev/null || true
    if ! grep -Fq "hihy cronTask" "$cron_tmp"; then
        printf '15 4 * * 1 %s cronTask\n' "$HIHY_BIN_LINK" >>"$cron_tmp"
        crontab "$cron_tmp" || { rm -f "$cron_tmp"; return 1; }
    fi
    rm -f -- "$cron_tmp"
    secureInstallPermissions || return 1
    setup_rc_local_for_arch

    clearInstallFailureMarker
    generate_client_config || return 1
    echoColor yellowBlack "$(msg install_done)"
}

# 将 listen 中的范围端口格式 47000-48000 转换为防火墙规则使用的 47000:48000
checkLogs() {
    if [ -f "/etc/hihy/logs/hihy.log" ]; then
        echoColor gray "$(msg logs_follow_hint)"
        # 父进程捕获 INT:Ctrl+C 只结束 tail,脚本本身回到菜单
        trap ':' INT
        tail -f /etc/hihy/logs/hihy.log
        trap - INT
        echo ""
    else
        echoColor red "$(msg logs_not_found)"
    fi
}
start() {
    if [ -f "/etc/rc.d/hihy" ] || [ -f "/etc/init.d/hihy" ]; then

        if [ -f "/etc/rc.d/hihy" ]; then
            /etc/rc.d/hihy start
        else
            /etc/init.d/hihy start
        fi
        if [ $? -eq 0 ]; then
            echoColor green "$(msg service_start_success)"
        else
            echoColor red "$(msg service_start_failure)"
            return 1
        fi
    else
        echoColor red "$(msg service_script_not_found)"
        return 1
    fi
}
stop() {
    if [ -f "/etc/rc.d/hihy" ] || [ -f "/etc/init.d/hihy" ]; then
        if [ -f "/etc/rc.d/hihy" ]; then
            /etc/rc.d/hihy stop
        else
            /etc/init.d/hihy stop
        fi
        if [ $? -eq 0 ]; then
            echoColor green "$(msg service_stop_success)"
        else
            echoColor red "$(msg service_stop_failure)"
            return 1
        fi
    else
        echoColor red "$(msg service_script_not_found)"
        return 1
    fi
}
restart() {
    if [ -f "/etc/rc.d/hihy" ] || [ -f "/etc/init.d/hihy" ]; then
        if [ -f "/etc/rc.d/hihy" ]; then
            /etc/rc.d/hihy restart
        else
            /etc/init.d/hihy restart
        fi
        if [ $? -eq 0 ]; then
            echoColor green "$(msg service_restart_success)"
        else
            echoColor red "$(msg service_restart_failure)"
            return 1
        fi
    else
        echoColor red "$(msg service_script_not_found)"
        return 1
    fi
}
checkStatus() {
    if [ -f "/etc/rc.d/hihy" ] || [ -f "/etc/init.d/hihy" ]; then
        if [ -f "/etc/rc.d/hihy" ]; then
            msg=$(/etc/rc.d/hihy status)
        else
            msg=$(/etc/init.d/hihy status)
        fi
        if [ $? -ne 0 ]; then
            echoColor red "$(msg service_status_failure)"
            exit 1
        fi

        if echo "$msg" | grep -q "is running"; then
            echoColor green "$(msg service_running "hysteria")"
            version=$(/etc/hihy/bin/appS version | grep "^Version" | awk '{print $2}')
            echoColor purple "$(msg service_current_version ${version})"
        else
            echoColor red "$(msg service_not_running "hysteria")"
        fi
    else
        echoColor red "$(msg service_script_not_found)"
        return 1
    fi
}

# 定义格式化字节大小的函数

# ----- 60-firewall.sh -----
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

# ----- 65-lifecycle.sh -----
killHysteriaProcess() {
    local signal="${1:-TERM}"
    local pid_file="${2:-/var/run/hihy.pid}"

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if isHysteriaPid "$pid" && kill -0 "$pid" 2>/dev/null; then
            kill "-${signal}" "$pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$pid_file"
    fi

    local candidate
    for candidate in $(pgrep -f "^$HIHY_ROOT_DIR/bin/appS" 2>/dev/null); do
        isHysteriaPid "$candidate" || continue
        kill "-$signal" "$candidate" 2>/dev/null || true
    done

}

# Port-hopping chains belong to the core and are cleaned up by its shutdown.
cleanupHysteria2Iptables() { return 0; }

checkRoot() {
    if [ "$(id -u)" -ne 0 ]; then
        echoColor red "$(msg error_root_required)"
        exit 1
    fi
}

uninstall() {
    subscriptionUninstall || return 1
    local install_state
    install_state=$(classifyInstallState)
    if [ "$install_state" = "not-installed" ]; then
        echoColor red "$(msg hysteria_not_installed)"
        return 1
    fi

    if [ "$install_state" = "partially-installed" ]; then
        echoColor yellow "$(msg partial_uninstall_cleanup)"
    fi

    # 停止服务
    if [ -f "/etc/alpine-release" ]; then
        if [ -f "/etc/init.d/hihy" ]; then
            rc-service hihy stop >/dev/null 2>&1 || true
            rc-update del hihy default >/dev/null 2>&1 || true
            rm -f /etc/init.d/hihy
        fi
    else
        if [ -f "/etc/rc.d/hihy" ]; then
            /etc/rc.d/hihy stop >/dev/null 2>&1 || true
            rm -f /etc/rc.d/hihy
        fi
        # 清理 install 时创建的 /etc/init.d/hihy 软链(否则卸载后留下悬空链接)
        if [ -L "/etc/init.d/hihy" ] && [ "$(readlink /etc/init.d/hihy)" = "/etc/rc.d/hihy" ]; then
            rm -f /etc/init.d/hihy
        fi
    fi

    killHysteriaProcess TERM

    # 删除定时任务
    removeHihyCron || return 1

    delHihyFirewallPort udp || return 1
    delHihyFirewallPort tcp || return 1

    # 删除相关目录和文件
    if [ -f "$HIHY_ROOT_DIR/conf/sysctl-owned" ]; then rm -f /etc/sysctl.d/99-hihy.conf; fi
    rm -rf /etc/hihy
    rm -f /var/run/hihy.pid
    rm -f "$HIHY_BIN_LINK"

    if [ -f "/etc/rc.local" ]; then
        sed -i '\|^/etc/rc[.]d/hihy start$|d' /etc/rc.local
    fi

    # Shared third-party tools are managed by their own installers.
    clearInstallFailureMarker

    # 删除 Arch Linux 的 rc.local systemd 服务
    uninstall_rc_local_for_arch
    # 检查是否完全删除
    if [ ! -d "/etc/hihy" ]; then
        echoColor green "$(msg uninstall_complete)"
    else
        echoColor red "$(msg uninstall_error)"
        exit 1
    fi
}


# ----- 70-client-common.sh -----
# 客户端配置公共参数层:一次性读取 backup/config.yaml,供 native/mihomo/singbox 三个生成器共用。
# 所有路径经 $HIHY_ROOT_DIR(默认 /etc/hihy),便于 fixture 测试。

# 解析 realm URI: realm://<token>@<host>[:port]/<realm-id> 或 realm+http://...
# 导出 HIHY_REALM_SCHEME / HIHY_REALM_SERVER_URL / HIHY_REALM_TOKEN / HIHY_REALM_ID
parseRealmURI() {
    local uri="$1"
    local rest hostport
    if [[ "$uri" == realm+http://* ]]; then
        HIHY_REALM_SCHEME="http"
        rest="${uri#realm+http://}"
    else
        HIHY_REALM_SCHEME="https"
        rest="${uri#realm://}"
    fi
    HIHY_REALM_TOKEN=$(urlDecode "${rest%%@*}") || return 1
    rest="${rest#*@}"
    hostport="${rest%%/*}"
    HIHY_REALM_ID=$(urlDecode "${rest#*/}") || return 1
    HIHY_REALM_SERVER_URL="${HIHY_REALM_SCHEME}://${hostport}"
    export HIHY_REALM_SCHEME HIHY_REALM_SERVER_URL HIHY_REALM_TOKEN HIHY_REALM_ID
}

# 读取全部客户端参数,导出 HIHY_CP_* 前缀变量。
loadClientParams() {
    local root="${HIHY_ROOT_DIR:-/etc/hihy}"
    local backup="$root/conf/backup.yaml"
    local config="$root/conf/config.yaml"

    HIHY_CP_remarks=$(getYamlValue "$backup" "remarks")
    HIHY_CP_serverAddress=$(getYamlValue "$backup" "serverAddress")
    HIHY_CP_serverAddress="${HIHY_CP_serverAddress#[}"
    HIHY_CP_serverAddress="${HIHY_CP_serverAddress%]}"
    HIHY_CP_realmMode=$(getBackupValueOrDefault "$backup" "realmMode" "false")
    HIHY_CP_realmURI=""
    if [ "$HIHY_CP_realmMode" = "true" ]; then
        HIHY_CP_realmURI=$(getYamlValue "$backup" "realmURI")
    fi

    local listen_value
    listen_value=$(getYamlValue "$config" "listen")
    HIHY_CP_port=$(getListenPrimaryPort "$listen_value")
    HIHY_CP_auth=$(getYamlValue "$config" "auth.password")
    HIHY_CP_sni=$(getYamlValue "$backup" "domain")
    HIHY_CP_insecure=$(getYamlValue "$backup" "insecure")
    HIHY_CP_pinSHA256=$(getBackupValueOrDefault "$backup" "pinSHA256" "")
    if [ -z "$HIHY_CP_pinSHA256" ] || [ "$HIHY_CP_pinSHA256" = "null" ]; then
        HIHY_CP_pinSHA256=""
        # 向后兼容:旧版自签只存了 insecure,从证书文件实时计算指纹,自动升级为 pinSHA256 校验
        local cert_path
        cert_path=$(getYamlValue "$config" "tls.cert")
        if [ "$HIHY_CP_insecure" = "true" ] && [ -n "$cert_path" ] && [ "$cert_path" != "null" ] && [ -f "$cert_path" ]; then
            HIHY_CP_pinSHA256=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_path" 2>/dev/null | sed 's/^.*=//')
        fi
    fi

    HIHY_CP_obfsType=$(getYamlValue "$config" "obfs.type")
    if [ "$HIHY_CP_obfsType" = "salamander" ] || [ "$HIHY_CP_obfsType" = "gecko" ]; then
        HIHY_CP_obfsStatus="true"
        HIHY_CP_obfsPass=$(getYamlValue "$config" "obfs.${HIHY_CP_obfsType}.password")
    else
        HIHY_CP_obfsStatus="false"
        HIHY_CP_obfsType=""
        HIHY_CP_obfsPass=""
    fi

    HIHY_CP_srw=$(getYamlValue "$config" "quic.initStreamReceiveWindow"); [ "$HIHY_CP_srw" = "null" ] && HIHY_CP_srw=""
    HIHY_CP_crw=$(getYamlValue "$config" "quic.initConnReceiveWindow"); [ "$HIHY_CP_crw" = "null" ] && HIHY_CP_crw=""
    HIHY_CP_maxCrw=$(getYamlValue "$config" "quic.maxConnReceiveWindow"); [ "$HIHY_CP_maxCrw" = "null" ] && HIHY_CP_maxCrw=""
    HIHY_CP_maxSrw=$(getYamlValue "$config" "quic.maxStreamReceiveWindow"); [ "$HIHY_CP_maxSrw" = "null" ] && HIHY_CP_maxSrw=""

    HIHY_CP_congestionMode=$(getBackupValueOrDefault "$backup" "congestionMode" "brutal")
    HIHY_CP_congestionType=$(getBackupValueOrDefault "$backup" "congestionType" "")
    HIHY_CP_bbrProfile=$(getBackupValueOrDefault "$backup" "congestionBbrProfile" "standard")

    # 注意:原生配置里 down 取 bandwidth.up、up 取 bandwidth.down(既有约定,保持不变)
    HIHY_CP_down=$(getYamlValue "$config" "bandwidth.up"); [ "$HIHY_CP_down" = "null" ] && HIHY_CP_down=""
    HIHY_CP_up=$(getYamlValue "$config" "bandwidth.down"); [ "$HIHY_CP_up" = "null" ] && HIHY_CP_up=""

    HIHY_CP_phStatus=$(getYamlValue "$backup" "portHoppingStatus")
    HIHY_CP_phStart=""; HIHY_CP_phEnd=""; HIHY_CP_phIntervalMode="fixed"
    HIHY_CP_phHopInterval="30s"; HIHY_CP_phMinHopInterval="10s"; HIHY_CP_phMaxHopInterval="30s"
    if [ "$HIHY_CP_phStatus" = "true" ]; then
        HIHY_CP_phStart=$(getBackupValueOrDefault "$backup" "portHoppingStart" "$HIHY_CP_port")
        HIHY_CP_phEnd=$(getBackupValueOrDefault "$backup" "portHoppingEnd" "$HIHY_CP_port")
        HIHY_CP_phIntervalMode=$(getBackupValueOrDefault "$backup" "portHoppingIntervalMode" "fixed")
        HIHY_CP_phHopInterval=$(getBackupValueOrDefault "$backup" "portHoppingHopInterval" "30s")
        HIHY_CP_phMinHopInterval=$(getBackupValueOrDefault "$backup" "portHoppingMinHopInterval" "10s")
        HIHY_CP_phMaxHopInterval=$(getBackupValueOrDefault "$backup" "portHoppingMaxHopInterval" "30s")
    fi

    # 伪装状态(v1.13 起记录;旧版 backup 无此键时按"曾默认开启"回退为 true)
    HIHY_CP_masqueradeStatus=$(getBackupValueOrDefault "$backup" "masquerade_status" "true")
    HIHY_CP_masqueradeTcp=$(getBackupValueOrDefault "$backup" "masquerade_tcp" "false")

    # ECH(v1.15 起记录):ech_config = 客户端 ECHConfigList base64
    HIHY_CP_echStatus=$(getBackupValueOrDefault "$backup" "ech_status" "false")
    HIHY_CP_echConfig=""
    if [ "$HIHY_CP_echStatus" = "true" ]; then
        HIHY_CP_echConfig=$(getBackupValueOrDefault "$backup" "ech_config" "")
        [ -n "$HIHY_CP_echConfig" ] || { securityError "缺少 ECH 客户端配置。"; return 1; }
    fi

    # Mimic(v1.17 起记录):伪装 TCP,仅原生客户端可用
    HIHY_CP_mimicStatus=$(getBackupValueOrDefault "$backup" "mimic_status" "false")
    if [ -n "$HIHY_CP_pinSHA256" ]; then
        isValidFingerprint "$HIHY_CP_pinSHA256" || return 1
    elif [ "$HIHY_CP_insecure" = true ]; then
        securityError "缺少证书验证信息，无法导出客户端配置。"
        return 1
    fi
    return 0

}

# ----- 72-client-native.sh -----
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


# ----- 74-client-mihomo.sh -----
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

# ----- 76-client-singbox.sh -----
# Generate a sing-box 1.14+ configuration with structured value encoding.
generateSingboxJson() (
    local profile="${1:-desktop}"
    case "$profile" in desktop|app) ;; *) return 1 ;; esac
    loadClientParams || return 1
    [ "$HIHY_CP_mimicStatus" != true ] || { securityError 'sing-box 不支持 Mimic。'; return 1; }
    local destination outFile json_file root="$HIHY_ROOT_DIR" mirror="$HIHY_RULESET_MIRROR" ca_file n up_num down_num
    destination=$(clientOutputPath "$HIHY_CP_remarks" singbox.json) || return 1
    outFile=$(mktemp "$HIHY_EXPORT_DIR/.singbox.XXXXXXXX") || return 1
    json_file=$(mktemp "$HIHY_EXPORT_DIR/.json.XXXXXXXX") || { rm -f "$outFile"; return 1; }
    trap 'rm -f -- "$outFile" "$json_file"' EXIT
    cat >"$outFile" <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "dns": {
    "servers": [
      {"type": "tls", "tag": "google", "server": "8.8.8.8", "detour": "PROXY"},
      {"type": "https", "tag": "local", "server": "223.5.5.5"}
    ],
    "rules": [{"rule_set": "geosite-cn", "server": "local"}],
    "final": "google"
  },
  "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 20808}],
  "outbounds": [{"type": "hysteria2", "tag": "PROXY", "tls": {"enabled": true, "insecure": false}}, {"type": "direct", "tag": "direct"}],
  "route": {
    "default_domain_resolver": "local",
    "rule_set": [
      {"type": "remote", "tag": "geosite-cn", "format": "binary", "download_detour": "PROXY"},
      {"type": "remote", "tag": "geoip-cn", "format": "binary", "download_detour": "PROXY"}
    ],
    "rules": [{"ip_is_private": true, "outbound": "direct"}, {"rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct"}],
    "final": "PROXY"
  },
  "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}, "cache_file": {"enabled": true}}
}
JSON
    addOrUpdateYaml "$outFile" route.rule_set[0].url "$mirror/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs" string || return 1
    addOrUpdateYaml "$outFile" route.rule_set[1].url "$mirror/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs" string || return 1
    if [ "$HIHY_CLIENT_ALLOW_LAN" = true ]; then addOrUpdateYaml "$outFile" inbounds[0].listen 0.0.0.0 string || return 1; fi
    addOrUpdateYaml "$outFile" outbounds[0].password "$HIHY_CP_auth" string || return 1
    addOrUpdateYaml "$outFile" outbounds[0].tls.server_name "$HIHY_CP_sni" string || return 1
    if [ -n "$HIHY_CP_pinSHA256" ]; then
        ca_file="$root/result/$HIHY_CP_sni.ca.crt"
        [ -s "$ca_file" ] || { securityError '导出 sing-box 配置需要 CA 证书。'; return 1; }
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            addOrUpdateYaml "$outFile" "outbounds[0].tls.certificate[$n]" "$line" string || return 1
            n=$((n+1))
        done <"$ca_file"
    fi
    if [ "$HIHY_CP_echStatus" = true ]; then
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.enabled true bool || return 1
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.config[0] '-----BEGIN ECH CONFIGS-----' string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.config[1] "$HIHY_CP_echConfig" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].tls.ech.config[2] '-----END ECH CONFIGS-----' string || return 1
    fi
    if [ "$HIHY_CP_realmMode" = true ]; then
        parseRealmURI "$HIHY_CP_realmURI"
        addOrUpdateYaml "$outFile" outbounds[0].realm.server_url "$HIHY_REALM_SERVER_URL" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.token "$HIHY_REALM_TOKEN" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.realm_id "$HIHY_REALM_ID" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.stun_servers[0] stun.nextcloud.com:3478 string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].realm.stun_servers[1] global.stun.twilio.com:3478 string || return 1
    else
        addOrUpdateYaml "$outFile" outbounds[0].server "$HIHY_CP_serverAddress" string || return 1
        if [ "$HIHY_CP_phStatus" = true ]; then
            addOrUpdateYaml "$outFile" outbounds[0].server_ports[0] "$HIHY_CP_phStart:$HIHY_CP_phEnd" string || return 1
            if [ "$HIHY_CP_phIntervalMode" = random ]; then
                addOrUpdateYaml "$outFile" outbounds[0].hop_interval "$HIHY_CP_phMinHopInterval" string || return 1
                addOrUpdateYaml "$outFile" outbounds[0].hop_interval_max "$HIHY_CP_phMaxHopInterval" string || return 1
            else addOrUpdateYaml "$outFile" outbounds[0].hop_interval "$HIHY_CP_phHopInterval" string || return 1; fi
        else addOrUpdateYaml "$outFile" outbounds[0].server_port "$HIHY_CP_port" number || return 1; fi
    fi
    if [ "$HIHY_CP_congestionMode" = brutal ]; then
        up_num="${HIHY_CP_up%% *}"; down_num="${HIHY_CP_down%% *}"
        up_num="${up_num%mbps}"; down_num="${down_num%mbps}"
        addOrUpdateYaml "$outFile" outbounds[0].up_mbps "$up_num" number || return 1
        addOrUpdateYaml "$outFile" outbounds[0].down_mbps "$down_num" number || return 1
    elif [ "$HIHY_CP_congestionMode" = bbr ] && [ -n "$HIHY_CP_bbrProfile" ]; then
        addOrUpdateYaml "$outFile" outbounds[0].bbr_profile "$HIHY_CP_bbrProfile" string || return 1
    fi
    if [ "$HIHY_CP_obfsStatus" = true ]; then
        addOrUpdateYaml "$outFile" outbounds[0].obfs.type "$HIHY_CP_obfsType" string || return 1
        addOrUpdateYaml "$outFile" outbounds[0].obfs.password "$HIHY_CP_obfsPass" string || return 1
    fi
    if [ "$profile" = app ]; then
        yq -i '.inbounds = [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1500, "auto_route": true}] | .route.auto_detect_interface = true | .route.rules = [{"port": 53, "action": "hijack-dns"}] + .route.rules | del(.experimental.clash_api)' "$outFile" || return 1
    fi
    yq -o=json '.' "$outFile" >"$json_file" || return 1
    [ ! -L "$destination" ] || return 1
    chmod 600 "$json_file" && mv -f -- "$json_file" "$destination" || return 1
    printf 'sing-box 1.14+: %s\n' "$destination"
)

# ----- 78-subscription-render.sh -----
# Read private subscription state without touching the network.
subscriptionRead() {
    [ ! -L "$HIHY_SUB_ETC/state.yaml" ] || return 1
    if [ ! -f "$HIHY_SUB_ETC/state.yaml" ]; then printf '%s\n' "${2:-}"; return 0; fi
    getBackupValueOrDefault "$HIHY_SUB_ETC/state.yaml" "$1" "${2:-}"
}
subscriptionPathOwned() {
    local dir="$1"
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/.hihy-sub-owned" ] && [ ! -L "$dir/.hihy-sub-owned" ] \
        && [ "$(stat -c %u "$dir/.hihy-sub-owned")" = 0 ] \
        && [ "$(cat "$dir/.hihy-sub-owned")" = hihy-subscription-v1 ]
}
subscriptionOwned() { subscriptionPathOwned "$HIHY_SUB_ETC"; }
subscriptionEnabled() { subscriptionOwned && [ "$(subscriptionRead enabled false)" = true ]; }
subscriptionError() { securityError "$(msg "$1")"; }

subscriptionValidatePaths() {
    local dir
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB" "$HIHY_SUB_UNIT"; do
        [[ "$dir" =~ ^/[A-Za-z0-9_./-]+$ ]] && [ "${#dir}" -gt 8 ] || return 1
        case "$dir/" in */../*|*/./*) return 1 ;; esac
        [ ! -L "$dir" ] || return 1
    done
}
subscriptionValidDomain() { isValidDomain "$1" && [[ "$1" = *.* && "$1" =~ [A-Za-z] ]]; }
subscriptionValidToken() { [[ "$1" =~ ^[a-f0-9]{64}$ ]]; }

# Render only client-facing credentials into one private, complete generation.
subscriptionRenderSnapshot() (
    local source_root="$1" output="$2" remarks file
    [ -s "$source_root/conf/config.yaml" ] && [ -s "$source_root/conf/backup.yaml" ] || return 1
    [ "$(getBackupValueOrDefault "$source_root/conf/backup.yaml" mimic_status false)" != true ] \
        && [ "$(getBackupValueOrDefault "$source_root/conf/config.yaml" mimic.enabled false)" != true ] \
        || { subscriptionError sub_incompatible; return 1; }
    local tcp_listen
    tcp_listen=$(getBackupValueOrDefault "$source_root/conf/config.yaml" masquerade.listenHTTPS '')
    [[ "$tcp_listen" != *:443 ]] || { subscriptionError sub_port_conflict; return 1; }
    mkdir -p "$output" || return 1
    [ ! -L "$output" ] || return 1
    HIHY_ROOT_DIR="$source_root"
    HIHY_EXPORT_DIR="$output/files"
    HIHY_CLIENT_ALLOW_LAN=false
    HIHY_CLIENT_QUIET=true
    if ! generate_client_config >"$output/render.log" 2>&1 || ! generateSingboxJson app >>"$output/render.log" 2>&1; then
        subscriptionError sub_render_failed; return 1
    fi
    remarks=$(getYamlValue "$source_root/conf/backup.yaml" remarks) || return 1
    cp -- "$(clientOutputPath "$remarks" v2rayN.yaml)" "$output/hysteria.yaml" || return 1
    cp -- "$(clientOutputPath "$remarks" mihomo.yaml)" "$output/mihomo.yaml" || return 1
    cp -- "$(clientOutputPath "$remarks" singbox.json)" "$output/singbox.json" || return 1
    yq -e '.auth != null and .server != null and .socks5.listen == "127.0.0.1:20808"' "$output/hysteria.yaml" >/dev/null || return 1
    yq -e '.proxies[0].type == "hysteria2" and .allow-lan == false' "$output/mihomo.yaml" >/dev/null || return 1
    yq -e '.inbounds[0].type == "tun" and .outbounds[0].type == "hysteria2" and .outbounds[0].tls.insecure == false' "$output/singbox.json" >/dev/null || return 1
    yq -e '.trafficStats == null and .acme == null and .tls.key == null' "$output/hysteria.yaml" >/dev/null || return 1
    for file in hysteria.yaml mihomo.yaml singbox.json; do
        chmod 600 "$output/$file" || return 1
    done
    rm -rf -- "$output/files"
    rm -f -- "$output/render.log"
)

# Generate an exact-path, format-negotiating Caddy site with no directory listing.
subscriptionWriteCaddyConfig() {
    local domain="$1" token="$2" out="$3" name format file content_type ua
    subscriptionValidatePaths && subscriptionValidDomain "$domain" && subscriptionValidToken "$token" || return 1
    [ ! -L "$out" ] || return 1
    cat >"$out" <<EOF
{
    admin off
    persist_config off
    auto_https disable_redirects
    log {
        output discard
    }
    servers {
        protocols h1 h2
    }
    storage file_system {
        root $HIHY_SUB_STATE/caddy
    }
}
https://$domain {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            disable_http_challenge
        }
    }
    header {
        Cache-Control "private, no-store, max-age=0"
        Vary "User-Agent"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        -Server
        -ETag
        -Last-Modified
    }
    @authorized path /s/$token
    handle @authorized {
        @read method GET HEAD
        handle @read {
            route {
                root * $HIHY_SUB_STATE/content/current
                request_header -If-None-Match
                request_header -If-Modified-Since
                request_header -Range
EOF
    for format in hysteria mihomo singbox; do
        case "$format" in
            hysteria) file=hysteria.yaml; content_type='application/yaml; charset=utf-8' ;;
            mihomo) file=mihomo.yaml; content_type='application/yaml; charset=utf-8' ;;
            singbox) file=singbox.json; content_type='application/json; charset=utf-8' ;;
        esac
        cat >>"$out" <<EOF
                @format_$format query format=$format
                handle @format_$format {
                    rewrite * /$file
                    header Content-Type "$content_type"
                    file_server
                }
EOF
    done
    cat >>"$out" <<'EOF'
                @other_format query format=*
                handle @other_format {
                    respond "Unsupported subscription format." 400
                }
EOF
    for name in hysteria mihomo singbox; do
        case "$name" in
            hysteria) file=hysteria.yaml; content_type='application/yaml; charset=utf-8'; ua='(?i)^v2rayn([/ ]|$)' ;;
            mihomo) file=mihomo.yaml; content_type='application/yaml; charset=utf-8'; ua='(?i)^(clash-verge|clashmeta|mihomo|clash)([/ ]|$)' ;;
            singbox) file=singbox.json; content_type='application/json; charset=utf-8'; ua='(?i)^(SFA|SFI|SFM)([/ ]|$)' ;;
        esac
        cat >>"$out" <<EOF
                @ua_$name header_regexp ua_$name User-Agent "$ua"
                handle @ua_$name {
                    rewrite * /$file
                    header Content-Type "$content_type"
                    file_server
                }
EOF
    done
    cat >>"$out" <<'EOF'
                handle {
                    respond "Unknown client. Specify format=hysteria, mihomo or singbox." 400
                }
            }
        }
        handle {
            respond "Method not allowed." 405
        }
    }
    handle {
        respond "Not found." 404
    }
}
EOF
    chmod 600 "$out"
}

# Publish one immutable generation; Caddy can read but cannot change these files.
subscriptionCommitSnapshot() (
    local source_dir="$1" generation="" tmp="" previous committed=false
    subscriptionPathOwned "$HIHY_SUB_STATE" || return 1
    trap 'if [ "$committed" != true ] && [ -n "$generation" ]; then rm -rf -- "$generation"; fi; [ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
    generation=$(mktemp -d "$HIHY_SUB_STATE/content/generations/g.XXXXXXXX") || return 1
    local file
    for file in hysteria.yaml mihomo.yaml singbox.json; do
        [ -s "$source_dir/$file" ] && [ ! -L "$source_dir/$file" ] || return 1
        cp -- "$source_dir/$file" "$generation/$file" || return 1
    done
    chown -R "root:$HIHY_SUB_USER" "$generation" && chmod 750 "$generation" \
        && chmod 640 "$generation/"* || { rm -rf -- "$generation"; return 1; }
    previous=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null) || previous=""
    if [ -n "$previous" ]; then
        [[ "$previous" =~ ^generations/g\.[A-Za-z0-9]+$ ]] || return 1
        ln -sfn -- "$previous" "$HIHY_SUB_STATE/content/previous" || return 1
    fi
    tmp="$HIHY_SUB_STATE/content/.current.$BASHPID"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    ln -s "generations/$(basename "$generation")" "$tmp" && mv -Tf -- "$tmp" "$HIHY_SUB_STATE/content/current" || return 1
    committed=true
)

subscriptionRestoreSnapshot() {
    local target="$1" temp="$HIHY_SUB_STATE/content/.restore.$BASHPID"
    if [ -z "$target" ]; then rm -f -- "$HIHY_SUB_STATE/content/current"; return; fi
    [[ "$target" =~ ^generations/g\.[A-Za-z0-9]+$ ]] && [ -d "$HIHY_SUB_STATE/content/$target" ] || return 1
    [ ! -e "$temp" ] && [ ! -L "$temp" ] || return 1
    ln -s "$target" "$temp" && mv -Tf -- "$temp" "$HIHY_SUB_STATE/content/current"
}

subscriptionPruneSnapshots() {
    local current previous dir
    subscriptionPathOwned "$HIHY_SUB_STATE" || return 1
    current=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null) || current=""
    previous=$(readlink "$HIHY_SUB_STATE/content/previous" 2>/dev/null) || previous=""
    for dir in "$HIHY_SUB_STATE/content/generations/"g.*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        [ "generations/$(basename "$dir")" = "$current" ] || [ "generations/$(basename "$dir")" = "$previous" ] || rm -rf -- "$dir"
    done
}

subscriptionRefresh() (
    subscriptionEnabled || { subscriptionError sub_not_enabled; return 1; }
    local dir
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    subscriptionRenderSnapshot "$HIHY_ROOT_DIR" "$dir/snapshot" && subscriptionCommitSnapshot "$dir/snapshot" || return 1
    subscriptionPruneSnapshots || return 1
    printf '%s\n' "$(msg sub_refreshed)"
)

# ----- 79-subscription-service.sh -----
subscriptionFirewall() {
    local HIHY_FIREWALL_LEDGER="$HIHY_SUB_ETC/firewall.tsv" HIHY_FIREWALL_OWNER=hihy-subscription
    case "$1" in
        add) allowPort tcp 443 ;;
        remove) delHihyFirewallPort tcp ;;
        restore) firewallRestore ;;
        *) return 1 ;;
    esac
}
subscriptionFirewallRestore() { subscriptionOwned && subscriptionFirewall restore; }
subscriptionUnitOwned() { [ -f "$HIHY_SUB_UNIT" ] && [ ! -L "$HIHY_SUB_UNIT" ] && grep -Fxq '# Managed-by: hihy-subscription-v1' "$HIHY_SUB_UNIT"; }

subscriptionCheckPlatform() {
    [ "$(id -u)" = 0 ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null || { subscriptionError sub_platform; return 1; }
    grep -Eq '^ID=(debian|ubuntu|"debian"|"ubuntu")$' /etc/os-release || { subscriptionError sub_platform; return 1; }
    [ -s "$HIHY_ROOT_DIR/conf/config.yaml" ] && [ -s "$HIHY_ROOT_DIR/conf/backup.yaml" ] || { subscriptionError sub_need_install; return 1; }
    subscriptionValidatePaths || return 1
}

# DNS must resolve before the local, publicly trusted TLS readiness check can succeed.
subscriptionCheckDomain() {
    local name="$1" records
    subscriptionValidDomain "$name" || { subscriptionError sub_bad_domain; return 1; }
    records=$( { dig +time=3 +tries=1 +short A "$name"; dig +time=3 +tries=1 +short AAAA "$name"; } 2>/dev/null)
    printf '%s\n' "$records" | grep -Eq '^([0-9]+\.){3}[0-9]+$|^[[:xdigit:]:]+:[[:xdigit:]:]+$' || { subscriptionError sub_dns_failed; return 1; }
}

subscriptionCheckPort() {
    if lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1; then subscriptionError sub_port_conflict; return 1; fi
}

# Install the official pinned archive into a project-owned binary directory.
subscriptionInstallCaddy() (
    local arch expected temp actual
    arch=$(getArchitecture)
    case "$arch" in
        amd64) expected=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
        arm64) expected=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
        *) subscriptionError sub_arch; return 1 ;;
    esac
    if [ -e "$HIHY_SUB_LIB/caddy" ]; then
        [ ! -L "$HIHY_SUB_LIB/caddy" ] && [ -f "$HIHY_SUB_LIB/caddy.sha256" ] && [ ! -L "$HIHY_SUB_LIB/caddy.sha256" ] || return 1
        actual=$(sha256sum "$HIHY_SUB_LIB/caddy" | cut -d' ' -f1)
        [ "$actual" = "$(cat "$HIHY_SUB_LIB/caddy.sha256")" ] && validateCoreArchitecture "$HIHY_SUB_LIB/caddy" "$arch" \
            && [ "$("$HIHY_SUB_LIB/caddy" version | awk '{print $1}')" = "v$HIHY_CADDY_VERSION" ] || { subscriptionError sub_binary_invalid; return 1; }
        return 0
    fi
    temp=$(secureTempDir) || return 1
    trap 'rm -rf -- "$temp"' EXIT
    downloadVerifiedFile "https://github.com/caddyserver/caddy/releases/download/v$HIHY_CADDY_VERSION/caddy_${HIHY_CADDY_VERSION}_linux_$arch.tar.gz" "$temp/caddy.tar.gz" "$expected" || return 1
    tar -xOf "$temp/caddy.tar.gz" caddy >"$temp/caddy" || return 1
    validateCoreArchitecture "$temp/caddy" "$arch" || return 1
    chmod 700 "$temp/caddy" || return 1
    [ "$("$temp/caddy" version | awk '{print $1}')" = "v$HIHY_CADDY_VERSION" ] || return 1
    actual=$(sha256sum "$temp/caddy" | cut -d' ' -f1)
    cp -- "$temp/caddy" "$HIHY_SUB_LIB/.caddy.pending" && chmod 755 "$HIHY_SUB_LIB/.caddy.pending" \
        && mv -f -- "$HIHY_SUB_LIB/.caddy.pending" "$HIHY_SUB_LIB/caddy" || return 1
    printf '%s\n' "$actual" >"$HIHY_SUB_LIB/caddy.sha256"
    chmod 600 "$HIHY_SUB_LIB/caddy.sha256"
)

# Claim only empty project namespaces and a new dedicated account.
subscriptionPreparePaths() {
    local dir
    subscriptionValidatePaths || return 1
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do
        if [ -e "$dir" ] && ! subscriptionPathOwned "$dir"; then subscriptionError sub_unowned; return 1; fi
    done
    if [ -e "$HIHY_SUB_UNIT" ] && ! subscriptionUnitOwned; then subscriptionError sub_unowned; return 1; fi
    if id "$HIHY_SUB_USER" >/dev/null 2>&1 || getent group "$HIHY_SUB_USER" >/dev/null; then
        subscriptionOwned && [ -f "$HIHY_SUB_ETC/account-owned" ] || { subscriptionError sub_unowned; return 1; }
        [ "$(id -u "$HIHY_SUB_USER")" -gt 0 ] && [ "$(id -gn "$HIHY_SUB_USER")" = "$HIHY_SUB_USER" ] \
            && [ -z "$(getent group "$HIHY_SUB_USER" | cut -d: -f4)" ] || return 1
    fi
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do
        if [ ! -e "$dir" ]; then
            mkdir -m 700 -p "$dir" || return 1
            printf '%s\n' hihy-subscription-v1 >"$dir/.hihy-sub-owned" || return 1
        fi
    done
    if ! id "$HIHY_SUB_USER" >/dev/null 2>&1; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$HIHY_SUB_USER" || return 1
        : >"$HIHY_SUB_ETC/account-owned"
    fi
    chown "root:$HIHY_SUB_USER" "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" || return 1
    chmod 750 "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" && chmod 755 "$HIHY_SUB_LIB" || return 1
    for dir in "$HIHY_SUB_STATE/content" "$HIHY_SUB_STATE/content/generations"; do
        [ ! -L "$dir" ] || return 1
        mkdir -p "$dir" && chown "root:$HIHY_SUB_USER" "$dir" && chmod 750 "$dir" || return 1
    done
    [ ! -L "$HIHY_SUB_STATE/caddy" ] || return 1
    mkdir -p "$HIHY_SUB_STATE/caddy" && chown "$HIHY_SUB_USER:$HIHY_SUB_USER" "$HIHY_SUB_STATE/caddy" && chmod 700 "$HIHY_SUB_STATE/caddy"
}

subscriptionWriteUnit() {
    local out="$1"
    subscriptionValidatePaths || return 1
    cat >"$out" <<EOF
# Managed-by: hihy-subscription-v1
[Unit]
Description=Hi Hysteria private subscription HTTPS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HIHY_SUB_USER
Group=$HIHY_SUB_USER
UMask=0077
Environment=HOME=$HIHY_SUB_STATE/caddy
Environment=XDG_DATA_HOME=$HIHY_SUB_STATE/caddy
Environment=XDG_CONFIG_HOME=$HIHY_SUB_STATE/caddy
Environment=HIHY_SUB_ETC=$HIHY_SUB_ETC
ExecStartPre=+$HIHY_BIN_LINK subscription-firewall-restore
ExecStart=$HIHY_SUB_LIB/caddy run --config $HIHY_SUB_ETC/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5s
TimeoutStopSec=15s
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=$HIHY_SUB_STATE/caddy
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$out"
}

# Probe through loopback with public-CA validation, keeping bearer URLs out of argv.
subscriptionProbe() (
    local domain="$1" token="$2" dir format file ok deadline=$((SECONDS + 120))
    subscriptionValidDomain "$domain" && subscriptionValidToken "$token" || return 1
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    while [ "$SECONDS" -lt "$deadline" ]; do
        ok=true
        for format in hysteria mihomo singbox; do
            file="$format.yaml"; [ "$format" != singbox ] || file=singbox.json
            printf 'url = "https://%s/s/%s?format=%s"\nresolve = "%s:443:127.0.0.1"\n' "$domain" "$token" "$format" "$domain" >"$dir/curl.conf"
            if ! curl --proto '=https' --noproxy '*' --fail --silent --show-error --connect-timeout 3 --max-time 10 --config "$dir/curl.conf" -o "$dir/body" 2>"$dir/error" \
                || ! cmp -s "$dir/body" "$HIHY_SUB_STATE/content/current/$file"; then ok=false; break; fi
        done
        [ "$ok" != true ] || return 0
        sleep 2
    done
    subscriptionError sub_tls_failed
)

subscriptionValidateCaddy() (
    local file="$1" dir
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    runuser -u "$HIHY_SUB_USER" -- "$HIHY_SUB_LIB/caddy" validate --config "$file" --adapter caddyfile >"$dir/validation.log" 2>&1 \
        || { subscriptionError sub_caddy_invalid; return 1; }
)

# Commit endpoint changes and restore the previous endpoint on any failed restart.
subscriptionApplyEndpoint() (
    local domain="$1" token="$2" dir previous="" was_active=false was_enabled=false success=false switched=false state_existed=false config_existed=false unit_existed=false
    dir=$(secureTempDir) || return 1
    rollbackSubscription() {
        local rc=$?
        if [ "$success" != true ] && [ "$switched" = true ]; then
            systemctl stop hihy-sub.service >/dev/null 2>&1 || true
            subscriptionRestoreSnapshot "$previous" || rc=1
            subscriptionPruneSnapshots || rc=1
            if [ "$config_existed" = true ]; then cp -p -- "$dir/Caddyfile.old" "$HIHY_SUB_ETC/Caddyfile" || rc=1; else rm -f -- "$HIHY_SUB_ETC/Caddyfile"; fi
            if [ "$state_existed" = true ]; then cp -p -- "$dir/state.old" "$HIHY_SUB_ETC/state.yaml" || rc=1; else rm -f -- "$HIHY_SUB_ETC/state.yaml"; fi
            if [ "$unit_existed" = true ]; then cp -p -- "$dir/unit.old" "$HIHY_SUB_UNIT" || rc=1; else systemctl disable hihy-sub.service >/dev/null 2>&1 || true; rm -f -- "$HIHY_SUB_UNIT"; fi
            systemctl daemon-reload || rc=1
            local HIHY_FIREWALL_LEDGER="$HIHY_SUB_ETC/firewall.tsv" HIHY_FIREWALL_OWNER=hihy-subscription
            restoreFirewallLedger "$dir/firewall.old" || rc=1
            if [ "$was_enabled" = true ]; then systemctl enable hihy-sub.service >/dev/null 2>&1 || rc=1; else systemctl disable hihy-sub.service >/dev/null 2>&1 || true; fi
            if [ "$was_active" = true ]; then systemctl start hihy-sub.service || rc=1; fi
        fi
        rm -f -- "$HIHY_SUB_ETC/.Caddyfile.pending"
        rm -rf -- "$dir"
        return "$rc"
    }
    trap rollbackSubscription EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ ! -f "$HIHY_SUB_ETC/Caddyfile" ] || { cp -p "$HIHY_SUB_ETC/Caddyfile" "$dir/Caddyfile.old" || return 1; config_existed=true; }
    [ ! -f "$HIHY_SUB_ETC/state.yaml" ] || { cp -p "$HIHY_SUB_ETC/state.yaml" "$dir/state.old" || return 1; state_existed=true; }
    [ ! -f "$HIHY_SUB_UNIT" ] || { subscriptionUnitOwned && cp -p "$HIHY_SUB_UNIT" "$dir/unit.old" || return 1; unit_existed=true; }
    previous=$(readlink "$HIHY_SUB_STATE/content/current" 2>/dev/null) || previous=""
    systemctl is-active --quiet hihy-sub.service && was_active=true
    systemctl is-enabled --quiet hihy-sub.service 2>/dev/null && was_enabled=true
    HIHY_FIREWALL_LEDGER="$HIHY_SUB_ETC/firewall.tsv" snapshotFirewallLedger "$dir/firewall.old" || return 1
    subscriptionRenderSnapshot "$HIHY_ROOT_DIR" "$dir/snapshot" || return 1
    subscriptionWriteCaddyConfig "$domain" "$token" "$HIHY_SUB_ETC/.Caddyfile.pending" || return 1
    chown "root:$HIHY_SUB_USER" "$HIHY_SUB_ETC/.Caddyfile.pending" && chmod 640 "$HIHY_SUB_ETC/.Caddyfile.pending" || return 1
    subscriptionValidateCaddy "$HIHY_SUB_ETC/.Caddyfile.pending" || return 1
    subscriptionWriteUnit "$dir/hihy-sub.service" || return 1
    systemd-analyze verify "$dir/hihy-sub.service" >"$dir/unit-check.log" 2>&1 || { subscriptionError sub_unit_invalid; return 1; }
    addOrUpdateYaml "$dir/state.yaml" domain "$domain" string && addOrUpdateYaml "$dir/state.yaml" token "$token" string \
        && addOrUpdateYaml "$dir/state.yaml" enabled true bool || return 1
    switched=true
    subscriptionFirewall add || return 1
    subscriptionCommitSnapshot "$dir/snapshot" || return 1
    mv -f -- "$HIHY_SUB_ETC/.Caddyfile.pending" "$HIHY_SUB_ETC/Caddyfile" && cp -p -- "$dir/hihy-sub.service" "$HIHY_SUB_UNIT" || return 1
    systemctl daemon-reload && systemctl restart hihy-sub.service || return 1
    subscriptionProbe "$domain" "$token" || return 1
    systemctl enable hihy-sub.service >/dev/null 2>&1 || return 1
    mv -f -- "$dir/state.yaml" "$HIHY_SUB_ETC/state.yaml" || return 1
    success=true
    subscriptionPruneSnapshots || true
)

subscriptionEnable() {
    local domain="${1:-}" token
    domain="${domain,,}"
    subscriptionCheckPlatform || return 1
    if subscriptionEnabled && systemctl is-active --quiet hihy-sub.service; then
        [ -z "$domain" ] || [ "$domain" = "$(subscriptionRead domain)" ] || { subscriptionError sub_disable_first; return 1; }
        subscriptionProbe "$(subscriptionRead domain)" "$(subscriptionRead token)" || return 1
        subscriptionShow
        return
    fi
    [ -n "$domain" ] || domain=$(subscriptionRead domain '')
    [ -n "$domain" ] || read -r -p "$(msg sub_domain_prompt)" domain
    domain="${domain,,}"
    subscriptionCheckDomain "$domain" && subscriptionCheckPort || return 1
    subscriptionPreparePaths && subscriptionInstallCaddy || return 1
    token=$(subscriptionRead token '')
    subscriptionValidToken "$token" || token=$(openssl rand -hex 32) || return 1
    printf '%s\n' "$(msg sub_enabling)"
    subscriptionApplyEndpoint "$domain" "$token" || return 1
    subscriptionShow
}

subscriptionShow() {
    local domain token url format
    subscriptionEnabled || { subscriptionError sub_not_enabled; return 1; }
    domain=$(subscriptionRead domain); token=$(subscriptionRead token)
    subscriptionValidDomain "$domain" && subscriptionValidToken "$token" || return 1
    url="https://$domain/s/$token"
    printf '%s\n%s\n' "$(msg sub_link)" "$url"
    printf '%s\n' "$(msg sub_v2rayn_hint)" "$(msg sub_formats_hint)"
    for format in hysteria mihomo singbox; do printf '%s?format=%s\n' "$url" "$format"; done
    printf 'sing-box://import-remote-profile?url=%s#HiHysteria\n' "$(urlEncode "$url")"
    printf '%s\n' "$(msg sub_secret_hint)"
}

subscriptionStatus() {
    if ! subscriptionOwned; then printf '%s\n' "$(msg sub_not_enabled)"; return 0; fi
    printf '%s: %s\n' "$(msg sub_domain_label)" "$(subscriptionRead domain '-')"
    printf '%s: %s\n' "$(msg sub_enabled_label)" "$(subscriptionRead enabled false)"
    systemctl is-active hihy-sub.service || true
}

subscriptionDisable() {
    subscriptionOwned || { subscriptionError sub_not_enabled; return 1; }
    if [ -f "$HIHY_SUB_UNIT" ]; then
        subscriptionUnitOwned || return 1
        systemctl stop hihy-sub.service && systemctl disable hihy-sub.service >/dev/null 2>&1 || return 1
    fi
    subscriptionFirewall remove || return 1
    addOrUpdateYaml "$HIHY_SUB_ETC/state.yaml" enabled false bool || return 1
    printf '%s\n' "$(msg sub_disabled)"
}

subscriptionRotateToken() {
    subscriptionEnabled || { subscriptionError sub_not_enabled; return 1; }
    subscriptionCheckPlatform && subscriptionInstallCaddy || return 1
    subscriptionApplyEndpoint "$(subscriptionRead domain)" "$(openssl rand -hex 32)" || return 1
    printf '%s\n' "$(msg sub_rotation_hint)"
    subscriptionShow
}

subscriptionUninstall() {
    local dir account_owned=false
    subscriptionOwned || return 0
    subscriptionValidatePaths || return 1
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do subscriptionPathOwned "$dir" || return 1; done
    [ ! -f "$HIHY_SUB_ETC/account-owned" ] || account_owned=true
    subscriptionDisable || return 1
    [ ! -f "$HIHY_SUB_UNIT" ] || { subscriptionUnitOwned && rm -f -- "$HIHY_SUB_UNIT"; } || return 1
    systemctl daemon-reload || return 1
    for dir in "$HIHY_SUB_ETC" "$HIHY_SUB_STATE" "$HIHY_SUB_LIB"; do rm -rf -- "$dir" || return 1; done
    if [ "$account_owned" = true ] && id "$HIHY_SUB_USER" >/dev/null 2>&1; then userdel "$HIHY_SUB_USER" || return 1; fi
}

subscriptionMenu() {
    local choice
    printf '%s\n' "$(msg sub_menu_choices)"
    read -r -p "$(msg menu_prompt_choice)" choice || return 1
    case "$choice" in
        1) subscriptionEnable ;;
        2) subscriptionStatus ;;
        3) subscriptionShow ;;
        4) subscriptionRefresh ;;
        5) subscriptionRotateToken ;;
        6) subscriptionDisable ;;
        0) return 0 ;;
        *) return 1 ;;
    esac
}
subscriptionCommand() {
    case "${1:-menu}" in
        enable) subscriptionEnable "${2:-}" ;;
        status) subscriptionStatus ;;
        show) subscriptionShow ;;
        refresh) subscriptionRefresh ;;
        rotate-token) subscriptionRotateToken ;;
        disable) subscriptionDisable ;;
        menu) subscriptionMenu ;;
        *) printf '%s\n' 'hihy subscription enable|status|show|refresh|rotate-token|disable'; return 2 ;;
    esac
}

# ----- 80-stats.sh -----
# 按终端显示宽度左对齐补齐(CJK 等宽字符按 2 列计),避免中文表头与数据错位
padl() {
    local s="$1" w="$2" i c len=0
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        if [ "$(printf '%d' "'${c}" 2>/dev/null)" -ge 128 ]; then
            len=$((len + 2))
        else
            len=$((len + 1))
        fi
    done
    printf '%s' "$s"
    while [ "${len}" -lt "${w}" ]; do
        printf ' '
        len=$((len + 1))
    done
}

# 活动连接表格行:9 列按显示宽度对齐
print_table_row() {
    padl "$1" 6; printf ' | '; padl "$2" 16; printf ' | '; padl "$3" 8; printf ' | '
    padl "$4" 5; printf ' | '; padl "$5" 9; printf ' | '; padl "$6" 9; printf ' | '
    padl "$7" 8; printf ' | '; padl "$8" 8; printf ' | '; padl "$9" 22; printf '\n'
}

format_bytes() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "$(msg unit_bytes ${bytes})"
    elif [ $bytes -lt $((1024 * 1024)) ]; then
        echo "$(msg unit_kilobytes $(echo "scale=2; $bytes/1024" | bc))"
    elif [ $bytes -lt $((1024 * 1024 * 1024)) ]; then
        echo "$(msg unit_megabytes $(echo "scale=2; $bytes/(1024*1024)" | bc))"
    else
        echo "$(msg unit_gigabytes $(echo "scale=2; $bytes/(1024*1024*1024)" | bc))"
    fi
}

getHysteriaTrafic() (
    local api_port=$(getBackupValueOrDefault "/etc/hihy/conf/backup.yaml" "trafficPort" "")
    local secret=$(getYamlValue "/etc/hihy/conf/config.yaml" "trafficStats.secret" 2>/dev/null)

    # 未安装/配置缺失时 trafficPort 拿不到,直接报错而不是对着乱值发请求
    if ! isPositiveInt "${api_port}"; then
        echoColor red "$(msg config_file_not_found)"
        return 1
    fi

    local header_dir
    local -a CURL_OPTS=()
    header_dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$header_dir"' EXIT
    if [ -n "$secret" ]; then
        printf 'Authorization: %s\n' "$secret" >"$header_dir/header"
        CURL_OPTS=(-H "@$header_dir/header")
    else
        CURL_OPTS=()
    fi

    echo "$(msg traffic_server_status_title)"

    # 流量统计部分保持不变
    echoColor green "$(msg traffic_stats_label)"
    # 用 yq 解析(脚本硬依赖):grep 正则对 JSON 的 { 转义/空白格式差异太脆弱,401/HTML 响应会被静默吞掉
    local traffic_resp traffic_out
    traffic_resp=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "${CURL_OPTS[@]}" "http://127.0.0.1:${api_port}/traffic") || return 1
    if [ -n "${traffic_resp}" ]; then
        traffic_out=$(printf '%s' "${traffic_resp}" | yq -p json -o tsv 'to_entries[] | [.key, .value.tx, .value.rx] | @tsv' 2>/dev/null)
        if [ -n "${traffic_out}" ]; then
            while IFS=$'\t' read -r user tx rx; do
                tx_formatted=$(format_bytes "${tx}")
                rx_formatted=$(format_bytes "${rx}")
                # 模板占位符必须由 msg 消费(外层 printf 再展开会把 %s 提前吞掉)
                printf '%s\n' "$(msg traffic_stats_row "$user" "$tx_formatted" "$rx_formatted")"
            done <<<"${traffic_out}"
        else
            echoColor red "$(msg traffic_api_error "${traffic_resp}")"
        fi
    fi

    # 在线用户部分保持不变
    echoColor green "\n$(msg traffic_online_users_label)"
    local online_resp online_out
    online_resp=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "${CURL_OPTS[@]}" "http://127.0.0.1:${api_port}/online") || return 1
    if [ -n "${online_resp}" ]; then
        online_out=$(printf '%s' "${online_resp}" | yq -p json -o tsv 'to_entries[] | [.key, .value] | @tsv' 2>/dev/null)
        if [ -n "${online_out}" ]; then
            while IFS=$'\t' read -r user count; do
                printf '%s\n' "$(msg traffic_online_users_row "$user" "$count")"
            done <<<"${online_out}"
        else
            echoColor red "$(msg traffic_api_error "${online_resp}")"
        fi
    fi

    echoColor green "\n$(msg traffic_active_connections_label)"
    STREAMS_OUTPUT=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "${CURL_OPTS[@]}" -H "Accept: text/plain" "http://127.0.0.1:${api_port}/dump/streams") || return 1

    if [ "$(echo "$STREAMS_OUTPUT" | wc -l)" -le 1 ]; then
        echo "$(msg traffic_no_active_connections)"
    else
        # 打印表头
        local _h_state _h_user _h_conn_id _h_flows _h_up _h_down _h_alive _h_last_active _h_target_addr
        _h_state="$(msg traffic_header_state)"
        _h_user="$(msg traffic_header_user)"
        _h_conn_id="$(msg traffic_header_conn_id)"
        _h_flows="$(msg traffic_header_flows)"
        _h_up="$(msg traffic_header_upload)"
        _h_down="$(msg traffic_header_download)"
        _h_alive="$(msg traffic_header_alive_time)"
        _h_last_active="$(msg traffic_header_last_active)"
        _h_target_addr="$(msg traffic_header_target_address)"
        print_table_row "$_h_state" "$_h_user" "$_h_conn_id" "$_h_flows" "$_h_up" "$_h_down" "$_h_alive" "$_h_last_active" "$_h_target_addr"
        echo "------|----------------|--------|-----|---------|---------|--------|--------|----------------------"

        # 使用临时文件存储排序数据
        temp_file="$header_dir/streams"

        echo "$STREAMS_OUTPUT" | awk \
            -v estab="$(msg traffic_status_estab)" \
            -v closed="$(msg traffic_status_closed)" \
            -v byte_suffix="$(msg unit_byte_literal)" \
            -v kb_suffix="$(msg unit_kilobyte_literal)" \
            -v mb_suffix="$(msg unit_megabyte_literal)" \
            -v gb_suffix="$(msg unit_gigabyte_literal)" \
            -v ms_suffix="$(msg unit_millisecond_literal)" \
            -v s_suffix="$(msg unit_second_literal)" \
            -v m_suffix="$(msg unit_minute_literal)" \
            -v h_suffix="$(msg unit_hour_literal)" \
            'BEGIN {
            status["ESTAB"]=estab
            status["CLOSED"]=closed
        }

        function format_bytes(bytes) {
            if (bytes < 1024) return bytes byte_suffix
            if (bytes < 1024*1024) return sprintf("%.2f%s", bytes/1024, kb_suffix)
            if (bytes < 1024*1024*1024) return sprintf("%.2f%s", bytes/(1024*1024), mb_suffix)
            return sprintf("%.2f%s", bytes/(1024*1024*1024), gb_suffix)
        }

        function format_time(time) {
            if (time == "-") return 0
            if (index(time, "ms") > 0) {
                gsub("ms", "", time)
                return time/1000
            }
            if (index(time, "s") > 0) {
                gsub("s", "", time)
                return time
            }
            if (index(time, "m") > 0) {
                gsub("m", "", time)
                return time * 60
            }
            if (index(time, "h") > 0) {
                gsub("h", "", time)
                return time * 3600
            }
            return time
        }

        function format_time_display(seconds) {
            if (seconds < 1) return sprintf("%.0f%s", seconds * 1000, ms_suffix)
            if (seconds < 60) return sprintf("%.1f%s", seconds, s_suffix)
            if (seconds < 3600) return sprintf("%.1f%s", seconds/60, m_suffix)
            return sprintf("%.1f%s", seconds/3600, h_suffix)
        }

        NR > 1 {
            last_active = format_time($8)
            # 第9列 Req-Addr 即客户端请求的目标地址;第10列 Hooked-Req-Addr 仅在 SNI 改写时非空,略去
            printf "%s|%s|%s|%s|%s|%s|%s|%.2f|%s\n", \
                status[$1], $2, $3, $4, \
                format_bytes($5), format_bytes($6), \
                format_time_display(format_time($7)), \
                last_active, \
                $9
        }' | sort -t'|' -k8,8nr >"$temp_file"

        # 读取排序后的数据并格式化输出
        while IFS='|' read -r state user conn_id flows up down alive last_active target_addr; do
            print_table_row "$state" "$user" "$conn_id" "$flows" "$up" "$down" \
                "$alive" "$(format_time_display "$last_active")" "$target_addr"
        done <"$temp_file"

        rm -f "$temp_file"
    fi

    echo "$(msg traffic_separator_line)"
)

# 辅助函数：格式化时间显示
format_time_display() {
    local seconds=$1

    # 处理毫秒级别
    if (($(echo "$seconds < 1" | bc -l))); then
        printf "$(msg unit_milliseconds $(echo "$seconds * 1000" | bc -l))"
        return
    fi

    # 处理秒级别
    if (($(echo "$seconds < 60" | bc -l))); then
        printf "$(msg unit_seconds $seconds)"
        return
    fi

    # 处理分钟级别
    if (($(echo "$seconds < 3600" | bc -l))); then
        local minutes=$(echo "$seconds / 60" | bc -l)
        printf "$(msg unit_minutes $minutes)"
        return
    fi

    # 处理小时级别
    local hours=$(echo "$seconds / 3600" | bc -l)
    # 如果小时数小于0.1，显示为分钟
    if (($(echo "$hours < 0.1" | bc -l))); then
        local minutes=$(echo "$seconds / 60" | bc -l)
        printf "$(msg unit_minutes $minutes)"
    else
        printf "$(msg unit_hours $hours)"
    fi
}


# ----- 85-actions.sh -----
hihyUpdate() {
    printf '%s\n' '此命令不提供脚本更新。'
}

changeIp64() (
    local config="$HIHY_ROOT_DIR/conf/config.yaml" dir input mode
    [ -f "$config" ] || return 1
    [ "$(getBackupValueOrDefault "$HIHY_ROOT_DIR/conf/backup.yaml" socks5_status false)" != true ] || return 1
    echoColor yellow "$(msg ip_priority_choice_ipv4)"
    echoColor yellow "$(msg ip_priority_choice_ipv6)"
    echoColor yellow "$(msg ip_priority_choice_auto)"
    read -r -p "$(msg prompt_choose)" input
    case "$input" in 1) mode=46 ;; 2) mode=64 ;; 3) mode=auto ;; 0) return 0 ;; *) return 1 ;; esac
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    cp -- "$config" "$dir/config.yaml" || return 1
    addOrUpdateYaml "$dir/config.yaml" outbounds[0].direct.mode "$mode" string || return 1
    commitServerEdit "$dir/config.yaml" || return 1
    echoColor green "$(msg switch_success)"
)

changeServerConfig() {
    [ -f "$HIHY_ROOT_DIR/conf/config.yaml" ] || return 1
    setHysteriaConfig || return 1
    generate_client_config || return 1
    echoColor green "$(msg change_config_success)"
}

aclControl() (
    local live="$HIHY_ROOT_DIR/acl/acl.txt" dir input domain rule prefix matches count
    [ -f "$live" ] || return 1
    echoColor purple "$(msg acl_action_prompt)"
    echoColor yellow "$(msg acl_choice_add)"
    echoColor yellow "$(msg acl_choice_delete)"
    echoColor yellow "$(msg acl_choice_view)"
    read -r -p "$(msg menu_prompt_choice)" input
    case "$input" in 0) return 0 ;; 3) cat "$live"; return 0 ;; 1|2) ;; *) return 1 ;; esac
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    cp -- "$live" "$dir/acl.txt" && cp -- "$HIHY_ROOT_DIR/conf/config.yaml" "$dir/config.yaml" || return 1
    if [ "$input" = 1 ]; then
        echoColor yellow "$(msg acl_choice_v4_suffix)"
        echoColor yellow "$(msg acl_choice_v6_suffix)"
        echoColor yellow "$(msg acl_choice_reject_suffix)"
        read -r input
        case "$input" in 1) prefix=v4_only ;; 2) prefix=v6_only ;; 3) prefix=reject ;; *) return 1 ;; esac
        read -r -p "$(msg acl_v4_domain_prompt)" domain
        domain="${domain,,}"
        isValidDomain "$domain" || return 1
        rule="$prefix(suffix:$domain)"
        grep -Fxq -- "$rule" "$live" && return 0
        printf '%s\n' "$rule" >>"$dir/acl.txt"
    else
        read -r -p "$(msg acl_delete_rule_prompt)" domain
        if isValidDomain "$domain"; then
            matches=""; count=0
            for prefix in v4_only v6_only reject; do
                rule="$prefix(suffix:${domain,,})"
                if grep -Fxq -- "$rule" "$live"; then matches="$rule"; count=$((count+1)); fi
            done
            [ "$count" = 1 ] || { securityError '域名匹配结果不唯一，请输入完整规则。'; return 1; }
            rule="$matches"
        else
            rule="$domain"
            [[ "$rule" != *$'\n'* ]] && grep -Fxq -- "$rule" "$live" || return 1
        fi
        grep -Fxv -- "$rule" "$live" >"$dir/acl.txt" || [ $? -eq 1 ] || return 1
    fi
    commitServerEdit "$dir/config.yaml" "$dir/acl.txt"
)

addSocks5Outbound() (
    local config="$HIHY_ROOT_DIR/conf/config.yaml" dir choice addr user pass port name status=true
    [ -f "$config" ] || return 1
    echoColor yellow "$(msg socks5_warp_choice)"
    echoColor yellow "$(msg socks5_custom_choice)"
    echoColor yellow "$(msg socks5_remove_choice)"
    read -r -p "$(msg menu_prompt_choice)" choice
    case "$choice" in 1|2|3) ;; *) return 0 ;; esac
    dir=$(secureTempDir) || return 1
    trap 'rm -rf -- "$dir"' EXIT
    if [ "$choice" = 3 ]; then
        name=$(getYamlValue "$config" outbounds[0].name) || return 1
        [[ "$name" = warp || "$name" = custom ]] || return 1
        yq 'del(.outbounds[0])' "$config" >"$dir/config.yaml" || return 1
        status=false
    else
        [ "$(getBackupValueOrDefault "$HIHY_ROOT_DIR/conf/backup.yaml" socks5_status false)" != true ] || return 1
        if [ "$choice" = 1 ]; then
            [ -f /etc/wireguard/proxy.conf ] || installWarpVerified w || return 1
            [ -f /etc/wireguard/proxy.conf ] || return 1
            port=$(awk -F: '/^[[:space:]]*BindAddress[[:space:]]*=/ {gsub(/[[:space:]]/, "", $NF); print $NF}' /etc/wireguard/proxy.conf)
            isValidPort "$port" || return 1
            name=warp; addr="127.0.0.1:$port"; user=""; pass=""
        else
            name=custom
            read -r -p "$(msg socks5_addr_prompt)" addr
            [[ "$addr" =~ ^(\[[A-Za-z0-9:.%]+\]|[A-Za-z0-9.-]+):[0-9]+$ ]] && isValidPort "${addr##*:}" || return 1
            read -r -p "$(msg socks5_user_prompt)" user
            pass=""
            if [ -n "$user" ]; then read -rs -p "$(msg socks5_pass_prompt)" pass; printf '\n'; [ -n "$pass" ] || return 1; fi
        fi
        addOrUpdateYaml "$dir/outbound.yaml" name "$name" string || return 1
        addOrUpdateYaml "$dir/outbound.yaml" type socks5 string || return 1
        addOrUpdateYaml "$dir/outbound.yaml" socks5.addr "$addr" string || return 1
        if [ -n "$user" ]; then
            addOrUpdateYaml "$dir/outbound.yaml" socks5.username "$user" string || return 1
            addOrUpdateYaml "$dir/outbound.yaml" socks5.password "$pass" string || return 1
        fi
        HIHY_OUTBOUND_FILE="$dir/outbound.yaml" yq '.outbounds = [load(strenv(HIHY_OUTBOUND_FILE))] + .outbounds' "$config" >"$dir/config.yaml" || return 1
    fi
    commitServerEdit "$dir/config.yaml" '' "$status" || return 1
    printf '%s\n' 'SOCKS5 configuration updated.'
)

# ----- 90-main.sh -----
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
