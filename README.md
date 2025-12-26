# sing-box Management Script

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

