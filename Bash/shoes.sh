#!/bin/bash

set -u
set -o pipefail

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

EXEC_PATH="/usr/local/bin/shoes"
CONFIG_DIR="/etc/shoes"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
STATE_PATH="${CONFIG_DIR}/deploy.env"
SERVICE_NAME="shoes"
SERVICE_FILE="/etc/systemd/system/shoes.service"
LATEST_API_URL="https://api.github.com/repos/cfal/shoes/releases/latest"

if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本${PLAIN}"
    exit 1
fi

pause_and_return() {
    read -rp "$(echo -e "${BLUE}按回车返回...${PLAIN}")"
    clear
}

pause_here() {
    read -rp "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
}

random_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

random_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        echo "00000000-0000-4000-8000-000000000000"
    fi
}

yaml_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

print_info() {
    echo -e "${BLUE}$*${PLAIN}"
}

print_ok() {
    echo -e "${GREEN}$*${PLAIN}"
}

print_warn() {
    echo -e "${YELLOW}$*${PLAIN}"
}

print_err() {
    echo -e "${RED}$*${PLAIN}"
}

require_commands() {
    local missing=()
    local cmd
    for cmd in curl tar systemctl ldd; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        print_err "缺少命令: ${missing[*]}"
        exit 1
    fi
}

load_defaults() {
    ENABLE_SS="n"
    SS_ADDRESS="[::]:8388"
    SS_CIPHER="aes-256-gcm"
    SS_PASSWORD=""
    SS_UDP_ENABLED="true"

    ENABLE_TROJAN="n"
    TROJAN_ADDRESS="[::]:4443"
    TROJAN_SNI=""
    TROJAN_WS_PATH="/"
    TROJAN_PASSWORD=""
    TROJAN_CERT=""
    TROJAN_KEY=""

    ENABLE_HY2="n"
    HY2_ADDRESS="[::]:8443"
    HY2_PASSWORD=""
    HY2_CERT=""
    HY2_KEY=""
    HY2_UDP_ENABLED="true"

    ENABLE_TUIC="n"
    TUIC_ADDRESS="[::]:9443"
    TUIC_UUID=""
    TUIC_PASSWORD=""
    TUIC_CERT=""
    TUIC_KEY=""
    TUIC_ZERO_RTT="false"

    ENABLE_ANYTLS="n"
    ANYTLS_ADDRESS="[::]:443"
    ANYTLS_SNI=""
    ANYTLS_USERNAME="user1"
    ANYTLS_PASSWORD=""
    ANYTLS_CERT=""
    ANYTLS_KEY=""
    ANYTLS_UDP_ENABLED="true"
}

load_state() {
    load_defaults
    if [[ -f "$STATE_PATH" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_PATH"
    fi

    if [[ -z "$TROJAN_SNI" && -n "$TROJAN_CERT" ]]; then
        TROJAN_SNI="$(derive_name_from_cert_path "$TROJAN_CERT")"
    fi

    if [[ -z "$ANYTLS_SNI" && -n "$ANYTLS_CERT" ]]; then
        ANYTLS_SNI="$(derive_name_from_cert_path "$ANYTLS_CERT")"
    fi
}

save_kv() {
    local name="$1"
    local value="$2"
    printf '%s=%q\n' "$name" "$value" >> "$STATE_PATH"
}

save_state() {
    mkdir -p "$CONFIG_DIR"
    : > "$STATE_PATH"

    save_kv "ENABLE_SS" "$ENABLE_SS"
    save_kv "SS_ADDRESS" "$SS_ADDRESS"
    save_kv "SS_CIPHER" "$SS_CIPHER"
    save_kv "SS_PASSWORD" "$SS_PASSWORD"
    save_kv "SS_UDP_ENABLED" "$SS_UDP_ENABLED"

    save_kv "ENABLE_TROJAN" "$ENABLE_TROJAN"
    save_kv "TROJAN_ADDRESS" "$TROJAN_ADDRESS"
    save_kv "TROJAN_SNI" "$TROJAN_SNI"
    save_kv "TROJAN_WS_PATH" "$TROJAN_WS_PATH"
    save_kv "TROJAN_PASSWORD" "$TROJAN_PASSWORD"
    save_kv "TROJAN_CERT" "$TROJAN_CERT"
    save_kv "TROJAN_KEY" "$TROJAN_KEY"

    save_kv "ENABLE_HY2" "$ENABLE_HY2"
    save_kv "HY2_ADDRESS" "$HY2_ADDRESS"
    save_kv "HY2_PASSWORD" "$HY2_PASSWORD"
    save_kv "HY2_CERT" "$HY2_CERT"
    save_kv "HY2_KEY" "$HY2_KEY"
    save_kv "HY2_UDP_ENABLED" "$HY2_UDP_ENABLED"

    save_kv "ENABLE_TUIC" "$ENABLE_TUIC"
    save_kv "TUIC_ADDRESS" "$TUIC_ADDRESS"
    save_kv "TUIC_UUID" "$TUIC_UUID"
    save_kv "TUIC_PASSWORD" "$TUIC_PASSWORD"
    save_kv "TUIC_CERT" "$TUIC_CERT"
    save_kv "TUIC_KEY" "$TUIC_KEY"
    save_kv "TUIC_ZERO_RTT" "$TUIC_ZERO_RTT"

    save_kv "ENABLE_ANYTLS" "$ENABLE_ANYTLS"
    save_kv "ANYTLS_ADDRESS" "$ANYTLS_ADDRESS"
    save_kv "ANYTLS_SNI" "$ANYTLS_SNI"
    save_kv "ANYTLS_USERNAME" "$ANYTLS_USERNAME"
    save_kv "ANYTLS_PASSWORD" "$ANYTLS_PASSWORD"
    save_kv "ANYTLS_CERT" "$ANYTLS_CERT"
    save_kv "ANYTLS_KEY" "$ANYTLS_KEY"
    save_kv "ANYTLS_UDP_ENABLED" "$ANYTLS_UDP_ENABLED"
}

read_value() {
    local __var="$1"
    local prompt="$2"
    local default_value="$3"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    input="${input:-$default_value}"
    printf -v "$__var" '%s' "$input"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_bind_address() {
    local raw
    raw="$(trim_whitespace "$1")"

    if [[ -z "$raw" ]]; then
        printf '%s' "$raw"
        return 0
    fi

    if [[ "$raw" == *:* ]]; then
        printf '%s' "$raw"
        return 0
    fi

    if [[ "$raw" =~ ^[0-9,-]+$ ]]; then
        printf '[::]:%s' "$raw"
        return 0
    fi

    printf '%s' "$raw"
}

read_address_value() {
    local __var="$1"
    local prompt="$2"
    local default_value="$3"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    input="${input:-$default_value}"
    input="$(normalize_bind_address "$input")"
    printf -v "$__var" '%s' "$input"
}

ask_yes_no() {
    local prompt="$1"
    local default_choice="$2"
    local suffix=""
    local answer=""

    if [[ "$default_choice" == "y" || "$default_choice" == "Y" ]]; then
        suffix="[Y/n]"
        default_choice="y"
    else
        suffix="[y/N]"
        default_choice="n"
    fi

    while true; do
        read -r -p "$(echo -e "${BLUE}${prompt} ${suffix}: ${PLAIN}")" answer
        answer="${answer:-$default_choice}"
        case "$answer" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) print_warn "请输入 y 或 n" ;;
        esac
    done
}

bool_to_yn() {
    if [[ "$1" == "true" ]]; then
        echo "y"
    else
        echo "n"
    fi
}

select_cert() {
    local current_cert="${1:-}"
    local current_key="${2:-}"
    local cert_files=()
    local opt=""
    local index=1

    while true; do
        echo -e "${BLUE}证书配置${PLAIN}"
        if [[ -n "$current_cert" && -n "$current_key" && -f "$current_cert" && -f "$current_key" ]]; then
            echo -e "${GREEN}回车.${PLAIN}保留当前证书: ${current_cert}"
        fi

        cert_files=()
        if compgen -G "/etc/cert/*.crt" > /dev/null 2>&1; then
            mapfile -t cert_files < <(ls /etc/cert/*.crt 2>/dev/null | sort)
        fi

        index=1
        while (( index <= ${#cert_files[@]} )); do
            echo -e "${GREEN}${index}.${PLAIN}$(basename "${cert_files[$((index-1))]}")"
            ((index++))
        done
        echo -e "${GREEN}0.${PLAIN}自定义路径"

        read -r -p "$(echo -e "${BLUE}输入选项: ${PLAIN}")" opt

        if [[ -z "$opt" && -n "$current_cert" && -n "$current_key" && -f "$current_cert" && -f "$current_key" ]]; then
            cert_path="$current_cert"
            key_path="$current_key"
            return 0
        fi

        if [[ "$opt" == "0" ]]; then
            read -r -p "$(echo -e "${BLUE}证书路径: ${PLAIN}")" cert_path
            read -r -p "$(echo -e "${BLUE}私钥路径: ${PLAIN}")" key_path
            if [[ -f "$cert_path" && -f "$key_path" ]]; then
                return 0
            fi
            print_err "路径无效"
            sleep 1
            continue
        fi

        if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#cert_files[@]} )); then
            cert_path="${cert_files[$((opt-1))]}"
            key_path="${cert_path%.crt}.key"
            if [[ -f "$key_path" ]]; then
                return 0
            fi
            print_err "未找到对应私钥: $key_path"
            sleep 1
            continue
        fi

        print_warn "无效选项"
        sleep 1
    done
}

derive_name_from_cert_path() {
    local cert_file base_name
    cert_file="$1"
    base_name="$(basename "$cert_file")"
    base_name="${base_name%.crt}"
    base_name="${base_name%.pem}"
    printf '%s' "$base_name"
}

configure_shadowsocks() {
    clear
    echo -e "${BLUE}===== Shadowsocks 配置 =====${PLAIN}"
    read_address_value "SS_ADDRESS" "监听地址(默认:${SS_ADDRESS}): " "$SS_ADDRESS"
    read_value "SS_CIPHER" "加密方式(默认:${SS_CIPHER}): " "$SS_CIPHER"
    read_value "SS_PASSWORD" "密码(回车随机): " "$SS_PASSWORD"
    if [[ -z "$SS_PASSWORD" ]]; then
        SS_PASSWORD="$(random_pass)"
        print_ok "密码: ${SS_PASSWORD}"
    fi
    SS_UDP_ENABLED="true"
    print_ok "UDP: 已默认开启"
}

configure_trojan() {
    clear
    echo -e "${BLUE}===== Trojan over WebSocket 配置 =====${PLAIN}"
    read_address_value "TROJAN_ADDRESS" "监听地址(默认:${TROJAN_ADDRESS}): " "$TROJAN_ADDRESS"
    read_value "TROJAN_WS_PATH" "WebSocket 路径(默认:${TROJAN_WS_PATH}): " "$TROJAN_WS_PATH"
    read_value "TROJAN_PASSWORD" "密码(回车随机): " "$TROJAN_PASSWORD"
    if [[ -z "$TROJAN_PASSWORD" ]]; then
        TROJAN_PASSWORD="$(random_pass)"
        print_ok "密码: ${TROJAN_PASSWORD}"
    fi
    select_cert "$TROJAN_CERT" "$TROJAN_KEY"
    TROJAN_CERT="$cert_path"
    TROJAN_KEY="$key_path"
    TROJAN_SNI="$(derive_name_from_cert_path "$TROJAN_CERT")"
    print_ok "域名/SNI: ${TROJAN_SNI}"
}

configure_hysteria2() {
    clear
    echo -e "${BLUE}===== Hysteria2 配置 =====${PLAIN}"
    read_address_value "HY2_ADDRESS" "监听地址(默认:${HY2_ADDRESS}): " "$HY2_ADDRESS"
    read_value "HY2_PASSWORD" "密码(回车随机): " "$HY2_PASSWORD"
    if [[ -z "$HY2_PASSWORD" ]]; then
        HY2_PASSWORD="$(random_pass)"
        print_ok "密码: ${HY2_PASSWORD}"
    fi
    HY2_UDP_ENABLED="true"
    print_ok "UDP: 已默认开启"
    select_cert "$HY2_CERT" "$HY2_KEY"
    HY2_CERT="$cert_path"
    HY2_KEY="$key_path"
}

configure_tuic() {
    clear
    echo -e "${BLUE}===== TUIC v5 配置 =====${PLAIN}"
    read_address_value "TUIC_ADDRESS" "监听地址(默认:${TUIC_ADDRESS}): " "$TUIC_ADDRESS"
    read_value "TUIC_UUID" "UUID(回车随机): " "$TUIC_UUID"
    if [[ -z "$TUIC_UUID" ]]; then
        TUIC_UUID="$(random_uuid)"
        print_ok "UUID: ${TUIC_UUID}"
    fi
    read_value "TUIC_PASSWORD" "密码(回车随机): " "$TUIC_PASSWORD"
    if [[ -z "$TUIC_PASSWORD" ]]; then
        TUIC_PASSWORD="$(random_pass)"
        print_ok "密码: ${TUIC_PASSWORD}"
    fi
    if ask_yes_no "启用 0-RTT" "$(bool_to_yn "$TUIC_ZERO_RTT")"; then
        TUIC_ZERO_RTT="true"
    else
        TUIC_ZERO_RTT="false"
    fi
    select_cert "$TUIC_CERT" "$TUIC_KEY"
    TUIC_CERT="$cert_path"
    TUIC_KEY="$key_path"
}

configure_anytls() {
    clear
    echo -e "${BLUE}===== AnyTLS 配置 =====${PLAIN}"
    read_address_value "ANYTLS_ADDRESS" "监听地址(默认:${ANYTLS_ADDRESS}): " "$ANYTLS_ADDRESS"
    read_value "ANYTLS_PASSWORD" "密码(回车随机): " "$ANYTLS_PASSWORD"
    if [[ -z "$ANYTLS_PASSWORD" ]]; then
        ANYTLS_PASSWORD="$(random_pass)"
        print_ok "密码: ${ANYTLS_PASSWORD}"
    fi
    ANYTLS_USERNAME="${ANYTLS_USERNAME:-user1}"
    ANYTLS_UDP_ENABLED="true"
    select_cert "$ANYTLS_CERT" "$ANYTLS_KEY"
    ANYTLS_CERT="$cert_path"
    ANYTLS_KEY="$key_path"
    ANYTLS_SNI="$(derive_name_from_cert_path "$ANYTLS_CERT")"
    print_ok "域名/SNI: ${ANYTLS_SNI}"
    print_ok "用户名: ${ANYTLS_USERNAME}"
    print_ok "UDP: 已默认开启"
}

protocol_count() {
    local count=0
    [[ "$ENABLE_SS" == "y" ]] && ((count++))
    [[ "$ENABLE_TROJAN" == "y" ]] && ((count++))
    [[ "$ENABLE_HY2" == "y" ]] && ((count++))
    [[ "$ENABLE_TUIC" == "y" ]] && ((count++))
    [[ "$ENABLE_ANYTLS" == "y" ]] && ((count++))
    echo "$count"
}

run_configuration_wizard() {
    while true; do
        clear
        echo -e "${BLUE}选择要启用的协议${PLAIN}"

        if ask_yes_no "启用 Shadowsocks" "$ENABLE_SS"; then
            ENABLE_SS="y"
            configure_shadowsocks
        else
            ENABLE_SS="n"
        fi

        if ask_yes_no "启用 Trojan over WebSocket" "$ENABLE_TROJAN"; then
            ENABLE_TROJAN="y"
            configure_trojan
        else
            ENABLE_TROJAN="n"
        fi

        if ask_yes_no "启用 Hysteria2" "$ENABLE_HY2"; then
            ENABLE_HY2="y"
            configure_hysteria2
        else
            ENABLE_HY2="n"
        fi

        if ask_yes_no "启用 TUIC v5" "$ENABLE_TUIC"; then
            ENABLE_TUIC="y"
            configure_tuic
        else
            ENABLE_TUIC="n"
        fi

        if ask_yes_no "启用 AnyTLS" "$ENABLE_ANYTLS"; then
            ENABLE_ANYTLS="y"
            configure_anytls
        else
            ENABLE_ANYTLS="n"
        fi

        if [[ "$(protocol_count)" -gt 0 ]]; then
            break
        fi

        print_err "至少需要启用一个协议"
        sleep 1
    done
}

append_shadowsocks() {
    local out="$1"
    cat >> "$out" <<EOF
- address: $(yaml_quote "$SS_ADDRESS")
  protocol:
    type: shadowsocks
    cipher: $(yaml_quote "$SS_CIPHER")
    password: $(yaml_quote "$SS_PASSWORD")
    udp_enabled: ${SS_UDP_ENABLED}

EOF
}

append_trojan() {
    local out="$1"
    cat >> "$out" <<EOF
- address: $(yaml_quote "$TROJAN_ADDRESS")
  protocol:
    type: tls
    tls_targets:
      $(yaml_quote "$TROJAN_SNI"):
        cert: $(yaml_quote "$TROJAN_CERT")
        key: $(yaml_quote "$TROJAN_KEY")
        protocol:
          type: websocket
          targets:
            - matching_path: $(yaml_quote "$TROJAN_WS_PATH")
              protocol:
                type: trojan
                password: $(yaml_quote "$TROJAN_PASSWORD")

EOF
}

append_hysteria2() {
    local out="$1"
    cat >> "$out" <<EOF
- address: $(yaml_quote "$HY2_ADDRESS")
  transport: quic
  quic_settings:
    cert: $(yaml_quote "$HY2_CERT")
    key: $(yaml_quote "$HY2_KEY")
    alpn_protocols:
      - "h3"
  protocol:
    type: hysteria2
    password: $(yaml_quote "$HY2_PASSWORD")
    udp_enabled: ${HY2_UDP_ENABLED}

EOF
}

append_tuic() {
    local out="$1"
    cat >> "$out" <<EOF
- address: $(yaml_quote "$TUIC_ADDRESS")
  transport: quic
  quic_settings:
    cert: $(yaml_quote "$TUIC_CERT")
    key: $(yaml_quote "$TUIC_KEY")
    alpn_protocols:
      - "h3"
  protocol:
    type: tuic
    uuid: $(yaml_quote "$TUIC_UUID")
    password: $(yaml_quote "$TUIC_PASSWORD")
    zero_rtt_handshake: ${TUIC_ZERO_RTT}

EOF
}

append_anytls() {
    local out="$1"
    cat >> "$out" <<EOF
- address: $(yaml_quote "$ANYTLS_ADDRESS")
  protocol:
    type: tls
    tls_targets:
      $(yaml_quote "$ANYTLS_SNI"):
        cert: $(yaml_quote "$ANYTLS_CERT")
        key: $(yaml_quote "$ANYTLS_KEY")
        protocol:
          type: anytls
          users:
            - name: $(yaml_quote "$ANYTLS_USERNAME")
              password: $(yaml_quote "$ANYTLS_PASSWORD")
          udp_enabled: ${ANYTLS_UDP_ENABLED}
          padding_scheme:
            - "stop=8"
            - "0=30-30"
            - "1=100-400"
            - "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000"
            - "3=9-9,500-1000"
            - "4=500-1000"
            - "5=500-1000"
            - "6=500-1000"
            - "7=500-1000"

EOF
}

generate_config_file() {
    local out="$1"
    : > "$out"

    cat >> "$out" <<EOF
# Generated by shoes.sh
# $(date '+%Y-%m-%d %H:%M:%S %Z')

EOF

    if [[ "$ENABLE_SS" == "y" ]]; then
        append_shadowsocks "$out"
    fi

    if [[ "$ENABLE_TROJAN" == "y" ]]; then
        append_trojan "$out"
    fi

    if [[ "$ENABLE_HY2" == "y" ]]; then
        append_hysteria2 "$out"
    fi

    if [[ "$ENABLE_TUIC" == "y" ]]; then
        append_tuic "$out"
    fi

    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        append_anytls "$out"
    fi

    if [[ "$(protocol_count)" -eq 0 ]]; then
        return 1
    fi

    return 0
}

create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=shoes proxy service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${EXEC_PATH} ${CONFIG_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
}

apply_configuration() {
    local tmp_config
    tmp_config="$(mktemp)"

    if ! generate_config_file "$tmp_config"; then
        rm -f "$tmp_config"
        print_err "未生成任何协议配置"
        return 1
    fi

    mkdir -p "$CONFIG_DIR"

    if ! "$EXEC_PATH" --dry-run "$tmp_config" >/tmp/shoes-dry-run.log 2>&1; then
        print_err "配置校验失败"
        echo -e "${YELLOW}---------------- 生成的配置 ----------------${PLAIN}"
        cat "$tmp_config"
        echo -e "${YELLOW}--------------------------------------------${PLAIN}"
        cat /tmp/shoes-dry-run.log
        rm -f "$tmp_config"
        return 1
    fi

    mv "$tmp_config" "$CONFIG_PATH"
    create_systemd_service
    if ! systemctl daemon-reload; then
        print_err "systemd daemon-reload 失败"
        return 1
    fi
    if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
        print_err "启用 shoes 服务失败"
        return 1
    fi
    if ! systemctl restart "$SERVICE_NAME"; then
        print_err "重启 shoes 服务失败"
        systemctl --no-pager --full status "$SERVICE_NAME" || true
        return 1
    fi
    return 0
}

show_summary() {
    clear
    echo -e "${BLUE}部署信息${PLAIN}"

    if [[ "$ENABLE_SS" == "y" ]]; then
        echo -e "${GREEN}Shadowsocks${PLAIN}  地址: ${SS_ADDRESS}  密码: ${SS_PASSWORD}  cipher: ${SS_CIPHER}"
    fi

    if [[ "$ENABLE_TROJAN" == "y" ]]; then
        echo -e "${GREEN}Trojan+WS${PLAIN}   地址: ${TROJAN_ADDRESS}  SNI: ${TROJAN_SNI}  Path: ${TROJAN_WS_PATH}  密码: ${TROJAN_PASSWORD}"
    fi

    if [[ "$ENABLE_HY2" == "y" ]]; then
        echo -e "${GREEN}Hysteria2${PLAIN}  地址: ${HY2_ADDRESS}  密码: ${HY2_PASSWORD}"
    fi

    if [[ "$ENABLE_TUIC" == "y" ]]; then
        echo -e "${GREEN}TUIC v5${PLAIN}    地址: ${TUIC_ADDRESS}  UUID: ${TUIC_UUID}  密码: ${TUIC_PASSWORD}"
    fi

    if [[ "$ENABLE_ANYTLS" == "y" ]]; then
        echo -e "${GREEN}AnyTLS${PLAIN}     地址: ${ANYTLS_ADDRESS}  SNI: ${ANYTLS_SNI}  用户: ${ANYTLS_USERNAME}  密码: ${ANYTLS_PASSWORD}"
    fi

    echo
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    pause_and_return
}

get_arch_target() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *)
            return 1
            ;;
    esac
}

get_libc_target() {
    if ldd --version 2>&1 | grep -qi musl; then
        echo "unknown-linux-musl"
    else
        echo "unknown-linux-gnu"
    fi
}

get_release_json() {
    curl -fsSL "$LATEST_API_URL"
}

extract_tag_name() {
    awk -F '"' '/"tag_name":/ {print $4; exit}'
}

extract_download_url() {
    local asset_name="$1"
    awk -F '"' '/browser_download_url/ {print $4}' | grep -F "/${asset_name}" | head -n1
}

normalize_version() {
    echo "${1#v}"
}

install_binary_from_release() {
    local arch_target libc_target asset_name release_json download_url temp_dir bin_path
    arch_target="$(get_arch_target)" || {
        print_err "当前架构 $(uname -m) 没有预编译 shoes 二进制"
        return 1
    }
    libc_target="$(get_libc_target)"
    asset_name="shoes-${arch_target}-${libc_target}.tar.gz"

    print_info "[*] 获取 shoes 最新版本..."
    release_json="$(get_release_json)" || {
        print_err "获取 release 信息失败"
        return 1
    }

    download_url="$(printf '%s\n' "$release_json" | extract_download_url "$asset_name")"
    if [[ -z "$download_url" ]]; then
        print_err "未找到匹配的下载资产: ${asset_name}"
        return 1
    fi

    temp_dir="$(mktemp -d)"
    print_info "[*] 下载 ${asset_name}..."
    if ! curl -fL "$download_url" -o "${temp_dir}/shoes.tar.gz"; then
        rm -rf "$temp_dir"
        print_err "下载失败"
        return 1
    fi

    if ! tar -xzf "${temp_dir}/shoes.tar.gz" -C "$temp_dir"; then
        rm -rf "$temp_dir"
        print_err "解压失败"
        return 1
    fi

    bin_path="$(find "$temp_dir" -type f -name shoes | head -n1)"
    if [[ -z "$bin_path" ]]; then
        rm -rf "$temp_dir"
        print_err "压缩包中未找到 shoes 可执行文件"
        return 1
    fi

    install -m 755 "$bin_path" "$EXEC_PATH"
    rm -rf "$temp_dir"
    return 0
}

install_shoes() {
    clear
    require_commands

    if [[ -f "$EXEC_PATH" && -f "$STATE_PATH" ]]; then
        print_warn "已安装，请使用管理服务功能"
        pause_and_return
        return
    fi

    mkdir -p "$CONFIG_DIR"
    if ! install_binary_from_release; then
        pause_and_return
        return
    fi
    print_ok "shoes 内核安装完成"

    load_state
    run_configuration_wizard

    if ! apply_configuration; then
        pause_and_return
        return
    fi
    save_state

    print_ok "安装完成"
    show_summary
}

protocol_status() {
    if [[ "$1" == "y" ]]; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

commit_changes() {
    if apply_configuration; then
        save_state
        print_ok "配置已更新"
        sleep 1
        return 0
    fi

    load_state
    print_warn "未应用新配置，已恢复到上次有效配置"
    pause_here
    return 1
}

disable_protocol() {
    local __var="$1"

    if [[ "$(protocol_count)" -le 1 ]]; then
        print_err "至少保留一个已启用协议"
        sleep 1
        return 1
    fi

    printf -v "$__var" '%s' "n"
    return 0
}

show_service_and_config() {
    clear
    echo -e "${BLUE}Shoes 服务状态:${PLAIN}"
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    read -rp "$(echo -e "${BLUE}按回车查看配置...${PLAIN}")"
    clear
    echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
    if [[ -f "$CONFIG_PATH" ]]; then
        cat "$CONFIG_PATH"
    else
        print_err "配置文件不存在"
    fi
    echo -e "${BLUE}------------------------------------------------------${PLAIN}"
    pause_and_return
}

modify_shadowsocks() {
    while true; do
        clear
        echo -e "${BLUE}✦ Shadowsocks_Conf ✦${PLAIN}"

        if [[ "$ENABLE_SS" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改加密"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}切换UDP"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1)
                    read_address_value "SS_ADDRESS" "新监听地址(当前:${SS_ADDRESS}): " "$SS_ADDRESS"
                    commit_changes
                    ;;
                2)
                    read_value "SS_CIPHER" "新加密方式(当前:${SS_CIPHER}): " "$SS_CIPHER"
                    commit_changes
                    ;;
                3)
                    read_value "SS_PASSWORD" "新密码: " "$SS_PASSWORD"
                    if [[ -n "$SS_PASSWORD" ]]; then
                        commit_changes
                    fi
                    ;;
                4)
                    if [[ "$SS_UDP_ENABLED" == "true" ]]; then
                        SS_UDP_ENABLED="false"
                    else
                        SS_UDP_ENABLED="true"
                    fi
                    commit_changes
                    ;;
                5)
                    if ask_yes_no "确定禁用 Shadowsocks" "n" && disable_protocol "ENABLE_SS"; then
                        commit_changes
                        break
                    fi
                    ;;
                0) break ;;
                *) print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ask_yes_no "是否启用" "n"; then
                ENABLE_SS="y"
                configure_shadowsocks
                commit_changes
            else
                break
            fi
        fi
    done
}

modify_anytls() {
    while true; do
        clear
        echo -e "${BLUE}✦ AnyTLS_Conf ✦${PLAIN}"

        if [[ "$ENABLE_ANYTLS" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改域名"
            echo -e "${GREEN}  3.${PLAIN}修改用户"
            echo -e "${GREEN}  4.${PLAIN}修改密码"
            echo -e "${GREEN}  5.${PLAIN}修改证书"
            echo -e "${GREEN}  6.${PLAIN}切换UDP"
            echo -e "${GREEN}  7.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1)
                    read_address_value "ANYTLS_ADDRESS" "新监听地址(当前:${ANYTLS_ADDRESS}): " "$ANYTLS_ADDRESS"
                    commit_changes
                    ;;
                2)
                    read_value "ANYTLS_SNI" "新域名/SNI(当前:${ANYTLS_SNI}): " "$ANYTLS_SNI"
                    commit_changes
                    ;;
                3)
                    read_value "ANYTLS_USERNAME" "新用户名(当前:${ANYTLS_USERNAME}): " "$ANYTLS_USERNAME"
                    commit_changes
                    ;;
                4)
                    read_value "ANYTLS_PASSWORD" "新密码: " "$ANYTLS_PASSWORD"
                    if [[ -n "$ANYTLS_PASSWORD" ]]; then
                        commit_changes
                    fi
                    ;;
                5)
                    select_cert "$ANYTLS_CERT" "$ANYTLS_KEY"
                    ANYTLS_CERT="$cert_path"
                    ANYTLS_KEY="$key_path"
                    ANYTLS_SNI="$(derive_name_from_cert_path "$ANYTLS_CERT")"
                    print_ok "域名/SNI 已同步为: ${ANYTLS_SNI}"
                    commit_changes
                    ;;
                6)
                    if [[ "$ANYTLS_UDP_ENABLED" == "true" ]]; then
                        ANYTLS_UDP_ENABLED="false"
                    else
                        ANYTLS_UDP_ENABLED="true"
                    fi
                    commit_changes
                    ;;
                7)
                    if ask_yes_no "确定禁用 AnyTLS" "n" && disable_protocol "ENABLE_ANYTLS"; then
                        commit_changes
                        break
                    fi
                    ;;
                0) break ;;
                *) print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ask_yes_no "是否启用" "n"; then
                ENABLE_ANYTLS="y"
                configure_anytls
                commit_changes
            else
                break
            fi
        fi
    done
}

modify_trojan() {
    while true; do
        clear
        echo -e "${BLUE}✦ Trojan_Conf ✦${PLAIN}"

        if [[ "$ENABLE_TROJAN" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改域名"
            echo -e "${GREEN}  3.${PLAIN}修改路径"
            echo -e "${GREEN}  4.${PLAIN}修改密码"
            echo -e "${GREEN}  5.${PLAIN}修改证书"
            echo -e "${GREEN}  6.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1)
                    read_address_value "TROJAN_ADDRESS" "新监听地址(当前:${TROJAN_ADDRESS}): " "$TROJAN_ADDRESS"
                    commit_changes
                    ;;
                2)
                    read_value "TROJAN_SNI" "新域名/SNI(当前:${TROJAN_SNI}): " "$TROJAN_SNI"
                    commit_changes
                    ;;
                3)
                    read_value "TROJAN_WS_PATH" "新 WS 路径(当前:${TROJAN_WS_PATH}): " "$TROJAN_WS_PATH"
                    commit_changes
                    ;;
                4)
                    read_value "TROJAN_PASSWORD" "新密码: " "$TROJAN_PASSWORD"
                    if [[ -n "$TROJAN_PASSWORD" ]]; then
                        commit_changes
                    fi
                    ;;
                5)
                    select_cert "$TROJAN_CERT" "$TROJAN_KEY"
                    TROJAN_CERT="$cert_path"
                    TROJAN_KEY="$key_path"
                    TROJAN_SNI="$(derive_name_from_cert_path "$TROJAN_CERT")"
                    print_ok "域名/SNI 已同步为: ${TROJAN_SNI}"
                    commit_changes
                    ;;
                6)
                    if ask_yes_no "确定禁用 Trojan" "n" && disable_protocol "ENABLE_TROJAN"; then
                        commit_changes
                        break
                    fi
                    ;;
                0) break ;;
                *) print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ask_yes_no "是否启用" "n"; then
                ENABLE_TROJAN="y"
                configure_trojan
                commit_changes
            else
                break
            fi
        fi
    done
}

modify_tuic() {
    while true; do
        clear
        echo -e "${BLUE}✦ TUIC_Conf ✦${PLAIN}"

        if [[ "$ENABLE_TUIC" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改UUID"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}修改证书"
            echo -e "${GREEN}  5.${PLAIN}切换0-RTT"
            echo -e "${GREEN}  6.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1)
                    read_address_value "TUIC_ADDRESS" "新监听地址(当前:${TUIC_ADDRESS}): " "$TUIC_ADDRESS"
                    commit_changes
                    ;;
                2)
                    read_value "TUIC_UUID" "新 UUID(当前:${TUIC_UUID}): " "$TUIC_UUID"
                    commit_changes
                    ;;
                3)
                    read_value "TUIC_PASSWORD" "新密码: " "$TUIC_PASSWORD"
                    if [[ -n "$TUIC_PASSWORD" ]]; then
                        commit_changes
                    fi
                    ;;
                4)
                    select_cert "$TUIC_CERT" "$TUIC_KEY"
                    TUIC_CERT="$cert_path"
                    TUIC_KEY="$key_path"
                    commit_changes
                    ;;
                5)
                    if [[ "$TUIC_ZERO_RTT" == "true" ]]; then
                        TUIC_ZERO_RTT="false"
                    else
                        TUIC_ZERO_RTT="true"
                    fi
                    commit_changes
                    ;;
                6)
                    if ask_yes_no "确定禁用 TUIC v5" "n" && disable_protocol "ENABLE_TUIC"; then
                        commit_changes
                        break
                    fi
                    ;;
                0) break ;;
                *) print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ask_yes_no "是否启用" "n"; then
                ENABLE_TUIC="y"
                configure_tuic
                commit_changes
            else
                break
            fi
        fi
    done
}

modify_hysteria() {
    while true; do
        clear
        echo -e "${BLUE}✦ Hysteria2_Conf ✦${PLAIN}"

        if [[ "$ENABLE_HY2" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改密码"
            echo -e "${GREEN}  3.${PLAIN}修改证书"
            echo -e "${GREEN}  4.${PLAIN}切换UDP"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1)
                    read_address_value "HY2_ADDRESS" "新监听地址(当前:${HY2_ADDRESS}): " "$HY2_ADDRESS"
                    commit_changes
                    ;;
                2)
                    read_value "HY2_PASSWORD" "新密码: " "$HY2_PASSWORD"
                    if [[ -n "$HY2_PASSWORD" ]]; then
                        commit_changes
                    fi
                    ;;
                3)
                    select_cert "$HY2_CERT" "$HY2_KEY"
                    HY2_CERT="$cert_path"
                    HY2_KEY="$key_path"
                    commit_changes
                    ;;
                4)
                    if [[ "$HY2_UDP_ENABLED" == "true" ]]; then
                        HY2_UDP_ENABLED="false"
                    else
                        HY2_UDP_ENABLED="true"
                    fi
                    commit_changes
                    ;;
                5)
                    if ask_yes_no "确定禁用 Hysteria2" "n" && disable_protocol "ENABLE_HY2"; then
                        commit_changes
                        break
                    fi
                    ;;
                0) break ;;
                *) print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ask_yes_no "是否启用" "n"; then
                ENABLE_HY2="y"
                configure_hysteria2
                commit_changes
            else
                break
            fi
        fi
    done
}

modify_config() {
    load_state

    while true; do
        clear
        echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}Anytls      [${YELLOW}$(protocol_status "$ENABLE_ANYTLS")${PLAIN}]"
        echo -e "${GREEN}  2.${PLAIN}Trojan      [${YELLOW}$(protocol_status "$ENABLE_TROJAN")${PLAIN}]"
        echo -e "${GREEN}  3.${PLAIN}Tuicv5      [${YELLOW}$(protocol_status "$ENABLE_TUIC")${PLAIN}]"
        echo -e "${GREEN}  4.${PLAIN}Hysteria    [${YELLOW}$(protocol_status "$ENABLE_HY2")${PLAIN}]"
        echo -e "${GREEN}  5.${PLAIN}Shadowsocks [${YELLOW}$(protocol_status "$ENABLE_SS")${PLAIN}]"
        echo -e "${GREEN}  0.${PLAIN}Return"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            1) modify_anytls ;;
            2) modify_trojan ;;
            3) modify_tuic ;;
            4) modify_hysteria ;;
            5) modify_shadowsocks ;;
            0) break ;;
            *) print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

manage_service() {
    while true; do
        load_state
        clear
        echo -e "${BLUE}✦ Shoes_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            1) show_service_and_config ;;
            2) modify_config ;;
            3)
                systemctl stop "$SERVICE_NAME"
                print_ok "已停止"
                pause_and_return
                ;;
            4)
                systemctl restart "$SERVICE_NAME"
                print_ok "已重启"
                pause_and_return
                ;;
            0) break ;;
            *) print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

update_shoes() {
    local current_version latest_tag latest_version release_json

    clear
    require_commands

    if [[ ! -x "$EXEC_PATH" ]]; then
        print_err "未安装 shoes"
        pause_and_return
        return
    fi

    current_version="$("$EXEC_PATH" --version 2>/dev/null | awk '{print $2; exit}')"
    current_version="${current_version:-未知}"

    release_json="$(get_release_json)" || {
        print_err "获取 release 信息失败"
        pause_and_return
        return
    }
    latest_tag="$(printf '%s\n' "$release_json" | extract_tag_name)"
    latest_version="$(normalize_version "$latest_tag")"

    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}最新版本: ${YELLOW}${latest_version}${PLAIN}"

    if [[ "$(normalize_version "$current_version")" == "$latest_version" ]]; then
        print_ok "已是最新版本"
        pause_and_return
        return
    fi

    if ! ask_yes_no "是否更新" "n"; then
        return
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    if install_binary_from_release; then
        systemctl start "$SERVICE_NAME" 2>/dev/null || true
        print_ok "更新完成"
    else
        systemctl start "$SERVICE_NAME" 2>/dev/null || true
        print_err "更新失败"
    fi
    pause_and_return
}

delete_shoes() {
    clear
    if ! ask_yes_no "确定删除 shoes 服务和配置" "n"; then
        return
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$EXEC_PATH"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "已删除"
    pause_and_return
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Shoes_Ver.1.0 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}退出脚本"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

        case "$option" in
            1) install_shoes ;;
            2)
                if [[ ! -f "$EXEC_PATH" ]]; then
                    print_err "未安装"
                    pause_and_return
                    continue
                fi
                manage_service
                ;;
            3) update_shoes ;;
            4) delete_shoes ;;
            0) exit 0 ;;
            *) print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu
