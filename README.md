# Docker Mailserver 一键安装脚本

## 介绍

Docker Mailserver 是一个基于 Docker 的邮件服务器，使用 Postfix, Dovecot, Rspamd, ClamAV, Roundcube 等组件构建，支持多域名、多用户、Web 邮件客户端等功能。

本脚本可以在 Ubuntu 系统上一键安装 Docker Mailserver，并配置阿里云解析的 DNS 记录。

## 要求

- Ubuntu 22.04 (推荐)
- 一个域名，例如 `example.com`

## 使用方法
```bash
curl -sL https://raw.githubusercontent.com/FlyRenxing/DMS-install/main/install.sh | bash -s -- 域名 IP 阿里云AccessKeyID 阿里云AccessKeySecret 默认发件人名称
```

## 示例
```bash
curl -sL https://raw.githubusercontent.com/FlyRenxing/DMS-install/main/install.sh | bash -s -- example.net 123.123.123.123 dfghI5tPxV14321432zn5jhPj SDFW8Sqmf14523CxwoDksj142UUzU admin
```