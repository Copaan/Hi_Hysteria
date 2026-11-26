# 单一 HTTPS 订阅地址

版本：ver1.21-secure.1。日期：2026-11-26。基于此前 ver1.20-secure.1 的安全整改继续开发。

## 功能和兼容基线

一个私有 HTTPS URL 根据请求的 User-Agent 返回完整配置。不是在线转换站，也不是只包含节点的 provider 文件。现有本地文件导出、分享链接、二维码、菜单和分流规则仍保留。

| 客户端 | 收到的内容 | 导入设置 |
| --- | --- | --- |
| v2rayN 7.25.6 | Hysteria 原生完整 YAML | 订阅分组设置 CustomCoreType = hysteria2，PreSocksPort = 20808；使用 Hysteria 2.14.0 |
| Clash Verge Rev 2.5.10 / mihomo 1.19.34 | 包含代理组、DNS、rule-providers 和分流的完整 YAML | 作为远程配置导入，不要作为 proxy-provider 导入 |
| 官方 sing-box Android / iOS / macOS App | 包含 TUN、DNS、路由和远程规则的完整 JSON | 远程配置；内核基线 1.14.4；系统提示时授权 VPN/TUN |

自动识别 v2rayN、clash-verge、ClashMeta、mihomo、Clash、SFA、SFI、SFM。浏览器和未知 UA 返回 400，不猜测格式。修改过 UA 的客户端可使用同一地址加 ?format=hysteria、?format=mihomo 或 ?format=singbox。显式格式优先于 UA。错误格式返回 400，错误路径/令牌返回 404，只允许 GET/HEAD。

v2rayN 的自定义核心和前置 SOCKS 端口是必要设置。只贴 URL 而保留普通节点订阅模式，不能保证其识别完整 YAML。菜单会输出三个显式格式地址及 sing-box://import-remote-profile 导入链接。

## 启用前

- 已通过完整本地安装包安装并配置 HY2，系统为 Debian/Ubuntu + systemd，架构 amd64 或 arm64。不要在生产机运行 test_*.sh / test_*.py。
- 准备自己控制的独立域名，例如 sub.example.com。A/AAAA 必须直连本服务器；没有可用 IPv6 时不要保留错误 AAAA。
- 放行公网入站 TCP 443，包括云安全组、上游 NAT 和防火墙。允许出站 HTTPS/DNS，用于下载固定依赖及证书申请/续期。
- 使用 DNS-only 解析。此方案使用 TLS-ALPN-01 自动申请证书，不适合前置 CDN/反向代理终止 TLS。Caddy 不监听 HTTP 80，不占用 UDP 443，关闭 HTTP/3 和管理 API。
- TCP 443 已被其他服务占用时直接拒绝，不停止或覆盖现有 nginx/Caddy。HY2 使用 UDP 443 可以共存；HY2 的 TCP 443 伪装不能共存。
- Mimic 不受三类客户端共同支持：保留原功能，但开启 Mimic 时不能启用三端订阅；已启用订阅时，重新配置会在安装 Mimic 前拒绝。可先关闭订阅，再使用原有 Mimic 导出。

Caddy 固定为 2.11.9，从官方固定 release 下载并校验固化的 amd64/arm64 SHA256 和 ELF 架构。它安装在 /usr/local/lib/hihy-sub/caddy，不覆盖系统 Caddy。没有远程脚本自更新，也不在菜单、状态或导出时查询最新版本。

## 操作

在已安装本版本的服务器上：

~~~bash
sudo hihy subscription enable sub.example.com
sudo hihy subscription status
sudo hihy subscription show
~~~

也可以进入菜单 17。启用明确触发下载、证书申请和受信任 HTTPS 探测；本机可信 HTTPS 探测成功后才显示地址。公网可达性仍需从服务器外部确认，尤其是复用已有有效证书时。准备、启动或 HTTPS 校验失败时恢复之前的端点和运行状态，不报告成功。初次证书申请最多等待约两分钟；失败后可修复 DNS/443 访问再重试。保留的私有证书状态便于续期和重试。

~~~bash
sudo hihy subscription refresh
sudo hihy subscription rotate-token
sudo hihy subscription disable
~~~

- refresh：离线重新生成并原子发布三份完整配置。重配成功或常规导出也会更新订阅内容；重配失败保留旧配置、证书和订阅。
- rotate-token：生成新的 256-bit 随机 URL 令牌。重启及 HTTPS 检查成功后旧 URL 失效；失败恢复旧 URL。
- disable：停止订阅 HTTPS、取消自启并移除本项目登记的订阅规则；保留私有设置和证书。重新 enable 会复用令牌，若旧链接泄漏应先轮换。
- status/show：只读本地状态，不进行网络探测。status 的 active 仅表示进程运行，不能代替外网访问测试。
- hihy uninstall：先移除本项目订阅服务、私有 Caddy、账户和文件，再按原流程卸载 HY2。不会删除系统 Caddy 或无关规则。

服务名为 hihy-sub.service。独立 hihy-sub 用户运行 HTTPS，仅授予绑定低端口的能力；启动前以 root 恢复本项目登记的防火墙规则。配置和快照由 root 持有，服务仅可读，只有自己的证书存储可写。原 HY2 守护进程仍沿用既有权限模型。

## URL 与凭据保护

URL 是 bearer secret：知道它的人可以下载代理密码、Realm token 和完整客户端配置。请通过可信渠道保存与传递，不要贴到公开日志、第三方订阅转换网站、截图或群聊。响应设置 private/no-store 和 Vary: User-Agent，禁用目录浏览、访问日志、ETag/Last-Modified 和范围/条件请求；代理或客户端自身的历史记录仍可能保留 URL。

轮换 URL 不会撤销已下载的代理密码。泄漏后同时更换 HY2 密码，并让所有客户端更新订阅。完整订阅默认禁止 LAN 代理和 DNS 监听；sing-box App 使用 VPN/TUN。原本地桌面 sing-box 导出继续使用回环 mixed 端口。

原生自签模式仍使用有效证书指纹；mihomo 使用指纹，sing-box 嵌入 CA 并保持 insecure=false。不会为了兼容而移除必要安全字段。用户手动编辑服务配置后，应执行 refresh；手动修改不受事务保护。

## 已有整改版的人工部署

全新安装请按 SECURITY_INSTALL.md（仓库 md/security-install.md）操作。install.sh 仍拒绝覆盖已有安装；没有新增从原作者/其他 fork 自动迁移的功能。

如果服务器已经是本仓库的 ver1.20-secure.1，先核对来源、路径、完整包摘要并备份 /usr/bin/hihy、/etc/hihy 和相关服务/防火墙记录。管理员可在没有其他 hihy 操作时，将本包 hy2.sh 和四份本地语言文件一起人工更新到现有脚本/语言位置，保留 0700/0600 权限；不更换内核或服务配置。此操作是审核后的本地脚本部署，不是旧安装器迁移。不要通过删除原配置来绕过安装检查。本次虚拟机测试使用了这类本地脚本替换，并另外验证完整包全新安装。

如果已有订阅，关闭后再更换脚本包。回退到没有订阅支持的旧脚本前，先执行 sudo hihy subscription disable，并保留当前包以便清理；需要完全移除时，当前版本的 hihy uninstall 会一并移除订阅与 HY2。不要让旧脚本负责清理它不认识的订阅服务。

## 验证边界

实际通过和未完成的测试见 SUBSCRIPTION_TEST_REPORT.md（仓库 md/subscription-test-report.md）。UA 模拟与真实 Linux 内核连接测试不代表 Windows/Android/iOS/macOS 图形界面已经实测。没有用户域名和服务器连接信息时，不能替你创建公网可用的最终 URL；将本包部署到你的服务器并 enable 域名后生成。

参考的官方实现：v2rayN 7.25.6 的自定义订阅处理、Clash Verge Rev 2.5.10 的远程配置处理、sing-box 官方客户端远程配置/URL scheme，以及 Caddy 2.11.9 的 TLS/请求路由配置。兼容基线为本轮验证版本，不承诺任意旧版本或修改版客户端。
