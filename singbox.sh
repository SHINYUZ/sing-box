#!/bin/bash

# =========================================================
# 脚本名称: Sing-box Script By Shinyuz (v1.9.4 - Auto Migration)
# 版本: v1.9.4 (自动迁移旧config中的domain_strategy)
# =========================================================

# --- 基础配置 ---
WORKDIR="/etc/sing-box"
CONFIG_FILE="$WORKDIR/config.json"
PK_FILE="$WORKDIR/vless_pk.conf"
TG_CONF="$WORKDIR/tg_notify.conf"
SB_BIN="$WORKDIR/sing-box"
CADDY_BIN="/usr/bin/caddy"
CADDY_FILE="/etc/caddy/Caddyfile"
MONITOR_SERVICE="/etc/systemd/system/singbox-traffic.service"
MONITOR_TIMER="/etc/systemd/system/singbox-traffic.timer"
SCRIPT_VERSION="v1.9.4"
FROM_MODIFY=false
NEED_RELOAD=false
VIEW_ONLY=false

# --- 颜色定义 ---
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
CYAN='\e[0;36m'
SKY='\e[0;36m'
PLAIN='\e[0m'

# =========================================================
# 核心函数
# =========================================================

apply_config() {
    if [[ "$VIEW_ONLY" == "true" ]]; then
        return 0
    fi
    # 1. 检查配置语法
    check_output=$($SB_BIN check -c $CONFIG_FILE 2>&1)
    if [[ $? -eq 0 ]]; then
        # 2. 尝试重载服务
        if systemctl reload sing-box >/dev/null 2>&1; then
            init_nftables  # 【新增】重载成功后立即刷新防火墙规则
            return 0
        else
            systemctl restart sing-box
            sleep 1
            init_nftables  # 【新增】重启成功后立即刷新防火墙规则
            return 0
        fi
    else
        echo -e "${RED}配置文件校验失败！sing-box 可能无法启动。${PLAIN}"
        echo -e "${PLAIN}$check_output${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        echo -e ""
        echo -e ""
        menu
        return 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须使用 root 用户！${PLAIN}"
        exit 1
    fi
}

get_latest_version() {
    # 尝试抓取最新版本号，只等待3秒
    # 如果抓取不到（网络不通），这里会返回空字符串
    wget -qO- -T 3 -t 1 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g'
}

check_dependencies() {
    # ==========================================
    # 1. 强力安装 jq (修复部分机器安装失败问题)
    # ==========================================
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装依赖 jq...${PLAIN}"
        echo -e "" # 【调整】空一行
        
        # [方案A] 尝试使用系统包管理器安装
        if [[ -f /etc/debian_version ]]; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y jq >/dev/null 2>&1
        elif [[ -f /etc/alpine-release ]]; then
            apk update >/dev/null 2>&1
            apk add jq >/dev/null 2>&1
        elif [[ -f /etc/arch-release ]]; then
            pacman -Sy --noconfirm jq >/dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            dnf install -y jq >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y jq >/dev/null 2>&1
        fi

        # [方案B] 强制模式：如果系统安装失败，直接下载二进制文件 (绝杀)
        if ! command -v jq &> /dev/null; then
            echo -e "${YELLOW}系统源安装失败，尝试强制下载 jq 二进制文件...${PLAIN}"
            echo -e "" # 【调整】空一行
            
            # 判断架构
            ARCH=$(uname -m)
            case $ARCH in
                x86_64) jq_arch="amd64" ;;
                aarch64) jq_arch="arm64" ;;
                *) echo -e "${RED}错误: 无法强制安装 jq，不支持的架构 $ARCH${PLAIN}"; exit 1 ;;
            esac

            # 直接下载官方编译好的文件 (使用 ghproxy 加速)
            wget -O /usr/bin/jq "https://ghproxy.net/https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${jq_arch}" >/dev/null 2>&1
            chmod +x /usr/bin/jq
            
            echo -e "${GREEN}jq 强制安装完成${PLAIN}"
        else
            echo -e "${GREEN}jq 安装成功${PLAIN}"
        fi

        # [最终检查]
        if ! command -v jq &> /dev/null; then
            echo -e "${RED}错误：依赖 'jq' 彻底安装失败！脚本无法运行。${PLAIN}"
            exit 1
        fi
        echo -e ""
    fi

    # ==========================================
    # 2. 其他依赖 (nftables, cron)
    # ==========================================
    if ! command -v nft &> /dev/null; then
        if [[ -f /etc/debian_version ]]; then
            apt-get install -y nftables >/dev/null 2>&1
        else
            yum install -y nftables >/dev/null 2>&1
        fi
        systemctl enable --now nftables >/dev/null 2>&1
    fi

    if ! command -v crontab &> /dev/null; then
        if [[ -f /etc/debian_version ]]; then
            apt-get install -y cron >/dev/null 2>&1
        else
            yum install -y cronie >/dev/null 2>&1
        fi
        systemctl enable --now cron >/dev/null 2>&1
    fi

    # ==========================================
    # 3. sing-box 安装核心逻辑 (保持原样)
    # ==========================================
    if [[ ! -f "$SB_BIN" ]]; then
        echo -e "${YELLOW}正在准备安装 sing-box...${PLAIN}"
        echo -e ""  # [空行]
        
        # 1. 架构判断
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) cputype="amd64" ;;
            aarch64) cputype="arm64" ;;
            *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
        esac
        
        # 2. 智能版本检测与策略选择
        echo -e "正在检测网络环境与最新版本..."
        echo -e ""  # [空行]
        
        ONLINE_TAG=$(get_latest_version)
        
        if [[ -n "$ONLINE_TAG" ]]; then
            # 情况A: 成功获取到最新版本
            TAG="$ONLINE_TAG"
            echo -e "检测到最新版本: ${GREEN}${TAG}${PLAIN}"
            echo -e ""  # [空行]
            echo -e "网络策略: ${GREEN}优先官方源${PLAIN}"
            echo -e ""  # [空行]
            USE_MIRROR_FIRST=false
        else
            # 情况B: 获取失败 (IPv6 Only / API不通)
            TAG="v1.12.14" # 保底版本
            echo -e "${YELLOW}无法连接 GitHub API，切换至保底版本: ${TAG}${PLAIN}"
            echo -e ""  # [空行]
            echo -e "网络策略: ${YELLOW}优先镜像源${PLAIN}"
            echo -e ""  # [空行]
            USE_MIRROR_FIRST=true
        fi
        
        # 3. 定义下载地址
        VER_NO_V="${TAG#v}"
        FILENAME="sing-box-${VER_NO_V}-linux-${cputype}.tar.gz"
        URL_OFFICIAL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/${FILENAME}"
        URL_MIRROR="https://gh-proxy.com/https://github.com/SagerNet/sing-box/releases/download/${TAG}/${FILENAME}"

        mkdir -p $WORKDIR
        DOWNLOAD_SUCCESS=0

        # 4. 执行下载
        if [[ "$USE_MIRROR_FIRST" == "true" ]]; then
            # === 策略B: 优先镜像 ===
            echo -e "正在下载..."
            echo -e ""  # [空行]
            wget -T 20 -t 2 -O sb.tar.gz "$URL_MIRROR"
            if [ $? -eq 0 ]; then
                DOWNLOAD_SUCCESS=1
            else
                echo -e "${YELLOW}镜像源失败，尝试官方源...${PLAIN}"
                wget -T 5 -t 1 -O sb.tar.gz "$URL_OFFICIAL"
                if [ $? -eq 0 ]; then DOWNLOAD_SUCCESS=1; fi
            fi
        else
            # === 策略A: 优先官方 ===
            echo -e "正在下载..."
            echo -e ""  # [空行]
            wget -T 10 -t 1 -O sb.tar.gz "$URL_OFFICIAL"
            if [ $? -eq 0 ]; then
                DOWNLOAD_SUCCESS=1
            else
                echo -e "${YELLOW}官方源超时，自动切换镜像源...${PLAIN}"
                wget -T 15 -t 2 -O sb.tar.gz "$URL_MIRROR"
                if [ $? -eq 0 ]; then DOWNLOAD_SUCCESS=1; fi
            fi
        fi

        if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
            echo -e ""
            echo -e "${RED}下载失败！${PLAIN}"
            echo -e "请检查网络连接。如果是 IPv6 Only 机器，请确保 DNS 解析正常。"
            rm -f sb.tar.gz
            exit 1
        fi

        # 5. 解压安装
        echo -e "${GREEN}下载成功，正在安装...${PLAIN}"
        tar -zxvf sb.tar.gz -C $WORKDIR >/dev/null 2>&1
        
        # 智能查找解压后的目录
        EXTRACTED_DIR=$(tar -tf sb.tar.gz | head -1 | cut -f1 -d"/")
        if [[ -d "$WORKDIR/$EXTRACTED_DIR" && -f "$WORKDIR/$EXTRACTED_DIR/sing-box" ]]; then
            mv "$WORKDIR/$EXTRACTED_DIR/sing-box" $SB_BIN
        else
            echo -e "${RED}解压出错：找不到 sing-box 二进制文件${PLAIN}"
            rm -rf sb.tar.gz
            exit 1
        fi
        
        chmod +x $SB_BIN
        rm -rf sb.tar.gz $WORKDIR/sing-box-*
        rm -f $WORKDIR/geosite.db $WORKDIR/geoip.db
        
        # 写入 Service
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target
[Service]
User=root
WorkingDirectory=$WORKDIR
ExecStart=$SB_BIN run -c $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        
        echo -e ""  # [空行]
        echo -e "${GREEN}sing-box 安装完成!${PLAIN}"
        echo -e ""
    fi
    
    # --- 配置文件检查 ---
    if [[ ! -f "$CONFIG_FILE" ]] || ! jq . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "{ \"log\": { \"level\": \"info\" }, \"inbounds\": [], \"outbounds\": [{\"type\":\"direct\",\"tag\":\"direct\"},{\"type\":\"block\",\"tag\":\"block\"}], \"route\": {\"rules\": [], \"rule_set\": [], \"final\": \"direct\"} }" > $CONFIG_FILE
    else
        if [[ $(jq '.route' $CONFIG_FILE) == "null" ]]; then
             jq '. + {"route": {"rules": [], "rule_set": [], "final": "direct"}}' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
        fi
        if [[ $(jq '.route.rule_set' $CONFIG_FILE) == "null" ]]; then
             jq '.route += {"rule_set": []}' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
        fi
        if [[ $(jq '[.outbounds[] | select(.tag == "block")] | length' $CONFIG_FILE) -eq 0 ]]; then
             jq '.outbounds += [{"type":"block","tag":"block"}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
        fi
    fi
    
    # [Bug1 Fix] 自动迁移已有 config.json 中残留的旧 domain_strategy 字段
    if jq -e '[.outbounds[] | select(.domain_strategy != null)] | length > 0' $CONFIG_FILE >/dev/null 2>&1; then
        jq '(.outbounds[] | select(.domain_strategy != null)) |= (. + {"domain_resolver": {"server": "local-dns", "strategy": .domain_strategy}} | del(.domain_strategy))' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    fi

    # [Bug1 Fix] 自动迁移已有 outbound 中的旧 domain_strategy 字段到 domain_resolver
    if [[ $(jq '[.outbounds[] | select(.domain_strategy != null)] | length' $CONFIG_FILE) -gt 0 ]]; then
        jq '(.outbounds[] | select(.domain_strategy != null)) |= (. + {"domain_resolver": {"server": "local-dns", "strategy": .domain_strategy}} | del(.domain_strategy))' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    fi

    # [Bug1 Fix] 确保 dns.servers 中有 local-dns server（domain_resolver 需要）
    if [[ $(jq '[.dns.servers // [] | .[] | select(.tag == "local-dns")] | length' $CONFIG_FILE) -eq 0 ]]; then
        jq 'if .dns == null then . + {"dns": {"servers": []}} else . end | if .dns.servers == null then .dns.servers = [] else . end | .dns.servers += [{"type":"local","tag":"local-dns"}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    fi
    if [[ $(jq '[.outbounds[] | select(.tag == "ipv4-out")] | length' $CONFIG_FILE) -eq 0 ]]; then
          jq '.outbounds += [{"type":"direct","tag":"ipv4-out","domain_resolver":{"server":"local-dns","strategy":"ipv4_only"}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    fi
    if [[ $(jq '[.outbounds[] | select(.tag == "ipv6-out")] | length' $CONFIG_FILE) -eq 0 ]]; then
          jq '.outbounds += [{"type":"direct","tag":"ipv6-out","domain_resolver":{"server":"local-dns","strategy":"ipv6_only"}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    fi

    if ! systemctl is-active --quiet sing-box; then
        systemctl start sing-box >/dev/null 2>&1
    fi
    
    init_nftables
}

create_shortcut() {
    mkdir -p $WORKDIR
    current=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ ! -f "$WORKDIR/.shortcut_fixed" ]]; then
        if grep -q "alias sb=" ~/.bashrc; then
            sed -i '/alias sb=/d' ~/.bashrc
            unalias sb >/dev/null 2>&1
        fi
        if [[ "$current" != "/usr/bin/sb" ]]; then
            ln -sf "$current" /usr/bin/sb
            chmod +x /usr/bin/sb
        fi
        touch "$WORKDIR/.shortcut_fixed"
        NEED_RELOAD=true
    else
        if [[ "$(readlink -f /usr/bin/sb)" != "$current" ]]; then
            ln -sf "$current" /usr/bin/sb
            chmod +x /usr/bin/sb
        fi
    fi
}

get_random_port() {
    if command -v shuf &> /dev/null; then
        shuf -i 10000-65535 -n 1
    else
        echo $(( $(od -An -N2 -i /dev/urandom | tr -d ' ') % 55535 + 10000 ))
    fi
}

show_banner() {
    local v=$($SB_BIN version | head -n 1 | awk '{print $3}')
    if [[ $(systemctl is-active sing-box) == "active" ]]; then
        s="${GREEN}running${PLAIN}"
    else
        s="${RED}stopped${PLAIN}"
    fi
    echo -e "${GREEN}========= Sing-box Script ${SCRIPT_VERSION} By Shinyuz =========${PLAIN}"
    echo -e ""
    echo -e " sing-box: ${GREEN}${v}${PLAIN}"
    echo -e "" 
    echo -e " sing-box: ${s}"
    echo -e ""
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "" 
}

send_tg_msg() {
    if [[ -f "$TG_CONF" ]]; then
        source "$TG_CONF"
        if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
            curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="$1" >/dev/null 2>&1
        fi
    fi
}

ensure_block_chain() {
    if ! nft list table inet sb_block >/dev/null 2>&1; then
        nft add table inet sb_block
        nft add chain inet sb_block input { type filter hook input priority -300 \; }
    fi
}

close_inbound_port() {
    local idx=$1
    local port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
    ensure_block_chain
    if ! nft list chain inet sb_block input | grep -q "tcp dport $port drop"; then
        nft add rule inet sb_block input tcp dport $port drop
    fi
    if ! nft list chain inet sb_block input | grep -q "udp dport $port drop"; then
        nft add rule inet sb_block input udp dport $port drop
    fi
}

open_inbound_port() {
    local idx=$1
    local port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
    ensure_block_chain
    while nft -a list chain inet sb_block input | grep -q "tcp dport $port drop"; do
        nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $port drop" | head -n 1 | awk '{print $NF}')
    done
    while nft -a list chain inet sb_block input | grep -q "udp dport $port drop"; do
        nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $port drop" | head -n 1 | awk '{print $NF}')
    done
}

init_nftables() {
    # 1. 建立基础表和链（如果不存在）
    if ! nft list table inet singbox_stats >/dev/null 2>&1; then
        nft add table inet singbox_stats
        nft add chain inet singbox_stats input_counter { type filter hook input priority 0 \; }
        nft add chain inet singbox_stats output_counter { type filter hook output priority 0 \; }
    fi

    # 2. 【核心修复】自动扫描当前配置文件中的所有节点端口并添加监控规则
    if [[ -f "$CONFIG_FILE" ]]; then
        # 提取所有入站端口
        local ports=$(jq -r '.inbounds[].listen_port' "$CONFIG_FILE" 2>/dev/null)
        
        if [[ -n "$ports" ]]; then
            for port in $ports; do
                # 确保端口是数字
                if [[ "$port" =~ ^[0-9]+$ ]]; then
                    # 检查入站规则是否存在，不存在则添加
                    if ! nft list chain inet singbox_stats input_counter | grep "tcp dport $port" >/dev/null 2>&1; then
                        nft add rule inet singbox_stats input_counter tcp dport $port counter
                    fi
                    # 检查出站规则是否存在，不存在则添加
                    if ! nft list chain inet singbox_stats output_counter | grep "tcp sport $port" >/dev/null 2>&1; then
                        nft add rule inet singbox_stats output_counter tcp sport $port counter
                    fi
                    # UDP 计数
                    if ! nft list chain inet singbox_stats input_counter | grep "udp dport $port" >/dev/null 2>&1; then
                        nft add rule inet singbox_stats input_counter udp dport $port counter
                    fi
                    if ! nft list chain inet singbox_stats output_counter | grep "udp sport $port" >/dev/null 2>&1; then
                        nft add rule inet singbox_stats output_counter udp sport $port counter
                    fi
                fi
            done
        fi
    fi
}

get_port_traffic() {
    local port=$1
    if ! nft list chain inet singbox_stats input_counter | grep "tcp dport $port" >/dev/null 2>&1; then
        nft add rule inet singbox_stats input_counter tcp dport $port counter
    fi
    if ! nft list chain inet singbox_stats output_counter | grep "tcp sport $port" >/dev/null 2>&1; then
        nft add rule inet singbox_stats output_counter tcp sport $port counter
    fi
    if ! nft list chain inet singbox_stats input_counter | grep "udp dport $port" >/dev/null 2>&1; then
        nft add rule inet singbox_stats input_counter udp dport $port counter
    fi
    if ! nft list chain inet singbox_stats output_counter | grep "udp sport $port" >/dev/null 2>&1; then
        nft add rule inet singbox_stats output_counter udp sport $port counter
    fi
    rx_tcp=$(nft list chain inet singbox_stats input_counter | grep "tcp dport $port" | awk '{for(i=1;i<=NF;i++) if($i=="bytes") print $(i+1)}')
    tx_tcp=$(nft list chain inet singbox_stats output_counter | grep "tcp sport $port" | awk '{for(i=1;i<=NF;i++) if($i=="bytes") print $(i+1)}')
    rx_udp=$(nft list chain inet singbox_stats input_counter | grep "udp dport $port" | awk '{for(i=1;i<=NF;i++) if($i=="bytes") print $(i+1)}')
    tx_udp=$(nft list chain inet singbox_stats output_counter | grep "udp sport $port" | awk '{for(i=1;i<=NF;i++) if($i=="bytes") print $(i+1)}')
    rx=$(( ${rx_tcp:-0} + ${rx_udp:-0} ))
    tx=$(( ${tx_tcp:-0} + ${tx_udp:-0} ))
    echo "${rx:-0} ${tx:-0}"
}

format_bytes() {
    local b=$1
    if [[ $b -lt 1024 ]]; then
        echo "${b} B"
    elif [[ $b -lt 1048576 ]]; then
        echo "$((b/1024)) KB"
    elif [[ $b -lt 1073741824 ]]; then
        echo "$((b/1048576)) MB"
    else
        echo "$((b/1073741824)) GB"
    fi
}

get_visual_length() {
    local s=$1
    local c=$(echo -e "$s" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
    echo $(( ${#c} + ( $(echo -n "$c" | wc -c) - ${#c} ) / 2 ))
}

get_padding() {
    local length=$1
    if [[ -z "$length" || ! "$length" =~ ^[0-9]+$ ]]; then length=1; fi
    if [[ "$length" -lt 1 ]]; then length=1; fi
    printf "%${length}s" ""
}

ensure_monitor_timer() {
    cat > "$MONITOR_SERVICE" <<EOF
[Unit]
Description=Singbox Traffic Monitor

[Service]
Type=oneshot
ExecStart=/bin/bash $(readlink -f $0) monitor
EOF

    cat > "$MONITOR_TIMER" <<EOF
[Unit]
Description=Singbox Traffic Monitor Timer

[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=singbox-traffic.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now singbox-traffic.timer >/dev/null 2>&1
}

check_tag_exists() {
    local t=$1
    local exists=$(jq --arg t "$t" '[.inbounds[].tag, .outbounds[].tag] | index($t)' $CONFIG_FILE)
    if [[ "$exists" != "null" ]]; then
        return 0 
    else
        return 1 
    fi
}

update_sb_core() {
    echo -e "${CYAN}>>> 开始检查 sing-box 核心版本...${PLAIN}"
    echo -e "" # 空一行
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) cputype="amd64" ;;
        aarch64) cputype="arm64" ;;
        *) echo -e "${RED}错误：不支持的系统架构 ($ARCH)${PLAIN}"; return ;;
    esac

    # 1. 获取最新版本
    TAG=$(get_latest_version)
    if [[ -z "$TAG" ]]; then
        echo -e "${RED}错误：无法获取最新版本信息，请检查网络或稍后再试。${PLAIN}"
        return
    fi

    CURRENT_VER=$($SB_BIN version | head -n 1 | awk '{print $3}')
    echo -e "当前版本: ${YELLOW}${CURRENT_VER}${PLAIN}"
    echo -e "" # 空一行
    echo -e "最新版本: ${GREEN}${TAG}${PLAIN}"
    echo -e "" # 空一行
    
    read -p "是否确认更新? (y/n): " confirm
    echo -e "" # 空一行

    if [[ "$confirm" != "y" ]]; then
        echo -e "${YELLOW}已取消${PLAIN}"
        return
    fi
    
    echo -e "${YELLOW}正在停止服务...${PLAIN}"
    echo -e "" # 空一行
    systemctl stop sing-box

    # 2. 准备下载
    VER_NO_V="${TAG#v}"
    FILENAME="sing-box-${VER_NO_V}-linux-${cputype}.tar.gz"
    URL_OFFICIAL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/${FILENAME}"
    URL_MIRROR="https://gh-proxy.com/https://github.com/SagerNet/sing-box/releases/download/${TAG}/${FILENAME}"

    mkdir -p "$WORKDIR/tmp_update"
    DOWNLOAD_SUCCESS=0

    # 3. 下载流程 (官方 -> 镜像)
    echo -e "${CYAN}正在下载...${PLAIN}"
    echo -e "" # 空一行
    
    wget -T 5 -t 1 -O "$WORKDIR/tmp_update/sb.tar.gz" "$URL_OFFICIAL" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        DOWNLOAD_SUCCESS=1
    else
        echo -e "${YELLOW}官方源失败，尝试镜像源...${PLAIN}"
        echo -e ""
        wget -T 15 -t 2 -O "$WORKDIR/tmp_update/sb.tar.gz" "$URL_MIRROR"
        if [ $? -eq 0 ]; then
            DOWNLOAD_SUCCESS=1
        fi
    fi

    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        echo -e "${RED}下载失败，正在恢复服务...${PLAIN}"
        rm -rf "$WORKDIR/tmp_update"
        systemctl start sing-box
        return
    fi

    echo -e "${CYAN}正在安装...${PLAIN}"
    echo -e "" # 空一行
    
    tar -zxvf "$WORKDIR/tmp_update/sb.tar.gz" -C "$WORKDIR/tmp_update" >/dev/null 2>&1
    
    # 查找并替换文件
    if [[ -d "$WORKDIR/tmp_update/sing-box-${VER_NO_V}-linux-${cputype}" ]]; then
        cp -f "$WORKDIR/tmp_update/sing-box-${VER_NO_V}-linux-${cputype}/sing-box" "$SB_BIN"
    else
        DIR_NAME=$(tar -tf "$WORKDIR/tmp_update/sb.tar.gz" | head -1 | cut -f1 -d"/")
        cp -f "$WORKDIR/tmp_update/$DIR_NAME/sing-box" "$SB_BIN"
    fi

    chmod +x "$SB_BIN"
    rm -rf "$WORKDIR/tmp_update"
    
    echo -e "${GREEN}更新成功，正在重启服务...${PLAIN}"
    echo -e "" # 空一行
    
    systemctl start sing-box
    sleep 1
    
    NEW_VER=$($SB_BIN version | head -n 1 | awk '{print $3}')
    echo -e "当前运行版本: ${GREEN}${NEW_VER}${PLAIN}"
    echo -e "" # 空一行
    
    read -n 1 -s -r -p "按任意键返回..."
    echo -e ""
    echo -e ""
    menu
}

install_caddy() {
    # --- 内部函数：获取最新版本 ---
    get_latest_caddy_ver() {
        wget -qO- -T 3 -t 1 "https://api.github.com/repos/caddyserver/caddy/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g'
    }

    if ! command -v caddy &> /dev/null; then
        echo -e "正在检查 Caddy... 未安装"
        echo -e ""
        
        # 1. 版本获取逻辑
        echo -e "正在检测 Caddy 最新版本..."
        CADDY_TAG=$(get_latest_caddy_ver)
        
        # 【修复排版】这里增加空行
        echo -e "" 

        if [[ -z "$CADDY_TAG" ]]; then
            CADDY_TAG="v2.10.2" # 默认保底版本
            echo -e "${YELLOW}无法连接 GitHub API，使用保底版本: ${CADDY_TAG}${PLAIN}"
        else
            echo -e "检测到最新版本: ${GREEN}${CADDY_TAG}${PLAIN}"
        fi
        
        CADDY_VER_NO_V="${CADDY_TAG#v}"

        # 2. 架构判断 (ARM/AMD 适配)
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) caddy_arch="amd64" ;;
            aarch64) caddy_arch="arm64" ;;
            *) echo -e "${RED}不支持的架构用于 Caddy: $ARCH${PLAIN}"; return ;;
        esac

        # 【修复排版】这里增加空行
        echo -e "" 

        # 3. 定义 双源下载链接
        URL_OFFICIAL="https://github.com/caddyserver/caddy/releases/download/${CADDY_TAG}/caddy_${CADDY_VER_NO_V}_linux_${caddy_arch}.tar.gz"
        URL_MIRROR="https://gh-proxy.com/https://github.com/caddyserver/caddy/releases/download/${CADDY_TAG}/caddy_${CADDY_VER_NO_V}_linux_${caddy_arch}.tar.gz"

        # 【核心修复】创建下载目录 (之前漏了这行导致报错)
        mkdir -p "$WORKDIR/tmp_caddy"

        echo -e "正在下载 Caddy (${CADDY_TAG} - ${caddy_arch})..."
        echo -e ""

        # 4. 下载逻辑
        DOWNLOAD_SUCCESS=0
        
        # 尝试官方源
        wget -T 5 -t 1 -O "$WORKDIR/tmp_caddy/caddy.tar.gz" "$URL_OFFICIAL" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}官方源下载成功${PLAIN}"
            DOWNLOAD_SUCCESS=1
        else
            echo -e "${YELLOW}官方源连接失败，切换镜像源...${PLAIN}"
            echo -e ""
            # 尝试镜像源
            wget -T 20 -t 2 -O "$WORKDIR/tmp_caddy/caddy.tar.gz" "$URL_MIRROR"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}镜像源下载成功${PLAIN}"
                DOWNLOAD_SUCCESS=1
            fi
        fi

        if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
             echo -e ""
             echo -e "${RED}Caddy 下载彻底失败！${PLAIN}"
             rm -rf "$WORKDIR/tmp_caddy"
             return
        fi

        # 5. 解压安装
        tar -zxvf "$WORKDIR/tmp_caddy/caddy.tar.gz" -C "$WORKDIR/tmp_caddy" >/dev/null 2>&1
        mv "$WORKDIR/tmp_caddy/caddy" "$CADDY_BIN"
        chmod +x "$CADDY_BIN"
        rm -rf "$WORKDIR/tmp_caddy"
        
        # 6. Systemd 配置
        cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target
[Service]
Type=notify
User=root
Group=root
ExecStart=$CADDY_BIN run --environ --config $CADDY_FILE
ExecReload=$CADDY_BIN reload --config $CADDY_FILE
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
        mkdir -p /etc/caddy
        systemctl daemon-reload
        systemctl enable caddy >/dev/null 2>&1

        # 【修复排版】这里增加空行
        echo -e ""
        echo -e "安装 Caddy 成功"
        echo -e ""
    else
        echo -e "正在检查 Caddy... 已安装"
        echo -e ""
    fi
}

# =========================================================
# 1. 添加配置 (Inbound)
# =========================================================

add_config() {
    echo -e "${CYAN}------------ 添加配置 (Add Config) ------------${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} Shadowsocks"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} VLESS-REALITY"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} VLESS-WS-TLS"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} Hysteria2"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} Tuic-V5"
    echo -e ""
    echo -e " ${GREEN}6.${PLAIN} Trojan"
    echo -e ""
    echo -e " ${GREEN}7.${PLAIN} AnyTLS"
    echo -e ""
    echo -e " ${GREEN}8.${PLAIN} Socks5"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回上一页"
    echo -e ""
    read -p " 请选择协议[0-8]: " type_choice
    echo -e ""
    case "$type_choice" in
        1) add_ss ;;
        2) add_vless ;;
        3) add_vless_ws_tls ;;
        4) add_hy2 ;;
        5) add_tuic ;;
        6) add_trojan ;;
        7) add_anytls ;;
        8) add_socks ;;
        0) 
           if [[ "$FROM_MODIFY" == "true" ]]; then
               modify_config
           else
               menu
           fi 
           ;;
        *) 
           echo -e "${RED}无效选择${PLAIN}"
           add_config 
           ;;
    esac
}

add_ss() {
    echo -e "${CYAN}>>> 配置 Shadowsocks ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(回车随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    echo -e ""
    while true; do
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="Shadowsocks-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    while true; do
        echo -e "请选择加密方式:"
        echo -e ""
        echo -e " ${GREEN}1.${PLAIN} aes-128-gcm"
        echo -e ""
        echo -e " ${GREEN}2.${PLAIN} aes-256-gcm"
        echo -e ""
        echo -e " ${GREEN}3.${PLAIN} chacha20-ietf-poly1305"
        echo -e ""
        echo -e " ${GREEN}4.${PLAIN} xchacha20-ietf-poly1305"
        echo -e ""
        echo -e " ${GREEN}5.${PLAIN} 2022-blake3-aes-128-gcm"
        echo -e ""
        echo -e " ${GREEN}6.${PLAIN} 2022-blake3-aes-256-gcm"
        echo -e ""
        echo -e " ${GREEN}7.${PLAIN} 2022-blake3-chacha20-poly1305"
        echo -e ""
        echo -e " ${GREEN}0.${PLAIN} 返回"
        echo -e ""
        read -p "请选择[0-7]: " m_opt
        echo -e ""
        if [[ -z "$m_opt" ]]; then continue; fi
        if [[ "$m_opt" == "0" ]]; then add_config; return; fi
        is_2022=false
        k_len=0
        case "$m_opt" in
            1) method="aes-128-gcm"; break ;; 
            2) method="aes-256-gcm"; break ;;
            3) method="chacha20-ietf-poly1305"; break ;; 
            4) method="xchacha20-ietf-poly1305"; break ;;
            5) method="2022-blake3-aes-128-gcm"; k_len=16; is_2022=true; break ;;
            6) method="2022-blake3-aes-256-gcm"; k_len=32; is_2022=true; break ;;
            7) method="2022-blake3-chacha20-poly1305"; k_len=32; is_2022=true; break ;;
            *) continue;; 
        esac
        break
    done
    if [[ "$is_2022" == "true" ]]; then 
        password=$($SB_BIN generate rand --base64 $k_len)
    else 
        password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
    fi
    jq --argjson p "$port" --arg pwd "$password" --arg tag "$name" --arg m "$method" \
        '.inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":$p,"method":$m,"password":$pwd}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    ss_base=$(echo -n "${method}:${password}" | base64 -w 0)
    ss_link="ss://${ss_base}@${server_ip}:${port}#${name}"
    if apply_config; then show_ss_info_display "$server_ip" "$port" "$password" "$method" "$name" "$ss_link"; fi
}

show_ss_info_display() {
    echo -e "${PLAIN}-------------- Shadowsocks-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "shadowsocks"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "密码 (password)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "加密 (encryption)" "$4"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

add_vless() {
    echo -e "${CYAN}>>> 配置 VLESS-REALITY ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(回车随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    while true; do
        echo -e ""
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="VLESS-REALITY-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    RANDOM=$(date +%s%N)
    domains=("www.paypal.com" "www.prada.com" "www.loewe.com" "www.rolex.com" "www.cartier.com")
    random_sni=${domains[$RANDOM % ${#domains[@]}]}
    read -p "请输入SNI(回车随机 ${random_sni}): " sni
    echo -e ""
    if [[ -z "$sni" ]]; then sni="$random_sni"; fi
    uuid=$($SB_BIN generate uuid)
    kp=$($SB_BIN generate reality-keypair)
    pk=$(echo "$kp" | grep "Private" | awk -F: '{print $2}' | tr -d ' ')
    pub=$(echo "$kp" | grep "Public" | awk -F: '{print $2}' | tr -d ' ')
    sid=$($SB_BIN generate rand --hex 8)
    touch $PK_FILE
    sed -i "/^$name:/d" $PK_FILE
    echo "${name}:${pub}" >> $PK_FILE
    jq --argjson p "$port" --arg u "$uuid" --arg n "$name" --arg sn "$sni" --arg pk "$pk" --arg sid "$sid" \
        '.inbounds += [{"type":"vless","tag":$n,"listen":"::","listen_port":$p,"users":[{"uuid":$u,"name":$n,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sn,"reality":{"enabled":true,"handshake":{"server":$sn,"server_port":443},"private_key":$pk,"short_id":$sid}}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=${sni}&pbk=${pub}&fp=chrome&sid=${sid}#${name}"
    if apply_config; then show_vless_info_display "$server_ip" "$port" "$uuid" "$sni" "$pub" "$name" "$link"; fi
}

show_vless_info_display() {
    echo -e "${PLAIN}-------------- VLESS-REALITY-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "vless-reality"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "用户ID (id)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "流控 (flow)" "xtls-rprx-vision"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "传输 (TLS)" "reality"
    echo -e ""
    printf " %-22s = ${PLAIN}%s${PLAIN}\n" "SNI (serverName)" "$4"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "公钥 (Public key)" "$5"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$6"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$7${PLAIN}"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

# --- VLESS-WS-TLS (Caddy) ---
add_vless_ws_tls() {
    echo -e "${CYAN}>>> 配置 VLESS-WS-TLS${PLAIN}"
    echo -e ""
    read -p "请输入域名: " domain
    echo -e ""
    install_caddy
    local_port=$(get_random_port)
    uuid=$($SB_BIN generate uuid)
    rand_str=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 40)
    ws_path="/${rand_str}"
    name="VLESS-WS-TLS-443"
    jq --argjson p "$local_port" --arg u "$uuid" --arg n "$name" --arg path "$ws_path" \
        '.inbounds += [{"type":"vless","tag":$n,"listen":"127.0.0.1","listen_port":$p,"users":[{"uuid":$u,"name":$n}],"transport":{"type":"ws","path":$path}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    mkdir -p /etc/caddy
    echo "$domain {
    reverse_proxy 127.0.0.1:$local_port
}" > "$CADDY_FILE"
    systemctl restart caddy >/dev/null 2>&1
    link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&fp=chrome&path=${ws_path}#${name}"
    if apply_config; then
        show_vless_ws_info_display "$domain" "443" "$uuid" "$ws_path" "$name" "$link"
    fi
}

show_vless_ws_info_display() {
    echo -e "${PLAIN}-------------- VLESS-WS-TLS.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "vless"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "用户ID (uuid)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "传输 (transport)" "ws"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "路径 (path)" "$4"
    echo -e ""
    printf " %-26s = ${PLAIN}%s${PLAIN}\n" "伪装域名 (host)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "安全 (security)" "tls"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "注意！这是真实证书，客户端【不需要】开启“跳过证书验证”。"
    echo -e ""
    echo -e "若直连不通，请检查域名解析是否生效，或 Caddy 服务状态。"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

add_hy2() {
    echo -e "${CYAN}>>> 配置 Hysteria2 ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(默认随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    while true; do
        echo -e ""
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="Hysteria2-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
    k="$WORKDIR/hy2_$port.key"
    c="$WORKDIR/hy2_$port.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$k" -out "$c" -subj "/CN=bing.com" >/dev/null 2>&1
    jq --argjson p "$port" --arg pwd "$password" --arg tag "$name" --arg k "$k" --arg c "$c" \
        '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pwd,"name":$tag}],"tls":{"enabled":true,"certificate_path":$c,"key_path":$k}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    link="hysteria2://${password}@${server_ip}:${port}?alpn=h3&insecure=1#${name}"
    if apply_config; then show_hy2_info_display "$server_ip" "$port" "$password" "$name" "$link"; fi
}

show_hy2_info_display() {
    echo -e "${PLAIN}-------------- Hysteria2-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "hysteria2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "密码 (password)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "传输 (TLS)" "tls"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$4"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$5${PLAIN}"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

add_tuic() {
    echo -e "${CYAN}>>> 配置 Tuic-V5 ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(默认随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    while true; do
        echo -e ""
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="Tuic-V5-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    uuid=$($SB_BIN generate uuid)
    password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
    k="$WORKDIR/tuic_${port}.key"
    c="$WORKDIR/tuic_${port}.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$k" -out "$c" -subj "/CN=bing.com" >/dev/null 2>&1
    jq --argjson p "$port" --arg u "$uuid" --arg pwd "$password" --arg n "$name" --arg k "$k" --arg c "$c" \
        '.inbounds += [{"type":"tuic","tag":$n,"listen":"::","listen_port":$p,"users":[{"uuid":$u,"password":$pwd,"name":$n}],"congestion_control":"bbr","tls":{"enabled":true,"certificate_path":$c,"key_path":$k,"alpn":["h3"]}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    link="tuic://${uuid}:${password}@${server_ip}:${port}?congestion_control=bbr&alpn=h3&sni=bing.com&allow_insecure=1#${name}"
    if apply_config; then show_tuic_info_display "$server_ip" "$port" "$uuid" "$password" "$name" "$link"; fi
}

show_tuic_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        uuid=$(jq -r ".inbounds[$idx].users[0].uuid" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        link="tuic://${uuid}:${password}@${server_ip}:${port}?congestion_control=bbr&alpn=h3&sni=bing.com&allow_insecure=1#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_tuic_info_display "$server_ip" "$port" "$uuid" "$password" "$name" "$link"
    fi
}

show_tuic_info_display() {
    echo -e "${PLAIN}-------------- Tuic-V5-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "tuic"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-22s = ${PLAIN}%s${PLAIN}\n" "UUID" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "密码 (password)" "$4"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "安全 (security)" "tls"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "注意！有些客户端如(V2rayN 等)导入链接后需要手动把“跳过证书验证(allowInsecure)”设置为 true"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

add_trojan() {
    echo -e "${CYAN}>>> 配置 Trojan ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(默认随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    while true; do
        echo -e ""
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="Trojan-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
    RANDOM=$(date +%s%N)
    domains=("www.paypal.com" "www.prada.com" "www.loewe.com" "www.rolex.com" "www.cartier.com")
    random_sni=${domains[$RANDOM % ${#domains[@]}]}
    read -p "请输入SNI(回车随机 ${random_sni}): " sni
    echo -e ""
    if [[ -z "$sni" ]]; then sni="$random_sni"; fi
    k="$WORKDIR/trojan_${port}.key"
    c="$WORKDIR/trojan_${port}.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$k" -out "$c" -subj "/CN=${sni}" >/dev/null 2>&1
    jq --argjson p "$port" --arg pwd "$password" --arg n "$name" --arg k "$k" --arg c "$c" --arg sn "$sni" \
        '.inbounds += [{"type":"trojan","tag":$n,"listen":"::","listen_port":$p,"users":[{"password":$pwd,"name":$n}],"tls":{"enabled":true,"server_name":$sn,"certificate_path":$c,"key_path":$k}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    link="trojan://${password}@${server_ip}:${port}?security=tls&sni=${sni}&allowInsecure=1#${name}"
    if apply_config; then show_trojan_info_display "$server_ip" "$port" "$password" "$sni" "$name" "$link"; fi
}

show_trojan_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        sni=$(jq -r ".inbounds[$idx].tls.server_name" $CONFIG_FILE)
        link="trojan://${password}@${server_ip}:${port}?security=tls&sni=${sni}&allowInsecure=1#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_trojan_info_display "$server_ip" "$port" "$password" "$sni" "$name" "$link"
    fi
}

show_trojan_info_display() {
    echo -e "${PLAIN}-------------- Trojan-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "trojan"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "密码 (password)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "安全 (security)" "tls"
    echo -e ""
    printf " %-22s = ${PLAIN}%s${PLAIN}\n" "SNI (serverName)" "$4"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "注意！有些客户端如(V2rayN 等)导入链接后需要手动把“跳过证书验证(allowInsecure)”设置为 true"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

add_anytls() {
    echo -e "${CYAN}>>> 配置 AnyTLS ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(默认随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    while true; do
        echo -e ""
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="AnyTLS-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
    RANDOM=$(date +%s%N)
    domains=("www.paypal.com" "www.prada.com" "www.loewe.com" "www.rolex.com" "www.cartier.com")
    random_sni=${domains[$RANDOM % ${#domains[@]}]}
    read -p "请输入SNI(回车随机 ${random_sni}): " sni
    echo -e ""
    if [[ -z "$sni" ]]; then sni="$random_sni"; fi
    k="$WORKDIR/anytls_${port}.key"
    c="$WORKDIR/anytls_${port}.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$k" -out "$c" -subj "/CN=${sni}" >/dev/null 2>&1
    jq --argjson p "$port" --arg pwd "$password" --arg tag "$name" --arg k "$k" --arg c "$c" --arg sn "$sni" \
        '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pwd,"name":$tag}],"tls":{"enabled":true,"server_name":$sn,"certificate_path":$c,"key_path":$k}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    link="anytls://${password}@${server_ip}:${port}?security=tls&sni=${sni}&allowInsecure=1#${name}"
    if apply_config; then show_anytls_info_display "$server_ip" "$port" "$password" "$sni" "$name" "$link"; fi
}

show_anytls_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        sni=$(jq -r ".inbounds[$idx].tls.server_name" $CONFIG_FILE)
        link="anytls://${password}@${server_ip}:${port}?security=tls&sni=${sni}&allowInsecure=1#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_anytls_info_display "$server_ip" "$port" "$password" "$sni" "$name" "$link"
    fi
}

show_anytls_info_display() {
    echo -e "${PLAIN}-------------- AnyTLS-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "Anytls"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "密码 (password)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "安全 (security)" "tls"
    echo -e ""
    printf " %-22s = ${PLAIN}%s${PLAIN}\n" "SNI (serverName)" "$4"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "注意！有些客户端如(V2rayN 等)导入链接后需要手动把“跳过证书验证(allowInsecure)”设置为 true"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

add_socks() {
    echo -e "${CYAN}>>> 配置 Socks5 ${PLAIN}"
    server_ip=$(curl -s4 ipv4.icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="你的服务器IP"; fi
    echo -e ""
    read -p "请输入端口(回车随机): " port
    echo -e ""
    if [[ -z "$port" ]]; then port=$(get_random_port); fi
    echo -e "${GREEN}使用端口: $port${PLAIN}"
    while true; do
        echo -e ""
        read -p "请输入备注(回车默认协议+端口): " input_name
        echo -e ""
        if [[ -z "$input_name" ]]; then name="Socks5-${port}"; else name="${input_name}-${port}"; fi
        if check_tag_exists "$name"; then
            echo -e "${RED}错误：备注 '$name' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请设置用户名(回车随机): " u
    echo -e ""
    if [[ -z "$u" ]]; then u=$($SB_BIN generate rand --hex 10); fi
    read -p "请设置密码(回车随机): " socks_pwd
    echo -e ""
    if [[ -z "$socks_pwd" ]]; then socks_pwd=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40); fi
    jq --argjson p "$port" --arg u "$u" --arg pwd "$socks_pwd" --arg tag "$name" \
        '.inbounds += [{"type":"socks","tag":$tag,"listen":"::","listen_port":$p,"users":[{"username":$u,"password":$pwd}]}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    link="socks://$(echo -n "${u}:${socks_pwd}" | base64 -w 0)@${server_ip}:${port}#${name}"
    if apply_config; then show_socks_info_display "$server_ip" "$port" "$u" "$socks_pwd" "$name" "$link"; fi
}

show_socks_info_display() {
    echo -e "${PLAIN}-------------- Socks5-${2}.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "socks5"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "用户名 (username)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "密码 (password)" "$4"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

# =========================================================
# 5. 分流规则管理 (Part 2 Starts Here)
# =========================================================

route_menu() {
    echo -e "${CYAN}------------ 分流规则管理 (Routing) ------------${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 添加分流出口 (添加节点)"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 添加域名规则 (指定分流)"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 屏蔽/恢复 大陆"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 查看/删除 配置"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回上一页"
    echo -e ""
    read -p "请选择[0-4]: " opt
    echo -e ""
    case "$opt" in
        1) add_outbound_menu ;;
        2) add_route_rule ;;
        3) block_cn_manager ;;
        4) view_del_route ;;
        0) menu ;;
        *) route_menu ;;
    esac
}

add_outbound_menu() {
    echo -e "${CYAN}>>> 添加分流出口 (Outbound)${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} Shadowsocks"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} VLESS-REALITY"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} VLESS-WS-TLS"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} Hysteria2"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} Tuic-V5"
    echo -e ""
    echo -e " ${GREEN}6.${PLAIN} Trojan"
    echo -e ""
    echo -e " ${GREEN}7.${PLAIN} AnyTLS"
    echo -e ""
    echo -e " ${GREEN}8.${PLAIN} Socks5"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-8]: " type
    echo -e ""
    case "$type" in
        1) add_outbound_ss ;;
        2) add_outbound_vless ;;
        3) add_outbound_vless_ws ;;
        4) add_outbound_hy2 ;;
        5) add_outbound_tuic ;;
        6) add_outbound_trojan ;;
        7) add_outbound_anytls ;;
        8) add_outbound_socks ;;
        0) route_menu ;;
        *) add_outbound_menu ;;
    esac
}

# --- 5.x Outbounds ---
add_outbound_ss() {
    while true; do
        read -p "请输入出口备注(回车默认 Shadowsocks-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="Shadowsocks-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入密码: " pwd
    echo -e ""
    while true; do
        echo -e "请选择加密方式:"
        echo -e ""
        echo -e " ${GREEN}1.${PLAIN} aes-128-gcm"
        echo -e ""
        echo -e " ${GREEN}2.${PLAIN} aes-256-gcm"
        echo -e ""
        echo -e " ${GREEN}3.${PLAIN} chacha20-ietf-poly1305"
        echo -e ""
        echo -e " ${GREEN}4.${PLAIN} xchacha20-ietf-poly1305"
        echo -e ""
        echo -e " ${GREEN}5.${PLAIN} 2022-blake3-aes-128-gcm"
        echo -e ""
        echo -e " ${GREEN}6.${PLAIN} 2022-blake3-aes-256-gcm"
        echo -e ""
        echo -e " ${GREEN}7.${PLAIN} 2022-blake3-chacha20-poly1305"
        echo -e ""
        echo -e " ${GREEN}0.${PLAIN} 返回"
        echo -e ""
        read -p "请选择[0-7]: " m_opt
        echo -e ""
        if [[ -z "$m_opt" ]]; then continue; fi
        if [[ "$m_opt" == "0" ]]; then route_menu; return; fi
        case "$m_opt" in 
            1) method="aes-128-gcm"; break ;; 
            2) method="aes-256-gcm"; break ;;
            3) method="chacha20-ietf-poly1305"; break ;; 
            4) method="xchacha20-ietf-poly1305"; break ;;
            5) method="2022-blake3-aes-128-gcm"; break ;;
            6) method="2022-blake3-aes-256-gcm"; break ;;
            7) method="2022-blake3-chacha20-poly1305"; break ;;
        esac
        break
    done
    jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg m "$method" --arg pwd "$pwd" \
        '.outbounds += [{"type":"shadowsocks","tag":$t,"server":$s,"server_port":$p,"method":$m,"password":$pwd}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_vless() {
    while true; do
        read -p "请输入出口备注(回车默认 VLESS-REALITY-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="VLESS-REALITY-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入UUID: " uuid
    echo -e ""
    read -p "请输入SNI: " sni
    echo -e ""
    read -p "请输入Public Key: " pk
    echo -e ""
    read -p "请输入Short ID (可选,回车跳过不填写): " sid
    echo -e ""
    if [[ -n "$sid" ]]; then
        jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg u "$uuid" --arg sn "$sni" --arg pk "$pk" --arg sid "$sid" \
            '.outbounds += [{"type":"vless","tag":$t,"server":$s,"server_port":$p,"uuid":$u,"flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":$sn,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":$pk,"short_id":$sid}}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    else
        jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg u "$uuid" --arg sn "$sni" --arg pk "$pk" \
            '.outbounds += [{"type":"vless","tag":$t,"server":$s,"server_port":$p,"uuid":$u,"flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":$sn,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":$pk,"short_id":""}}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    fi
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_vless_ws() {
    while true; do
        read -p "请输入出口备注(回车默认 VLESS-WS-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="VLESS-WS-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入UUID: " uuid
    echo -e ""
    read -p "请输入Path: " path
    if [[ -z "$path" ]]; then path="/"; fi
    if [[ "${path:0:1}" != "/" ]]; then path="/${path}"; fi
    echo -e ""
    read -p "请输入SNI (TLS ServerName): " sni
    echo -e ""
    jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg u "$uuid" --arg path "$path" --arg sni "$sni" \
        '.outbounds += [{"type":"vless","tag":$t,"server":$s,"server_port":$p,"uuid":$u,"tls":{"enabled":true,"server_name":$sni,"insecure":false},"transport":{"type":"ws","path":$path}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_hy2() {
    while true; do
        read -p "请输入出口备注(回车默认 Hysteria2-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="Hysteria2-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入密码: " pwd
    echo -e ""
    read -p "请输入SNI: " sni
    echo -e ""
    jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg pwd "$pwd" --arg sn "$sni" \
        '.outbounds += [{"type":"hysteria2","tag":$t,"server":$s,"server_port":$p,"password":$pwd,"tls":{"enabled":true,"server_name":$sn,"insecure":true}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_tuic() {
    while true; do
        read -p "请输入出口备注(回车默认 Tuic-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="Tuic-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入UUID: " uuid
    echo -e ""
    read -p "请输入密码: " pwd
    echo -e ""
    read -p "请输入SNI: " sni
    echo -e ""
    jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg u "$uuid" --arg pwd "$pwd" --arg sni "$sni" \
        '.outbounds += [{"type":"tuic","tag":$t,"server":$s,"server_port":$p,"uuid":$u,"password":$pwd,"congestion_control":"bbr","tls":{"enabled":true,"server_name":$sni,"insecure":true,"alpn":["h3"]}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_trojan() {
    while true; do
        read -p "请输入出口备注(回车默认 Trojan-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="Trojan-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入密码: " pwd
    echo -e ""
    read -p "请输入SNI: " sni
    echo -e ""
    if [[ -z "$sni" ]]; then echo -e "${RED}SNI不能为空${PLAIN}"; route_menu; return; fi
    jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg pwd "$pwd" --arg sni "$sni" \
        '.outbounds += [{"type":"trojan","tag":$t,"server":$s,"server_port":$p,"password":$pwd,"tls":{"enabled":true,"server_name":$sni,"insecure":true}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_anytls() {
    while true; do
        read -p "请输入出口备注(回车默认 AnyTLS-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="AnyTLS-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入密码: " pwd
    echo -e ""
    read -p "请输入SNI: " sni
    echo -e ""
    if [[ -z "$sni" ]]; then echo -e "${RED}SNI不能为空${PLAIN}"; route_menu; return; fi
    jq --arg t "$tag" --arg s "$addr" --argjson p "$port" --arg pwd "$pwd" --arg sn "$sni" \
        '.outbounds += [{"type":"anytls","tag":$t,"server":$s,"server_port":$p,"password":$pwd,"tls":{"enabled":true,"server_name":$sn,"insecure":true}}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

add_outbound_socks() {
    while true; do
        read -p "请输入出口备注(回车默认 Socks5-Out): " tag
        echo -e ""
        if [[ -z "$tag" ]]; then tag="Socks5-Out"; fi
        if check_tag_exists "$tag"; then
            echo -e "${RED}错误：备注 '$tag' 已存在，请换一个名字。${PLAIN}"
            echo -e ""
        else
            break
        fi
    done
    read -p "请输入服务器IP/域名: " addr
    echo -e ""
    read -p "请输入端口: " port
    echo -e ""
    read -p "请输入用户名: " u
    echo -e ""
    read -p "请输入密码: " p
    echo -e ""
    jq --arg t "$tag" --arg s "$addr" --argjson port "$port" --arg u "$u" --arg p "$p" \
        '.outbounds += [{"type":"socks","tag":$t,"server":$s,"server_port":$port,"username":$u,"password":$p}]' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加出口: $tag${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

block_cn_manager() {
    # 检查当前是否已经存在屏蔽规则
    # 只要检测到有针对 geoip-cn 或 geosite-cn 的阻断规则，就视为“已开启”
    is_blocked=$(jq '.route.rules[]? | select(.outbound == "block" and ((.rule_set | index("geoip-cn") != null) or (.rule_set | index("geosite-cn") != null)))' $CONFIG_FILE 2>/dev/null)

    echo -e "${CYAN}>>> 屏蔽/恢复 大陆管理${PLAIN}"
    echo -e ""

    if [[ -n "$is_blocked" ]]; then
        # === 当前状态：已屏蔽大陆 ===
        echo -e "当前状态: ${GREEN}已屏蔽大陆${PLAIN}"
        echo -e ""
        read -p "是否恢复大陆流量? (y/n): " c
        
        if [[ "$c" == "y" ]]; then
            # 恢复操作：把跟 geoip-cn 和 geosite-cn 有关的阻断规则全部删掉
            jq 'del(.route.rules[] | select(.outbound == "block" and ((.rule_set | index("geoip-cn") != null) or (.rule_set | index("geosite-cn") != null))))' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
            
            apply_config
            
            echo -e "" 
            echo -e "${GREEN}已恢复大陆访问，现在可以正常访问${PLAIN}"
            echo -e "" 
            
            read -n 1 -s -r -p "按任意键返回..."
            echo -e "" 
            echo -e "" 
            route_menu
        else
            echo -e "" 
            echo -e "${YELLOW}已取消操作${PLAIN}"
            echo -e "" 
            read -n 1 -s -r -p "按任意键返回..."
            echo -e "" 
            echo -e "" 
            route_menu
        fi
    else
        # === 当前状态：未屏蔽大陆 ===
        echo -e "当前状态: ${GREEN}未屏蔽大陆${PLAIN}"
        echo -e ""
        read -p "是否屏蔽大陆流量? (y/n): " c

        if [[ "$c" == "y" ]]; then
            # 1. 确保下载了 geoip-cn (大陆IP库)
            rs_ip=$(jq '.route.rule_set[]? | select(.tag == "geoip-cn")' $CONFIG_FILE)
            if [[ -z "$rs_ip" ]]; then
                jq --arg t "geoip-cn" --arg u "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" \
                   '.route.rule_set += [{"tag": $t, "type": "remote", "format": "binary", "url": $u, "download_detour": "direct"}]' \
                   $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
            fi

            # 2. 确保下载了 geosite-cn (大陆域名库)
            rs_site=$(jq '.route.rule_set[]? | select(.tag == "geosite-cn")' $CONFIG_FILE)
            if [[ -z "$rs_site" ]]; then
                jq --arg t "geosite-cn" --arg u "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" \
                   '.route.rule_set += [{"tag": $t, "type": "remote", "format": "binary", "url": $u, "download_detour": "direct"}]' \
                   $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
            fi

            # 3. 写入“双重阻断”规则：同时包含 IP 和 域名
            jq '.route.rules = [{"rule_set": ["geoip-cn", "geosite-cn"], "outbound": "block"}] + .route.rules' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
            
            apply_config
            
            echo -e "" 
            echo -e "${GREEN}已屏蔽大陆访问，相关流量已被阻断${PLAIN}"
            echo -e "" 
            
            read -n 1 -s -r -p "按任意键返回..."
            echo -e "" 
            echo -e "" 
            route_menu
        else
            echo -e "" 
            echo -e "${YELLOW}已取消操作${PLAIN}"
            echo -e "" 
            read -n 1 -s -r -p "按任意键返回..."
            echo -e "" 
            echo -e "" 
            route_menu
        fi
    fi
}

view_del_route() {
    echo -e "${CYAN}------------ 当前分流规则 (Current Rules) ------------${PLAIN}"
    echo -e ""
    rcount=$(jq '.route.rules | length' $CONFIG_FILE)
    if [[ "$rcount" -eq 0 ]]; then
        echo -e " ${YELLOW}暂无规则${PLAIN}"
        echo -e "" # 保持之前的修复：这里加空行
    else
        for ((i=0; i<$rcount; i++)); do
            out=$(jq -r ".route.rules[$i].outbound" $CONFIG_FILE)
            dom=$(jq -r ".route.rules[$i].domain // [] | join(\",\")" $CONFIG_FILE)
            rs=$(jq -r ".route.rules[$i].rule_set // [] | join(\",\")" $CONFIG_FILE)
            inb=$(jq -r ".route.rules[$i].inbound // [] | join(\",\")" $CONFIG_FILE)
            display=""
            if [[ -n "$inb" ]]; then display="Inbound:[$inb] "; fi
            if [[ -n "$dom" ]]; then display="${display}Domain:$dom "; fi
            if [[ -n "$rs" ]]; then rs_display=$(echo "$rs" | sed 's/geosite-/geosite:/g; s/geoip-/geoip:/g'); display="${display}RuleSet:$rs_display"; fi
            echo -e " ${GREEN}$((i+1)).${PLAIN} 规则: [${SKY}$display${PLAIN}] -> [${YELLOW}$out${PLAIN}]"
            echo -e ""
        done
    fi
    echo -e "${CYAN}------------ 自定义出口 (Outbounds) ------------${PLAIN}"
    echo -e ""
    ocount=$(jq '.outbounds | length' $CONFIG_FILE)
    for ((i=0; i<$ocount; i++)); do
        tag=$(jq -r ".outbounds[$i].tag" $CONFIG_FILE)
        type=$(jq -r ".outbounds[$i].type" $CONFIG_FILE)
        echo -e " ${GREEN}N$((i+1)).${PLAIN} 节点: [${YELLOW}$tag${PLAIN}] ($type)"
        echo -e ""
    done
    echo -e "------------------------------------------------------"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 删除规则 (输入序号 1, 2...)"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 删除出口节点 (输入序号 N3, N4...)"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-2]: " op
    echo -e ""
    if [[ "$op" == "0" ]]; then route_menu; return; fi
    
    # === 删除规则逻辑 ===
    if [[ "$op" == "1" ]]; then
        read -p "请输入要删除的规则序号: " del_idx
        real_idx=$((del_idx-1))
        jq "del(.route.rules[$real_idx])" $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
        apply_config
        
        echo -e ""
        echo -e "${GREEN}规则已删除${PLAIN}"
        echo -e ""
        
        read -n 1 -s -r -p "按任意键返回..."
        echo -e ""
        echo -e "" # 【关键】下方空一行
        view_del_route
    fi

    # === 删除节点逻辑 ===
    if [[ "$op" == "2" ]]; then
        read -p "请输入要删除的节点序号 (数字即可，不加N): " del_idx
        real_idx=$((del_idx-1))
        tag=$(jq -r ".outbounds[$real_idx].tag" $CONFIG_FILE)
        if [[ "$tag" == "direct" || "$tag" == "block" ]]; then
            echo -e "${RED}错误：不能删除默认的 direct 或 block 出口！${PLAIN}"
            sleep 1
            echo -e ""
            view_del_route
            return
        fi
        in_use=$(jq --arg t "$tag" '.route.rules[] | select(.outbound == $t)' $CONFIG_FILE)
        if [[ -n "$in_use" ]]; then
            echo -e "${RED}错误：该节点正在被分流规则使用，请先删除对应规则！${PLAIN}"
            sleep 2
            echo -e ""
            view_del_route
            return
        fi
        jq "del(.outbounds[$real_idx])" $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
        apply_config
        
        echo -e ""
        echo -e "${GREEN}节点 $tag 已删除${PLAIN}"
        echo -e ""
        
        read -n 1 -s -r -p "按任意键返回..."
        echo -e ""
        echo -e "" # 【关键】下方空一行
        view_del_route
    fi
}

add_route_rule() {
    echo -e "${CYAN}>>> 添加分流规则${PLAIN}"
    echo -e ""
    read -p "请输入目标域名 (多个用逗号分隔, 支持 geosite:xxx): " domains
    echo -e ""
    echo -e "请选择流量去向 (Target Outbound):"
    echo -e ""
    count=$(jq '.outbounds | length' $CONFIG_FILE)
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".outbounds[$i].tag" $CONFIG_FILE)
        type=$(jq -r ".outbounds[$i].type" $CONFIG_FILE)
        if [[ "$type" == "direct" || "$type" == "block" ]]; then
            display_info="($type)"
        else
            port=$(jq -r ".outbounds[$i].server_port // empty" $CONFIG_FILE)
            if [[ "$type" == "vless" ]]; then
                # 简单判断是 Reality, WS
                if [[ $(jq -r ".outbounds[$i].tls.reality.enabled" $CONFIG_FILE) == "true" ]]; then
                    display_type="vless-reality"
                elif [[ $(jq -r ".outbounds[$i].transport.type" $CONFIG_FILE) == "ws" ]]; then
                    display_type="vless-ws"
                else
                    display_type="vless"
                fi
            elif [[ "$type" == "anytls" ]]; then
                display_type="Anytls"
            else
                display_type="$type"
            fi
            if [[ -n "$port" ]]; then
                display_info="(${display_type}-${port})"
            else
                display_info="(${display_type})"
            fi
        fi
        printf " ${GREEN}%d.${PLAIN} %-20s %s\n" "$((i+1))" "$tag" "$display_info"
        echo -e ""
    done
    read -p "请选择[1-$count]: " idx
    echo -e ""
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "$count" ]]; then
        echo -e "${RED}无效选择${PLAIN}"
        route_menu
        return
    fi
    target_tag=$(jq -r ".outbounds[$((idx-1))].tag" $CONFIG_FILE)
    domain_json="[]"
    rule_set_json="[]"
    IFS=',' read -ra ITEMS <<< "$domains"
    for item in "${ITEMS[@]}"; do
        if [[ "$item" == geosite:* ]]; then
            site_name=${item#geosite:}
            tag_name="geosite-${site_name}"
            url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${site_name}.srs"
            exists=$(jq --arg t "$tag_name" '.route.rule_set[]? | select(.tag == $t)' $CONFIG_FILE)
            if [[ -z "$exists" ]]; then
                jq --arg t "$tag_name" --arg u "$url" \
                    '.route.rule_set += [{"tag": $t, "type": "remote", "format": "binary", "url": $u, "download_detour": "direct"}]' \
                    $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
            fi
            rule_set_json=$(echo "$rule_set_json" | jq --arg v "$tag_name" '. + [$v]')
        else
            domain_json=$(echo "$domain_json" | jq --arg v "$item" '. + [$v]')
        fi
    done
    rule_obj="{ \"outbound\": \"$target_tag\" }"
    d_len=$(echo "$domain_json" | jq 'length')
    rs_len=$(echo "$rule_set_json" | jq 'length')
    if [[ "$d_len" -gt 0 ]]; then
        rule_obj=$(echo "$rule_obj" | jq --argjson d "$domain_json" '. + { "domain": $d }')
    fi
    if [[ "$rs_len" -gt 0 ]]; then
        rule_obj=$(echo "$rule_obj" | jq --argjson rs "$rule_set_json" '. + { "rule_set": $rs }')
    fi
    jq --argjson r "$rule_obj" '.route.rules = [$r] + .route.rules' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}[成功] 已添加规则: [$domains] -> [$target_tag]${PLAIN}"
    sleep 1
    echo -e "" 
    route_menu
}

modify_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}配置文件不存在${PLAIN}"; sleep 1; menu; fi
    echo -e "${CYAN}------------ 更改配置 (Modify Config) ------------${PLAIN}"
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${RED}当前没有节点配置！${PLAIN}"
        echo -e ""
        read -n 1 -s -r -p "按任意键返回..."
        echo -e ""
        echo -e ""
        menu
    fi
    echo -e ""
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}.json"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回上一页"
    echo -e ""
    read -p "请选择要更改的配置[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then menu; fi
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "$count" ]]; then
        echo -e "${RED}无效输入${PLAIN}"
        modify_config
    fi
    real_idx=$((idx-1))
    target_type=$(jq -r ".inbounds[$real_idx].type" $CONFIG_FILE)
    case "$target_type" in
        "shadowsocks") mod_ss_menu "$real_idx" ;;
        "vless")       
             is_ws=$(jq -r ".inbounds[$real_idx].transport.type // empty" $CONFIG_FILE)
             is_reality=$(jq -r ".inbounds[$real_idx].tls.reality.enabled // false" $CONFIG_FILE)
             if [[ "$is_ws" == "ws" ]]; then
                 mod_vless_ws_menu "$real_idx"
             elif [[ "$is_reality" == "true" ]]; then
                 mod_vless_menu "$real_idx"
             else
                 echo -e "${RED}未知 VLESS 类型${PLAIN}"; modify_config
             fi
             ;;
        "hysteria2")   mod_hy2_menu "$real_idx" ;;
        "tuic")        mod_tuic_menu "$real_idx" ;;
        "trojan")      mod_trojan_menu "$real_idx" ;;
        "socks")       mod_socks_menu "$real_idx" ;;
        "anytls")      mod_anytls_menu "$real_idx" ;;
        *) echo -e "${RED}未知或暂不支持修改的协议: $target_type${PLAIN}"; modify_config ;;
    esac
}

change_protocol_logic() {
    local idx=$1
    echo -e "${YELLOW}更改协议需要重置此节点配置...${PLAIN}"
    echo -e "" 
    jq "del(.inbounds[$idx])" $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    FROM_MODIFY=true
    add_config
}

mod_ss_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    local port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
    local p_status="${GREEN}running${PLAIN}"
    if nft list table inet sb_block >/dev/null 2>&1; then
        if nft list chain inet sb_block input | grep -q "dport $port drop"; then
            p_status="${RED}stopped${PLAIN}"
        fi
    fi
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " 端口: ${port}  状态: ${p_status}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改密码"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改加密方式"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}6.${PLAIN} 打开端口"
    echo -e ""
    echo -e " ${GREEN}7.${PLAIN} 关闭端口"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-7]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新端口: " p
           new_tag="Shadowsocks-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           show_ss_info "$idx" "端口及备注已更新" 
           ;;
        3) 
           m=$(jq -r ".inbounds[$idx].method" $CONFIG_FILE)
           echo -e "${YELLOW}生成新密码...${PLAIN}"
           if [[ "$m" == *"2022"* ]]; then
               if [[ "$m" == *"128"* ]]; then k_len=16; else k_len=32; fi
               p=$($SB_BIN generate rand --base64 $k_len)
           else
               p=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
           fi
           jq --arg p "$p" --argjson i "$idx" '.inbounds[$i].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_ss_info "$idx" "密码已更新" 
           ;;
        4) 
           while true; do
               echo -e "请选择加密方式:"
               echo -e "" 
               echo -e " ${GREEN}1.${PLAIN} aes-128-gcm"
               echo -e ""
               echo -e " ${GREEN}2.${PLAIN} aes-256-gcm"
               echo -e ""
               echo -e " ${GREEN}3.${PLAIN} chacha20-ietf-poly1305"
               echo -e ""
               echo -e " ${GREEN}4.${PLAIN} xchacha20-ietf-poly1305"
               echo -e ""
               echo -e " ${GREEN}5.${PLAIN} 2022-blake3-aes-128-gcm"
               echo -e ""
               echo -e " ${GREEN}6.${PLAIN} 2022-blake3-aes-256-gcm"
               echo -e ""
               echo -e " ${GREEN}7.${PLAIN} 2022-blake3-chacha20-poly1305"
               echo -e ""
               echo -e " ${GREEN}0.${PLAIN} 返回"
               echo -e ""
               read -p "请选择[0-7]: " m_opt
               echo -e ""
               if [[ -z "$m_opt" ]]; then continue; fi
               if [[ "$m_opt" == "0" ]]; then mod_ss_menu "$idx"; return; fi
               
               need_key=false
               k_len=0
               case $m_opt in 
                   1) m="aes-128-gcm";; 
                   2) m="aes-256-gcm";; 
                   3) m="chacha20-ietf-poly1305";; 
                   4) m="xchacha20-ietf-poly1305";; 
                   5) m="2022-blake3-aes-128-gcm"; need_key=true; k_len=32;; 
                   6) m="2022-blake3-aes-256-gcm"; need_key=true; k_len=32;; 
                   7) m="2022-blake3-chacha20-poly1305"; need_key=true; k_len=32;; 
                   *) continue;; 
               esac
               break
           done
           
           if [[ "$need_key" == "true" ]]; then
               p=$($SB_BIN generate rand --base64 $k_len)
               jq --arg m "$m" --arg p "$p" --argjson i "$idx" '.inbounds[$i].method = $m | .inbounds[$i].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               show_ss_info "$idx" "加密已更新 (密码已自动重置以匹配协议)"
           else
               jq --arg m "$m" --argjson i "$idx" '.inbounds[$i].method = $m' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               show_ss_info "$idx" "加密已更新" 
           fi
           ;;
        5) 
           read -p "请输入新备注: " p
           if [[ -n "$p" ]]; then
               port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               t="${p}-${port}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_ss_info "$idx" "备注已更新"
           else
               mod_ss_menu "$idx"
           fi 
           ;;
        6)
           open_inbound_port "$idx"
           echo -e "${GREEN}端口已开启！${PLAIN}"
           echo -e ""
           read -n 1 -s -r -p "按任意键返回..."
           echo -e ""
           echo -e ""
           mod_ss_menu "$idx"
           ;;
        7)
           close_inbound_port "$idx"
           echo -e "${GREEN}端口已关闭！${PLAIN}"
           echo -e ""
           read -n 1 -s -r -p "按任意键返回..."
           echo -e ""
           echo -e ""
           mod_ss_menu "$idx"
           ;;
        0) modify_config ;;
        *) mod_ss_menu "$idx" ;;
    esac
}

show_ss_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].password" $CONFIG_FILE)
        method=$(jq -r ".inbounds[$idx].method" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        ss_link="ss://$(echo -n "${method}:${password}" | base64 -w 0)@${server_ip}:${port}#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_ss_info_display "$server_ip" "$port" "$password" "$method" "$name" "$ss_link"
    fi
}

mod_hy2_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改密码"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-4]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新端口: " p
           new_tag="Hysteria2-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_hy2_info "$idx" "端口及备注已更新" 
           ;;
        3) 
           echo -e "${YELLOW}生成密码...${PLAIN}"
           p=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
           jq --arg p "$p" --argjson i "$idx" '.inbounds[$i].users[0].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_hy2_info "$idx" "密码已更新" 
           ;;
        4) 
           read -p "请输入新备注: " p
           if [[ -n "$p" ]]; then
               port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               t="${p}-${port}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_hy2_info "$idx" "备注已更新"
           else
               mod_hy2_menu "$idx"
           fi 
           ;;
        0) modify_config ;;
        *) mod_hy2_menu "$idx" ;;
    esac
}

show_hy2_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        link="hysteria2://${password}@${server_ip}:${port}?alpn=h3&insecure=1#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_hy2_info_display "$server_ip" "$port" "$password" "$name" "$link"
    fi
}

mod_tuic_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改UUID"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改密码"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-5]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新端口: " p
           new_tag="Tuic-V5-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_tuic_info "$idx" "端口及备注已更新" 
           ;;
        3) 
           read -p "UUID(回车随机生成): " u
           if [[ -z "$u" ]]; then u=$($SB_BIN generate uuid); fi
           jq --arg u "$u" --argjson i "$idx" '.inbounds[$i].users[0].uuid = $u' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_tuic_info "$idx" "UUID已更新" 
           ;;
        4) 
           echo -e "${YELLOW}生成新密码...${PLAIN}"
           p=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
           jq --arg p "$p" --argjson i "$idx" '.inbounds[$i].users[0].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_tuic_info "$idx" "密码已更新" 
           ;;
        5) 
           read -p "请输入新备注: " p
           if [[ -n "$p" ]]; then
               port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               t="${p}-${port}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_tuic_info "$idx" "备注已更新"
           else
               mod_tuic_menu "$idx"
           fi 
           ;;
        0) modify_config ;;
        *) mod_tuic_menu "$idx" ;;
    esac
}

mod_trojan_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改密码"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改 SNI"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-5]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新端口: " p
           new_tag="Trojan-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_trojan_info "$idx" "端口及备注已更新" 
           ;;
        3) 
           p=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
           jq --arg p "$p" --argjson i "$idx" '.inbounds[$i].users[0].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_trojan_info "$idx" "密码已更新" 
           ;;
        4) 
           read -p "请输入新备注: " p
           if [[ -n "$p" ]]; then
               port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               t="${p}-${port}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_trojan_info "$idx" "备注已更新"
           else
               mod_trojan_menu "$idx"
           fi 
           ;;
        5) 
           RANDOM=$(date +%s%N)
           domains=("www.paypal.com" "www.prada.com" "www.loewe.com" "www.rolex.com" "www.cartier.com")
           random_sni=${domains[$RANDOM % ${#domains[@]}]}
           read -p "请输入SNI(回车随机 ${random_sni}): " sni
           if [[ -z "$sni" ]]; then sni="$random_sni"; fi
           k=$(jq -r ".inbounds[$idx].tls.key_path" $CONFIG_FILE)
           c=$(jq -r ".inbounds[$idx].tls.certificate_path" $CONFIG_FILE)
           openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$k" -out "$c" -subj "/CN=${sni}" >/dev/null 2>&1
           jq --arg s "$sni" --argjson i "$idx" '.inbounds[$i].tls.server_name = $s' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_trojan_info "$idx" "SNI 已更新 (证书已重置)" 
           ;;
        0) modify_config ;;
        *) mod_trojan_menu "$idx" ;;
    esac
}

mod_anytls_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改密码"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改 SNI"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-5]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新端口: " p
           new_tag="AnyTLS-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_anytls_info "$idx" "端口及备注已更新" 
           ;;
        3) 
           echo -e "${YELLOW}生成新密码...${PLAIN}"
           p=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
           jq --arg p "$p" --argjson i "$idx" '.inbounds[$i].users[0].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_anytls_info "$idx" "密码已更新" 
           ;;
        4) 
           read -p "请输入新备注: " p
           if [[ -n "$p" ]]; then
               port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               t="${p}-${port}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_anytls_info "$idx" "备注已更新"
           else
               mod_anytls_menu "$idx"
           fi 
           ;;
        5) 
           RANDOM=$(date +%s%N)
           domains=("www.paypal.com" "www.prada.com" "www.loewe.com" "www.rolex.com" "www.cartier.com")
           random_sni=${domains[$RANDOM % ${#domains[@]}]}
           read -p "请输入SNI(回车随机 ${random_sni}): " sni
           if [[ -z "$sni" ]]; then sni="$random_sni"; fi
           k=$(jq -r ".inbounds[$idx].tls.key_path" $CONFIG_FILE)
           c=$(jq -r ".inbounds[$idx].tls.certificate_path" $CONFIG_FILE)
           openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout "$k" -out "$c" -subj "/CN=${sni}" >/dev/null 2>&1
           jq --arg s "$sni" --argjson i "$idx" '.inbounds[$i].tls.server_name = $s' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_anytls_info "$idx" "SNI 已更新 (证书已重置)" 
           ;;
        0) modify_config ;;
        *) mod_anytls_menu "$idx" ;;
    esac
}

mod_vless_ws_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改域名 (会自动重置证书)"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改 UUID"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改路径"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-5]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新域名: " d
           if [[ -n "$d" ]]; then
               local_port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               echo "$d {
    reverse_proxy 127.0.0.1:$local_port
}" > "$CADDY_FILE"
               systemctl restart caddy
               echo -e ""
               show_vless_ws_info "$idx" "域名已更新" 
           else
               mod_vless_ws_menu "$idx"
           fi
           ;;
        3) 
           read -p "UUID(回车随机生成): " u
           if [[ -z "$u" ]]; then u=$($SB_BIN generate uuid); fi
           jq --arg u "$u" --argjson i "$idx" '.inbounds[$i].users[0].uuid = $u' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_vless_ws_info "$idx" "UUID已更新" 
           ;;
        4) 
           read -p "请输入新路径: " path
           if [[ -z "$path" ]]; then path="/"; fi
           if [[ "${path:0:1}" != "/" ]]; then path="/${path}"; fi
           jq --arg p "$path" --argjson i "$idx" '.inbounds[$i].transport.path = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_vless_ws_info "$idx" "路径已更新" 
           ;;
        5) 
           read -p "请输入新备注: " p
           if [[ -n "$p" ]]; then
               t="${p}-443"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_vless_ws_info "$idx" "备注已更新"
           else
               mod_vless_ws_menu "$idx"
           fi 
           ;;
        0) modify_config ;;
        *) mod_vless_ws_menu "$idx" ;;
    esac
}

show_vless_ws_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        domain=$(grep -oP '(?<=^)[^ {]+(?= \{)' /etc/caddy/Caddyfile 2>/dev/null | head -n 1)
        uuid=$(jq -r ".inbounds[$idx].users[0].uuid" $CONFIG_FILE)
        path=$(jq -r ".inbounds[$idx].transport.path" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&fp=chrome&path=${path}#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_vless_ws_info_display "$domain" "443" "$uuid" "$path" "$name" "$link"
    fi
}

show_vless_ws_info_display() {
    echo -e "${PLAIN}-------------- VLESS-WS-TLS.json -------------${PLAIN}"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "协议 (protocol)" "vless"
    echo -e ""
    # 24s 强制向右回调两格对齐
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "地址 (address)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "端口 (port)" "$2"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "用户ID (uuid)" "$3"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "传输 (transport)" "ws"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "路径 (path)" "$4"
    echo -e ""
    printf " %-26s = ${PLAIN}%s${PLAIN}\n" "伪装域名 (host)" "$1"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "安全 (security)" "tls"
    echo -e ""
    printf " %-24s = ${PLAIN}%s${PLAIN}\n" "备注 (name)" "$5"
    echo -e ""
    echo -e "${PLAIN}------------- 链接 (URL) -------------${PLAIN}"
    echo -e ""
    echo -e "${SKY}$6${PLAIN}"
    echo -e ""
    echo -e "注意！这是真实证书，客户端【不需要】开启“跳过证书验证”。"
    echo -e ""
    echo -e "若直连不通，请检查域名解析是否生效，或 Caddy 服务状态。"
    echo -e ""
    echo -e "${PLAIN}------------- END -------------${PLAIN}"
    echo -e ""
    echo -e "${GREEN}操作完成${PLAIN}"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo -e ""
    echo -e ""
    menu
}

mod_vless_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改 UUID"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改密钥"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改 SNI"
    echo -e ""
    echo -e " ${GREEN}6.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-6]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "请输入新端口: " p
           old_tag=$(jq -r --argjson i "$idx" '.inbounds[$i].tag' $CONFIG_FILE)
           new_tag="VLESS-REALITY-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           if [[ -f "$PK_FILE" ]]; then sed -i "s/^${old_tag}:/${new_tag}:/" $PK_FILE; fi
           echo -e ""
           show_vless_info "$idx" "端口更新" 
           ;;
        3) 
           read -p "UUID(回车随机生成): " u
           if [[ -z "$u" ]]; then u=$($SB_BIN generate uuid); fi
           jq --arg u "$u" --argjson i "$idx" '.inbounds[$i].users[0].uuid = $u' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_vless_info "$idx" "UUID已更新" 
           ;;
        4) 
           echo -e "${YELLOW}重置密钥...${PLAIN}"
           kp=$($SB_BIN generate reality-keypair)
           pk=$(echo "$kp"|grep Private|awk -F: '{print $2}'|tr -d ' ')
           pub=$(echo "$kp"|grep Public|awk -F: '{print $2}'|tr -d ' ')
           jq --arg pk "$pk" --argjson i "$idx" '.inbounds[$i].tls.reality.private_key = $pk' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           touch $PK_FILE
           sed -i "/^$tag:/d" $PK_FILE
           echo "${tag}:${pub}" >> $PK_FILE
           echo -e ""
           show_vless_info "$idx" "密钥已更新" "$pub" 
           ;;
        5) 
           RANDOM=$(date +%s%N)
           domains=("www.paypal.com" "www.prada.com" "www.loewe.com" "www.rolex.com" "www.cartier.com")
           random_sni=${domains[$RANDOM % ${#domains[@]}]}
           read -p "SNI(回车随机生成): " sn
           if [[ -z "$sn" ]]; then sn="$random_sni"; fi
           jq --arg sn "$sn" --argjson i "$idx" '.inbounds[$i].tls.server_name = $sn | .inbounds[$i].tls.reality.handshake.server = $sn' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_vless_info "$idx" "SNI已更新" 
           ;;
        6) 
           read -p "新备注: " p
           if [[ -n "$p" ]]; then
               current=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               old=$(jq -r --argjson i "$idx" '.inbounds[$i].tag' $CONFIG_FILE)
               t="${p}-${current}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               if [[ -f "$PK_FILE" ]]; then sed -i "s/^${old}:/${t}:/" $PK_FILE; fi
               echo -e ""
               show_vless_info "$idx" "备注已更新"
           else
               mod_vless_menu "$idx"
           fi 
           ;;
        0) modify_config ;;
        *) mod_vless_menu "$idx" ;;
    esac
}

show_vless_info() {
    local idx=$1
    local msg=$2
    local temp_pub=$3
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        uuid=$(jq -r ".inbounds[$idx].users[0].uuid" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        sni=$(jq -r ".inbounds[$idx].tls.server_name" $CONFIG_FILE)
        sid=$(jq -r ".inbounds[$idx].tls.reality.short_id[0]" $CONFIG_FILE)
        
        if [[ -n "$temp_pub" ]]; then
            pub="$temp_pub"
        elif [[ -f "$PK_FILE" ]]; then
            pub=$(grep "^$name:" "$PK_FILE" | cut -d: -f2)
        fi
        
        if [[ -z "$pub" ]]; then pub="未知"; fi
        
        link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=${sni}&pbk=${pub}&fp=chrome&sid=${sid}#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_vless_info_display "$server_ip" "$port" "$uuid" "$sni" "$pub" "$name" "$link"
    fi
}

mod_socks_menu() {
    local idx=$1
    local tag=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
    echo -e "${CYAN}>>> 更改: ${tag} ${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 更改协议"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改端口"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 更改用户名"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更改密码"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 更改备注"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-5]: " opt
    echo -e ""
    case "$opt" in
        1) change_protocol_logic "$idx" ;;
        2) 
           read -p "新端口: " p
           new_tag="Socks5-${p}"
           jq --argjson p "$p" --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].listen_port = $p | .inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_socks_info "$idx" "端口更新" 
           ;;
        3) 
           read -p "新用户名: " u
           jq --arg u "$u" --argjson i "$idx" '.inbounds[$i].users[0].username = $u' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_socks_info "$idx" "用户更新" 
           ;;
        4) 
           read -p "新密码: " p
           jq --arg p "$p" --argjson i "$idx" '.inbounds[$i].users[0].password = $p' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
           echo -e ""
           show_socks_info "$idx" "密码更新" 
           ;;
        5) 
           read -p "新备注: " p
           if [[ -n "$p" ]]; then
               port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
               t="${p}-${port}"
               jq --arg t "$t" --argjson i "$idx" '.inbounds[$i].tag = $t' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
               echo -e ""
               show_socks_info "$idx" "备注更新"
           else
               mod_socks_menu "$idx"
           fi 
           ;;
        0) modify_config ;;
        *) mod_socks_menu "$idx" ;;
    esac
}

show_socks_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        user=$(jq -r ".inbounds[$idx].users[0].username" $CONFIG_FILE)
        pass=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        cred=$(echo -n "${user}:${pass}" | base64 -w 0)
        link="socks://${cred}@${server_ip}:${port}#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_socks_info_display "$server_ip" "$port" "$user" "$pass" "$name" "$link"
    fi
}

view_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}无配置${PLAIN}"; sleep 1; menu; fi
    echo -e "${CYAN}------------ 查看配置 (View Config) ------------${PLAIN}"
    echo -e ""
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${RED}当前没有节点配置！${PLAIN}"
        echo -e ""
        read -n 1 -s -r -p "按任意键返回..."
        echo -e ""
        echo -e ""
        menu
    fi
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}.json"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回上一页"
    echo -e ""
    read -p "请选择[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then menu; fi
    if [[ ! "$idx" =~ ^[0-9]+$ || "$idx" -lt 1 || "$idx" -gt "$count" ]]; then
        echo -e "${RED}无效${PLAIN}"
        view_config
    fi
    real_idx=$((idx-1))
    VIEW_ONLY=true
    type=$(jq -r ".inbounds[$real_idx].type" $CONFIG_FILE)
    case "$type" in
        "shadowsocks") show_ss_info "$real_idx" "" ;; 
        "vless") 
             is_ws=$(jq -r ".inbounds[$real_idx].transport.type // empty" $CONFIG_FILE)
             is_reality=$(jq -r ".inbounds[$real_idx].tls.reality.enabled // false" $CONFIG_FILE)
             if [[ "$is_ws" == "ws" ]]; then
                 domain=$(grep -oP '(?<=^)[^ {]+(?= \{)' /etc/caddy/Caddyfile 2>/dev/null | head -n 1)
                 uuid=$(jq -r ".inbounds[$real_idx].users[0].uuid" $CONFIG_FILE)
                 path=$(jq -r ".inbounds[$real_idx].transport.path" $CONFIG_FILE)
                 name=$(jq -r ".inbounds[$real_idx].tag" $CONFIG_FILE)
                 link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&fp=chrome&path=${path}#${name}"
                 show_vless_ws_info_display "$domain" "443" "$uuid" "$path" "$name" "$link"
             elif [[ "$is_reality" == "true" ]]; then
                 show_vless_info "$real_idx" "" 
             else
                 show_vless_info "$real_idx" ""
             fi
             ;; 
        "hysteria2") show_hy2_info "$real_idx" "" ;; 
        "tuic") show_tuic_info "$real_idx" "" ;; 
        "trojan") show_trojan_info "$real_idx" "" ;; 
        "socks") show_socks_info "$real_idx" "" ;;
        "anytls") show_anytls_info "$real_idx" "" ;;
    esac
}

show_tuic_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        uuid=$(jq -r ".inbounds[$idx].users[0].uuid" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        link="tuic://${uuid}:${password}@${server_ip}:${port}?congestion_control=bbr&alpn=h3&sni=bing.com&allow_insecure=1#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_tuic_info_display "$server_ip" "$port" "$uuid" "$password" "$name" "$link"
    fi
}

show_trojan_info() {
    local idx=$1
    local msg=$2
    if apply_config; then
        server_ip=$(curl -s4 ipv4.icanhazip.com)
        port=$(jq -r ".inbounds[$idx].listen_port" $CONFIG_FILE)
        password=$(jq -r ".inbounds[$idx].users[0].password" $CONFIG_FILE)
        name=$(jq -r ".inbounds[$idx].tag" $CONFIG_FILE)
        sni=$(jq -r ".inbounds[$idx].tls.server_name" $CONFIG_FILE)
        link="trojan://${password}@${server_ip}:${port}?security=tls&sni=${sni}&allowInsecure=1#${name}"
        if [[ -n "$msg" ]]; then
             echo -e "${GREEN}${msg}${PLAIN}"
             echo -e ""
        fi
        show_trojan_info_display "$server_ip" "$port" "$password" "$sni" "$name" "$link"
    fi
}

del_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${RED}无配置${PLAIN}"; sleep 1; menu; fi
    echo -e "${CYAN}------------ 删除配置 (Delete Config) ------------${PLAIN}"
    echo -e ""
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${RED}当前没有节点配置！${PLAIN}"
        echo -e ""
        read -n 1 -s -r -p "按任意键返回..."
        echo -e ""
        echo -e ""
        menu
    fi
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then menu; fi
    if [[ ! "$idx" =~ ^[0-9]+$ || "$idx" -lt 1 || "$idx" -gt "$count" ]]; then del_config; fi
    real_idx=$((idx-1))
    tag=$(jq -r ".inbounds[$real_idx].tag" $CONFIG_FILE)
    echo -e " 选择: ${GREEN}${tag}${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 确认删除"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 取消"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-2]: " opt
    echo -e ""
    
    if [[ "$opt" == "1" ]]; then
        jq "del(.inbounds[$real_idx])" $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
        apply_config
        
        echo -e "${GREEN}已删除${PLAIN}"
        echo -e ""
        
        read -n 1 -s -r -p "按任意键返回..."
        echo -e "" 
        echo -e "" # 下方空一行
        del_config
    elif [[ "$opt" == "0" ]]; then
        del_config
    else
        # 选 2 (取消) 或其他无效输入，都直接返回列表
        del_config
    fi
}

show_traffic() {
    echo -e "${CYAN}------------ 流量监控与限制 (Traffic Monitor) ------------${PLAIN}"
    echo -e "--------------------------------------------------------------------------------------------------------------------"
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}暂无节点${PLAIN}"
    else
        for ((i=0; i<$count; i++)); do
            tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
            port=$(jq -r ".inbounds[$i].listen_port" $CONFIG_FILE)
            read rx tx <<< $(get_port_traffic "$port")
            total=$((rx + tx))
            rx_f=$(format_bytes $rx)
            tx_f=$(format_bytes $tx)
            total_f=$(format_bytes $total)
            status_text=""
            is_stopped=false
            if [[ -f "$WORKDIR/limit_${port}.conf" ]]; then
                limit=$(cat "$WORKDIR/limit_${port}.conf")
                l_bytes=$((limit * 1024 * 1024 * 1024))
                if [[ $total -ge $l_bytes ]]; then
                    status_text="${RED}已停用${PLAIN}"
                    is_stopped=true
                else
                    status_text="${YELLOW}限${limit}G${PLAIN}"
                fi
            fi
            if [[ -f "$WORKDIR/limit_rate_${port}.conf" && "$is_stopped" == "false" ]]; then
                rate=$(cat "$WORKDIR/limit_rate_${port}.conf")
                if [[ -n "$status_text" ]]; then
                    status_text="${status_text} ${YELLOW}限速${rate}M${PLAIN}"
                else
                    status_text="${YELLOW}限速${rate}M${PLAIN}"
                fi
            fi
            if [[ -z "$status_text" ]]; then status_text="${PLAIN}正常${PLAIN}"; fi
            v_len=$(get_visual_length "$tag")
            pad_len=$((30 - v_len))
            padding=$(get_padding "$pad_len")
            
            # 【UI修改】 在箭头前分别加了 出 和 入，并调整了对齐
            printf "${GREEN}%d.${PLAIN}    %s%s    ${PLAIN}出↑${PLAIN} %-12s    ${PLAIN}入↓${PLAIN} %-12s    ${PLAIN}总:${PLAIN} %-12s    %b\n" \
            "$((i+1))" "$tag" "$padding" "$tx_f" "$rx_f" "$total_f" "$status_text"
            
            if [[ $i -lt $((count-1)) ]]; then echo -e ""; fi
        done
    fi
    echo -e "--------------------------------------------------------------------------------------------------------------------"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 刷新统计"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 设置流量限制"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 设置端口限速"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 重置流量统计数据"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 设置 Telegram 通知"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回上一页"
    echo -e ""
    read -p "选项[0-5]: " c
    echo -e ""
    case "$c" in
        1) show_traffic ;;
        2) set_traffic_quota ;;
        3) set_port_limit ;;
        4) reset_traffic_menu ;;
        5) setup_tg_notify ;;
        0) menu ;;
        *) show_traffic ;;
    esac
}

setup_tg_notify() {
    echo -e "${CYAN}------------ 设置 Telegram 通知 ------------${PLAIN}"
    echo -e ""
    if [[ -f "$TG_CONF" ]]; then
        source "$TG_CONF"
        echo -e "当前 Token: ${GREEN}${TG_BOT_TOKEN:0:10}******${PLAIN}"
        echo -e "当前 ChatID: ${GREEN}${TG_CHAT_ID}${PLAIN}"
    else
        echo -e "当前状态: ${YELLOW}未配置${PLAIN}"
    fi
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 配置/修改"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 测试消息"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 清除配置"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "选项[0-3]: " o
    echo -e ""
    case "$o" in
        1) 
           read -p "Token: " t
           read -p "ChatID: " c
           echo "TG_BOT_TOKEN=\"$t\"" > "$TG_CONF"
           echo "TG_CHAT_ID=\"$c\"" >> "$TG_CONF"
           echo -e "${GREEN}保存成功${PLAIN}"
           echo -e ""
           read -n 1 -s -r -p "按键返回..."
           echo -e ""
           setup_tg_notify 
           ;;
        2) 
           echo -e "${YELLOW}发送中...${PLAIN}"
           send_tg_msg "Sing-box 通知测试"
           echo -e "${GREEN}发送完成${PLAIN}"
           echo -e ""
           read -n 1 -s -r -p "按键返回..."
           echo -e ""
           setup_tg_notify 
           ;;
        3) 
           rm -f "$TG_CONF"
           echo -e "${GREEN}已清除${PLAIN}"
           echo -e ""
           read -n 1 -s -r -p "按键返回..."
           echo -e ""
           setup_tg_notify 
           ;;
        0) show_traffic ;;
        *) setup_tg_notify ;;
    esac
}

set_traffic_quota() {
    echo -e "${CYAN}------------ 设置流量限制 ------------${PLAIN}"
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    echo -e ""
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "选择[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then show_traffic; return; fi
    real=$((idx-1))
    port=$(jq -r ".inbounds[$real].listen_port" $CONFIG_FILE)
    read -p "流量配额(GB, 0取消): " gb
    echo -e ""
    if [[ "$gb" == "0" ]]; then
        rm -f "$WORKDIR/limit_${port}.conf"
        ensure_block_chain
        while nft -a list chain inet sb_block input | grep -q "tcp dport $port drop"; do
            nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
        done
        while nft -a list chain inet sb_block input | grep -q "udp dport $port drop"; do
            nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
        done
        echo -e "${YELLOW}已取消限制${PLAIN}"
    else
        echo "$gb" > "$WORKDIR/limit_${port}.conf"
        ensure_block_chain
        ensure_monitor_timer

        # 立刻检查一次并自动恢复
        read rx tx <<< $(get_port_traffic "$port")
        total=$((rx + tx))
        limit_bytes=$((gb * 1024 * 1024 * 1024))
        if [[ $total -ge $limit_bytes ]]; then
            if ! nft list chain inet sb_block input | grep -q "tcp dport $port drop"; then
                nft add rule inet sb_block input tcp dport $port drop
            fi
            if ! nft list chain inet sb_block input | grep -q "udp dport $port drop"; then
                nft add rule inet sb_block input udp dport $port drop
            fi
        else
            while nft -a list chain inet sb_block input | grep -q "tcp dport $port drop"; do
                nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
            done
            while nft -a list chain inet sb_block input | grep -q "udp dport $port drop"; do
                nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
            done
        fi

        echo -e "${GREEN}设置完成 (已启动后台自动监控)${PLAIN}"
    fi
    echo -e ""
    read -n 1 -s -r -p "按键返回..."
    echo -e ""
    echo -e ""
    show_traffic
}

if [[ "$1" == "monitor" ]]; then
    init_nftables
    ensure_block_chain
    for file in $WORKDIR/limit_*.conf; do
        if [[ -f "$file" ]]; then
            port=${file#*limit_}
            port=${port%.conf}
            limit_gb=$(cat "$file")
            read rx tx <<< $(get_port_traffic "$port")
            total=$((rx + tx))
            limit_bytes=$((limit_gb * 1024 * 1024 * 1024))
            if [[ $total -ge $limit_bytes ]]; then
                is_blocked=$(nft list chain inet sb_block input | grep -E "tcp dport $port drop|udp dport $port drop")
                if [[ -z "$is_blocked" ]]; then
                    nft add rule inet sb_block input tcp dport $port drop
                    nft add rule inet sb_block input udp dport $port drop
                    name=$(jq -r --argjson p "$port" '.inbounds[] | select(.listen_port == $p) | .tag' $CONFIG_FILE)
                    used_h=$(format_bytes $total)
                    msg="🚨 [流量耗尽] 节点 ${name} (${port}) 已自动停止 (已用 ${used_h} / 限额 ${limit_gb}GB)"
                    send_tg_msg "$msg"
                fi
            else
                while nft -a list chain inet sb_block input | grep -q "tcp dport $port drop"; do
                    nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
                done
                while nft -a list chain inet sb_block input | grep -q "udp dport $port drop"; do
                    nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
                done
            fi
        fi
    done
    exit 0
fi

set_port_limit() {
    echo -e "${CYAN}------------ 设置端口限速 ------------${PLAIN}"
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    echo -e ""
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "选择[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then show_traffic; return; fi
    real=$((idx-1))
    port=$(jq -r ".inbounds[$real].listen_port" $CONFIG_FILE)
    dev=$(ip route|grep default|head -n1|awk '{print $5}')
    read -p "限速(Mbps, 0取消): " limit
    echo -e ""
    tc filter del dev $dev parent 1:0 protocol ip prio 1 u32 match ip sport $port 0xffff >/dev/null 2>&1
    tc class del dev $dev parent 1:1 classid 1:$(printf "%x" $port) >/dev/null 2>&1
    if [[ "$limit" == "0" ]]; then
        rm -f "$WORKDIR/limit_rate_${port}.conf"
        echo -e "${YELLOW}已取消限速${PLAIN}"
    else
        if ! tc qdisc show dev $dev | grep -q "htb 1:"; then
             tc qdisc add dev $dev root handle 1: htb default 10
             tc class add dev $dev parent 1: classid 1:1 htb rate 1000mbit
        fi
        k=$((limit*1000))
        class_id="1:$(printf "%x" $port)"
        tc class add dev $dev parent 1:1 classid $class_id htb rate ${k}kbit ceil ${k}kbit
        tc filter add dev $dev protocol ip parent 1:0 prio 1 u32 match ip sport $port 0xffff flowid $class_id
        echo "$limit" > "$WORKDIR/limit_rate_${port}.conf"
        echo -e "${GREEN}设置完成${PLAIN}"
    fi
    echo -e ""
    read -n 1 -s -r -p "按键返回..."
    echo -e ""
    echo -e ""
    show_traffic
}

reset_traffic_menu() {
    echo -e "${CYAN}------------ 重置流量统计 ------------${PLAIN}"
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    echo -e ""
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        port=$(jq -r ".inbounds[$i].listen_port" $CONFIG_FILE)
        cron=$(crontab -l 2>/dev/null | grep "# reset_${port}")
        if [[ -n "$cron" ]]; then st="${YELLOW}每月$(echo $cron|awk '{print $3}')号重置${PLAIN}"; else st="${PLAIN}未设置自动${PLAIN}"; fi
        v_len=$(get_visual_length "$tag")
        pad_len=$((35 - v_len))
        if [[ $pad_len -lt 1 ]]; then pad_len=1; fi
        padding=$(get_padding "$pad_len")
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}${padding}(${st})"
        echo -e ""
    done
    echo -e " ${GREEN}$((count+1)).${PLAIN} 重置所有"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-$((count+1))]: " idx 
    echo -e ""
    if [[ "$idx" == "0" ]]; then show_traffic; return; fi
    if [[ "$idx" == "$((count+1))" ]]; then
        nft flush chain inet singbox_stats input_counter
        nft flush chain inet singbox_stats output_counter
        echo -e "${GREEN}已重置所有${PLAIN}"
        echo -e "" 
        read -n 1 -s -r -p "按键返回..."
        echo -e ""
        echo -e ""
        reset_traffic_menu
        return
    fi
    real=$((idx-1))
    port=$(jq -r ".inbounds[$real].listen_port" $CONFIG_FILE)
    name=$(jq -r ".inbounds[$real].tag" $CONFIG_FILE)
    echo -e " ${GREEN}1.${PLAIN} 立即清零"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 设置自动重置日"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-2]: " op 
    echo -e ""
    if [[ "$op" == "0" ]]; then reset_traffic_menu; return; fi
    if [[ "$op" == "1" ]]; then
        ensure_block_chain
        nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $port drop" | awk '{print $NF}') 2>/dev/null
        nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $port drop" | awk '{print $NF}') 2>/dev/null
        nft delete rule inet singbox_stats input_counter handle $(nft -a list chain inet singbox_stats input_counter | grep "tcp dport $port" | awk '{print $NF}') 2>/dev/null
        nft delete rule inet singbox_stats output_counter handle $(nft -a list chain inet singbox_stats output_counter | grep "tcp sport $port" | awk '{print $NF}') 2>/dev/null
        nft delete rule inet singbox_stats input_counter handle $(nft -a list chain inet singbox_stats input_counter | grep "udp dport $port" | awk '{print $NF}') 2>/dev/null
        nft delete rule inet singbox_stats output_counter handle $(nft -a list chain inet singbox_stats output_counter | grep "udp sport $port" | awk '{print $NF}') 2>/dev/null
        nft add rule inet singbox_stats input_counter tcp dport $port counter
        nft add rule inet singbox_stats output_counter tcp sport $port counter
        nft add rule inet singbox_stats input_counter udp dport $port counter
        nft add rule inet singbox_stats output_counter udp sport $port counter
        echo -e "${GREEN}已清零${PLAIN}"
        echo -e "" 
        read -n 1 -s -r -p "按键返回..."
        echo -e ""
        echo -e ""
        reset_traffic_menu
    elif [[ "$op" == "2" ]]; then
        read -p "每月几号(1-31, 0关闭): " d
        echo -e ""
        (crontab -l 2>/dev/null | grep -v "# reset_${port}") | crontab -
        if [[ "$d" != "0" ]]; then
            (crontab -l 2>/dev/null; echo "0 0 $d * * /bin/bash $(readlink -f $0) reset_port_exec $port \"$name\" >/dev/null 2>&1 # reset_${port}") | crontab -
        fi
        echo -e "${GREEN}设置成功${PLAIN}"
        echo -e "" 
        read -n 1 -s -r -p "按键返回..."
        echo -e ""
        echo -e ""
        reset_traffic_menu
    fi
}

sb_service_mgr() {
    echo -e "${CYAN}------------ sing-box 服务管理 ------------${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 启动"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 停止"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 重启"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 更新"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 日志"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-5]: " o
    echo -e ""
    case $o in 
        1) 
            systemctl start sing-box
            echo -e "${GREEN}服务已启动${PLAIN}"
            echo -e ""
            read -n 1 -s -r -p "按任意键返回..."
            echo -e ""
            echo -e "" 
            sb_service_mgr 
            ;; 
        2) 
            systemctl stop sing-box
            echo -e "${RED}服务已停止${PLAIN}"
            echo -e ""
            read -n 1 -s -r -p "按任意键返回..."
            echo -e ""
            echo -e "" 
            sb_service_mgr 
            ;; 
        3) 
            systemctl restart sing-box
            echo -e "${GREEN}服务已重启${PLAIN}"
            echo -e ""
            read -n 1 -s -r -p "按任意键返回..."
            echo -e ""
            echo -e "" 
            sb_service_mgr 
            ;; 
        4) update_sb_core; sb_service_mgr ;;
        5) 
            # 这里去掉了 -f (实时)，改成了 -n 100 (显示最后100行)，否则无法按键返回
            journalctl -u sing-box -n 100 --no-pager
            
            echo -e "" # 日志输出完后空一行
            read -n 1 -s -r -p "按任意键返回..."
            echo -e "" # 结束按键读取的光标
            echo -e "" # 【关键】下方空一行
            sb_service_mgr 
            ;; 
        0) menu ;; 
        *) echo -e "${RED}无效选择${PLAIN}"; sleep 1; sb_service_mgr ;; 
    esac
}

script_mgr() {
    echo -e " ${GREEN}1.${PLAIN} 开启 BBR"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更新脚本"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 卸载脚本"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-3]: " o
    echo -e ""
    case "$o" in
        1) 
             if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; fi
             if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; fi
             sysctl -p >/dev/null 2>&1
             if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then echo -e "${GREEN}BBR+FQ 开启成功！${PLAIN}"; else echo -e "${RED}开启失败，请检查内核版本是否 >= 4.9${PLAIN}"; fi
             ;;
        2) 
            echo -e "${GREEN}正在更新脚本...${PLAIN}"
            echo -e ""
            # wget -> 成功提示(无前置空行) -> 输出一个空行 -> 延时 -> 重启
            wget -N --no-check-certificate "https://raw.githubusercontent.com/SHINYUZ/sing-box/main/singbox.sh" && chmod +x singbox.sh && \
            echo -e "${GREEN}更新成功！正在重启脚本...${PLAIN}" && \
            echo -e "" && \
            sleep 1 && \
            exec ./singbox.sh
            exit 0
            ;;
        3) uninstall ;;
    esac
    menu
}

uninstall() {
    # === 关键修复：第一步就获取脚本的绝对路径 ===
    # 使用 ${BASH_SOURCE[0]} 比 $0 更可靠，兼容 source 运行模式
    current_script=$(readlink -f "${BASH_SOURCE[0]}")

    read -p "确认卸载? (y/n): " c
    if [[ "$c" == "y" ]]; then
        echo -e "" 
        
        # 1. 停止并禁用 Sing-box 服务
        systemctl stop sing-box
        systemctl disable sing-box
        
        # 2. 删除 Sing-box 核心文件、配置和证书
        rm -rf $WORKDIR
        rm -f /etc/systemd/system/sing-box.service
        rm -f /usr/bin/sb  # 此时删除快捷方式不影响上面的 current_script 变量
        rm -f "$WORKDIR/.shortcut_fixed"
        
        # 3. 如果安装了 Caddy，一并清理
        if [[ -f "$CADDY_BIN" ]]; then
            systemctl stop caddy
            systemctl disable caddy
            rm -f /etc/systemd/system/caddy.service
            rm -f "$CADDY_BIN"
            rm -rf /etc/caddy
            rm -rf /root/.local/share/caddy
        fi
        
        # 4. 清理防火墙规则
        nft delete table inet singbox_stats >/dev/null 2>&1
        
        # 5. 清理定时任务
        # 使用刚才保存的 current_script 变量
        if command -v crontab &> /dev/null; then
             crontab -l 2>/dev/null | grep -v "$current_script" | crontab -
        fi

        systemctl disable --now singbox-traffic.timer >/dev/null 2>&1
        rm -f "$MONITOR_SERVICE"
        rm -f "$MONITOR_TIMER"
        systemctl daemon-reload

        echo -e "" 
        echo -e "${GREEN}卸载完成 (全部清理)${PLAIN}"
        echo -e "" 
        
        # 6. 删除脚本自身
        # 双重保险：既删除计算出的路径，也尝试删除当前目录下的同名文件
        rm -f "$current_script"
        rm -f "singbox.sh" 
        
        exit 0
    else
        echo -e "" 
        script_mgr 
    fi
}

if [[ "$1" == "reset_port_exec" ]]; then
    ensure_block_chain
    nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $2 drop" | awk '{print $NF}') 2>/dev/null
    nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $2 drop" | awk '{print $NF}') 2>/dev/null
    nft delete rule inet singbox_stats input_counter handle $(nft -a list chain inet singbox_stats input_counter | grep "tcp dport $2" | awk '{print $NF}') 2>/dev/null
    nft delete rule inet singbox_stats output_counter handle $(nft -a list chain inet singbox_stats output_counter | grep "tcp sport $2" | awk '{print $NF}') 2>/dev/null
    nft delete rule inet singbox_stats input_counter handle $(nft -a list chain inet singbox_stats input_counter | grep "udp dport $2" | awk '{print $NF}') 2>/dev/null
    nft delete rule inet singbox_stats output_counter handle $(nft -a list chain inet singbox_stats output_counter | grep "udp sport $2" | awk '{print $NF}') 2>/dev/null
    nft add rule inet singbox_stats input_counter tcp dport $2 counter
    nft add rule inet singbox_stats output_counter tcp sport $2 counter
    nft add rule inet singbox_stats input_counter udp dport $2 counter
    nft add rule inet singbox_stats output_counter udp sport $2 counter
    send_tg_msg "🔔 [流量重置] 节点 $3 ($2) 已自动重置"
    exit 0
fi

if [[ "$1" == "monitor" ]]; then
    init_nftables
    ensure_block_chain
    for file in $WORKDIR/limit_*.conf; do
        if [[ -f "$file" ]]; then
            port=${file#*limit_}
            port=${port%.conf}
            limit_gb=$(cat "$file")
            read rx tx <<< $(get_port_traffic "$port")
            total=$((rx + tx))
            limit_bytes=$((limit_gb * 1024 * 1024 * 1024))
            if [[ $total -ge $limit_bytes ]]; then
                ensure_block_chain
                is_blocked=$(nft list chain inet sb_block input | grep -E "tcp dport $port drop|udp dport $port drop")
                if [[ -z "$is_blocked" ]]; then
                    nft add rule inet sb_block input tcp dport $port drop
                    nft add rule inet sb_block input udp dport $port drop
                    name=$(jq -r --argjson p "$port" '.inbounds[] | select(.listen_port == $p) | .tag' $CONFIG_FILE)
                    used_h=$(format_bytes $total)
                    msg="?? [????] ?? ${name} (${port}) ????? (?? ${used_h} / ?? ${limit_gb}GB)"
                    send_tg_msg "$msg"
                fi
            else
                while nft -a list chain inet sb_block input | grep -q "tcp dport $port drop"; do
                    nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "tcp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
                done
                while nft -a list chain inet sb_block input | grep -q "udp dport $port drop"; do
                    nft delete rule inet sb_block input handle $(nft -a list chain inet sb_block input | grep "udp dport $port drop" | head -n 1 | awk '{print $NF}') 2>/dev/null
                done
            fi
        fi
    done
    exit 0
fi

ipv_menu() {
    echo -e "${CYAN}------------ IPv4/IPv6 优先级与策略 ------------${PLAIN}"
    echo -e ""
    global_s=$(jq -r '.outbounds[] | select(.tag == "direct") | .domain_resolver.strategy // "默认(prefer_ipv4)"' $CONFIG_FILE)
    echo -e " 当前全局默认: ${YELLOW}${global_s}${PLAIN}"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 修改全局默认: 优先 IPv4"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 修改全局默认: 优先 IPv6"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 指定节点 --> 强制 IPv4"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 指定节点 --> 强制 IPv6"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 查看节点偏好配置"
    echo -e ""
    echo -e " ${GREEN}6.${PLAIN} 重置节点设置"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 返回主菜单"
    echo -e ""
    read -p "请选择[0-6]: " opt
    echo -e ""
    case "$opt" in
        1) set_global_strategy "prefer_ipv4" ;;
        2) set_global_strategy "prefer_ipv6" ;;
        3) set_node_strategy "ipv4-out" ;;
        4) set_node_strategy "ipv6-out" ;;
        5) view_node_strategy ;;
        6) clear_node_strategy ;;
        0) menu ;;
        *) ipv_menu ;;
    esac
}

set_global_strategy() {
    strategy=$1
    jq --arg s "$strategy" '(.outbounds[] | select(.tag == "direct")).domain_resolver = {"server":"local-dns","strategy":$s}' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}全局策略已设置为: $strategy${PLAIN}"
    echo -e ""
    sleep 1
    ipv_menu
}

set_node_strategy() {
    target_outbound=$1 
    echo -e "请选择要设置的入站节点 (Inbound):"
    echo -e ""
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    if [[ "$count" -eq 0 ]]; then echo -e "${RED}无节点${PLAIN}"; sleep 1; ipv_menu; return; fi
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then ipv_menu; return; fi
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "$count" ]]; then ipv_menu; return; fi
    inbound_tag=$(jq -r ".inbounds[$((idx-1))].tag" $CONFIG_FILE)
    jq --arg t "$inbound_tag" 'del(.route.rules[] | select(.inbound[0] == $t))' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    new_rule="{ \"inbound\": [\"$inbound_tag\"], \"outbound\": \"$target_outbound\" }"
    jq --argjson r "$new_rule" '.route.rules = [$r] + .route.rules' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}设置成功: [${inbound_tag}] -> [${target_outbound}]${PLAIN}"
    echo -e ""
    sleep 1
    ipv_menu
}

clear_node_strategy() {
    echo -e "请选择要重置的入站节点 (Inbound):"
    echo -e ""
    count=$(jq '.inbounds | length' $CONFIG_FILE)
    for ((i=0; i<$count; i++)); do
        tag=$(jq -r ".inbounds[$i].tag" $CONFIG_FILE)
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${tag}"
        echo -e ""
    done
    echo -e " ${GREEN}0.${PLAIN} 返回"
    echo -e ""
    read -p "请选择[0-$count]: " idx
    echo -e ""
    if [[ "$idx" == "0" ]]; then ipv_menu; return; fi
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "$count" ]]; then ipv_menu; return; fi
    inbound_tag=$(jq -r ".inbounds[$((idx-1))].tag" $CONFIG_FILE)
    jq --arg t "$inbound_tag" 'del(.route.rules[] | select(.inbound[0] == $t))' $CONFIG_FILE > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" $CONFIG_FILE
    apply_config
    echo -e "${GREEN}已重置节点 [${inbound_tag}] 为默认策略${PLAIN}"
    echo -e ""
    sleep 1
    ipv_menu
}

view_node_strategy() {
    echo -e "---------------- 当前节点偏好列表 ----------------"
    echo -e ""
    echo -e "[强制 IPv4 的节点]:"
    v4_nodes=$(jq -r '.route.rules[] | select(.outbound=="ipv4-out") | .inbound[]' $CONFIG_FILE 2>/dev/null)
    if [[ -z "$v4_nodes" ]]; then echo -e " (无)"; else echo "$v4_nodes" | while read n; do echo -e " - ${SKY}$n${PLAIN}"; done; fi
    echo -e ""
    echo -e "[强制 IPv6 的节点]:"
    v6_nodes=$(jq -r '.route.rules[] | select(.outbound=="ipv6-out") | .inbound[]' $CONFIG_FILE 2>/dev/null)
    if [[ -z "$v6_nodes" ]]; then echo -e " (无)"; else echo "$v6_nodes" | while read n; do echo -e " - ${SKY}$n${PLAIN}"; done; fi
    echo -e ""
    echo -e "------------------------------------------------"
    echo -e ""
    read -n 1 -s -r -p "按任意键返回..."
    echo -e ""
    echo -e ""
    ipv_menu
}

menu() {
    FROM_MODIFY=false
    VIEW_ONLY=false
    check_root
    check_dependencies
    create_shortcut
    init_nftables
    show_banner
    echo -e " ${GREEN}1.${PLAIN} 添加配置"
    echo -e ""
    echo -e " ${GREEN}2.${PLAIN} 更改配置"
    echo -e ""
    echo -e " ${GREEN}3.${PLAIN} 查看配置"
    echo -e ""
    echo -e " ${GREEN}4.${PLAIN} 删除配置"
    echo -e ""
    echo -e " ${GREEN}5.${PLAIN} 分流规则管理"
    echo -e ""
    echo -e " ${GREEN}6.${PLAIN} IPv4/IPv6 优先级与策略"
    echo -e ""
    echo -e " ${GREEN}7.${PLAIN} 配置流量使用情况"
    echo -e "" 
    echo -e " ${GREEN}8.${PLAIN} sing-box管理"
    echo -e ""
    echo -e " ${GREEN}9.${PLAIN} 脚本管理"
    echo -e ""
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e ""
    read -p "请输入选项[0-9]: " choice
    echo -e ""
    case "$choice" in 
        1) add_config ;; 
        2) modify_config ;; 
        3) view_config ;; 
        4) del_config ;; 
        5) route_menu ;; 
        6) ipv_menu ;; 
        7) show_traffic ;; 
        8) sb_service_mgr ;; 
        9) script_mgr ;; 
        0) 
           if [[ "$NEED_RELOAD" == "true" ]]; then
               exec bash -l
           else
               exit 0
           fi
           ;; 
        *) menu ;; 
    esac
}

# 判断当前脚本是不是以 "sb" 这个名字运行的
if [[ "$0" == *"/sb" ]]; then
    echo -e ""
fi

menu
