# 流媒体协议安装工具

面向 Debian、Ubuntu 和 RHEL 系发行版的 FTP、SFTP、WebDAV 多账户管理脚本。

## 一键安装并运行

```bash
sudo bash -lc 'curl -fsSL https://raw.githubusercontent.com/YuFan08/spm/main/deploy.sh -o /usr/local/bin/spm && chmod +x /usr/local/bin/spm && exec spm'
```

脚本启动后直接按 Enter，可进入一键安装全部协议流程。

## 功能

- 管理多个 FTP、SFTP 和 WebDAV 账户
- 新增、修改或 purge 指定账户
- 管理 FTP 密码和 SFTP 登录方式
- 自定义服务端口与数据目录
- purge 时保留 FTP、SFTP 和 WebDAV 数据目录

## 注意

SFTP 与普通 SSH 共用 `sshd` 服务和端口。默认使用端口 `22` 不会影响普通 SSH 登录；修改 SFTP 端口会同时改变普通 SSH 登录端口。

执行前建议检查脚本内容：

```bash
curl -fsSL https://raw.githubusercontent.com/YuFan08/spm/main/deploy.sh | less
```
