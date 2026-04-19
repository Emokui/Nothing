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
WIREPROXY_BASE_URL="https://cdn-wireproxy.pages.dev/windtf/wireproxy"

WGCF_PATH="/usr/local/bin/wgcf"
WGCF_TMP=""
WIREPROXY_ARCH=""
WGCF_ARCH=""
NET_MODE=""

DEFAULT_SOCKS_BIND="127.0.0.1:40000"
SOCKS_BIND="$DEFAULT_SOCKS_BIND"
SOCKS_USER=""
SOCKS_PASS=""

check_root() { [[ $EUID -ne 0 ]] && err "请使用 root 用户运行此脚本"; }

require_apt() {
    command -v apt-get >/dev/null 2>&1 || err "仅支持 Debian/Ubuntu（未找到 apt-get）"
}

check_dependencies() {
    local cmd
    require_apt
    for cmd in curl tar systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || err "缺少依赖: $cmd"
    done
}

ensure_wireguard_tools() {
    command -v wg >/dev/null 2>&1 || err "缺少依赖: wg（请先安装 wireguard-tools）"
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

detect_network() {
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
        NET_MODE="dual"
    elif $has_v6; then
        NET_MODE="v6_only"
    elif $has_v4; then
        NET_MODE="v4_only"
    else
        NET_MODE="none"
    fi
}

latest_release_tag() {
    local repo="$1"
    curl --connect-timeout 5 --max-time 20 -fsSI "https://github.com/${repo}/releases/latest" \
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
    info "获取 wireproxy 最新版本 ..."
    version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${WIREPROXY_BASE_URL}/releases/latest" \
        | grep -oE '/releases/tag/v[0-9.]+' \
        | sed 's#.*/##' \
        | head -n1)"
    [[ -n "$version" ]] || err "无法获取 wireproxy 最新版本"

    asset="wireproxy_linux_${WIREPROXY_ARCH}.tar.gz"
    url="${WIREPROXY_BASE_URL}/releases/download/${version}/${asset}"
    tmpdir="$(mktemp -d)" || err "创建临时目录失败"

    info "下载 wireproxy ${version} ..."
    if ! curl --connect-timeout 5 --max-time 120 -fL "$url" -o "${tmpdir}/wireproxy.tar.gz"; then
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
    local version url tmpdir wgcf_base_url

    if [[ -x "$WGCF_PATH" ]]; then
        return 0
    fi

    detect_arch
    detect_network
    wgcf_base_url="https://github.com/${WGCF_REPO}"
    info "获取 wgcf 最新版本 ..."
    if [[ "$NET_MODE" == "v6_only" ]]; then
        wgcf_base_url="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
        info "检测到纯 IPv6，wgcf 下载改用镜像: $wgcf_base_url"
        version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${wgcf_base_url}/releases/latest" \
            | grep -oE '/releases/tag/v[0-9.]+' \
            | sed 's#.*/##' \
            | head -n1)"
    else
        version="$(latest_release_tag "$WGCF_REPO")"
    fi
    [[ -n "$version" ]] || err "无法获取 wgcf 最新版本"

    url="${wgcf_base_url}/releases/download/${version}/wgcf_${version#v}_linux_${WGCF_ARCH}"
    tmpdir="$(mktemp -d)" || err "创建临时目录失败"
    WGCF_TMP="${tmpdir}/wgcf"

    info "下载 wgcf ${version} ..."
    if ! curl --connect-timeout 5 --max-time 120 -fL "$url" -o "$WGCF_TMP"; then
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

endpoint_host() {
    local value="$1"
    if [[ "$value" =~ ^\[([0-9a-fA-F:]+)\]:[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]+):[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$value"
    fi
}

endpoint_port() {
    local value="$1"
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[^:]+:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

is_ipv4_literal() {
    local host="$1"
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6_literal() {
    local host="$1"
    [[ "$host" == *:* ]]
}

resolve_host_by_family() {
    local host="$1" family="$2"
    command -v getent >/dev/null 2>&1 || err "缺少 getent，无法解析 Endpoint"
    case "$family" in
        4) getent ahostsv4 "$host" | awk 'NR==1 { print $1; exit }' ;;
        6) getent ahostsv6 "$host" | awk 'NR==1 { print $1; exit }' ;;
        *) return 1 ;;
    esac
}

select_endpoint_for_network() {
    local current="$1" preferred_v4="$2" preferred_v6="$3" preferred_port="$4"
    local host port resolved

    [[ -n "$NET_MODE" ]] || detect_network
    port="${preferred_port:-$(endpoint_port "$current")}"
    [[ -z "$port" ]] && port="2408"

    case "$NET_MODE" in
        v6_only)
            if [[ -n "$preferred_v6" ]]; then
                printf '[%s]:%s\n' "$preferred_v6" "$port"
                return 0
            fi
            host="$(endpoint_host "$current")"
            [[ -n "$host" ]] || err "无法确定 IPv6 Endpoint"
            if is_ipv6_literal "$host" && ! is_ipv4_literal "$host"; then
                printf '[%s]:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(resolve_host_by_family "$host" 6)"
            [[ -n "$resolved" ]] || err "无法解析 IPv6 Endpoint: $host"
            printf '[%s]:%s\n' "$resolved" "$port"
            ;;
        dual|v4_only)
            if [[ -n "$preferred_v4" ]]; then
                printf '%s:%s\n' "$preferred_v4" "$port"
                return 0
            fi
            host="$(endpoint_host "$current")"
            [[ -n "$host" ]] || err "无法确定 IPv4 Endpoint"
            if is_ipv4_literal "$host"; then
                printf '%s:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(resolve_host_by_family "$host" 4)"
            [[ -n "$resolved" ]] || err "无法解析 IPv4 Endpoint: $host"
            printf '%s:%s\n' "$resolved" "$port"
            ;;
        none)
            err "当前服务器无可用网络，无法确定 Endpoint"
            ;;
        *)
            err "未知网络模式: $NET_MODE"
            ;;
    esac
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

prepare_install() {
    local account_type="$1"
    check_dependencies
    detect_arch
    prompt_socks_settings
    download_wireproxy
    [[ "$account_type" == "free" ]] && ensure_wgcf || ensure_wireguard_tools
}

finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5" account="$6"
    info "Endpoint: $endpoint"
    write_wg_conf "$priv" "$v4" "$v6" "$pub" "$endpoint" "$account"
    write_wireproxy_conf
    restart_service
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
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
}

show_proxy_trace() {
    local trace="" v4_trace="" ip="" ip4="" ip6="" loc="" warp="" attempt
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

    ip="$(trace_value "$trace" "ip")"
    if [[ -n "$ip" ]]; then
        if is_ipv6_literal "$ip" && ! is_ipv4_literal "$ip"; then
            ip6="$ip"
        else
            ip4="$ip"
        fi
    fi

    for attempt in 1 2 3; do
        v4_trace="$(fetch_trace_via_proxy_v4 || true)"
        [[ -n "$v4_trace" ]] && break
        sleep 1
    done

    [[ -n "$v4_trace" ]] && ip4="$(trace_value "$v4_trace" "ip")"

    if [[ -z "$ip6" ]]; then
        for attempt in 1 2 3; do
            ip6="$(fetch_ipv6_ip_via_proxy || true)"
            [[ -n "$ip6" ]] && break
            sleep 1
        done
    fi

    [[ -z "$ip4" ]] && ip4="无"
    [[ -z "$ip6" ]] && ip6="无"
    loc="$(trace_value "$trace" "loc")"
    warp="$(trace_value "$trace" "warp")"

    echo -e "  IPv4: ${GREEN}${ip4}${NC}"
    echo -e "  IPv6: ${CYAN}${ip6}${NC}"
    [[ -n "$loc" ]] && echo -e "  Loc:  ${CYAN}${loc}${NC}"
    [[ -n "$warp" ]] && echo -e "  Warp: ${YELLOW}${warp}${NC}"
    echo ""
}

fetch_trace_via_proxy() {
    local scheme="$1" proxy_url
    local curl_args=()
    local trace=""

    proxy_url="${scheme}://${SOCKS_BIND}"
    curl_args=(--proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s)
    if [[ -n "$SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

fetch_trace_via_proxy_v4() {
    local proxy_url trace=""
    local curl_args=()

    proxy_url="socks5://${SOCKS_BIND}"
    curl_args=(-4 --proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s)
    if [[ -n "$SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

fetch_ipv6_ip_via_proxy() {
    local proxy_url ip=""
    local curl_args=()

    proxy_url="socks5h://${SOCKS_BIND}"
    curl_args=(--proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s https://api6.ipify.org)
    if [[ -n "$SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS}")
    fi

    ip="$(curl "${curl_args[@]}" 2>/dev/null || true)"
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    printf '%s\n' "$ip"
}

trace_value() {
    local trace="$1" key="$2"
    printf '%s\n' "$trace" | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

install_free() {
    local tmpdir priv pub addr endpoint warp_v4 warp_v6 version

    echo ""
    info "免费账户 SOCKS 安装"
    echo ""

    prepare_install free

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

    endpoint="$(select_endpoint_for_network "$endpoint" "" "" "")"

    cd / || true
    rm -rf "$tmpdir"
    cleanup_wgcf

    finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$endpoint" "free"

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

    prepare_install team

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

    if [[ -n "$ep_host" ]]; then
        endpoint="$ep_host"
    elif [[ -n "$ep_v4" && "$ep_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        endpoint="${ep_v4}:${ep_port}"
    elif [[ -n "$ep_v6" ]]; then
        endpoint="[${ep_v6}]:${ep_port}"
    else
        err "API 未返回可用的 Endpoint"
    fi

    endpoint="$(select_endpoint_for_network "$endpoint" "$ep_v4" "$ep_v6" "$ep_port")"

    finish_install "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$endpoint" "team(${org:-unknown})"

    echo ""
    ok "团队 WARP SOCKS 配置完成"
    echo -e "  组织: ${CYAN}${org:-unknown}${NC}"
    echo -e "  SOCKS: ${GREEN}${SOCKS_BIND}${NC}"
    show_proxy_trace
}

modify_config() {
    local current_endpoint current_mtu new_ep new_bind new_mtu input escaped_value backup_file auth_label auth_color service_label service_color

    clear

    [[ -f "$WIREPROXY_CONF" && -f "$WG_WARP_CONF" ]] || { warn "未找到配置，请先安装"; return; }

    load_socks_settings
    current_endpoint="$(extract_ini_value "$WG_WARP_CONF" "Peer" "Endpoint")"
    current_mtu="$(extract_ini_value "$WG_WARP_CONF" "Interface" "MTU")"
    [[ -z "$current_mtu" ]] && current_mtu="1280"
    if [[ -n "$SOCKS_USER" ]]; then
        auth_label="$SOCKS_USER"
        auth_color="$GREEN"
    else
        auth_label="无"
        auth_color="$YELLOW"
    fi
    if service_running; then
        service_label="运行中"
        service_color="$GREEN"
    else
        service_label="未运行"
        service_color="$YELLOW"
    fi

    menu_divider
    echo -e "  ${CYAN}WARP:${NC} ${service_color}${service_label}${NC}"
    echo -e "  ${CYAN}Endpoint:${NC} ${current_endpoint}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}  ${CYAN}SOCKS:${NC} ${SOCKS_BIND}"
    echo -e "  ${CYAN}认证:${NC} ${auth_color}${auth_label}${NC}"
    menu_divider
    echo -e "  ${GREEN}1)${NC} 改 Endpoint  ${CYAN}2)${NC} 改 MTU"
    echo -e "  ${YELLOW}3)${NC} 改 SOCKS 监听 ${GREEN}4)${NC} 改 SOCKS 认证"
    echo -e "  ${CYAN}5)${NC} 编辑 WARP 配置 ${YELLOW}6)${NC} 编辑代理配置"
    echo -e "  ${RED}0)${NC} 返回上级"
    echo
    read -rp "  请选择 [0-6]: " input

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
            echo -e "\n  当前 SOCKS 监听: ${SOCKS_BIND}\n"
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
            echo -e "\n  当前认证: ${auth_label}\n"
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
        0) return 1 ;;
        *) warn "无效选择" ;;
    esac
}

show_ip() {
    clear
    load_socks_settings
    menu_divider
    echo -e "  ${CYAN}WARP 出口${NC}"
    echo -e "  ${CYAN}SOCKS:${NC} ${SOCKS_BIND}"
    menu_divider
    show_proxy_trace
}

uninstall_warp() {
    clear
    menu_divider
    echo -e "  ${RED}删除 WARP SOCKS 服务${NC}"
    if service_running; then
        echo -e "  ${CYAN}WARP:${NC} ${GREEN}运行中${NC}"
    else
        echo -e "  ${CYAN}WARP:${NC} ${YELLOW}未运行${NC}"
    fi
    menu_divider
    echo -e "  ${RED}将停止服务并删除配置与程序文件${NC}"
    echo
    read -rp "  确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if service_running; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || err "服务停止失败，请先处理后再删除"
        service_running && err "服务仍在运行，请先处理后再删除"
        ok "服务已停止"
    fi

    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -f "$WIREPROXY_BIN"
    rm -rf "$WIREPROXY_CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true

    ok "WARP SOCKS 服务已删除"
}

show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP SOCKS 管理 v3.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    show_proxy_status
    menu_divider
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 修改配置   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 退出脚本"
}

pause() {
    read -rp "回车继续..." _
}

menu_divider() {
    echo "  ══════════════════════════"
}

main() {
    check_root
    while true; do
        show_menu
        menu_divider
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) install_free; pause ;;
            2) install_team; pause ;;
            3) modify_config && pause ;;
            4) uninstall_warp && pause ;;
            5) show_ip; pause ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效选项"; pause ;;
        esac
    done
}

main "$@"
