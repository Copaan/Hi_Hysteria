# Hi Hysteria

Hysteria2 安装与管理脚本，提供中文菜单、三类客户端配置和 HTTPS 订阅。

## 安装

支持 Debian / Ubuntu，amd64 / arm64。使用 root 或 sudo 运行。

下载安装脚本并打开菜单：

~~~bash
curl --proto '=https' --proto-redir '=https' -fL --retry 2 --connect-timeout 10 --max-time 180 \
  -o install.sh https://raw.githubusercontent.com/Copaan/Hi_Hysteria/main/server/install.sh &&
sudo bash install.sh
~~~

也可以直接下载 [install.sh](https://raw.githubusercontent.com/Copaan/Hi_Hysteria/main/server/install.sh)，上传服务器后执行：

~~~bash
sudo bash install.sh
~~~

脚本会自动安装缺失依赖、创建目录并进入中文菜单。选择 **1** 交互安装，或选择 **16** 自动安装。以 root 登录时可以省略 sudo。

自动安装并生成端口、密码和客户端配置：

~~~bash
sudo bash install.sh --auto
~~~

安装后使用 hihy 管理。已有安装不重复覆盖；需要调整配置时使用菜单 **9**。

## 常用操作

| 命令 | 用途 |
| --- | --- |
| hihy | 打开菜单 |
| hihy 3 / hihy 4 / hihy 5 | 启动 / 停止 / 重启 |
| hihy 6 | 查看状态 |
| hihy 7 | 升级 Hysteria 内核 |
| hihy 8 | 导出客户端配置和分享链接 |
| hihy 9 | 重新配置 |
| hihy 12 | 管理 ACL 分流 |
| hihy 13 / hihy 14 | 查看流量 / 日志 |
| hihy 15 | 配置 SOCKS5 出站 |
| hihy 17 | 管理 HTTPS 订阅 |
| hihy 2 | 卸载 |

配置文件位于 /etc/hihy/conf/，客户端导出位于 /etc/hihy/result/。客户端可以使用 Hysteria 原生、mihomo 或 sing-box 配置。

## HTTPS 订阅

将自己的订阅域名直接解析到服务器，使用 DNS-only，并开放公网 TCP 443。该端口需要空闲；使用 Mimic 时先关闭 Mimic，再启用三端订阅。

~~~bash
sudo hihy subscription enable sub.example.com
sudo hihy subscription show
~~~

复制输出的同一个订阅地址到客户端：

| 客户端 | 导入方式 |
| --- | --- |
| v2rayN | 订阅分组选择自定义核心 hysteria2，前置 SOCKS 端口设置为 20808 |
| Clash Verge Rev | 作为远程配置导入 |
| 官方 sing-box Android / iOS / macOS App | 添加远程配置，或使用输出的 sing-box 导入链接 |

~~~bash
sudo hihy subscription refresh       # 更新订阅内容
sudo hihy subscription rotate-token  # 更换订阅地址
sudo hihy subscription disable       # 关闭订阅
~~~

## 更多用法

- [安装与管理](md/security-install.md)
- [自动安装参数](md/onekey.md)
- [订阅设置](md/subscriptions.md)
- [客户端设置](md/client.md)
- [证书](md/certificate.md) · [防火墙](md/firewall.md)
- [伪装网站](md/masquerade.md) · [ECH](md/ech.md) · [Realm](md/realm.md) · [Mimic](md/mimic.md)

## 开发构建

~~~bash
bash scripts/build.sh
bash server/test_build.sh
bash scripts/package.sh
~~~

生成 server/hy2.sh、独立 server/install.sh 和校验清单；分发文件位于 dist/。

[许可证](LICENSE)
