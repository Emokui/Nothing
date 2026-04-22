#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

wireproxy_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
wireproxy_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
wireproxy_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
wireproxy_err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

WIREPROXY_BIN="/usr/local/bin/wireproxy"
WIREPROXY_CONF_DIR="/etc/wireproxy"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
WIREPROXY_WG_WARP_CONF="/etc/wireproxy/wgcf-warp.conf"
WIREPROXY_SERVICE_NAME="wireproxy-warp"
WIREPROXY_SERVICE_FILE="/etc/systemd/system/${WIREPROXY_SERVICE_NAME}.service"

WIREPROXY_WGCF_REPO="ViRb3/wgcf"
WIREPROXY_BASE_URL="https://cdn-wireproxy.pages.dev/windtf/wireproxy"

WIREPROXY_WGCF_PATH="/usr/local/bin/wgcf"
WIREPROXY_WGCF_TMP=""
WIREPROXY_ARCH=""
WIREPROXY_WGCF_ARCH=""
WIREPROXY_NET_MODE=""

WIREPROXY_DEFAULT_SOCKS_BIND="127.0.0.1:40000"
WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
WIREPROXY_SOCKS_USER=""
WIREPROXY_SOCKS_PASS=""

wireproxy_check_root() { [[ $EUID -ne 0 ]] && wireproxy_err "请使用 root 用户运行此脚本"; }

wireproxy_require_apt() {
    command -v apt-get >/dev/null 2>&1 || wireproxy_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
}

wireproxy_check_dependencies() {
    local cmd
    wireproxy_require_apt
    for cmd in curl tar systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || wireproxy_err "缺少依赖: $cmd"
    done
}

wireproxy_ensure_wireguard_tools() {
    command -v wg >/dev/null 2>&1 && return 0

    wireproxy_info "安装 wireguard-tools ..."
    apt-get update -qq || wireproxy_err "apt update 失败"
    apt-get install -y -qq --no-install-recommends wireguard-tools || wireproxy_err "wireguard-tools 安装失败"
    command -v wg >/dev/null 2>&1 || wireproxy_err "wireguard-tools 安装后仍未检测到 wg 命令"
}

wireproxy_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            WIREPROXY_ARCH="amd64"
            WIREPROXY_WGCF_ARCH="amd64"
            ;;
        aarch64|arm64)
            WIREPROXY_ARCH="arm64"
            WIREPROXY_WGCF_ARCH="arm64"
            ;;
        armv7l)
            WIREPROXY_ARCH="arm"
            WIREPROXY_WGCF_ARCH="armv7"
            ;;
        *)
            wireproxy_err "不支持的架构: $(uname -m)"
            ;;
    esac
}

wireproxy_detect_network() {
    local has_v4=false has_v6=false

    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show scope global 2>/dev/null | grep -q inet &&
            curl -4 --connect-timeout 3 --max-time 5 -s http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
            has_v4=true
        ip -6 addr show scope global 2>/dev/null | grep -q inet6 &&
            curl -6 -g --connect-timeout 3 --max-time 5 -s "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
            has_v6=true
    else
        curl -4 --connect-timeout 3 --max-time 5 -s http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
            has_v4=true
        curl -6 -g --connect-timeout 3 --max-time 5 -s "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
            has_v6=true
    fi

    if $has_v4 && $has_v6; then
        WIREPROXY_NET_MODE="dual"
    elif $has_v6; then
        WIREPROXY_NET_MODE="v6_only"
    elif $has_v4; then
        WIREPROXY_NET_MODE="v4_only"
    else
        WIREPROXY_NET_MODE="none"
    fi
}

wireproxy_latest_release_tag() {
    local repo="$1"
    curl --connect-timeout 5 --max-time 20 -fsSI "https://github.com/${repo}/releases/latest" \
        | awk 'tolower($1)=="location:" {print $2}' \
        | tail -n1 \
        | tr -d '\r' \
        | awk -F/ '{print $NF}'
}

wireproxy_download_binary() {
    local version asset url tmpdir bin_path

    if [[ -x "$WIREPROXY_BIN" ]]; then
        wireproxy_ok "wireproxy 已安装"
        return 0
    fi

    wireproxy_detect_arch
    wireproxy_info "获取 wireproxy 最新版本 ..."
    version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${WIREPROXY_BASE_URL}/releases/latest" \
        | grep -oE '/releases/tag/v[0-9.]+' \
        | sed 's#.*/##' \
        | head -n1)"
    [[ -n "$version" ]] || wireproxy_err "无法获取 wireproxy 最新版本"

    asset="wireproxy_linux_${WIREPROXY_ARCH}.tar.gz"
    url="${WIREPROXY_BASE_URL}/releases/download/${version}/${asset}"
    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"

    wireproxy_info "下载 wireproxy ${version} ..."
    if ! curl --connect-timeout 5 --max-time 120 -fL "$url" -o "${tmpdir}/wireproxy.tar.gz"; then
        rm -rf "$tmpdir"
        wireproxy_err "wireproxy 下载失败"
    fi

    tar -xzf "${tmpdir}/wireproxy.tar.gz" -C "$tmpdir" || {
        rm -rf "$tmpdir"
        wireproxy_err "wireproxy 解压失败"
    }

    bin_path="$(find "$tmpdir" -type f -name wireproxy | head -n1)"
    [[ -n "$bin_path" ]] || {
        rm -rf "$tmpdir"
        wireproxy_err "压缩包中未找到 wireproxy 可执行文件"
    }

    install -m 755 "$bin_path" "$WIREPROXY_BIN"
    rm -rf "$tmpdir"
    wireproxy_ok "wireproxy 已安装到 ${WIREPROXY_BIN}"
}

wireproxy_ensure_wgcf() {
    local version url tmpdir wgcf_base_url

    if [[ -x "$WIREPROXY_WGCF_PATH" ]]; then
        return 0
    fi

    wireproxy_detect_arch
    wireproxy_detect_network
    wgcf_base_url="https://github.com/${WIREPROXY_WGCF_REPO}"
    wireproxy_info "获取 wgcf 最新版本 ..."
    if [[ "$WIREPROXY_NET_MODE" == "v6_only" ]]; then
        wgcf_base_url="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
        wireproxy_info "检测到纯 IPv6，wgcf 下载改用镜像: $wgcf_base_url"
        version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${wgcf_base_url}/releases/latest" \
            | grep -oE '/releases/tag/v[0-9.]+' \
            | sed 's#.*/##' \
            | head -n1)"
    else
        version="$(wireproxy_latest_release_tag "$WIREPROXY_WGCF_REPO")"
    fi
    [[ -n "$version" ]] || wireproxy_err "无法获取 wgcf 最新版本"

    url="${wgcf_base_url}/releases/download/${version}/wgcf_${version#v}_linux_${WIREPROXY_WGCF_ARCH}"
    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"
    WIREPROXY_WGCF_TMP="${tmpdir}/wgcf"

    wireproxy_info "下载 wgcf ${version} ..."
    if ! curl --connect-timeout 5 --max-time 120 -fL "$url" -o "$WIREPROXY_WGCF_TMP"; then
        rm -rf "$tmpdir"
        WIREPROXY_WGCF_TMP=""
        wireproxy_err "wgcf 下载失败"
    fi

    chmod +x "$WIREPROXY_WGCF_TMP"
    WIREPROXY_WGCF_PATH="$WIREPROXY_WGCF_TMP"
    wireproxy_ok "wgcf 已临时就绪"
}

wireproxy_cleanup_wgcf() {
    if [[ -n "$WIREPROXY_WGCF_TMP" ]]; then
        rm -rf "$(dirname "$WIREPROXY_WGCF_TMP")"
        WIREPROXY_WGCF_TMP=""
        WIREPROXY_WGCF_PATH="/usr/local/bin/wgcf"
    fi
}

wireproxy_is_valid_host_port() {
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

wireproxy_escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

wireproxy_extract_ini_value() {
    local file="$1" section="$2" key="$3"
    awk -F' = ' -v section="$section" -v key="$key" '
        $0 == "[" section "]" { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $1 == key { print $2; exit }
    ' "$file"
}

wireproxy_endpoint_host() {
    local value="$1"
    if [[ "$value" =~ ^\[([0-9a-fA-F:]+)\]:[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]+):[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$value"
    fi
}

wireproxy_endpoint_port() {
    local value="$1"
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[^:]+:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

wireproxy_is_ipv4_literal() {
    local host="$1"
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

wireproxy_is_ipv6_literal() {
    local host="$1"
    [[ "$host" == *:* ]]
}

wireproxy_resolve_host_by_family() {
    local host="$1" family="$2"
    command -v getent >/dev/null 2>&1 || wireproxy_err "缺少 getent，无法解析 Endpoint"
    case "$family" in
        4) getent ahostsv4 "$host" | awk 'NR==1 { print $1; exit }' ;;
        6) getent ahostsv6 "$host" | awk 'NR==1 { print $1; exit }' ;;
        *) return 1 ;;
    esac
}

wireproxy_select_endpoint_for_network() {
    local current="$1" preferred_v4="$2" preferred_v6="$3" preferred_port="$4"
    local host port resolved

    [[ -n "$WIREPROXY_NET_MODE" ]] || wireproxy_detect_network
    port="${preferred_port:-$(wireproxy_endpoint_port "$current")}"
    [[ -z "$port" ]] && port="2408"

    case "$WIREPROXY_NET_MODE" in
        v6_only)
            if [[ -n "$preferred_v6" ]]; then
                printf '[%s]:%s\n' "$preferred_v6" "$port"
                return 0
            fi
            host="$(wireproxy_endpoint_host "$current")"
            [[ -n "$host" ]] || wireproxy_err "无法确定 IPv6 Endpoint"
            if wireproxy_is_ipv6_literal "$host" && ! wireproxy_is_ipv4_literal "$host"; then
                printf '[%s]:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(wireproxy_resolve_host_by_family "$host" 6)"
            [[ -n "$resolved" ]] || wireproxy_err "无法解析 IPv6 Endpoint: $host"
            printf '[%s]:%s\n' "$resolved" "$port"
            ;;
        dual|v4_only)
            if [[ -n "$preferred_v4" ]]; then
                printf '%s:%s\n' "$preferred_v4" "$port"
                return 0
            fi
            host="$(wireproxy_endpoint_host "$current")"
            [[ -n "$host" ]] || wireproxy_err "无法确定 IPv4 Endpoint"
            if wireproxy_is_ipv4_literal "$host"; then
                printf '%s:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(wireproxy_resolve_host_by_family "$host" 4)"
            [[ -n "$resolved" ]] || wireproxy_err "无法解析 IPv4 Endpoint: $host"
            printf '%s:%s\n' "$resolved" "$port"
            ;;
        none)
            wireproxy_err "当前服务器无可用网络，无法确定 Endpoint"
            ;;
        *)
            wireproxy_err "未知网络模式: $WIREPROXY_NET_MODE"
            ;;
    esac
}

wireproxy_load_socks_settings() {
    WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
    WIREPROXY_SOCKS_USER=""
    WIREPROXY_SOCKS_PASS=""

    [[ -f "$WIREPROXY_CONF" ]] || return 0

    local bind user pass
    bind="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "BindAddress")"
    user="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "Username")"
    pass="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "Password")"

    [[ -n "$bind" ]] && WIREPROXY_SOCKS_BIND="$bind"
    [[ -n "$user" ]] && WIREPROXY_SOCKS_USER="$user"
    [[ -n "$pass" ]] && WIREPROXY_SOCKS_PASS="$pass"
}

wireproxy_prompt_socks_settings() {
    local input current_pass

    wireproxy_load_socks_settings
    current_pass="$WIREPROXY_SOCKS_PASS"

    while true; do
        read -rp "SOCKS 监听地址(默认:${WIREPROXY_SOCKS_BIND}): " input
        input="${input:-$WIREPROXY_SOCKS_BIND}"
        if wireproxy_is_valid_host_port "$input"; then
            WIREPROXY_SOCKS_BIND="$input"
            break
        fi
        wireproxy_warn "监听地址格式无效，请使用 127.0.0.1:40000 或 [::]:40000"
    done

    read -rp "SOCKS 用户名(留空为无认证，当前:${WIREPROXY_SOCKS_USER:-无}): " input
    if [[ -n "$input" ]]; then
        WIREPROXY_SOCKS_USER="$input"
        read -rsp "SOCKS 密码(留空保持当前，输入 - 清空): " input
        echo ""
        if [[ "$input" == "-" ]]; then
            WIREPROXY_SOCKS_PASS=""
        elif [[ -n "$input" ]]; then
            WIREPROXY_SOCKS_PASS="$input"
        else
            WIREPROXY_SOCKS_PASS="$current_pass"
        fi
    else
        WIREPROXY_SOCKS_USER=""
        WIREPROXY_SOCKS_PASS=""
    fi
}

wireproxy_write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5" account="$6"

    mkdir -p "$WIREPROXY_CONF_DIR"
    cat > "$WIREPROXY_WG_WARP_CONF" <<EOF
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
    chmod 600 "$WIREPROXY_WG_WARP_CONF"
    wireproxy_ok "WireGuard 配置已写入 ${WIREPROXY_WG_WARP_CONF}"
}

wireproxy_write_conf() {
    mkdir -p "$WIREPROXY_CONF_DIR"

    cat > "$WIREPROXY_CONF" <<EOF
WGConfig = ${WIREPROXY_WG_WARP_CONF}

[Socks5]
BindAddress = ${WIREPROXY_SOCKS_BIND}
EOF

    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        cat >> "$WIREPROXY_CONF" <<EOF
Username = ${WIREPROXY_SOCKS_USER}
Password = ${WIREPROXY_SOCKS_PASS}
EOF
    fi

    chmod 600 "$WIREPROXY_CONF"
    wireproxy_ok "wireproxy 配置已写入 ${WIREPROXY_CONF}"
}

wireproxy_create_service() {
    cat > "$WIREPROXY_SERVICE_FILE" <<EOF
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
    chmod 644 "$WIREPROXY_SERVICE_FILE"
}

wireproxy_validate_config() {
    "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" -n >/tmp/wireproxy-configtest.log 2>&1
}

wireproxy_try_restart_service() {
    if ! wireproxy_validate_config; then
        cat /tmp/wireproxy-configtest.log
        return 1
    fi

    wireproxy_create_service
    systemctl daemon-reload || return 1
    systemctl enable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || wireproxy_warn "设置开机自启失败"

    if systemctl restart "$WIREPROXY_SERVICE_NAME"; then
        return 0
    else
        systemctl --no-pager --full status "$WIREPROXY_SERVICE_NAME" || true
        return 1
    fi
}

wireproxy_restart_service() {
    if wireproxy_try_restart_service; then
        wireproxy_ok "${WIREPROXY_SERVICE_NAME} 已启动"
    else
        wireproxy_err "${WIREPROXY_SERVICE_NAME} 启动失败"
    fi
}

wireproxy_make_backup() {
    local file="$1" backup
    backup="$(mktemp)" || wireproxy_err "创建配置备份失败"
    cp "$file" "$backup" || {
        rm -f "$backup"
        wireproxy_err "备份配置失败: $file"
    }
    printf '%s\n' "$backup"
}

wireproxy_restart_service_with_backup() {
    local backup="$1" target="$2"

    if wireproxy_try_restart_service; then
        rm -f "$backup"
        wireproxy_ok "${WIREPROXY_SERVICE_NAME} 已启动"
        return 0
    fi

    wireproxy_warn "新配置启动失败，正在回滚..."
    cp "$backup" "$target" || true
    rm -f "$backup"

    if wireproxy_try_restart_service; then
        wireproxy_warn "已回滚到上一份可用配置"
    else
        wireproxy_warn "回滚后服务仍未启动，请手动检查配置"
    fi

    return 1
}

wireproxy_prepare_install() {
    local account_type="$1"
    wireproxy_check_dependencies
    wireproxy_detect_arch
    wireproxy_prompt_socks_settings
    wireproxy_download_binary
    [[ "$account_type" == "free" ]] && wireproxy_ensure_wgcf || wireproxy_ensure_wireguard_tools
}

wireproxy_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5" account="$6"
    wireproxy_info "Endpoint: $endpoint"
    wireproxy_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$endpoint" "$account"
    wireproxy_write_conf
    wireproxy_restart_service
}

wireproxy_service_running() {
    systemctl is-active --quiet "$WIREPROXY_SERVICE_NAME"
}

wireproxy_show_proxy_status() {
    wireproxy_load_socks_settings
    echo -e "  SOCKS: ${CYAN}${WIREPROXY_SOCKS_BIND}${NC}"
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        echo -e "  认证: ${GREEN}${WIREPROXY_SOCKS_USER}${NC}"
    else
        echo -e "  认证: ${YELLOW}无${NC}"
    fi

    if wireproxy_service_running; then
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
}

wireproxy_show_proxy_trace() {
    local trace="" v4_trace="" ip="" ip4="" ip6="" loc="" warp="" attempt
    wireproxy_load_socks_settings

    [[ -f "$WIREPROXY_CONF" ]] || { wireproxy_warn "未找到配置文件"; return; }

    for attempt in 1 2 3 4 5; do
        trace="$(wireproxy_fetch_trace_via_proxy "socks5h" || true)"
        [[ -n "$trace" ]] && break
        sleep 1
    done

    if [[ -z "$trace" ]]; then
        for attempt in 1 2 3; do
            trace="$(wireproxy_fetch_trace_via_proxy "socks5" || true)"
            [[ -n "$trace" ]] && break
            sleep 1
        done
    fi

    if [[ -z "$trace" ]]; then
        wireproxy_warn "无法通过 SOCKS 代理获取 WARP 出口信息，可稍等几秒后再试一次"
        return
    fi

    ip="$(wireproxy_trace_value "$trace" "ip")"
    if [[ -n "$ip" ]]; then
        if wireproxy_is_ipv6_literal "$ip" && ! wireproxy_is_ipv4_literal "$ip"; then
            ip6="$ip"
        else
            ip4="$ip"
        fi
    fi

    for attempt in 1 2 3; do
        v4_trace="$(wireproxy_fetch_trace_via_proxy_v4 || true)"
        [[ -n "$v4_trace" ]] && break
        sleep 1
    done

    [[ -n "$v4_trace" ]] && ip4="$(wireproxy_trace_value "$v4_trace" "ip")"

    if [[ -z "$ip6" ]]; then
        for attempt in 1 2 3; do
            ip6="$(wireproxy_fetch_ipv6_ip_via_proxy || true)"
            [[ -n "$ip6" ]] && break
            sleep 1
        done
    fi

    [[ -z "$ip4" ]] && ip4="无"
    [[ -z "$ip6" ]] && ip6="无"
    loc="$(wireproxy_trace_value "$trace" "loc")"
    warp="$(wireproxy_trace_value "$trace" "warp")"

    echo -e "  IPv4: ${GREEN}${ip4}${NC}"
    echo -e "  IPv6: ${CYAN}${ip6}${NC}"
    [[ -n "$loc" ]] && echo -e "  Loc:  ${CYAN}${loc}${NC}"
    [[ -n "$warp" ]] && echo -e "  Warp: ${YELLOW}${warp}${NC}"
    echo ""
}

wireproxy_fetch_trace_via_proxy() {
    local scheme="$1" proxy_url
    local curl_args=()
    local trace=""

    proxy_url="${scheme}://${WIREPROXY_SOCKS_BIND}"
    curl_args=(--proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s)
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

wireproxy_fetch_trace_via_proxy_v4() {
    local proxy_url trace=""
    local curl_args=()

    proxy_url="socks5://${WIREPROXY_SOCKS_BIND}"
    curl_args=(-4 --proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s)
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

wireproxy_fetch_ipv6_ip_via_proxy() {
    local proxy_url ip=""
    local curl_args=()

    proxy_url="socks5h://${WIREPROXY_SOCKS_BIND}"
    curl_args=(--proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s https://api6.ipify.org)
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")
    fi

    ip="$(curl "${curl_args[@]}" 2>/dev/null || true)"
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    printf '%s\n' "$ip"
}

wireproxy_trace_value() {
    local trace="$1" key="$2"
    printf '%s\n' "$trace" | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

wireproxy_install_free() {
    local tmpdir priv pub addr endpoint warp_v4 warp_v6 version

    echo ""
    wireproxy_info "免费账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install free

    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"
    cd "$tmpdir" || wireproxy_err "进入临时目录失败"

    wireproxy_info "注册 WARP 免费账户 ..."
    yes | "$WIREPROXY_WGCF_PATH" register >/dev/null 2>&1 || {
        cd / || true
        rm -rf "$tmpdir"
        wireproxy_cleanup_wgcf
        wireproxy_err "WARP 注册失败"
    }

    wireproxy_info "生成 WireGuard 配置 ..."
    "$WIREPROXY_WGCF_PATH" generate >/dev/null 2>&1 || {
        cd / || true
        rm -rf "$tmpdir"
        wireproxy_cleanup_wgcf
        wireproxy_err "配置生成失败"
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
        wireproxy_cleanup_wgcf
        wireproxy_err "无法从 wgcf-profile.conf 提取 WARP 配置"
    }

    endpoint="$(wireproxy_select_endpoint_for_network "$endpoint" "" "" "")"

    cd / || true
    rm -rf "$tmpdir"
    wireproxy_cleanup_wgcf

    wireproxy_finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$endpoint" "free"

    echo ""
    wireproxy_ok "WARP SOCKS 配置完成"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_install_team() {
    local jwt_token priv pub response warp_v4 warp_v6 peer_pub endpoint ep_host ep_v4 ep_v6 ep_port org api_ports

    echo ""
    wireproxy_info "团队账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install team

    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 -> Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}Token 有效期较短，复制后请立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " jwt_token
    echo ""
    [[ -z "$jwt_token" ]] && { wireproxy_warn "已取消"; return; }

    wireproxy_info "生成 WireGuard 密钥对 ..."
    priv="$(wg genkey)"
    pub="$(printf '%s' "$priv" | wg pubkey)"

    wireproxy_info "向 Cloudflare API 注册设备 ..."
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

    [[ -n "$response" ]] || wireproxy_err "Cloudflare API 无响应，请检查网络后重试"
    printf '%s' "$response" | grep -q '"account"' || wireproxy_err "团队设备注册失败，请检查 Token 是否过期"

    warp_v4="$(printf '%s' "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v4"\s*:\s*"\K[^"]+' | head -1)"
    warp_v6="$(printf '%s' "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[^"]+' | head -1)"
    [[ -z "$warp_v4" ]] && warp_v4="$(printf '%s' "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)"
    [[ -z "$warp_v6" ]] && warp_v6="$(printf '%s' "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)"
    peer_pub="$(printf '%s' "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | tail -1)"
    org="$(printf '%s' "$response" | grep -oP '"organization"\s*:\s*"\K[^"]+' | head -1)"

    [[ -n "$warp_v4" && -n "$warp_v6" && -n "$peer_pub" ]] || wireproxy_err "无法从 API 响应中提取配置"

    ep_port=2408
    api_ports="$(printf '%s' "$response" | grep -oP '"ports"\s*:\s*\[\K[^\]]+' | head -1)"
    [[ -n "$api_ports" ]] && ep_port="$(printf '%s' "$api_ports" | cut -d',' -f1 | tr -d ' ')"

    ep_host="$(printf '%s' "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)"
    ep_v4="$(printf '%s' "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1 | sed 's/:0$//g')"
    ep_v6="$(printf '%s' "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1 | sed 's/\[//g; s/\]//g; s/:0$//g')"

    if [[ -n "$ep_host" ]]; then
        endpoint="$ep_host"
    elif [[ -n "$ep_v4" && "$ep_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        endpoint="${ep_v4}:${ep_port}"
    elif [[ -n "$ep_v6" ]]; then
        endpoint="[${ep_v6}]:${ep_port}"
    else
        wireproxy_err "API 未返回可用的 Endpoint"
    fi

    endpoint="$(wireproxy_select_endpoint_for_network "$endpoint" "$ep_v4" "$ep_v6" "$ep_port")"

    wireproxy_finish_install "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$endpoint" "team(${org:-unknown})"

    echo ""
    wireproxy_ok "团队 WARP SOCKS 配置完成"
    echo -e "  组织: ${CYAN}${org:-unknown}${NC}"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_modify_config() {
    local current_endpoint current_mtu new_ep new_bind new_mtu input escaped_value backup_file auth_label auth_color service_label service_color

    clear

    [[ -f "$WIREPROXY_CONF" && -f "$WIREPROXY_WG_WARP_CONF" ]] || { wireproxy_warn "未找到配置，请先安装"; return; }

    wireproxy_load_socks_settings
    current_endpoint="$(wireproxy_extract_ini_value "$WIREPROXY_WG_WARP_CONF" "Peer" "Endpoint")"
    current_mtu="$(wireproxy_extract_ini_value "$WIREPROXY_WG_WARP_CONF" "Interface" "MTU")"
    [[ -z "$current_mtu" ]] && current_mtu="1280"
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        auth_label="$WIREPROXY_SOCKS_USER"
        auth_color="$GREEN"
    else
        auth_label="无"
        auth_color="$YELLOW"
    fi
    if wireproxy_service_running; then
        service_label="运行中"
        service_color="$GREEN"
    else
        service_label="未运行"
        service_color="$YELLOW"
    fi

    wireproxy_menu_divider
    echo -e "  ${CYAN}WARP:${NC} ${service_color}${service_label}${NC}"
    echo -e "  ${CYAN}Endpoint:${NC} ${current_endpoint}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}  ${CYAN}SOCKS:${NC} ${WIREPROXY_SOCKS_BIND}"
    echo -e "  ${CYAN}认证:${NC} ${auth_color}${auth_label}${NC}"
    wireproxy_menu_divider
    echo -e "  ${GREEN}1)${NC} 改 Endpoint      ${CYAN}2)${NC} 改 MTU"
    echo -e "  ${YELLOW}3)${NC} 改 SOCKS 监听   ${GREEN}4)${NC} 改 SOCKS 认证"
    echo -e "  ${CYAN}5)${NC} 编辑 WARP 配置 ${RED}0)${NC} 返回上级"
    echo
    read -rp "  请选择 [0-5]: " input

    case "$input" in
        1)
            echo -e "\n  当前 Endpoint: ${current_endpoint}\n"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                wireproxy_is_valid_host_port "$new_ep" || { wireproxy_warn "Endpoint 格式无效"; return; }
                backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")"
                escaped_value="$(wireproxy_escape_sed_replacement "$new_ep")"
                sed -i "s|^Endpoint = .*|Endpoint = ${escaped_value}|" "$WIREPROXY_WG_WARP_CONF"
                wireproxy_ok "Endpoint 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            fi
            ;;
        2)
            echo -e "\n  当前 MTU: ${current_mtu}\n"
            read -rp "新 MTU [1280-1500]: " new_mtu
            if [[ "$new_mtu" =~ ^[0-9]+$ ]] && (( new_mtu >= 1280 && new_mtu <= 1500 )); then
                backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")"
                sed -i "s|^MTU = .*|MTU = ${new_mtu}|" "$WIREPROXY_WG_WARP_CONF"
                wireproxy_ok "MTU 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            else
                wireproxy_warn "无效的 MTU 值"
            fi
            ;;
        3)
            echo -e "\n  当前 SOCKS 监听: ${WIREPROXY_SOCKS_BIND}\n"
            read -rp "新 SOCKS 监听地址: " new_bind
            if [[ -n "$new_bind" ]]; then
                wireproxy_is_valid_host_port "$new_bind" || { wireproxy_warn "监听地址格式无效"; return; }
                backup_file="$(wireproxy_make_backup "$WIREPROXY_CONF")"
                escaped_value="$(wireproxy_escape_sed_replacement "$new_bind")"
                sed -i "s|^BindAddress = .*|BindAddress = ${escaped_value}|" "$WIREPROXY_CONF"
                wireproxy_ok "SOCKS 监听地址已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            fi
            ;;
        4)
            echo -e "\n  当前认证: ${auth_label}\n"
            backup_file="$(wireproxy_make_backup "$WIREPROXY_CONF")"
            wireproxy_prompt_socks_settings
            wireproxy_write_conf
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            ;;
        5)
            backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")"
            ${EDITOR:-nano} "$WIREPROXY_WG_WARP_CONF"
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            ;;
        0) return 1 ;;
        *) wireproxy_warn "无效选择" ;;
    esac
}

wireproxy_show_ip() {
    clear
    wireproxy_load_socks_settings
    wireproxy_menu_divider
    echo -e "  ${CYAN}WARP 出口${NC}"
    echo -e "  ${CYAN}SOCKS:${NC} ${WIREPROXY_SOCKS_BIND}"
    wireproxy_menu_divider
    wireproxy_show_proxy_trace
}

wireproxy_uninstall() {
    clear
    wireproxy_menu_divider
    echo -e "  ${RED}删除 WARP SOCKS 服务${NC}"
    if wireproxy_service_running; then
        echo -e "  ${CYAN}WARP:${NC} ${GREEN}运行中${NC}"
    else
        echo -e "  ${CYAN}WARP:${NC} ${YELLOW}未运行${NC}"
    fi
    wireproxy_menu_divider
    echo -e "  ${RED}将停止服务并删除配置与程序文件${NC}"
    echo
    read -rp "  确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if wireproxy_service_running; then
        systemctl stop "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || wireproxy_err "服务停止失败，请先处理后再删除"
        wireproxy_service_running && wireproxy_err "服务仍在运行，请先处理后再删除"
        wireproxy_ok "服务已停止"
    fi

    systemctl disable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$WIREPROXY_SERVICE_FILE"
    rm -f "$WIREPROXY_BIN"
    rm -rf "$WIREPROXY_CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true

    wireproxy_ok "WARP SOCKS 服务已删除"
}

wireproxy_show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP SOCKS 管理 v3.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    wireproxy_show_proxy_status
    wireproxy_menu_divider
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 修改配置   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 退出脚本"
}

wireproxy_pause() {
    read -rp "回车继续..." _
}

wireproxy_menu_divider() {
    echo "  ══════════════════════════"
}

wireproxy_menu() {
    local choice

    wireproxy_check_root
    while true; do
        wireproxy_show_menu
        wireproxy_menu_divider
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) wireproxy_install_free; wireproxy_pause ;;
            2) wireproxy_install_team; wireproxy_pause ;;
            3) wireproxy_modify_config && wireproxy_pause ;;
            4) wireproxy_uninstall && wireproxy_pause ;;
            5) wireproxy_show_ip; wireproxy_pause ;;
            0) return 0 ;;
            *) wireproxy_warn "无效选项"; wireproxy_pause ;;
        esac
    done
}

wireproxy_menu
