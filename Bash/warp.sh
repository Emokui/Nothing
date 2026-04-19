#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WG_CONF="/etc/wireguard/wg0.conf"
WGCF_BIN="/usr/local/bin/wgcf"
APT_UPDATED=0
AUTOSTART_STATUS="未设置"

check_root() { [[ $EUID -ne 0 ]] && err "请使用 root 用户运行此脚本"; }

install_pkg() {
    local pkg="$1"
    command -v apt-get &>/dev/null || err "仅支持 Debian/Ubuntu（未找到 apt-get）"
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        apt-get update -qq || return 1
        APT_UPDATED=1
    fi
    apt-get install -y -qq "$pkg"
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
    ip -4 addr show scope global 2>/dev/null | grep -q inet &&
        curl -4 -s --max-time 2 http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
        HAS_V4=true
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 &&
        curl -6 -g -s --max-time 2 "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
        HAS_V6=true

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
}

install_wireguard_tools() {
    command -v wg &>/dev/null && { ok "wireguard-tools 已安装"; return; }
    info "安装 wireguard-tools ..."
    install_pkg wireguard-tools || err "wireguard-tools 安装失败"
    command -v wg &>/dev/null || err "wireguard-tools 安装后仍未检测到 wg 命令"
    ok "wireguard-tools 已安装"
}

check_dependencies() {
    if ! command -v curl &>/dev/null; then
        info "安装 curl ..."
        install_pkg curl || err "curl 安装失败"
    fi
    command -v curl &>/dev/null || err "curl 不可用，无法继续"
}

prepare_install() {
    local account_type="$1"
    check_dependencies
    determine_install_mode || return 1
    check_wg0_exists
    [[ "$account_type" == "free" ]] && detect_arch
    install_wireguard_tools
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
    ok "配置完成"

    local v4a v6a
    v4a=$(public_ip "-4" "获取失败")
    v6a=$(public_ip "-6" "获取失败")

    if [[ "$mode" == "add_v4" ]]; then
        echo -e "  模式: 纯 IPv6 -> 添加 IPv4"
        echo -e "  IPv4: ${GREEN}${v4a}${NC} (WARP)"
        echo -e "  IPv6: ${CYAN}${v6a}${NC} (原生)"
    else
        echo -e "  模式: 纯 IPv4 -> 添加 IPv6"
        echo -e "  IPv4: ${CYAN}${v4a}${NC} (原生)"
        echo -e "  IPv6: ${GREEN}${v6a}${NC} (WARP)"
    fi
    echo -e "  自启: ${AUTOSTART_STATUS}"
    echo -e "  配置: ${YELLOW}${WG_CONF}${NC}"
}

finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" acct="$6"
    info "Endpoint: $ep"
    write_wg_conf "$priv" "$v4" "$v6" "$pub" "$ep" "$INSTALL_MODE" "$acct"
    start_and_enable
    show_result "$INSTALL_MODE"
}

conf_value() {
    local key="$1"
    awk -F' = ' -v key="$key" '$1 == key { print $2; exit }' "$WG_CONF"
}

public_ip() {
    local family="$1" fallback="$2" ip
    ip=$(curl -s "$family" --max-time 5 ip.gs 2>/dev/null || true)
    [[ -n "$ip" ]] && printf '%s' "$ip" || printf '%s' "$fallback"
}

install_free() {
    prepare_install free || return 1

    local wgcf_downloaded=false
    if [[ ! -x "$WGCF_BIN" ]]; then
        info "获取 wgcf 最新版本 ..."
        local wgcf_ver wgcf_host
        wgcf_host="https://github.com/ViRb3/wgcf"
        if [[ "$NET_MODE" == "v6_only" ]]; then
            wgcf_host="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
            info "检测到纯 IPv6，wgcf 下载改用镜像: $wgcf_host"
            wgcf_ver=$(curl -fsSL "${wgcf_host}/releases/latest" | grep -oE '/releases/tag/v[0-9.]+' | sed 's#.*/##' | head -n1)
        else
            wgcf_ver=$(curl -fsSI "${wgcf_host}/releases/latest" | sed -nE 's/^[Ll]ocation:.*(v[0-9.]+).*/\1/p' | head -n1)
        fi
        [[ -z "$wgcf_ver" ]] && err "无法获取 wgcf 最新版本号"
        local url="${wgcf_host}/releases/download/${wgcf_ver}/wgcf_${wgcf_ver#v}_linux_${WGCF_ARCH}"
        info "下载 wgcf ${wgcf_ver} ..."
        curl -fsSL -o "$WGCF_BIN" "$url" || err "wgcf 下载失败"
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

    finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$ep" "free"
}

install_team() {
    prepare_install team || return 1
    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 → Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}⚠ Token 有效期 60 秒，复制后立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " JWT_TOKEN
    printf '\n'
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

    local ep_port=2408
    local api_ports; api_ports=$(echo "$response" | grep -oP '"ports"\s*:\s*\[\K[^\]]+' | head -1)
    [[ -n "$api_ports" ]] && ep_port=$(echo "$api_ports" | cut -d',' -f1 | tr -d ' ')

    local ep_host; ep_host=$(echo "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)
    if [[ "$NET_MODE" == "v6_only" ]]; then
        local ep_v6; ep_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1)
        ep_v6=$(echo "$ep_v6" | sed 's/\[//g; s/\]//g; s/:0$//g')
        if [[ -n "$ep_v6" && "$ep_v6" != *"cf1"* ]]; then
            ENDPOINT="[${ep_v6}]:${ep_port}"
        elif [[ -n "$ep_host" ]]; then
            ENDPOINT="${ep_host%%:*}:${ep_port}"
        else
            err "API 未返回可用的 Endpoint"
        fi
    else
        local ep_v4; ep_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1)
        ep_v4=$(echo "$ep_v4" | sed 's/:0$//g')
        if [[ -n "$ep_v4" && "$ep_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ENDPOINT="${ep_v4}:${ep_port}"
        elif [[ -n "$ep_host" ]]; then
            ENDPOINT="${ep_host%%:*}:${ep_port}"
        else
            err "API 未返回可用的 Endpoint"
        fi
    fi
    finish_install "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$ENDPOINT" "team($org)"
}

modify_config() {
    clear
    info "${BOLD}${CYAN}修改 WARP 配置${NC}"
    [[ ! -f "$WG_CONF" ]] && { warn "未找到 ${WG_CONF}，请先安装"; return; }

    local current_ep current_mtu
    current_ep=$(conf_value "Endpoint")
    current_mtu=$(conf_value "MTU")

    echo -e "  ${CYAN}Endpoint:${NC} ${current_ep}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}"
    echo -e "  ${GREEN}1)${NC} 改 Endpoint  ${CYAN}2)${NC} 改 MTU  ${YELLOW}3)${NC} 编辑配置  ${RED}0)${NC} 返回"
    read -rp "请选择 [0-3]: " sub

    case "$sub" in
        1)
            echo -e "  ${CYAN}当前 Endpoint:${NC} ${current_ep}"
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
            echo -e "  ${CYAN}当前 MTU:${NC} ${current_mtu}  建议: 1280 或 1420"
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
        0) return 1 ;;
        *) warn "无效选择" ;;
    esac
}

stop_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        info "暂停 wg0 ..."
        down_wg || err "wg0 暂停失败"
        ok "wg0 已暂停"
    else
        warn "wg0 未运行"
    fi
}

down_wg() {
    wg-quick down wg0 2>/dev/null || true
    ! ip link show wg0 &>/dev/null 2>&1
}

restart_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        info "重启 wg0 ..."
        down_wg || err "wg0 停止失败"
        wg-quick up wg0 || err "wg0 重启失败"; ok "wg0 已重启"
    else
        info "启动 wg0 ..."; wg-quick up wg0 || err "wg0 启动失败"; ok "wg0 已启动"
    fi
}

manage_service() {
    while true; do
        clear
        info "${BOLD}${CYAN}管理 WARP 服务${NC}"
        if ip link show wg0 &>/dev/null 2>&1; then
            echo -e "  ${CYAN}状态:${NC} ${GREEN}运行中${NC}"
        else
            echo -e "  ${CYAN}状态:${NC} ${YELLOW}未运行${NC}"
        fi
        echo -e "  ${GREEN}1)${NC} 修改配置  ${CYAN}2)${NC} 暂停服务  ${YELLOW}3)${NC} 重启服务  ${RED}0)${NC} 返回"
        read -rp "请选择 [0-3]: " sub

        case "$sub" in
            1) modify_config && pause ;;
            2) stop_wg; pause ;;
            3) restart_wg; pause ;;
            0) return 0 ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

show_ip() {
    clear
    info "当前出口 IP"
    local v4 v6
    v4=$(public_ip "-4" "无")
    v6=$(public_ip "-6" "无")
    echo -e "  IPv4: ${CYAN}${v4}${NC}"
    echo -e "  IPv6: ${CYAN}${v6}${NC}"
}

uninstall_warp() {
    clear
    info "删除 WARP 服务"
    echo -e "  ${RED}将删除 wg0 与配置文件${NC}"
    read -rp "确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { warn "已取消"; return 1; }

    if ip link show wg0 &>/dev/null 2>&1; then
        down_wg && ok "隧道已关闭" || warn "隧道关闭失败"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl disable wg-quick@wg0 &>/dev/null 2>&1 && ok "已取消自启" || warn "取消自启失败"
    else
        warn "未检测到 systemctl，跳过取消自启"
    fi
    rm -f "$WG_CONF"; ok "已删除 $WG_CONF"
    ok "WARP 服务已完全删除"
}

show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP 出口管理 v2.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    show_network_status
    echo "  ══════════════════════════"
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 管理服务   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 退出脚本"
}

pause() {
    read -rp "回车继续..." _
}

main() {
    check_root
    while true; do
        show_menu
        echo "  ══════════════════════════"
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) install_free; pause ;;
            2) install_team; pause ;;
            3) manage_service ;;
            4) uninstall_warp && pause ;;
            5) show_ip; pause ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效选项"; pause ;;
        esac
    done
}

main "$@"
