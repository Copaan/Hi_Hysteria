# 安装与管理

## 下载并运行

在 Debian / Ubuntu 服务器上，以 root 或 sudo 执行：

~~~bash
curl --proto '=https' --proto-redir '=https' -fL --retry 2 --connect-timeout 10 --max-time 180 \
  -o install.sh https://raw.githubusercontent.com/Copaan/Hi_Hysteria/main/server/install.sh &&
sudo bash install.sh
~~~

可以通过浏览器下载同一个文件，再上传到服务器执行。只需要 install.sh，不需要下载项目目录或语言文件。

安装器自动准备缺失依赖和目标目录，然后显示中文菜单：选择 1 进入安装向导，选择 16 使用自动配置。

~~~bash
sudo bash install.sh --auto  # 自动安装
bash install.sh --help       # 查看用法
~~~

以 root 登录时可以省略 sudo。安装文件保留在当前目录，之后直接使用 hihy 管理服务。

## 已安装的服务器

~~~bash
sudo hihy       # 打开管理菜单
sudo hihy 6     # 查看状态
sudo hihy 8     # 查看与导出客户端配置
sudo hihy 9     # 修改服务配置
sudo hihy 7     # 升级内核
sudo hihy 2     # 卸载
~~~

install.sh 不覆盖已有或未完成的安装。先用 hihy 检查现有状态，再按需调整配置或卸载后重新安装。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| /usr/bin/hihy | 管理程序 |
| /etc/hihy/bin/ | Hysteria 内核和私有工具 |
| /etc/hihy/conf/ | 配置和备份 |
| /etc/hihy/cert/ | 证书 |
| /etc/hihy/result/ | 客户端配置与分享信息 |
| /etc/hihy/logs/ | 服务日志 |

## 使用压缩包

也可以解压版本对应的 hihy-*.tar.gz，在解压目录执行：

~~~bash
sha256sum --strict -c SHA256SUMS
sudo bash install.sh
~~~

## 订阅

将订阅域名解析到服务器，开放公网 TCP 443 后执行：

~~~bash
sudo hihy subscription enable sub.example.com
sudo hihy subscription show
~~~

详细操作见 SUBSCRIPTIONS.md（仓库 md/subscriptions.md）。
