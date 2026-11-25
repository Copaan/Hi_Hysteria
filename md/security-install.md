# Hi_Hysteria 安全整改版安装说明

版本：ver1.20-secure.1。基于 ver1.20 / 649ae47。维护日期：2026-11-26。

## 安装前

本包面向 Debian/Ubuntu 的全新 HY2 安装。已完成的实测平台与未完成项见同包 TEST_REPORT.md（仓库内为 md/security-test-report.md）。默认安装 Hysteria 2.14.0；客户端兼容基线为 mihomo 1.19.34、sing-box 1.14.4。yq 固定为 4.54.3，安装在 /etc/hihy/bin/yq。当前固定 yq 摘要覆盖 amd64、arm64；其他架构会明确失败。arm64 未完成实机回归。

请先从可信渠道获取并审核整个安装包及其 SHA256。不要执行旧 README、旧 Release 或任意 main 分支中的远程一键安装命令；旧引导脚本可能覆盖本轮修改。本仓库不证明原作者或第三方代码可信，也不对历史版本作全面审计结论。

安装包的外部 .sha256 和包内 SHA256SUMS 用于验证完整性。与文件一起被替换的摘要不能提供发布者身份认证。默认 Hysteria 2.14.0 的官方清单摘要及 yq 摘要固化在已审核源码中；主动升级到其他版本时，仍依赖官方 GitHub/TLS 返回的摘要清单，尚无独立发布签名验证。

## 从完整本地包安装

在可信机器核对外部摘要后，将包复制到服务器，再执行：

~~~bash
sha256sum -c hihy-ver1.20-secure.1.tar.gz.sha256
tar -xzf hihy-ver1.20-secure.1.tar.gz
cd hihy-ver1.20-secure.1
sha256sum --strict -c SHA256SUMS
sudo bash install.sh --lang zh
~~~

菜单中选择安装。也可以执行自动配置安装（会生成随机服务密码）：

~~~bash
sudo bash install.sh --auto --lang zh
~~~

从审核后的源码工作区安装时，先运行 bash scripts/build.sh，再以 root 执行 bash server/install.sh --lang zh。不要单独复制 install.sh；必须同时提供 hy2.sh、四份语言文件和 SHA256SUMS。包不完整、摘要不符或检测到现有内核、配置、服务脚本时立即停止，不自动迁移或覆盖。已有安装应先单独备份并制定迁移方案，不要为了绕过检查而删除配置。

防火墙只管理本项目新建并登记的规则。云平台安全组仍需由管理员按实际 UDP 端口及跳跃范围放行；HTTP ACME 还需要 80/TCP。请保留服务器管理入口。

## 日常操作与升级

- hihy：本地菜单；hihy 6：状态；hihy 8：导出；hihy 9：重新配置。
- hihy 7：仅这项主动操作会查询官方当前稳定内核，并校验后更新。
- hihy updateHysteriaCore app/v2.14.0：指定版本，不查询 latest；已有相同版本时不重复安装。
- 菜单 11 / hihyUpdate 保留为本地提示，不联网，也没有重新分配给其他功能。
- 脚本更新只能审核完整本地包后人工部署。本版安装器不实现旧安装迁移。
- 服务带 --disable-update-check；菜单、状态、导出和重配不检查脚本/内核软件版本，不下载语言包。重配显式选择 Mimic 时仍可能查询并安装该可选依赖。

下载和摘要/ELF 架构校验在停服前完成。配置、证书和 ACL 先暂存，使用本次验证进程的精确 PID 检查真实启动。验证和切换失败恢复旧文件及原运行状态；原来停止的服务完成内核升级后仍保持停止。断电、内核崩溃和 SIGKILL 不受 Shell 退出陷阱保障，重要配置仍应另行备份。

## 凭据与客户端

- 安装操作使用 umask 077；/etc/hihy 下目录为 0700，配置、私钥、备份和导出为 0600。外部导入证书的原始文件仍由管理员负责保护。
- 客户端文件位于 /etc/hihy/result/，使用清理后的备注加摘要命名，备注不再控制路径。保留原有分流用途及规则更新来源。
- 原生客户端使用有效 SHA256 指纹绑定。其自签配置中的 insecure: true 与 pinSHA256 配套，不能删掉指纹只保留 insecure。
- mihomo 使用证书指纹；sing-box 自签模式嵌入受信任 CA。缺少必要信任材料或客户端不支持已选择的功能时，明确拒绝对应导出。
- 三类客户端代理、mihomo DNS 默认只监听回环地址。确实需要局域网访问时执行 sudo env HIHY_CLIENT_ALLOW_LAN=true hihy 8；请同时配置客户端侧访问控制。此选项不等于启用了代理认证。
- 终端输出、二维码和分享链接本身含凭据，请勿公开日志、录屏或导出文件。建议使用完整配置文件；导入分享链接后需确认客户端保留指纹/ECH 等必要字段。
- 统计 API 仅监听 127.0.0.1，使用独立随机密钥。它与代理密码不同。

## 可选功能与依赖边界

Realm、Mimic、WARP、三种伪装模式和分流菜单均保留，默认不自动开启。

WARP 只有显式选择才允许执行，且需要管理员审核过的固定 GitLab 提交 URL 和对应 SHA256：

~~~bash
sudo env HIHY_WARP_URL='https://gitlab.com/fscarmen/warp/-/raw/<40位提交>/menu.sh' \
  HIHY_WARP_SHA256='<64位SHA256>' hihy
~~~

这是输入格式示例，不能原样执行。未提供可信固定值时失败；不会运行当前目录遗留的 menu.sh。已安装的 WARP 仍可复用。审核入口文件不能保证第三方脚本后续下载链可信，第三方内部行为不在本轮完整审计范围。

Mimic 只有显式开启才安装；固定本次解析的 release 标签并严格检查其 .deb 摘要。安装失败中止配置，不静默关掉该功能。Mimic/DKMS 会修改系统、需要 root，不属于私有 yq 依赖；卸载 Hi_Hysteria 不移除共享 WARP、Mimic 或系统 yq。

文件伪装默认目录 /etc/hihy/file 不存在时，仍会部署 mikutap，但使用固定提交 fb292bc1c3b3a29d80feaac2dbe93fca981776ee 和固化 SHA256，并在私有暂存目录验证、解包。自定义目录必须已存在且为绝对路径；不会向任意新路径下载和解包。代理伪装的 HTTPS 上游启用证书验证，验证失败不会降级。

## 构建、验证与边界

~~~bash
bash scripts/build.sh
bash server/test_build.sh
bash scripts/i18n-validate.sh
bash scripts/package.sh
~~~

产物位于 dist/。构建统一 LF，包只包含运行脚本、本地语言、摘要、许可证及安全/测试说明；不会包含 .devtools 中的虚拟机、测试 SSH 密钥和日志。

仅在可丢弃 Linux 虚拟机/容器中创建 /etc/hihy-test-environment 标记后运行 test_lifecycle.sh、test_server_edits.sh 和 test_transport.py；它们会安装、重配和卸载 /etc/hihy，不能在生产服务器运行。CI 配置了 Debian 12、Ubuntu 24.04 容器回归，但提交 CI 配置不代表远端流水线已实际通过。

保留现有 rc.d/OpenRC 服务架构，没有承诺消除 root 常驻。取消了实时调度；专用账户、按功能拆分能力和服务架构改造留待独立工作。旧 HY1 安装链、第三方项目内部代码、所有操作系统/硬件组合及公网 ACME/DNS 账户端到端申请不在本轮完整验收范围。
