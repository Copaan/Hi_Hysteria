# 单地址订阅实际测试记录

日期：2026-11-26。交付版本：ver1.21-secure.1。开发基线：a339170（此前三批安全整改之后）。本记录针对新增订阅、客户端 App 配置及其直接依赖，不替代 md/security-test-report.md 的历史记录。

## 环境和方法

复用 Windows 宿主上的隔离 Debian 12 amd64 QEMU 虚拟机，真实 systemd、防火墙、Caddy 2.11.9、Hysteria 2.14.0、mihomo 1.19.34、sing-box 1.14.4。全部域名、URL token、密码、私钥都是可丢弃测试数据，未连接或改动用户生产服务器。

HTTPS 测试使用仅在测试环境信任的临时 CA 和 sub.example.test 叶证书。生产配置的 Caddyfile 已由真实 Caddy validate 检查；生命周期测试仅替换证书签发器和域名 DNS 检查，其余发布、权限、systemd、HTTPS 探测、回滚及防火墙代码均使用实际实现。此方法验证 TLS/SNI 和 CA 校验，不声称完成公网 Let's Encrypt ACME 申请/续期。

## 已完成的验证

- 完整三份配置生成；原生/mihomo YAML 与 sing-box JSON 包含既有业务配置。真实 mihomo -t、sing-box check 通过；sing-box App 版含 TUN/DNS 劫持而原桌面导出保留 mixed 入口。
- 固定摘要官方 Caddy 安装、真实 Caddyfile 校验、systemd-analyze verify、真实非 root Caddy 启动。篡改二进制摘要、非 ELF 架构均在执行前拒绝。
- 一个真实 HTTPS URL 按 v2rayN、Clash Verge、mihomo、SFA/SFI/SFM UA 返回逐字节一致的相应完整文件。显式格式、未知 UA/格式、错误 token、路径穿越、直读文件、POST/HEAD 及缓存/条件/范围请求检查通过。
- 普通用户无法读取私有状态/订阅凭据，订阅账户无法读取 HY2 服务配置。Caddy 实际仅绑定 TCP 443，未监听 UDP 443、HTTP 80 或管理端口 2019。
- 初次 HTTPS 校验失败回滚、令牌轮换成功后旧 URL 404、轮换后 HTTPS 探测失败与重启失败均恢复原 token、文件及活动服务。
- HY2 重配成功时发布新订阅；注入发布失败时还原服务配置及订阅快照。启用订阅时尝试 Mimic，在第三方安装之前拒绝。失败代内容不被无限留存。
- status、show、refresh 在隔离网络命名空间内完成，不依赖外网；正常导出与重配未增加软件版本查询。
- 关闭、重新启用、卸载订阅后，原 HY2、无关防火墙规则及系统 /usr/bin/caddy 保留。

- 实际重启 Debian 虚拟机后，两项服务自动恢复；订阅仍为非 root，实际有效能力仅 CAP_NET_BIND_SERVICE，IPv4/IPv6 独立订阅规则恢复，三份 HTTPS 内容摘要保持不变。错误 CA 和错误 SNI 被拒绝，大小写域名的重复启用也通过。
- 完整本地 tar.gz 的运行文件逐项校验通过；全新安装成功并启动 HY2，订阅默认关闭。已有安装覆盖被拒绝；最终完全卸载保留系统 Caddy 和无关规则，随后关闭测试虚拟机。
- ShellCheck error 级别、Bash 语法、语言占位符、源码/生成文件一致性、特殊字符与权限回归通过。测试中的预期错误日志来自负向用例，不代表验收失败。

## 真实连接结果

| 测试配置 | Hysteria 原生 | mihomo | sing-box SOCKS | sing-box 完整 App TUN |
| --- | --- | --- | --- | --- |
| 常规配置 | 通过 | 通过 | 通过 | 通过 |
| Gecko + ECH + aggressive BBR | 通过 | 通过 | 通过 | 通过 |
| 端口跳跃 | 通过 | 通过 | 通过 | 通过 |

三类内核分别拒绝错误密码和错误证书信任材料；重配失败恢复、sniff.enable 的 HTTP Host ACL、固定默认伪装站点的受信任 HTTPS 访问也通过。传输脚本输出 18 条结果，详见 subscription-transport.log。

## 传输测试口径

server/test_transport.py 在 HIHY_TEST_SUBSCRIPTION=1 下通过真实 HTTPS 和客户端 UA 下载配置，而非读取旧本地导出代替。三内核连接矩阵保持此前隔离传输测试方法：对 mihomo / sing-box 的 SOCKS 传输测试，调整测试端口并用确定性的代理路由隔离认证、TLS 和传输行为；不能把这部分称作所有原始规则的端到端验证。

另外增加独立真实 Linux TUN 测试：直接运行从 HTTPS 下载的完整、未修改 sing-box App JSON，包括原有远程规则。隔离命名空间禁止到测试目标的直连；启动前与退出后访问失败，TUN 运行时 HTTP 访问成功。最初测试中的黑洞路由优先于 TUN 规则，已改用出口防火墙限制直连后验证，不将测试隔离规则的问题归为生产配置故障。

## 未覆盖与剩余风险

- 未进行 v2rayN / Clash Verge Rev 图形界面及 Android / iOS / macOS 真机导入、系统 VPN 权限和后台更新实测；UA 分发与 Linux 内核测试不能代替这些测试。
- 未使用用户公网域名执行 ACME 申请/续期、云安全组/NAT 外网访问、CDN 场景或移动网络验证。部署时仍须正确 DNS-only 解析、开放 TCP 443，并确认客户端能够访问订阅域名。
- Ubuntu 24.04、arm64 未在本轮本地实测。此前 Ubuntu 虚拟机启动被执行策略拒绝，本轮没有重试。新增独立 systemd GitHub Actions job 仅是可执行测试配置，未推送或运行远端 CI。
- Realm 的实际外部 rendezvous 和 Mimic 第三方内核模块不在本轮端到端范围；原功能保留。Mimic 与三端订阅不兼容时明确拒绝，不伪造可用结果。
- 外部规则站点的可达性及规则内容仍影响客户端，未转为离线规则包。sing-box 1.14 对保留的 download_detour 会提示未来弃用（预计 1.16 移除）；本轮未迁移全部格式，不能据此承诺 1.16 兼容。
- 原 HY2 服务仍可能 root 常驻；新增 HTTPS 服务使用专用账户。Shell 事务不能保证断电/SIGKILL 时自动恢复，生产配置需要独立备份。
- URL 令牌本身授予读取代理凭据的能力。轮换 URL 不能撤回已下载的代理密码。

## 交付与证据

实现提交：242fd76。运行脚本 server/hy2.sh 的 SHA256：

~~~text
1481e1864801b9f145768d2525cdfc07802d38c7190813703be81d4539c7a61d
~~~

最终安装包：dist/hihy-ver1.21-secure.1.tar.gz；包校验值见同目录 .sha256 文件。验收后仅补充本说明与日志并重新打包，运行文件与 Linux 安装验收使用的文件一致。包检查覆盖清单、路径安全、私有权限、LF、JSON 和生成脚本的逐字节一致性。

仓库 md/test-results/ 下保留脱敏证据：subscription-prepare.log、subscription-lifecycle.log、subscription-regression.log、subscription-transport.log、subscription-reboot.log、subscription-package.log。运行时语言文件、服务密码和 URL token 不包含在这些日志中。源码、生成脚本、测试和文档一并交付；未推送远端。

## 复现入口

仅在可丢弃环境并存在 /etc/hihy-test-environment 标记时运行安装/生命周期/传输测试。不要在生产机创建该标记来运行测试。

~~~bash
bash scripts/build.sh
bash server/test_build.sh
bash scripts/i18n-validate.sh
bash server/test_client_config.sh
bash server/test_security.sh
sudo env HIHY_SUB_TEST_KEEP=1 bash server/test_subscription_lifecycle.sh
sudo env HIHY_TEST_SUBSCRIPTION=1 \
  CURL_CA_BUNDLE=/var/lib/hihy-sub/caddy/test-ca.crt \
  HIHY_TEST_CORES=/path/to/verified/cores python3 server/test_transport.py
~~~

重启验证使用 server/test_subscription_reboot.sh prepare，管理员重启可丢弃 VM 后执行同脚本 verify。

该 systemd 测试要求先安装测试 HY2；保留状态后应完成重启检查并使用当前版本 hihy uninstall 清理。普通 Docker --init 容器不提供本测试需要的完整 systemd。
