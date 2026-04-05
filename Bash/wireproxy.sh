#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WIREPROXY_BIN="/usr/local/bin/wireproxy"
WIREPROXY_CONF_DIR="/etc/wireproxy"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
WG_WARP_CONF="/etc/wireproxy/wgcf-warp.conf"
SERVICE_NAME="wireproxy-warp"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

WGCF_REPO="ViRb3/wgcf"
WIREPROXY_REPO="windtf/wireproxy"

WGCF_PATH="/usr/local/bin/wgcf"
WGCF_TMP=""
PKG_MANAGER=""
APT_UPDATED=0
WIREPROXY_ARCH=""
WGCF_ARCH=""

DEFAULT_SOCKS_BIND="127.0.0.1:40000"
SOCKS_BIND="$DEFAULT_SOCKS_BIND"
SOCKS_USER=""
SOCKS_PASS=""

check_root() { [[ $EUID -ne 0 ]] && err "请使用 root 用户运行此脚本"; }

detect_pkg_manager() {
    [[ -n "$PKG_MANAGER" ]] && return
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v dnf >/dev/null 2>&1; then
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

check_dependencies() {
    local cmd
    for cmd in curl tar systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            install_pkg "$cmd" || err "安装依赖失败: $cmd"
        fi
    done
}

ensure_wireguard_tools() {
    command -v wg >/dev/null 2>&1 && return
    info "安装 wireguard-tools ..."
    install_pkg wireguard-tools || err "wireguard-tools 安装失败"
    command -v wg >/dev/null 2>&1 || err "wireguard-tools 安装后仍不可用"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            WIREPROXY_ARCH="amd64"
            WGCF_ARCH="amd64"
            ;;
        aarch64|arm64)
            WIREPROXY_ARCH="arm64"
            WGCF_ARCH="arm64"
            ;;
        armv7l)
            WIREPROXY_ARCH="arm"
            WGCF_ARCH="armv7"
            ;;
        *)
            err "不支持的架构: $(uname -m)"
            ;;
    esac
}

latest_release_tag() {
    local repo="$1"
    curl -fsSI "https://github.com/${repo}/releases/latest" \
        | awk 'tolower($1)=="location:" {print $2}' \
        | tail -n1 \
        | tr -d '\r' \
        | awk -F/ '{print $NF}'
}

download_wireproxy() {
    local version asset url tmpdir bin_path

    if [[ -x "$WIREPROXY_BIN" ]]; then
        ok "wireproxy 已安装"
        return 0
    fi

    detect_arch
    version="$(latest_release_tag "$WIREPROXY_REPO")"
    [[ -n "$version" ]] || err "无法获取 wireproxy 最新版本"

    asset="wireproxy_linux_${WIREPROXY_ARCH}.tar.gz"
    url="https://github.com/${WIREPROXY_REPO}/releases/download/${version}/${asset}"
    tmpdir="$(mktemp -d)" || err "创建临时目录失败"

    info "下载 wireproxy ${version} ..."
    if ! curl -fL "$url" -o "${tmpdir}/wireproxy.tar.gz"; then
        rm -rf "$tmpdir"
        err "wireproxy 下载失败"
    fi

    tar -xzf "${tmpdir}/wireproxy.tar.gz" -C "$tmpdir" || {
        rm -rf "$tmpdir"
        err "wireproxy 解压失败"
    }

    bin_path="$(find "$tmpdir" -type f -name wireproxy | head -n1)"
    [[ -n "$bin_path" ]] || {
        rm -rf "$tmpdir"
        err "压缩包中未找到 wireproxy 可执行文件"
    }

    install -m 755 "$bin_path" "$WIREPROXY_BIN"
    rm -rf "$tmpdir"
    ok "wireproxy 已安装到 ${WIREPROXY_BIN}"
}

ensure_wgcf() {
    local version url tmpdir

    if [[ -x "$WGCF_PATH" ]]; then
        return 0
    fi

    detect_arch
    version="$(latest_release_tag "$WGCF_REPO")"
    [[ -n "$version" ]] || err "无法获取 wgcf 最新版本"

    url="https://github.com/${WGCF_REPO}/releases/download/${version}/wgcf_${version#v}_linux_${WGCF_ARCH}"
    tmpdir="$(mktemp -d)" || err "创建临时目录失败"
    WGCF_TMP="${tmpdir}/wgcf"

    info "下载 wgcf ${version} ..."
    if ! curl -fL "$url" -o "$WGCF_TMP"; then
        rm -rf "$tmpdir"
        WGCF_TMP=""
        err "wgcf 下载失败"
    fi

    chmod +x "$WGCF_TMP"
    WGCF_PATH="$WGCF_TMP"
    ok "wgcf 已临时就绪"
}

cleanup_wgcf() {
    if [[ -n "$WGCF_TMP" ]]; then
        rm -rf "$(dirname "$WGCF_TMP")"
        WGCF_TMP=""
        WGCF_PATH="/usr/local/bin/wgcf"
    fi
}

is_valid_host_port() {
    local value="$1" port host
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    else
        return 1
    fi
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

extract_ini_value() {
    local file="$1" section="$2" key="$3"
    awk -F' = ' -v section="$section" -v key="$key" '
        $0 == "[" section "]" { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $1 == key { print $2; exit }
    ' "$file"
}

load_socks_settings() {
    SOCKS_BIND="$DEFAULT_SOCKS_BIND"
    SOCKS_USER=""
    SOCKS_PASS=""

    [[ -f "$WIREPROXY_CONF" ]] || return 0

    local bind user pass
    bind="$(extract_ini_value "$WIREPROXY_CONF" "Socks5" "BindAddress")"
    user="$(extract_ini_value "$WIREPROXY_CONF" "Socks5" "Username")"
    pass="$(extract_ini_value "$WIREPROXY_CONF" "Socks5" "Password")"

    [[ -n "$bind" ]] && SOCKS_BIND="$bind"
    [[ -n "$user" ]] && SOCKS_USER="$user"
    [[ -n "$pass" ]] && SOCKS_PASS="$pass"
}

prompt_socks_settings() {
    local input current_pass

    load_socks_settings
    current_pass="$SOCKS_PASS"

    while true; do
        read -rp "SOCKS 监听地址(默认:${SOCKS_BIND}): " input
        input="${input:-$SOCKS_BIND}"
        if is_valid_host_port "$input"; then
            SOCKS_BIND="$input"
            break
        fi
        warn "监听地址格式无效，请使用 127.0.0.1:40000 或 [::]:40000"
    done

    read -rp "SOCKS 用户名(留空为无认证，当前:${SOCKS_USER:-无}): " input
    if [[ -n "$input" ]]; then
        SOCKS_USER="$input"
        read -rsp "SOCKS 密码(留空保持当前，输入 - 清空): " input
        echo ""
        if [[ "$input" == "-" ]]; then
            SOCKS_PASS=""
        elif [[ -n "$input" ]]; then
            SOCKS_PASS="$input"
        else
            SOCKS_PASS="$current_pass"
        fi
    else
        SOCKS_USER=""
        SOCKS_PASS=""
    fi
}

write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5" account="$6"

    mkdir -p "$WIREPROXY_CONF_DIR"
    cat > "$WG_WARP_CONF" <<EOF
# WARP SOCKS - ${account} | $(date '+%Y-%m-%d %H:%M:%S')
[Interface]
PrivateKey = ${priv}
Address = ${v4}/32, ${v6}/128
DNS = 2606:4700:4700::1111
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_WARP_CONF"
    ok "WireGuard 配置已写入 ${WG_WARP_CONF}"
}

write_wireproxy_conf() {
    mkdir -p "$WIREPROXY_CONF_DIR"

    cat > "$WIREPROXY_CONF" <<EOF
WGConfig = ${WG_WARP_CONF}

[Socks5]
BindAddress = ${SOCKS_BIND}
EOF

    if [[ -n "$SOCKS_USER" ]]; then
        cat >> "$WIREPROXY_CONF" <<EOF
Username = ${SOCKS_USER}
Password = ${SOCKS_PASS}
EOF
    fi

    chmod 600 "$WIREPROXY_CONF"
    ok "wireproxy 配置已写入 ${WIREPROXY_CONF}"
}

create_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WARP SOCKS proxy via wireproxy
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WIREPROXY_BIN} -c ${WIREPROXY_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
}

validate_config() {
    "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" -n >/tmp/wireproxy-configtest.log 2>&1
}

try_restart_service() {
    if ! validate_config; then
        cat /tmp/wireproxy-configtest.log
        return 1
    fi

    create_service
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "设置开机自启失败"

    if systemctl restart "$SERVICE_NAME"; then
        return 0
    else
        systemctl --no-pager --full status "$SERVICE_NAME" || true
        return 1
    fi
}

restart_service() {
    if try_restart_service; then
        ok "${SERVICE_NAME} 已启动"
    else
        err "${SERVICE_NAME} 启动失败"
    fi
}

make_backup() {
    local file="$1" backup
    backup="$(mktemp)" || err "创建配置备份失败"
    cp "$file" "$backup" || {
        rm -f "$backup"
        err "备份配置失败: $file"
    }
    printf '%s\n' "$backup"
}

restart_service_with_backup() {
    local backup="$1" target="$2"

    if try_restart_service; then
        rm -f "$backup"
        ok "${SERVICE_NAME} 已启动"
        return 0
    fi

    warn "新配置启动失败，正在回滚..."
    cp "$backup" "$target" || true
    rm -f "$backup"

    if try_restart_service; then
        warn "已回滚到上一份可用配置"
    else
        warn "回滚后服务仍未启动，请手动检查配置"
    fi

    return 1
}

service_running() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

show_proxy_status() {
    load_socks_settings
    echo -e "  SOCKS: ${CYAN}${SOCKS_BIND}${NC}"
    if [[ -n "$SOCKS_USER" ]]; then
        echo -e "  认证: ${GREEN}${SOCKS_USER}${NC}"
    else
        echo -e "  认证: ${YELLOW}无${NC}"
    fi

    if service_running; then
        echo -e "  服务: ${GREEN}运行中${NC}"
    else
        echo -e "  服务: ${YELLOW}未运行${NC}"
    fi
    echo ""
}

show_proxy_trace() {
    local trace attempt
    load_socks_settings

    [[ -f "$WIREPROXY_CONF" ]] || { warn "未找到配置文件"; return; }

    for attempt in 1 2 3 4 5; do
        trace="$(fetch_trace_via_proxy "socks5h" || true)"
        [[ -n "$trace" ]] && break
        sleep 1
    done

    if [[ -z "$trace" ]]; then
        for attempt in 1 2 3; do
            trace="$(fetch_trace_via_proxy "socks5" || true)"
            [[ -n "$trace" ]] && break
            sleep 1
        done
    fi

    if [[ -z "$trace" ]]; then
        warn "无法通过 SOCKS 代理获取 WARP 出口信息，可稍等几秒后再试一次"
        return
    fi

    echo -e "  IP:   ${GREEN}$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')${NC}"
    echo -e "  Loc:  ${CYAN}$(printf '%s\n' "$trace" | awk -F= '/^loc=/{print $2}')${NC}"
    echo -e "  Warp: ${YELLOW}$(printf '%s\n' "$trace" | awk -F= '/^warp=/{print $2}')${NC}"
    echo ""
}

fetch_trace_via_proxy() {
    local scheme="$1" proxy_url
    local curl_args=()
    local trace=""

    proxy_url="${scheme}://${SOCKS_BIND}"
    curl_args=(--proxy "$proxy_url" --max-time 10 -s)
    if [[ -n "$SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

install_free() {
    local tmpdir priv pub addr endpoint warp_v4 warp_v6 version

    echo ""
    info "免费账户 SOCKS 安装"
    echo ""

    check_dependencies
    detect_arch
    prompt_socks_settings
    download_wireproxy
    ensure_wgcf

    tmpdir="$(mktemp -d)" || err "创建临时目录失败"
    cd "$tmpdir" || err "进入临时目录失败"

    info "注册 WARP 免费账户 ..."
    yes | "$WGCF_PATH" register >/dev/null 2>&1 || {
        cd / || true
        rm -rf "$tmpdir"
        cleanup_wgcf
        err "WARP 注册失败"
    }

    info "生成 WireGuard 配置 ..."
    "$WGCF_PATH" generate >/dev/null 2>&1 || {
        cd / || true
        rm -rf "$tmpdir"
        cleanup_wgcf
        err "配置生成失败"
    }

    priv="$(awk -F' = ' '/^PrivateKey = /{print $2}' wgcf-profile.conf)"
    pub="$(awk -F' = ' '/^PublicKey = /{print $2}' wgcf-profile.conf)"
    addr="$(awk -F' = ' '/^Address = /{print $2}' wgcf-profile.conf)"
    endpoint="$(awk -F' = ' '/^Endpoint = /{print $2}' wgcf-profile.conf)"
    warp_v4="$(printf '%s\n' "$addr" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    warp_v6="$(printf '%s\n' "$addr" | grep -oE '2606:[0-9a-f:]+' | head -n1)"

    [[ -n "$priv" && -n "$pub" && -n "$warp_v4" && -n "$warp_v6" && -n "$endpoint" ]] || {
        cd / || true
        rm -rf "$tmpdir"
        cleanup_wgcf
        err "无法从 wgcf-profile.conf 提取 WARP 配置"
    }

    cd / || true
    rm -rf "$tmpdir"
    cleanup_wgcf

    write_wg_conf "$priv" "$warp_v4" "$warp_v6" "$pub" "$endpoint" "free"
    write_wireproxy_conf
    restart_service

    echo ""
    ok "WARP SOCKS 配置完成"
    echo -e "  SOCKS: ${GREEN}${SOCKS_BIND}${NC}"
    show_proxy_trace
}

install_team() {
    local jwt_token priv pub response warp_v4 warp_v6 peer_pub endpoint ep_host ep_v4 ep_v6 ep_port org api_ports

    echo ""
    info "团队账户 SOCKS 安装"
    echo ""

    check_dependencies
    detect_arch
    prompt_socks_settings
    download_wireproxy
    ensure_wireguard_tools

    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 -> Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}Token 有效期较短，复制后请立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " jwt_token
    echo ""
    [[ -z "$jwt_token" ]] && { warn "已取消"; return; }

    info "生成 WireGuard 密钥对 ..."
    priv="$(wg genkey)"
    pub="$(printf '%s' "$priv" | wg pubkey)"

    info "向 Cloudflare API 注册设备 ..."
    response="$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: ${jwt_token}" \
        -d "{
            \"key\": \"${pub}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"Linux\",
            \"serial_number\": \"$(cat /proc/sys/kernel/random/uuid)\"
        }" 2>/dev/null)"

    [[ -n "$response" ]] || err "Cloudflare API 无响应，请检查网络后重试"
    printf '%s' "$response" | grep -q '"account"' || err "团队设备注册失败，请检查 Token 是否过期"

    warp_v4="$(printf '%s' "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v4"\s*:\s*"\K[^"]+' | head -1)"
    warp_v6="$(printf '%s' "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[^"]+' | head -1)"
    [[ -z "$warp_v4" ]] && warp_v4="$(printf '%s' "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)"
    [[ -z "$warp_v6" ]] && warp_v6="$(printf '%s' "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)"
    peer_pub="$(printf '%s' "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | tail -1)"
    org="$(printf '%s' "$response" | grep -oP '"organization"\s*:\s*"\K[^"]+' | head -1)"

    [[ -n "$warp_v4" && -n "$warp_v6" && -n "$peer_pub" ]] || err "无法从 API 响应中提取配置"

    ep_port=2408
    api_ports="$(printf '%s' "$response" | grep -oP '"ports"\s*:\s*\[\K[^\]]+' | head -1)"
    [[ -n "$api_ports" ]] && ep_port="$(printf '%s' "$api_ports" | cut -d',' -f1 | tr -d ' ')"

    ep_host="$(printf '%s' "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)"
    ep_v4="$(printf '%s' "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1 | sed 's/:0$//g')"
    ep_v6="$(printf '%s' "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1 | sed 's/\[//g; s/\]//g; s/:0$//g')"

    if [[ -n "$ep_v4" && "$ep_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        endpoint="${ep_v4}:${ep_port}"
    elif [[ -n "$ep_host" ]]; then
        endpoint="${ep_host%%:*}:${ep_port}"
    elif [[ -n "$ep_v6" ]]; then
        endpoint="[${ep_v6}]:${ep_port}"
    else
        err "API 未返回可用的 Endpoint"
    fi

    write_wg_conf "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$endpoint" "team(${org:-unknown})"
    write_wireproxy_conf
    restart_service

    echo ""
    ok "团队 WARP SOCKS 配置完成"
    echo -e "  组织: ${CYAN}${org:-unknown}${NC}"
    echo -e "  SOCKS: ${GREEN}${SOCKS_BIND}${NC}"
    show_proxy_trace
}

modify_config() {
    local current_endpoint current_mtu new_ep new_bind new_mtu input escaped_value backup_file

    echo ""
    info "修改 SOCKS 模式配置"
    echo ""

    [[ -f "$WIREPROXY_CONF" && -f "$WG_WARP_CONF" ]] || { warn "未找到配置，请先安装"; return; }

    load_socks_settings
    current_endpoint="$(extract_ini_value "$WG_WARP_CONF" "Peer" "Endpoint")"
    current_mtu="$(extract_ini_value "$WG_WARP_CONF" "Interface" "MTU")"
    [[ -z "$current_mtu" ]] && current_mtu="1280"

    echo -e "  1) 改 Endpoint"
    echo -e "  2) 改 MTU"
    echo -e "  3) 改 SOCKS 监听地址"
    echo -e "  4) 改 SOCKS 认证"
    echo -e "  5) 编辑 WireGuard 配置"
    echo -e "  6) 编辑 wireproxy 配置"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-6]: " input

    case "$input" in
        1)
            echo -e "\n  当前 Endpoint: ${current_endpoint}\n"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                is_valid_host_port "$new_ep" || { warn "Endpoint 格式无效"; return; }
                backup_file="$(make_backup "$WG_WARP_CONF")"
                escaped_value="$(escape_sed_replacement "$new_ep")"
                sed -i "s|^Endpoint = .*|Endpoint = ${escaped_value}|" "$WG_WARP_CONF"
                ok "Endpoint 已更新"
                restart_service_with_backup "$backup_file" "$WG_WARP_CONF"
            fi
            ;;
        2)
            echo -e "\n  当前 MTU: ${current_mtu}\n"
            read -rp "新 MTU [1280-1500]: " new_mtu
            if [[ "$new_mtu" =~ ^[0-9]+$ ]] && (( new_mtu >= 1280 && new_mtu <= 1500 )); then
                backup_file="$(make_backup "$WG_WARP_CONF")"
                sed -i "s|^MTU = .*|MTU = ${new_mtu}|" "$WG_WARP_CONF"
                ok "MTU 已更新"
                restart_service_with_backup "$backup_file" "$WG_WARP_CONF"
            else
                warn "无效的 MTU 值"
            fi
            ;;
        3)
            echo -e "\n  当前 SOCKS: ${SOCKS_BIND}\n"
            read -rp "新 SOCKS 监听地址: " new_bind
            if [[ -n "$new_bind" ]]; then
                is_valid_host_port "$new_bind" || { warn "监听地址格式无效"; return; }
                backup_file="$(make_backup "$WIREPROXY_CONF")"
                escaped_value="$(escape_sed_replacement "$new_bind")"
                sed -i "s|^BindAddress = .*|BindAddress = ${escaped_value}|" "$WIREPROXY_CONF"
                ok "SOCKS 监听地址已更新"
                restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            fi
            ;;
        4)
            backup_file="$(make_backup "$WIREPROXY_CONF")"
            prompt_socks_settings
            write_wireproxy_conf
            restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            ;;
        5)
            backup_file="$(make_backup "$WG_WARP_CONF")"
            ${EDITOR:-nano} "$WG_WARP_CONF"
            restart_service_with_backup "$backup_file" "$WG_WARP_CONF"
            ;;
        6)
            backup_file="$(make_backup "$WIREPROXY_CONF")"
            ${EDITOR:-nano} "$WIREPROXY_CONF"
            restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
}

show_ip() {
    echo ""
    info "当前 WARP SOCKS 出口"
    echo ""
    show_proxy_trace
}

uninstall_warp() {
    echo ""
    info "删除 WARP SOCKS 服务"
    echo ""
    read -rp "确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { warn "已取消"; return; }

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -f "$WIREPROXY_BIN"
    rm -rf "$WIREPROXY_CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true

    ok "WARP SOCKS 服务已删除"
}

show_menu() {
    clear
    echo -e "${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║        WARP SOCKS 管理脚本 v3.0     ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    show_proxy_status
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 修改配置   ${RED}4)${NC} 删除服务"
    echo -e "  5) 查看出口   0) 退出脚本"
    echo ""
}

main() {
    check_root
    while true; do
        show_menu
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) install_free ;;
            2) install_team ;;
            3) modify_config ;;
            4) uninstall_warp ;;
            5) show_ip ;;
            0) echo ""; info "再见！"; exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo ""
        read -rp "回车继续..." _
    done
}

main "$@"
