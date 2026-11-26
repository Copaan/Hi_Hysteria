# HTTPS 订阅

## 准备域名

- 将订阅域名的 A / AAAA 记录指向服务器。没有可用 IPv6 时不设置 AAAA。
- 使用 DNS-only 解析，并在服务器防火墙、云安全组和 NAT 放行 TCP 443。
- TCP 443 需要空闲；若已有网站服务或 TCP 伪装占用该端口，先调整配置。Hysteria 的 UDP 443 可以继续使用。
- 当前三端订阅不支持 Mimic；先关闭 Mimic 再启用订阅。

## 启用和导入

首次交互安装时，在证书和域名选择之后、端口配置之前设置订阅，默认选择“是”。ACME／本地证书模式会预填当前域名，可以修改；自签模式另填自己的订阅域名，留空跳过。订阅会在 Hysteria 启动成功后自动启用并显示地址，不再重复询问。自动安装和重新配置不会新增询问，可随时从菜单 17 启用。

~~~bash
sudo hihy subscription enable sub.example.com
sudo hihy subscription show
~~~

也可以从 hihy 菜单 17 操作。首次启用会自动安装私有 Caddy、申请 HTTPS 证书并生成订阅地址。

同一个地址根据客户端返回完整配置：

| 客户端 | 操作 |
| --- | --- |
| v2rayN | 新建订阅分组，选择 CustomCoreType=hysteria2，设置 PreSocksPort=20808，再更新订阅 |
| Clash Verge Rev | 新建远程配置并粘贴订阅地址 |
| 官方 sing-box App | 添加远程配置，或打开输出的 sing-box 导入链接；按系统提示允许 VPN/TUN |

配置使用 Hysteria 2.14.0、mihomo 1.19.34、sing-box 1.14.4 对应的字段。sing-box App 订阅包含 TUN；本地导出的桌面配置使用回环 mixed 入口。

如果客户端无法自动识别，使用输出的对应格式地址：

- ?format=hysteria：Hysteria 原生配置。
- ?format=mihomo：mihomo 完整配置。
- ?format=singbox：sing-box App 完整配置。

## 日常管理

~~~bash
sudo hihy subscription status        # 查看状态
sudo hihy subscription show          # 显示地址
sudo hihy subscription refresh       # 重新生成订阅内容
sudo hihy subscription rotate-token  # 更换地址，使旧地址失效
sudo hihy subscription disable       # 停止订阅服务
~~~

重新配置或导出客户端文件后，订阅会同步更新。更换地址后，在各客户端替换订阅 URL；需要撤销已下载的连接凭据时，同时使用 hihy 9 修改代理密码。

关闭后可以再次 enable；关闭操作保留域名和证书。修改订阅域名时先 disable，再使用新域名 enable。

## 服务与卸载

~~~bash
sudo systemctl status hihy-sub.service
sudo hihy 2
~~~

hihy 2 会同时卸载 Hysteria 和本项目订阅组件。仅需关闭 HTTPS 订阅时使用 subscription disable。
