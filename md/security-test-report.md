# 安全整改验收记录

日期：2026-11-26。源码基线：649ae474ee26d462f21672e9644fcc3a696353de；交付版本：ver1.20-secure.1。

## 环境与方法

- Windows 主机仅用于编辑、Git、打包及启动隔离环境；没有在主机安装 Hysteria 服务。
- 实际运行环境为 QEMU/TCG 中的 Debian 12 amd64，2 vCPU、2 GB RAM；具有独立内核、网络命名空间和 iptables。
- 实测二进制：Hysteria 2.14.0、mihomo 1.19.34、sing-box 1.14.4、yq 4.54.3。下载均经过对应 SHA256 校验。测试脚本 scripts/fetch-test-cores.sh 固化客户端版本和摘要。
- 默认安装使用本地 Windows 构建的分发脚本、四份语言文件和摘要清单；不在 Linux 中悄悄重新生成另一份清单来掩盖跨平台问题。
- 全部集成测试都使用明确标记的可丢弃环境。没有在用户生产服务器执行安装、卸载或防火墙操作。

## 已完成的检查

| 检查 | 证据 / 实际覆盖 |
| --- | --- |
| 构建 | Bash 语法、ShellCheck error 级、24 个模块与生成脚本逐字节一致、LF 和 SHA256 清单 |
| 本地包 | 完整包通过；修改内容、缺文件、清单缺项和符号链接拒绝 |
| 下载失败 | 注入 curl TLS 错误、超时和传输中断；错误摘要与 ELF 架构拒绝；旧文件不被覆盖、错误架构不执行 version 探测 |
| 序列化 | 引号、反斜杠、换行、URI 特殊字符、路径穿越备注、true/null/00123/-n/-e 字符串、无效键路径和端口 |
| 无后台更新 | 菜单、自更新占位及 WARP 未校验入口使用联网哨兵；实际配置编辑、状态/导出与统计操作不调用核心版本查询 |
| 安装生命周期 | 完整本地包全新安装、真实启动、重启、停止/启动、拒绝覆盖现有安装、无 RR 实时调度 |
| 整机重启 | 比较 boot_id 确认真正重启；服务自动启动、IPv4/IPv6 自有防火墙规则恢复，配置权限及后台更新禁用参数保持 |
| 最小权限 | 配置、私钥、备份和客户端导出为 0600；nobody 无法读取；私有目录 0700 |
| 卸载边界 | 系统 yq 摘要保持不变；无关 iptables 规则、同名风格 HYSTERIA 链及 cron 注释保留；整机重启后再次卸载也清除自身服务与防火墙规则 |
| 配置事务 | 真实内核验证错误证书后失败，旧配置摘要及运行状态恢复 |
| 内核事务 | 停服前下载失败不停止旧服务；注入切换后启动失败，真实旧核心及运行服务恢复；原停止状态的更新经真实启动校验后仍保持停止 |
| ACL / SOCKS | 使用 2.14 acl test 检查实际匹配；父子域名精确删除、恶意输入拒绝；带特殊字符的 SOCKS 凭据写入、删除和 IP 优先级修改后服务正常 |
| 统计接口 | 独立密钥与代理密码不同；代理密码返回 HTTP 401，统计密钥返回 200；回环监听 |
| 客户端 | 三个真实客户端的普通连接、Gecko+ECH+aggressive BBR、端口跳跃成功；逐一拒绝错误密码及错误证书 |
| 嗅探生效 | SOCKS 指定 IP 目标，HTTP Host 命中拒绝规则时连接被拒，正常 Host 可连接；验证 sniff.enable 的实际行为 |
| 文件伪装 | 固定提交和 SHA256 下载的默认站点经真实服务启动，并使用受信任 CA 完成 HTTPS 访问 |
| 高级映射 | 单元覆盖随机跳跃范围、Realm 凭据解码、Mimic 不支持导出时拒绝、BBR profile、ECH；不会自动启用未选择特性 |

集成中发现并修复了 sing-box 1.14 不接受空 direct 出站作为 DNS detour、Hysteria 不按 YAML 读取 .new 暂存扩展名等问题。这些问题未被简单的 YAML/JSON 语法解析发现。

## 连接测试的边界

原生客户端使用完整生成配置；mihomo、sing-box 完整导出另经真实内核配置检查。为使连接测试可重复，其传输测试副本停用远程规则下载、使用固定代理路由并访问测试网络命名空间中的 HTTP 服务。生产导出中的业务分流规则保留。

测试验证的是通过 HY2 QUIC/UDP 承载的实际 TCP 请求，不等于所有 UDP 应用、DNS 分流准确性、规则订阅服务可用性或性能基准均已通过。Realm 的公网打洞、真实 Mimic/DKMS 加载和第三方 WARP 安装没有完成端到端实测。它们的功能入口保留，解析/失败分支有定向测试；不能把这些单元测试描述成网络实测。

TLS/超时/摘要故障通过受控注入模拟；不依赖公网故障碰巧发生。升级启动失败和停止阶段失败也使用受控故障注入，恢复后检查真实服务和原文件摘要，没有伪造成功输出。

## 尚未完成的验收与残余风险

- Ubuntu 独立虚拟机的下载与启动被自动审批拒绝，返回理由只有 blocked by policy。因此本次没有宣称 Ubuntu 已通过实机集成。CI 已安排 Debian 12 / Ubuntu 24.04 容器测试，但尚未运行远端流水线。
- 未覆盖 arm64 实机、公网 ACME/DNS Token 申请续期、OpenRC、UFW/firewalld 的完整系统矩阵。
- 仍保留部分模式下的 root 常驻及原有服务架构。SIGKILL、掉电不在 Shell 事务陷阱保障内。
- 核心更新依赖官方 TLS/摘要供应链；第三方项目内部代码、旧 HY1 安装链不视为已全面审计。

## 复现入口

在已安装 CA、Python、ShellCheck、OpenSSL 及私有 yq 的 Linux 环境，运行 server/test_bootstrap_install.sh、server/test_install_recovery.sh、server/test_security.sh、server/test_auto_config.sh、server/test_client_config.sh、server/test_build.sh 和 scripts/i18n-validate.sh。

在可丢弃 root 环境创建 /etc/hihy-test-environment，再依次执行 server/test_lifecycle.sh、scripts/fetch-test-cores.sh、server/test_server_edits.sh、server/test_transport.py。详细命令及依赖见 .github/workflows/ci.yml。禁止在生产服务器运行这些集成脚本。

## 本次运行日志

仓库 md/test-results/ 保存终端结果（测试凭据均为隔离环境专用；未包含配置、私钥或 SSH 密钥）：final-core-tests.log、final-lifecycle-tests.log、final-rollback-tests.log、final-package-install.log、boot-check.log、post-reboot-uninstall.log。安装包中的运行脚本 SHA256 为 f29228e1754ceb8a8989e70bae3579d80336cecf5171f5c72c6d04636283b012，与最终包安装后的 /usr/bin/hihy 一致。
