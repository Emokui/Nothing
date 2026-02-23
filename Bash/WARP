
#!/bin/bash
# WARP 一键双栈管理脚本 v2.0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WORK_DIR="/root/.warp-script"
WG_CONF="/etc/wireguard/wg0.conf"
WGCF_BIN="/usr/local/bin/wgcf"
WGCF_VERSION="2.2.30"

check_root() { [[ $EUID -ne 0 ]] && err "请使用 root 用户运行此脚本"; }

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        armv7l)  WGCF_ARCH="armv7" ;;
        *)       err "不支持的架构: $ARCH" ;;
    esac
}

detect_network() {
    HAS_V4=false; HAS_V6=false
    ping -4 -c 1 -W 3 1.1.1.1 &>/dev/null && HAS_V4=true
    ping -6 -c 1 -W 3 2606:4700:4700::1111 &>/dev/null && HAS_V6=true

    if $HAS_V4 && $HAS_V6; then NET_MODE="dual"
    elif $HAS_V6; then NET_MODE="v6_only"
    elif $HAS_V4; then NET_MODE="v4_only"
    else NET_MODE="none"; fi
}

show_network_status() {
    detect_network
    echo ""
    case "$NET_MODE" in
        dual)    echo -e "  网络状态: ${GREEN}IPv4${NC} ✓  ${GREEN}IPv6${NC} ✓ (双栈)" ;;
        v6_only) echo -e "  网络状态: ${RED}IPv4${NC} ✗  ${GREEN}IPv6${NC} ✓ (纯 IPv6)" ;;
        v4_only) echo -e "  网络状态: ${GREEN}IPv4${NC} ✓  ${RED}IPv6${NC} ✗ (纯 IPv4)" ;;
        none)    echo -e "  网络状态: ${RED}IPv4${NC} ✗  ${RED}IPv6${NC} ✗ (无连接)" ;;
    esac
    if ip link show wg0 &>/dev/null 2>&1; then
        echo -e "  WARP 状态: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP 状态: ${YELLOW}未运行${NC}"
    fi
    echo ""
}

install_wireguard_tools() {
    command -v wg &>/dev/null && { ok "wireguard-tools 已安装"; return; }
    info "安装 wireguard-tools ..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y -qq wireguard-tools
    elif command -v yum &>/dev/null; then
        yum install -y epel-release && yum install -y wireguard-tools
    elif command -v dnf &>/dev/null; then
        dnf install -y wireguard-tools
    else
        err "无法识别包管理器，请手动安装 wireguard-tools"
    fi
    ok "wireguard-tools 已安装"
}

check_dependencies() {
    command -v curl &>/dev/null || {
        info "安装 curl ..."
        apt install -y -qq curl 2>/dev/null || yum install -y curl 2>/dev/null || dnf install -y curl 2>/dev/null
    }
    command -v dig &>/dev/null || {
        info "安装 dnsutils (dig) ..."
        apt install -y -qq dnsutils 2>/dev/null || yum install -y bind-utils 2>/dev/null || dnf install -y bind-utils 2>/dev/null || true
    }
}

enable_bbr() {
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" != "bbr" ]]; then
        info "启用 BBR ..."
        grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p &>/dev/null
        ok "BBR 已启用"
    else
        ok "BBR 已处于启用状态"
    fi
}

resolve_endpoint() {
    local raw_ep="$1" host port

    [[ "$raw_ep" =~ ^\[.*\]:[0-9]+$ ]] && { ENDPOINT="$raw_ep"; return; }

    host=$(echo "$raw_ep" | sed 's/:[0-9]*$//')
    port=$(echo "$raw_ep" | grep -oP ':\K[0-9]+$')
    [[ -z "$port" ]] && port=2408

    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { ENDPOINT="${host}:${port}"; return; }

    if [[ "$NET_MODE" == "v6_only" ]]; then
        local resolved; resolved=$(dig +short AAAA "$host" 2>/dev/null | head -1)
        if [[ -n "$resolved" ]]; then
            ENDPOINT="[${resolved}]:${port}"
            info "域名 ${host} 解析为 IPv6: ${resolved}"
        else
            ENDPOINT="[2606:4700:d0::a29f:c001]:${port}"
            warn "域名解析失败，使用回退 IPv6 Endpoint"
        fi
    else
        local resolved; resolved=$(dig +short A "$host" 2>/dev/null | head -1)
        if [[ -n "$resolved" ]]; then
            ENDPOINT="${resolved}:${port}"
            info "域名 ${host} 解析为 IPv4: ${resolved}"
        else
            ENDPOINT="${raw_ep}"
            warn "域名解析失败，保持原始 Endpoint"
        fi
    fi
}

determine_install_mode() {
    detect_network
    case "$NET_MODE" in
        dual)
            warn "当前服务器已经是双栈，无需添加"
            echo -e "  IPv4: $(curl -s -4 --max-time 5 ip.gs 2>/dev/null || echo '获取失败')"
            echo -e "  IPv6: $(curl -s -6 --max-time 5 ip.gs 2>/dev/null || echo '获取失败')"
            return 1 ;;
        v6_only) INSTALL_MODE="add_v4"; info "检测到: 纯 IPv6 → 将通过 WARP 添加 IPv4 出口" ;;
        v4_only) INSTALL_MODE="add_v6"; info "检测到: 纯 IPv4 → 将通过 WARP 添加 IPv6 出口" ;;
        none)    err "当前服务器无任何网络连接，无法继续" ;;
    esac
    return 0
}

check_wg0_exists() {
    ip link show wg0 &>/dev/null 2>&1 && err "wg0 接口已存在。如需重新安装，请先选择「删除服务」"
}

write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" mode="$6" acct="$7"
    mkdir -p /etc/wireguard

    if [[ "$mode" == "add_v4" ]]; then
        cat > "$WG_CONF" << EOF
# WARP - ${acct} | $(date '+%Y-%m-%d %H:%M:%S')
[Interface]
PrivateKey = ${priv}
Address = ${v4}/32, ${v6}/128
MTU = 1280
Table = 51820
PostUp  = ip -4 route add default dev %i table main
PostDown = ip -4 route del default dev %i table main
PostUp  = ip -6 rule add from ${v6}/128 table 51820
PostUp  = ip -6 rule add oif %i table 51820
PostDown = ip -6 rule del from ${v6}/128 table 51820
PostDown = ip -6 rule del oif %i table 51820

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ep}
PersistentKeepalive = 25
EOF
    elif [[ "$mode" == "add_v6" ]]; then
        cat > "$WG_CONF" << EOF
# WARP - ${acct} | $(date '+%Y-%m-%d %H:%M:%S')
[Interface]
PrivateKey = ${priv}
Address = ${v4}/32, ${v6}/128
MTU = 1280
Table = 51820
PostUp  = ip -6 route add default dev %i table main
PostDown = ip -6 route del default dev %i table main
PostUp  = ip -4 rule add from ${v4}/32 table 51820
PostUp  = ip -4 rule add oif %i table 51820
PostDown = ip -4 rule del from ${v4}/32 table 51820
PostDown = ip -4 rule del oif %i table 51820

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ep}
PersistentKeepalive = 25
EOF
    fi
    chmod 600 "$WG_CONF"
    ok "wg0.conf 已写入"
}

start_and_enable() {
    info "启动 wg0 隧道 ..."
    wg-quick up wg0 || err "wg0 启动失败，请检查配置"
    ok "wg0 隧道已启动"
    systemctl enable wg-quick@wg0 &>/dev/null
    ok "已设置开机自启"
}

show_result() {
    local mode="$1"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  WARP 隧道配置完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    sleep 2

    local v4a v6a
    v4a=$(curl -s -4 --max-time 5 ip.gs 2>/dev/null || echo "获取失败")
    v6a=$(curl -s -6 --max-time 5 ip.gs 2>/dev/null || echo "获取失败")

    if [[ "$mode" == "add_v4" ]]; then
        echo -e "  模式:      纯 IPv6 → 添加 IPv4"
        echo -e "  IPv4 出口: ${GREEN}${v4a}${NC} (WARP)"
        echo -e "  IPv6 出口: ${CYAN}${v6a}${NC} (原生)"
    else
        echo -e "  模式:      纯 IPv4 → 添加 IPv6"
        echo -e "  IPv4 出口: ${CYAN}${v4a}${NC} (原生)"
        echo -e "  IPv6 出口: ${GREEN}${v6a}${NC} (WARP)"
    fi
    echo ""
    echo -e "  BBR:       $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo -e "  开机自启:   已启用"
    echo ""
    echo -e "  常用命令:  ${CYAN}wg show${NC} / ${CYAN}wg-quick down wg0${NC} / ${CYAN}wg-quick up wg0${NC}"
    echo -e "  隧道配置:  ${YELLOW}${WG_CONF}${NC}"
    echo ""
}

# ======================== 1. 免费账户 ========================

install_free() {
    echo ""; info "===== 免费 WARP 账户安装 ====="; echo ""

    determine_install_mode || return
    check_wg0_exists; detect_arch; check_dependencies; install_wireguard_tools

    if [[ ! -f "$WGCF_BIN" ]]; then
        local url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${WGCF_ARCH}"
        info "下载 wgcf v${WGCF_VERSION} ..."
        wget -qO "$WGCF_BIN" "$url" || curl -sLo "$WGCF_BIN" "$url" || err "wgcf 下载失败"
        chmod +x "$WGCF_BIN"; ok "wgcf 已下载"
    fi

    mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
    if [[ ! -f "wgcf-account.toml" ]]; then
        info "注册 WARP 免费账户 ..."
        yes | wgcf register || err "WARP 注册失败"
        ok "注册成功"
    else
        info "已存在账户文件，跳过注册"
    fi

    info "生成 WireGuard 配置 ..."
    wgcf generate || err "配置生成失败"

    local priv pub addr ep warp_v4 warp_v6
    priv=$(grep 'PrivateKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    pub=$(grep 'PublicKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    addr=$(grep 'Address' wgcf-profile.conf | awk -F' = ' '{print $2}')
    ep=$(grep 'Endpoint' wgcf-profile.conf | awk -F' = ' '{print $2}')
    warp_v4=$(echo "$addr" | grep -oP '\d+\.\d+\.\d+\.\d+')
    warp_v6=$(echo "$addr" | grep -oP '2606:[0-9a-f:]+')

    info "WARP IPv4: $warp_v4 | IPv6: $warp_v6"

    rm -f "$WGCF_BIN"; ok "wgcf 已清理"

    resolve_endpoint "$ep"
    info "Endpoint: $ENDPOINT"
    write_wg_conf "$priv" "$warp_v4" "$warp_v6" "$pub" "$ENDPOINT" "$INSTALL_MODE" "free"
    enable_bbr; start_and_enable; show_result "$INSTALL_MODE"
}

# ======================== 2. 团队账户 ========================

install_team() {
    echo ""; info "===== 团队 (Zero Trust) 账户安装 ====="; echo ""

    determine_install_mode || return
    check_wg0_exists; check_dependencies; install_wireguard_tools
    command -v wg &>/dev/null || err "wg 命令不可用"

    echo ""
    echo -e "${BOLD}获取 Token：${NC}打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC} 并登录"
    echo -e "  认证后按 F12 → Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}⚠ Token 有效期 60 秒，复制后立即粘贴${NC}"
    echo ""
    read -rp "请粘贴 JWT Token（直接回车取消）: " JWT_TOKEN
    [[ -z "$JWT_TOKEN" ]] && { warn "已取消"; return; }

    info "生成 WireGuard 密钥对 ..."
    local priv pub; priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey)

    info "向 Cloudflare API 注册设备 ..."
    local response
    response=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: ${JWT_TOKEN}" \
        -d "{
            \"key\": \"${pub}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"Linux\",
            \"serial_number\": \"$(cat /proc/sys/kernel/random/uuid)\"
        }" 2>/dev/null)

    echo "$response" | grep -q '"account"' || {
        echo -e "${RED}API 返回:${NC}"; echo "$response"
        err "注册失败，请检查 Token 是否过期"
    }
    ok "团队设备注册成功"

    local warp_v4 warp_v6 peer_pub
    warp_v4=$(echo "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v4"\s*:\s*"\K[^"]+' | head -1)
    warp_v6=$(echo "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$warp_v4" ]] && warp_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$warp_v6" ]] && warp_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)
    peer_pub=$(echo "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | tail -1)

    [[ -z "$warp_v4" || -z "$warp_v6" || -z "$peer_pub" ]] && {
        echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        err "无法从 API 响应中提取配置"
    }

    local org; org=$(echo "$response" | grep -oP '"organization"\s*:\s*"\K[^"]+' | head -1)
    info "WARP IPv4: $warp_v4 | IPv6: $warp_v6 | 组织: $org"

    local raw_ep; raw_ep=$(echo "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)
    if [[ -z "$raw_ep" ]]; then
        if [[ "$NET_MODE" == "v6_only" ]]; then
            local v6r; v6r=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1)
            v6r=$(echo "$v6r" | sed 's/\[//g; s/\]:.*//g; s/:0$//g')
            raw_ep="[${v6r}]:2408"
        else
            local v4r; v4r=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1)
            v4r=$(echo "$v4r" | sed 's/:0$//g')
            raw_ep="${v4r}:2408"
        fi
    fi
    resolve_endpoint "$raw_ep"
    info "Endpoint: $ENDPOINT"

    mkdir -p "$WORK_DIR"
    echo "$response" | python3 -m json.tool 2>/dev/null > "$WORK_DIR/team-account.json" || echo "$response" > "$WORK_DIR/team-account.json"
    echo "$priv" > "$WORK_DIR/team-private.key"; chmod 600 "$WORK_DIR/team-private.key"
    ok "账户信息已保存到 $WORK_DIR/"

    write_wg_conf "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$ENDPOINT" "$INSTALL_MODE" "team($org)"
    enable_bbr; start_and_enable; show_result "$INSTALL_MODE"
}

# ======================== 3. 修改配置 ========================

modify_config() {
    echo ""; info "===== 修改 WARP 配置 ====="; echo ""
    [[ ! -f "$WG_CONF" ]] && { warn "未找到 ${WG_CONF}，请先安装"; return; }

    echo -e "${BOLD}当前配置：${NC}"
    echo -e "${CYAN}────────────────────────────────────${NC}"
    cat "$WG_CONF"
    echo -e "${CYAN}────────────────────────────────────${NC}"
    echo ""
    echo -e "  1) 修改 Endpoint   2) 修改 MTU   3) 手动编辑   0) 返回"
    echo ""
    read -rp "请选择 [0-3]: " sub

    case "$sub" in
        1)
            echo -e "\n  当前: $(grep 'Endpoint' "$WG_CONF" | awk -F' = ' '{print $2}')"
            echo -e "  可用: ${CYAN}162.159.192.1:2408${NC} / ${CYAN}[2606:4700:d0::a29f:c001]:2408${NC}"
            echo -e "  端口: 2408, 500, 1701, 4500\n"
            read -rp "新 Endpoint: " new_ep
            [[ -n "$new_ep" ]] && { sed -i "s|^Endpoint = .*|Endpoint = ${new_ep}|" "$WG_CONF"; ok "已更新"; restart_wg; }
            ;;
        2)
            echo -e "\n  当前: $(grep 'MTU' "$WG_CONF" | awk -F' = ' '{print $2}')  建议: 1280(保守) / 1420(较优)\n"
            read -rp "新 MTU [1280-1500]: " mtu
            [[ -n "$mtu" ]] && [[ "$mtu" -ge 1280 ]] && [[ "$mtu" -le 1500 ]] && {
                sed -i "s|^MTU = .*|MTU = ${mtu}|" "$WG_CONF"; ok "已更新"; restart_wg
            } || warn "无效的 MTU 值"
            ;;
        3)
            ${EDITOR:-nano} "$WG_CONF"
            read -rp "重启 wg0？[y/N]: " yn
            [[ "$yn" =~ ^[Yy]$ ]] && restart_wg
            ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
}

restart_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        info "重启 wg0 ..."; wg-quick down wg0 2>/dev/null || true
        wg-quick up wg0 || err "wg0 重启失败"; ok "wg0 已重启"
    else
        info "启动 wg0 ..."; wg-quick up wg0 || err "wg0 启动失败"; ok "wg0 已启动"
    fi
}

# ======================== 4. 删除服务 ========================

uninstall_warp() {
    echo ""; info "===== 删除 WARP 服务 ====="; echo ""
    echo -e "  ${RED}将删除: wg0 隧道 / 开机自启 / ${WG_CONF} / ${WORK_DIR}${NC}\n"
    read -rp "确认删除？[y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { warn "已取消"; return; }

    ip link show wg0 &>/dev/null 2>&1 && { wg-quick down wg0 2>/dev/null || true; ok "隧道已关闭"; }
    systemctl disable wg-quick@wg0 &>/dev/null 2>&1 || true; ok "已取消自启"
    rm -f "$WG_CONF"; ok "已删除 $WG_CONF"
    rm -rf "$WORK_DIR"; ok "已删除 $WORK_DIR"
    rm -f "$WGCF_BIN"
    echo -e "\n${GREEN}WARP 服务已完全删除${NC}\n"
}

# ======================== 主菜单 ========================

show_menu() {
    clear
    echo -e "${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║     WARP 一键双栈管理脚本  v2.0     ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    show_network_status
    echo -e "  ${BOLD}请选择操作：${NC}\n"
    echo -e "    ${GREEN}1)${NC} 免费账户安装    ${CYAN}2)${NC} 团队账户安装"
    echo -e "    ${YELLOW}3)${NC} 修改配置        ${RED}4)${NC} 删除服务"
    echo -e "\n    0) 退出\n"
}

main() {
    check_root
    while true; do
        show_menu
        read -rp "  请输入选项 [0-4]: " choice
        case "$choice" in
            1) install_free ;; 2) install_team ;;
            3) modify_config ;; 4) uninstall_warp ;;
            0) echo ""; info "再见！"; exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo ""; read -rp "按回车返回主菜单 ..." _
    done
}

main "$@"
