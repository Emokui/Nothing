#!/bin/bash
# WARP 一键双栈管理脚本 v2.0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WG_CONF="/etc/wireguard/wg0.conf"
WGCF_BIN="/usr/local/bin/wgcf"
APT_UPDATED=0
PKG_MANAGER=""
AUTOSTART_STATUS="未设置"

check_root() { [[ $EUID -ne 0 ]] && err "请使用 root 用户运行此脚本"; }

detect_pkg_manager() {
    [[ -n "$PKG_MANAGER" ]] && return
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="none"
    fi
}

install_pkg() {
    local pkg="$1"
    detect_pkg_manager
    case "$PKG_MANAGER" in
        apt)
            if [[ "$APT_UPDATED" -eq 0 ]]; then
                apt-get update -qq || return 1
                APT_UPDATED=1
            fi
            apt-get install -y -qq "$pkg"
            ;;
        yum) yum install -y "$pkg" ;;
        dnf) dnf install -y "$pkg" ;;
        *) return 1 ;;
    esac
}

has_ipv4_connectivity() {
    ping -4 -c 1 -W 3 1.1.1.1 &>/dev/null && return 0
    command -v curl &>/dev/null && curl -4 -s --max-time 4 http://1.1.1.1/cdn-cgi/trace &>/dev/null && return 0
    return 1
}

has_ipv6_connectivity() {
    ping -6 -c 1 -W 3 2606:4700:4700::1111 &>/dev/null && return 0
    command -v curl &>/dev/null && curl -6 -g -s --max-time 4 "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null && return 0
    return 1
}

resolve_host_record() {
    local family="$1" host="$2"
    if command -v dig &>/dev/null; then
        dig +short "$family" "$host" 2>/dev/null | head -1
        return
    fi
    if command -v getent &>/dev/null; then
        if [[ "$family" == "A" ]]; then
            getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}'
        else
            getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1{print $1}'
        fi
    fi
}

is_valid_endpoint() {
    local ep="$1" host port
    if [[ "$ep" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$ep" =~ ^([^:]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    else
        return 1
    fi
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

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
    has_ipv4_connectivity && HAS_V4=true
    has_ipv6_connectivity && HAS_V6=true

    if $HAS_V4 && $HAS_V6; then NET_MODE="dual"
    elif $HAS_V6; then NET_MODE="v6_only"
    elif $HAS_V4; then NET_MODE="v4_only"
    else NET_MODE="none"; fi
}

show_network_status() {
    detect_network
    case "$NET_MODE" in
        dual)    echo -e "  网络: ${GREEN}IPv4✓${NC} ${GREEN}IPv6✓${NC}" ;;
        v6_only) echo -e "  网络: ${RED}IPv4✗${NC} ${GREEN}IPv6✓${NC}" ;;
        v4_only) echo -e "  网络: ${GREEN}IPv4✓${NC} ${RED}IPv6✗${NC}" ;;
        none)    echo -e "  网络: ${RED}IPv4✗${NC} ${RED}IPv6✗${NC}" ;;
    esac
    if ip link show wg0 &>/dev/null 2>&1; then
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
    echo ""
}

install_wireguard_tools() {
    command -v wg &>/dev/null && { ok "wireguard-tools 已安装"; return; }
    info "安装 wireguard-tools ..."
    detect_pkg_manager
    case "$PKG_MANAGER" in
        apt)
            install_pkg wireguard-tools || err "wireguard-tools 安装失败"
            ;;
        yum)
            install_pkg epel-release >/dev/null 2>&1 || warn "epel-release 安装失败，继续尝试安装 wireguard-tools"
            install_pkg wireguard-tools || err "wireguard-tools 安装失败"
            ;;
        dnf)
            install_pkg wireguard-tools || err "wireguard-tools 安装失败"
            ;;
        *)
            err "无法识别包管理器，请手动安装 wireguard-tools"
            ;;
    esac
    command -v wg &>/dev/null || err "wireguard-tools 安装后仍未检测到 wg 命令"
    ok "wireguard-tools 已安装"
}

check_dependencies() {
    if ! command -v curl &>/dev/null; then
        info "安装 curl ..."
        install_pkg curl || err "curl 安装失败"
    fi
    command -v curl &>/dev/null || err "curl 不可用，无法继续"

    if ! command -v dig &>/dev/null; then
        info "安装 dns 工具 ..."
        detect_pkg_manager
        case "$PKG_MANAGER" in
            apt) install_pkg dnsutils || warn "dnsutils 安装失败，将尝试使用 getent 解析域名" ;;
            yum|dnf) install_pkg bind-utils || warn "bind-utils 安装失败，将尝试使用 getent 解析域名" ;;
            *) warn "未识别包管理器，将尝试使用 getent 解析域名" ;;
        esac
    fi
    command -v dig &>/dev/null || command -v getent &>/dev/null || warn "未检测到 dig/getent，域名解析将依赖固定回退 Endpoint"
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
    port=$(echo "$raw_ep" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')
    [[ -z "$port" ]] && port=2408

    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { ENDPOINT="${host}:${port}"; return; }

    if [[ "$NET_MODE" == "v6_only" ]]; then
        local resolved; resolved=$(resolve_host_record AAAA "$host")
        if [[ -n "$resolved" ]]; then
            ENDPOINT="[${resolved}]:${port}"
            info "域名 ${host} 解析为 IPv6: ${resolved}"
        else
            ENDPOINT="[2606:4700:d0::a29f:c001]:${port}"
            warn "域名解析失败，使用回退 IPv6 Endpoint"
        fi
    else
        local resolved; resolved=$(resolve_host_record A "$host")
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
            warn "已是双栈，无需安装"
            return 1 ;;
        v6_only) INSTALL_MODE="add_v4"; info "检测到纯 IPv6，将添加 IPv4 出口" ;;
        v4_only) INSTALL_MODE="add_v6"; info "检测到纯 IPv4，将添加 IPv6 出口" ;;
        none)    err "当前服务器无任何网络连接，无法继续" ;;
    esac
    return 0
}

check_wg0_exists() {
    ip link show wg0 &>/dev/null 2>&1 && err "检测到 wg0，请先删除后再安装"
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
    if command -v systemctl &>/dev/null; then
        if systemctl enable wg-quick@wg0 &>/dev/null; then
            AUTOSTART_STATUS="已启用"
            ok "已设置开机自启"
        else
            AUTOSTART_STATUS="启用失败"
            warn "设置开机自启失败（可能不是 systemd 环境）"
        fi
    else
        AUTOSTART_STATUS="不支持(systemctl 不存在)"
        warn "未检测到 systemctl，跳过开机自启设置"
    fi
}

show_result() {
    local mode="$1"
    echo ""
    ok "配置完成"

    local v4a v6a
    v4a=$(curl -s -4 --max-time 5 ip.gs 2>/dev/null || echo "获取失败")
    v6a=$(curl -s -6 --max-time 5 ip.gs 2>/dev/null || echo "获取失败")

    if [[ "$mode" == "add_v4" ]]; then
        echo -e "  模式: 纯 IPv6 -> 添加 IPv4"
        echo -e "  IPv4: ${GREEN}${v4a}${NC} (WARP)"
        echo -e "  IPv6: ${CYAN}${v6a}${NC} (原生)"
    else
        echo -e "  模式: 纯 IPv4 -> 添加 IPv6"
        echo -e "  IPv4: ${CYAN}${v4a}${NC} (原生)"
        echo -e "  IPv6: ${GREEN}${v6a}${NC} (WARP)"
    fi
    echo -e "  BBR:       $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo -e "  自启:      ${AUTOSTART_STATUS}"
    echo -e "  配置:      ${YELLOW}${WG_CONF}${NC}"
    echo ""
}

# ======================== 1. 免费账户 ========================

install_free() {
    echo ""; info "免费账户安装"; echo ""

    check_dependencies
    determine_install_mode || return
    check_wg0_exists; detect_arch; install_wireguard_tools

    local wgcf_downloaded=false
    if [[ ! -x "$WGCF_BIN" ]]; then
        info "获取 wgcf 最新版本 ..."
        local wgcf_ver
        wgcf_ver=$(curl -sI "https://github.com/ViRb3/wgcf/releases/latest" | grep -i '^location:' | grep -oP 'v[\d.]+')
        [[ -z "$wgcf_ver" ]] && err "无法获取 wgcf 最新版本号"
        local url="https://github.com/ViRb3/wgcf/releases/download/${wgcf_ver}/wgcf_${wgcf_ver#v}_linux_${WGCF_ARCH}"
        info "下载 wgcf ${wgcf_ver} ..."
        wget -qO "$WGCF_BIN" "$url" || curl -sLo "$WGCF_BIN" "$url" || err "wgcf 下载失败"
        chmod +x "$WGCF_BIN"; ok "wgcf ${wgcf_ver} 已下载"
        wgcf_downloaded=true
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    [[ -z "$tmpdir" ]] && err "创建临时目录失败"
    cd "$tmpdir" || err "进入临时目录失败: $tmpdir"

    info "注册 WARP 免费账户 ..."
    yes | "$WGCF_BIN" register || err "WARP 注册失败"
    ok "注册成功"

    info "生成 WireGuard 配置 ..."
    "$WGCF_BIN" generate || err "配置生成失败"

    local priv pub addr ep warp_v4 warp_v6
    priv=$(grep 'PrivateKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    pub=$(grep 'PublicKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    addr=$(grep 'Address' wgcf-profile.conf | awk -F' = ' '{print $2}')
    ep=$(grep 'Endpoint' wgcf-profile.conf | awk -F' = ' '{print $2}')
    warp_v4=$(echo "$addr" | grep -oP '\d+\.\d+\.\d+\.\d+')
    warp_v6=$(echo "$addr" | grep -oP '2606:[0-9a-f:]+')

    info "WARP IPv4: $warp_v4 | IPv6: $warp_v6"

    cd / || true
    rm -rf "$tmpdir"
    if $wgcf_downloaded; then
        rm -f "$WGCF_BIN"
        ok "wgcf 与临时文件已清理"
    else
        ok "临时文件已清理"
    fi

    resolve_endpoint "$ep"
    info "Endpoint: $ENDPOINT"
    write_wg_conf "$priv" "$warp_v4" "$warp_v6" "$pub" "$ENDPOINT" "$INSTALL_MODE" "free"
    enable_bbr; start_and_enable; show_result "$INSTALL_MODE"
}

# ======================== 2. 团队账户 ========================

install_team() {
    echo ""; info "团队账户安装"; echo ""
    check_dependencies
    determine_install_mode || return
    check_wg0_exists; install_wireguard_tools
    command -v wg &>/dev/null || err "wg 命令不可用"
    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开{CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 → Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}⚠ Token 有效期 60 秒，复制后立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " JWT_TOKEN
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

    [[ -z "$response" ]] && err "Cloudflare API 无响应，请检查网络后重试"
    echo "$response" | grep -q '"account"' || {
        local response_brief
        response_brief=$(echo "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)
        warn "API 返回摘要: ${response_brief}"
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

    write_wg_conf "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$ENDPOINT" "$INSTALL_MODE" "team($org)"
    enable_bbr; start_and_enable; show_result "$INSTALL_MODE"
}

# ======================== 3. 修改配置 ========================

modify_config() {
    echo ""; info "修改 WARP 配置"; echo ""
    [[ ! -f "$WG_CONF" ]] && { warn "未找到 ${WG_CONF}，请先安装"; return; }

    echo -e "  Endpoint: $(grep '^Endpoint = ' "$WG_CONF" | awk -F' = ' '{print $2}')"
    echo -e "  MTU:      $(grep '^MTU = ' "$WG_CONF" | awk -F' = ' '{print $2}')"
    echo -e "  1) 改 Endpoint  2) 改 MTU  3) 编辑配置  0) 返回"
    echo ""
    read -rp "请选择 [0-3]: " sub

    case "$sub" in
        1)
            echo -e "\n  当前: $(grep 'Endpoint' "$WG_CONF" | awk -F' = ' '{print $2}')"
            echo -e "  示例: ${CYAN}162.159.192.1:2408${NC} 或 ${CYAN}[2606:4700:d0::a29f:c001]:2408${NC}\n"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                if ! is_valid_endpoint "$new_ep"; then
                    warn "Endpoint 格式无效，请使用 域名/IP:端口 或 [IPv6]:端口"
                else
                    local escaped_ep
                    escaped_ep=$(escape_sed_replacement "$new_ep")
                    sed -i "s|^Endpoint = .*|Endpoint = ${escaped_ep}|" "$WG_CONF"
                    ok "已更新"
                    restart_wg
                fi
            fi
            ;;
        2)
            echo -e "\n  当前: $(grep 'MTU' "$WG_CONF" | awk -F' = ' '{print $2}')  建议: 1280 或 1420\n"
            read -rp "新 MTU [1280-1500]: " mtu
            if [[ "$mtu" =~ ^[0-9]+$ ]] && [[ "$mtu" -ge 1280 ]] && [[ "$mtu" -le 1500 ]]; then
                sed -i "s|^MTU = .*|MTU = ${mtu}|" "$WG_CONF"; ok "已更新"; restart_wg
            else
                warn "无效的 MTU 值"
            fi
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
    echo ""; info "删除 WARP 服务"; echo ""
    echo -e "  ${RED}将删除 wg0 与配置文件${NC}\n"
    read -rp "确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { warn "已取消"; return; }

    ip link show wg0 &>/dev/null 2>&1 && { wg-quick down wg0 2>/dev/null || true; ok "隧道已关闭"; }
    if command -v systemctl &>/dev/null; then
        systemctl disable wg-quick@wg0 &>/dev/null 2>&1 && ok "已取消自启" || warn "取消自启失败"
    else
        warn "未检测到 systemctl，跳过取消自启"
    fi
    rm -f "$WG_CONF"; ok "已删除 $WG_CONF"
    echo -e "\n${GREEN}WARP 服务已完全删除${NC}\n"
}

# ======================== 主菜单 ========================

show_menu() {
    clear
    echo -e "${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║       WARP 双栈管理脚本  v2.0     ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    show_network_status
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 修改配置   ${RED}4)${NC} 删除服务"
    echo -e "  0) 退出\n"
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
        echo ""; read -rp "回车继续..." _
    done
}

main "$@"
