# Sing-box Management Script

![License](https://img.shields.io/github/license/SHINYUZ/sing-box?color=blue) ![Language](https://img.shields.io/badge/language-Bash-green) ![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)

全能 sing-box 管理脚本，支持多协议配置与管理。

---

## ✨ 功能特性 (Features)

- **多协议支持**: Shadowsocks, VLESS-Reality, VLESS-WS-TLS, Hysteria2, Tuic-V5, Trojan, AnyTLS, Socks5
- **智能管理**:
  - 自动根据网络环境选择 GitHub API 或镜像源下载
  - 自动管理防火墙 (nftables)
  - 快捷指令 `sb` 唤出菜单
- **流量监控**: 实时查看端口流量，支持设置流量限额与自动重置
- **高级功能**:
  - 支持进行节点分流
  - IPv4/IPv6 优先级策略切换
  - 支持设置端口限速
  - BBR 加速一键开启
  - Telegram 机器人通知

---

## 🚀 安装 (Installation)

推荐使用 root 用户运行：

```bash
wget 
```
如果下载失败，请检查 VPS 的网络连接或 DNS 设置

使用镜像加速源下载：

```bash
wget
```
如果下载失败，请使用其他加速源下载

---

## ⌨️ 快捷指令

安装完毕后，直接输入以下命令即可管理：

```bash
sb
```

---

## 🖥️ 主菜单界面

```text
========= Sing-box Script v6.9.59 By Shinyuz =========

 sing-box: v1.12.14

 sing-box: running

======================================================

 1. 添加配置

 2. 更改配置

 3. 查看配置

 4. 删除配置

 5. 分流规则管理

 6. IPv4/IPv6 优先级与策略

 7. 配置流量使用情况

 8. Sing-box 管理

 9. 脚本管理

 0. 退出

请输入选项[0-9]:
```

---

## 🛠 环境要求

- **架构**: AMD64 (x86_64) / ARM64
- **系统**: Debian / Ubuntu / CentOS 等主流 Linux 发行版

---

## 📂 目录结构

脚本安装后的文件与配置默认路径如下：

```text
/etc/sing-box/
├── sing-box              # Sing-box 核心二进制文件
├── config.json           # 节点主配置文件
├── vless_pk.conf         # VLESS-Reality 私钥存储文件
├── tg_notify.conf        # Telegram 通知配置文件
├── *.crt / *.key         # 各协议的 SSL 证书与密钥文件
└── limit_*.conf          # 流量限制/限速记录文件

/usr/bin/sb               # 快捷指令软链接
/etc/systemd/system/      # 系统服务文件 (sing-box.service)
```

---

## ⚠️ 免责声明

1. 本脚本仅供学习交流使用，请勿用于非法用途。
2. 使用本脚本造成的任何损失（包括但不限于数据丢失、服务器被封锁等），作者不承担任何责任。
3. 请遵守当地法律法规。

---

## 📄 开源协议

本项目遵循 [GPL-3.0 License](LICENSE) 协议开源。

Copyright (c) 2025 Shinyuz

---

**如果这个脚本对你有帮助，请给一个 ⭐ Star！**
