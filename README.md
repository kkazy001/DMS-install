# Docker Mailserver 一键安装脚本

## 介绍

本脚本可以在 Ubuntu 系统上一键安装 Docker Mailserver，并配置阿里云解析的 DNS 记录。

## 要求

- Ubuntu 22.04

## 使用方法
```bash
curl -sL https://raw.githubusercontent.com/用户名/DMS-install/main/install.sh | bash -s -- 域名 IP 阿里云AccessKeyID 阿里云AccessKeySecret 默认发件人名称
```