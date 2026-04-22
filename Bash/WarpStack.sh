#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

warpstack_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
warpstack_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warpstack_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
warpstack_err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WARPSTACK_WG_CONF="/etc/wireguard/wg0.conf"
WARPSTACK_WGCF_BIN="/usr/local/bin/wgcf"
WARPSTACK_APT_UPDATED=0
WARPSTACK_AUTOSTART_STATUS="未设置"

warpstack_check_root() { [[ $EUID -ne 0 ]] && warpstack_err "请使用 root 用户运行此脚本"; }

warpstack_install_pkg() {
    local packages=("$@")
    command -v apt-get &>/dev/null || warpstack_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
    if [[ "$WARPSTACK_APT_UPDATED" -eq 0 ]]; then
        apt-get update -qq || return 1
        WARPSTACK_APT_UPDATED=1
    fi
    apt-get install -y -qq "${packages[@]}"
}

warpstack_is_valid_endpoint() {
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

warpstack_escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

warpstack_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  WARPSTACK_WGCF_ARCH="amd64" ;;
        aarch64) WARPSTACK_WGCF_ARCH="arm64" ;;
        armv7l)  WARPSTACK_WGCF_ARCH="armv7" ;;
        *)       warpstack_err "不支持的架构: $arch" ;;
    esac
}

warpstack_detect_network() {
    local has_v4=false has_v6=false

    ip -4 addr show scope global 2>/dev/null | grep -q inet &&
        curl -4 -s --max-time 2 http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
        has_v4=true
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 &&
        curl -6 -g -s --max-time 2 "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
        has_v6=true

    if $has_v4 && $has_v6; then WARPSTACK_NET_MODE="dual"
    elif $has_v6; then WARPSTACK_NET_MODE="v6_only"
    elif $has_v4; then WARPSTACK_NET_MODE="v4_only"
    else WARPSTACK_NET_MODE="none"; fi
}

warpstack_show_network_status() {
    warpstack_detect_network
    case "$WARPSTACK_NET_MODE" in
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

warpstack_install_wireguard_tools() {
    command -v wg &>/dev/null && { warpstack_ok "wireguard-tools 已安装"; return; }
    warpstack_info "安装 wireguard-tools ..."
    warpstack_install_pkg --no-install-recommends wireguard-tools || warpstack_err "wireguard-tools 安装失败"
    command -v wg &>/dev/null || warpstack_err "wireguard-tools 安装后仍未检测到 wg 命令"
    warpstack_ok "wireguard-tools 已安装"
}

warpstack_check_dependencies() {
    if ! command -v curl &>/dev/null; then
        warpstack_info "安装 curl ..."
        warpstack_install_pkg curl || warpstack_err "curl 安装失败"
    fi
    command -v curl &>/dev/null || warpstack_err "curl 不可用，无法继续"
}

warpstack_prepare_install() {
    local account_type="$1"
    warpstack_check_dependencies
    warpstack_determine_install_mode || return 1
    warpstack_check_wg0_exists
    [[ "$account_type" == "free" ]] && warpstack_detect_arch
    warpstack_install_wireguard_tools
}

warpstack_determine_install_mode() {
    warpstack_detect_network
    case "$WARPSTACK_NET_MODE" in
        dual)
            warpstack_warn "已是双栈，无需安装"
            return 1 ;;
        v6_only) WARPSTACK_INSTALL_MODE="add_v4"; warpstack_info "检测到纯 IPv6，将添加 IPv4 出口" ;;
        v4_only) WARPSTACK_INSTALL_MODE="add_v6"; warpstack_info "检测到纯 IPv4，将添加 IPv6 出口" ;;
        none)    warpstack_err "当前服务器无任何网络连接，无法继续" ;;
    esac
    return 0
}

warpstack_check_wg0_exists() {
    ip link show wg0 &>/dev/null 2>&1 && warpstack_err "检测到 wg0，请先删除后再安装"
}

warpstack_write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" mode="$6" acct="$7"
    mkdir -p /etc/wireguard

    if [[ "$mode" == "add_v4" ]]; then
        cat > "$WARPSTACK_WG_CONF" << EOF
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
        cat > "$WARPSTACK_WG_CONF" << EOF
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
    chmod 600 "$WARPSTACK_WG_CONF"
    warpstack_ok "wg0.conf 已写入"
}

warpstack_start_and_enable() {
    warpstack_info "启动 wg0 隧道 ..."
    wg-quick up wg0 || warpstack_err "wg0 启动失败，请检查配置"
    warpstack_ok "wg0 隧道已启动"
    if command -v systemctl &>/dev/null; then
        if systemctl enable wg-quick@wg0 &>/dev/null; then
            WARPSTACK_AUTOSTART_STATUS="已启用"
            warpstack_ok "已设置开机自启"
        else
            WARPSTACK_AUTOSTART_STATUS="启用失败"
            warpstack_warn "设置开机自启失败（可能不是 systemd 环境）"
        fi
    else
        WARPSTACK_AUTOSTART_STATUS="不支持(systemctl 不存在)"
        warpstack_warn "未检测到 systemctl，跳过开机自启设置"
    fi
}

warpstack_show_result() {
    local mode="$1"
    warpstack_ok "配置完成"

    local v4a v6a
    v4a=$(warpstack_public_ip "-4" "获取失败")
    v6a=$(warpstack_public_ip "-6" "获取失败")

    if [[ "$mode" == "add_v4" ]]; then
        echo -e "  模式: 纯 IPv6 -> 添加 IPv4"
        echo -e "  IPv4: ${GREEN}${v4a}${NC} (WARP)"
        echo -e "  IPv6: ${CYAN}${v6a}${NC} (原生)"
    else
        echo -e "  模式: 纯 IPv4 -> 添加 IPv6"
        echo -e "  IPv4: ${CYAN}${v4a}${NC} (原生)"
        echo -e "  IPv6: ${GREEN}${v6a}${NC} (WARP)"
    fi
    echo -e "  自启: ${WARPSTACK_AUTOSTART_STATUS}"
    echo -e "  配置: ${YELLOW}${WARPSTACK_WG_CONF}${NC}"
}

warpstack_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" acct="$6"
    warpstack_info "Endpoint: $ep"
    warpstack_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$ep" "$WARPSTACK_INSTALL_MODE" "$acct"
    warpstack_start_and_enable
    warpstack_show_result "$WARPSTACK_INSTALL_MODE"
}

warpstack_conf_value() {
    local key="$1"
    awk -F' = ' -v key="$key" '$1 == key { print $2; exit }' "$WARPSTACK_WG_CONF"
}

warpstack_public_ip() {
    local family="$1" fallback="$2" ip
    ip=$(curl -s "$family" --max-time 5 ip.gs 2>/dev/null || true)
    [[ -n "$ip" ]] && printf '%s' "$ip" || printf '%s' "$fallback"
}

warpstack_install_free() {
    warpstack_prepare_install free || return 1

    local wgcf_downloaded=false
    if [[ ! -x "$WARPSTACK_WGCF_BIN" ]]; then
        warpstack_info "获取 wgcf 最新版本 ..."
        local wgcf_ver wgcf_host
        wgcf_host="https://github.com/ViRb3/wgcf"
        if [[ "$WARPSTACK_NET_MODE" == "v6_only" ]]; then
            wgcf_host="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
            warpstack_info "检测到纯 IPv6，wgcf 下载改用镜像: $wgcf_host"
            wgcf_ver=$(curl -fsSL "${wgcf_host}/releases/latest" | grep -oE '/releases/tag/v[0-9.]+' | sed 's#.*/##' | head -n1)
        else
            wgcf_ver=$(curl -fsSI "${wgcf_host}/releases/latest" | sed -nE 's/^[Ll]ocation:.*(v[0-9.]+).*/\1/p' | head -n1)
        fi
        [[ -z "$wgcf_ver" ]] && warpstack_err "无法获取 wgcf 最新版本号"
        local url="${wgcf_host}/releases/download/${wgcf_ver}/wgcf_${wgcf_ver#v}_linux_${WARPSTACK_WGCF_ARCH}"
        warpstack_info "下载 wgcf ${wgcf_ver} ..."
        curl -fsSL -o "$WARPSTACK_WGCF_BIN" "$url" || warpstack_err "wgcf 下载失败"
        chmod +x "$WARPSTACK_WGCF_BIN"; warpstack_ok "wgcf ${wgcf_ver} 已下载"
        wgcf_downloaded=true
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    [[ -z "$tmpdir" ]] && warpstack_err "创建临时目录失败"
    cd "$tmpdir" || warpstack_err "进入临时目录失败: $tmpdir"

    warpstack_info "注册 WARP 免费账户 ..."
    yes | "$WARPSTACK_WGCF_BIN" register || warpstack_err "WARP 注册失败"
    warpstack_ok "注册成功"

    warpstack_info "生成 WireGuard 配置 ..."
    "$WARPSTACK_WGCF_BIN" generate || warpstack_err "配置生成失败"

    local priv pub addr ep warp_v4 warp_v6
    priv=$(grep 'PrivateKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    pub=$(grep 'PublicKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    addr=$(grep 'Address' wgcf-profile.conf | awk -F' = ' '{print $2}')
    ep=$(grep 'Endpoint' wgcf-profile.conf | awk -F' = ' '{print $2}')
    warp_v4=$(echo "$addr" | grep -oP '\d+\.\d+\.\d+\.\d+')
    warp_v6=$(echo "$addr" | grep -oP '2606:[0-9a-f:]+')

    warpstack_info "WARP IPv4: $warp_v4 | IPv6: $warp_v6"

    cd / || true
    rm -rf "$tmpdir"
    if $wgcf_downloaded; then
        rm -f "$WARPSTACK_WGCF_BIN"
        warpstack_ok "wgcf 与临时文件已清理"
    else
        warpstack_ok "临时文件已清理"
    fi

    warpstack_finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$ep" "free"
}

warpstack_install_team() {
    local jwt_token priv pub response warp_v4 warp_v6 peer_pub org ep_port api_ports ep_host ep_v4 ep_v6 endpoint response_brief

    warpstack_prepare_install team || return 1
    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 → Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}⚠ Token 有效期 60 秒，复制后立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " jwt_token
    printf '\n'
    [[ -z "$jwt_token" ]] && { warpstack_warn "已取消"; return; }

    warpstack_info "生成 WireGuard 密钥对 ..."
    priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey)

    warpstack_info "向 Cloudflare API 注册设备 ..."
    response=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: ${jwt_token}" \
        -d "{
            \"key\": \"${pub}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"Linux\",
            \"serial_number\": \"$(cat /proc/sys/kernel/random/uuid)\"
        }" 2>/dev/null)

    [[ -z "$response" ]] && warpstack_err "Cloudflare API 无响应，请检查网络后重试"
    echo "$response" | grep -q '"account"' || {
        response_brief=$(echo "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)
        warpstack_warn "API 返回摘要: ${response_brief}"
        warpstack_err "注册失败，请检查 Token 是否过期"
    }
    warpstack_ok "团队设备注册成功"

    warp_v4=$(echo "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v4"\s*:\s*"\K[^"]+' | head -1)
    warp_v6=$(echo "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$warp_v4" ]] && warp_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$warp_v6" ]] && warp_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)
    peer_pub=$(echo "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | tail -1)

    [[ -z "$warp_v4" || -z "$warp_v6" || -z "$peer_pub" ]] && {
        echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        warpstack_err "无法从 API 响应中提取配置"
    }

    org=$(echo "$response" | grep -oP '"organization"\s*:\s*"\K[^"]+' | head -1)
    warpstack_info "WARP IPv4: $warp_v4 | IPv6: $warp_v6 | 组织: $org"

    ep_port=2408
    api_ports=$(echo "$response" | grep -oP '"ports"\s*:\s*\[\K[^\]]+' | head -1)
    [[ -n "$api_ports" ]] && ep_port=$(echo "$api_ports" | cut -d',' -f1 | tr -d ' ')

    ep_host=$(echo "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)
    if [[ "$WARPSTACK_NET_MODE" == "v6_only" ]]; then
        ep_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1)
        ep_v6=$(echo "$ep_v6" | sed 's/\[//g; s/\]//g; s/:0$//g')
        if [[ -n "$ep_v6" && "$ep_v6" != *"cf1"* ]]; then
            endpoint="[${ep_v6}]:${ep_port}"
        elif [[ -n "$ep_host" ]]; then
            endpoint="${ep_host%%:*}:${ep_port}"
        else
            warpstack_err "API 未返回可用的 Endpoint"
        fi
    else
        ep_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1)
        ep_v4=$(echo "$ep_v4" | sed 's/:0$//g')
        if [[ -n "$ep_v4" && "$ep_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            endpoint="${ep_v4}:${ep_port}"
        elif [[ -n "$ep_host" ]]; then
            endpoint="${ep_host%%:*}:${ep_port}"
        else
            warpstack_err "API 未返回可用的 Endpoint"
        fi
    fi
    warpstack_finish_install "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$endpoint" "team($org)"
}

warpstack_modify_config() {
    clear
    warpstack_menu_divider
    [[ ! -f "$WARPSTACK_WG_CONF" ]] && { warpstack_warn "未找到 ${WARPSTACK_WG_CONF}，请先安装"; return; }

    local current_ep current_mtu
    current_ep=$(warpstack_conf_value "Endpoint")
    current_mtu=$(warpstack_conf_value "MTU")

    echo -e "  ${CYAN}Endpoint:${NC} ${current_ep}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}"
    warpstack_menu_divider
    echo -e "  ${GREEN}1)${NC} 改 Endpoint  ${CYAN}2)${NC} 改 MTU"
    echo -e "  ${YELLOW}3)${NC} 编辑配置     ${RED}0)${NC} 返回上级"
    echo
    read -rp "  请选择 [0-3]: " sub

    case "$sub" in
        1)
            echo -e "  ${CYAN}当前 Endpoint:${NC} ${current_ep}"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                if ! warpstack_is_valid_endpoint "$new_ep"; then
                    warpstack_warn "Endpoint 格式无效，请使用 域名/IP:端口 或 [IPv6]:端口"
                else
                    local escaped_ep
                    escaped_ep=$(warpstack_escape_sed_replacement "$new_ep")
                    sed -i "s|^Endpoint = .*|Endpoint = ${escaped_ep}|" "$WARPSTACK_WG_CONF"
                    warpstack_ok "已更新"
                    warpstack_restart_wg
                fi
            fi
            ;;
        2)
            echo -e "  ${CYAN}当前 MTU:${NC} ${current_mtu}  建议: 1280 或 1420"
            read -rp "新 MTU [1280-1500]: " mtu
            if [[ "$mtu" =~ ^[0-9]+$ ]] && [[ "$mtu" -ge 1280 ]] && [[ "$mtu" -le 1500 ]]; then
                sed -i "s|^MTU = .*|MTU = ${mtu}|" "$WARPSTACK_WG_CONF"; warpstack_ok "已更新"; warpstack_restart_wg
            else
                warpstack_warn "无效的 MTU 值"
            fi
            ;;
        3)
            ${EDITOR:-nano} "$WARPSTACK_WG_CONF"
            read -rp "重启 wg0？[y/N]: " yn
            [[ "$yn" =~ ^[Yy]$ ]] && warpstack_restart_wg
            ;;
        0) return 1 ;;
        *) warpstack_warn "无效选择" ;;
    esac
}

warpstack_stop_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_info "暂停 wg0 ..."
        warpstack_down_wg || warpstack_err "wg0 暂停失败"
        warpstack_ok "wg0 已暂停"
    else
        warpstack_warn "wg0 未运行"
    fi
}

warpstack_down_wg() {
    wg-quick down wg0 2>/dev/null || true
    ! ip link show wg0 &>/dev/null 2>&1
}

warpstack_restart_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_info "重启 wg0 ..."
        warpstack_down_wg || warpstack_err "wg0 停止失败"
        wg-quick up wg0 || warpstack_err "wg0 重启失败"; warpstack_ok "wg0 已重启"
    else
        warpstack_info "启动 wg0 ..."; wg-quick up wg0 || warpstack_err "wg0 启动失败"; warpstack_ok "wg0 已启动"
    fi
}

warpstack_manage_service() {
    while true; do
        clear
        warpstack_menu_divider
        if ip link show wg0 &>/dev/null 2>&1; then
            echo -e "  ${CYAN}WARP 状态:${NC} ${GREEN}运行中${NC}"
        else
            echo -e "  ${CYAN}WARP 状态:${NC} ${YELLOW}未运行${NC}"
        fi
        warpstack_menu_divider
        echo -e "  ${GREEN}1)${NC} 修改配置  ${CYAN}2)${NC} 暂停服务"
        echo -e "  ${YELLOW}3)${NC} 重启服务  ${RED}0)${NC} 返回上级"
        echo
        read -rp "  请选择 [0-3]: " sub

        case "$sub" in
            1) warpstack_modify_config && warpstack_pause ;;
            2) warpstack_stop_wg; warpstack_pause ;;
            3) warpstack_restart_wg; warpstack_pause ;;
            0) return 0 ;;
            *) warpstack_warn "无效选择"; warpstack_pause ;;
        esac
    done
}

warpstack_show_ip() {
    clear
    warpstack_info "当前出口 IP"
    local v4 v6
    v4=$(warpstack_public_ip "-4" "无")
    v6=$(warpstack_public_ip "-6" "无")
    echo -e "  IPv4: ${CYAN}${v4}${NC}"
    echo -e "  IPv6: ${CYAN}${v6}${NC}"
}

warpstack_uninstall() {
    clear
    warpstack_info "删除 WARP 服务"
    echo -e "  ${RED}将删除 wg0 与配置文件${NC}"
    read -rp "确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_down_wg || warpstack_err "隧道关闭失败，请先处理后再删除"
        warpstack_ok "隧道已关闭"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl disable wg-quick@wg0 &>/dev/null 2>&1 && warpstack_ok "已取消自启" || warpstack_warn "取消自启失败"
    else
        warpstack_warn "未检测到 systemctl，跳过取消自启"
    fi
    rm -f "$WARPSTACK_WG_CONF"; warpstack_ok "已删除 $WARPSTACK_WG_CONF"
    warpstack_ok "WARP 服务已完全删除"
}

warpstack_show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP 出口管理 v2.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    warpstack_show_network_status
    warpstack_menu_divider
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 管理服务   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 退出脚本"
}

warpstack_pause() {
    read -rp "回车继续..." _
}

warpstack_menu_divider() {
    echo "  ══════════════════════════"
}

warpstack_menu() {
    local choice

    warpstack_check_root
    while true; do
        warpstack_show_menu
        warpstack_menu_divider
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) warpstack_install_free; warpstack_pause ;;
            2) warpstack_install_team; warpstack_pause ;;
            3) warpstack_manage_service ;;
            4) warpstack_uninstall && warpstack_pause ;;
            5) warpstack_show_ip; warpstack_pause ;;
            0) return 0 ;;
            *) warpstack_warn "无效选项"; warpstack_pause ;;
        esac
    done
}

warpstack_menu
