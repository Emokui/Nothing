#!/bin/bash

set -u
set -o pipefail

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

SHOES_EXEC_PATH="/usr/local/bin/shoes"
SHOES_CONFIG_DIR="/etc/shoes"
SHOES_CONFIG_PATH="${SHOES_CONFIG_DIR}/config.yaml"
SHOES_SERVICE_NAME="shoes"
SHOES_SERVICE_FILE="/etc/systemd/system/shoes.service"
SHOES_RELEASE_REPO="sukurain/shoes"
SHOES_LATEST_API_URL="https://api.github.com/repos/${SHOES_RELEASE_REPO}/releases/latest"
SHOES_RELEASE_ASSET_NAME_GNU="shoes-bbr.tar.gz"
SHOES_RELEASE_ASSET_NAME_MUSL="shoes-bbr-musl.tar.gz"
SHOES_CURRENT_DEBIAN_STABLE_MAJOR="13"
SHOES_CURRENT_UBUNTU_RELEASE_VERSION="25.10"

if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本${PLAIN}"
    exit 1
fi

shoes_check_supported_os() {
    local os_id os_name

    if [[ ! -r /etc/os-release ]]; then
        shoes_print_err "无法识别系统类型，仅支持 Debian 和 Ubuntu"
        return 1
    fi

    source /etc/os-release
    os_id="${ID:-}"
    os_name="${PRETTY_NAME:-${NAME:-未知系统}}"

    case "$os_id" in
        debian|ubuntu)
            return 0
            ;;
        *)
            shoes_print_err "当前系统为 ${os_name}，此脚本仅支持 Debian 和 Ubuntu"
            return 1
            ;;
    esac
}

shoes_pause_and_return() {
    read -rp "$(echo -e "${BLUE}按回车返回...${PLAIN}")"
    clear
}

shoes_pause_here() {
    read -rp "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
}

shoes_random_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

shoes_random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

shoes_yaml_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

shoes_print_info() {
    echo -e "${BLUE}$*${PLAIN}"
}

shoes_print_ok() {
    echo -e "${GREEN}$*${PLAIN}"
}

shoes_print_warn() {
    echo -e "${YELLOW}$*${PLAIN}"
}

shoes_print_err() {
    echo -e "${RED}$*${PLAIN}"
}

shoes_require_commands() {
    local missing=()
    local cmd
    for cmd in curl tar systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        shoes_print_err "缺少命令: ${missing[*]}"
        return 1
    fi
}

shoes_load_defaults() {
    local protocol_key reset_fn
    while IFS= read -r protocol_key; do
        reset_fn="$(shoes_protocol_meta_value "$protocol_key" "reset_fn")"
        "$reset_fn"
    done < <(shoes_protocol_keys)
}

shoes_protocol_marker() {
    printf '# shoes-managed: protocol=%s' "$1"
}

shoes_extract_protocol_block() {
    local protocol_type="$1"
    local marker block
    [[ -f "$SHOES_CONFIG_PATH" ]] || return 0

    marker="$(shoes_protocol_marker "$protocol_type")"
    block="$(awk -v RS='' -v marker="$marker" '
        index($0, marker) > 0 { print; exit }
    ' "$SHOES_CONFIG_PATH")"

    if [[ -n "$block" ]]; then
        printf '%s\n' "$block"
        return 0
    fi

    awk -v RS='' -v protocol_type="$protocol_type" '
        $0 ~ ("type:[[:space:]]*" protocol_type "([[:space:]]|$)") { print; exit }
    ' "$SHOES_CONFIG_PATH"
}

shoes_extract_scalar_from_block() {
    local block="$1"
    local field="$2"
    printf '%s\n' "$block" | sed -nE "s/^[[:space:]-]*${field}:[[:space:]]*\"?([^\"]*)\"?$/\1/p" | head -n1
}

shoes_load_current_config() {
    shoes_load_defaults
    local protocol_key load_fn
    while IFS= read -r protocol_key; do
        load_fn="$(shoes_protocol_meta_value "$protocol_key" "load_fn")"
        "$load_fn"
    done < <(shoes_protocol_keys)
}

shoes_read_value() {
    local __var="$1"
    local prompt="$2"
    local default_value="$3"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    input="${input:-$default_value}"
    printf -v "$__var" '%s' "$input"
}

shoes_trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

shoes_normalize_bind_address() {
    local raw
    raw="$(shoes_trim_whitespace "$1")"

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

shoes_read_address_value() {
    local __var="$1"
    local prompt="$2"
    local default_value="$3"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    input="${input:-$default_value}"
    input="$(shoes_normalize_bind_address "$input")"
    printf -v "$__var" '%s' "$input"
}

shoes_read_password_or_random() {
    local __var="$1"
    local prompt="$2"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    if [[ -z "$input" ]]; then
        input="$(shoes_random_pass)"
        shoes_print_ok "密码: ${input}"
    fi
    printf -v "$__var" '%s' "$input"
}

shoes_read_uuid_or_random() {
    local __var="$1"
    local prompt="$2"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    if [[ -z "$input" ]]; then
        input="$(shoes_random_uuid)"
        shoes_print_ok "UUID: ${input}"
    fi
    printf -v "$__var" '%s' "$input"
}

shoes_ask_yes_no() {
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
            *) shoes_print_warn "请输入 y 或 n" ;;
        esac
    done
}

shoes_select_cert() {
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
            shoes_print_err "路径无效"
            sleep 1
            continue
        fi

        if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#cert_files[@]} )); then
            cert_path="${cert_files[$((opt-1))]}"
            key_path="${cert_path%.crt}.key"
            if [[ -f "$key_path" ]]; then
                return 0
            fi
            shoes_print_err "未找到对应私钥: $key_path"
            sleep 1
            continue
        fi

        shoes_print_warn "无效选项"
        sleep 1
    done
}

shoes_derive_name_from_cert_path() {
    local cert_file base_name
    cert_file="$1"
    base_name="$(basename "$cert_file")"
    base_name="${base_name%.crt}"
    base_name="${base_name%.pem}"
    printf '%s' "$base_name"
}

shoes_protocol_metadata() {
    cat <<'EOF'
anytls|ENABLE_ANYTLS|shoes_reset_anytls_state|shoes_load_anytls_config|shoes_configure_anytls|shoes_append_anytls|shoes_modify_anytls|shoes_print_anytls_summary|AnyTLS|Anytls
trojan|ENABLE_TROJAN|shoes_reset_trojan_state|shoes_load_trojan_config|shoes_configure_trojan|shoes_append_trojan|shoes_modify_trojan|shoes_print_trojan_summary|Trojan|Trojan
tuic|ENABLE_TUIC|shoes_reset_tuic_state|shoes_load_tuic_config|shoes_configure_tuic|shoes_append_tuic|shoes_modify_tuic|shoes_print_tuic_summary|Tuicv5|Tuicv5
hy2|ENABLE_HY2|shoes_reset_hysteria2_state|shoes_load_hysteria2_config|shoes_configure_hysteria2|shoes_append_hysteria2|shoes_modify_hysteria|shoes_print_hysteria2_summary|Hysteria|Hysteria
shadowsocks|ENABLE_SS|shoes_reset_shadowsocks_state|shoes_load_shadowsocks_config|shoes_configure_shadowsocks|shoes_append_shadowsocks|shoes_modify_shadowsocks|shoes_print_shadowsocks_summary|Shadowsocks|Shadowsocks
EOF
}

shoes_protocol_keys() {
    shoes_protocol_metadata | awk -F'|' '{print $1}'
}

shoes_protocol_meta_value() {
    local protocol_key="$1"
    local field="$2"
    local field_index

    case "$field" in
        enable_var) field_index=2 ;;
        reset_fn) field_index=3 ;;
        load_fn) field_index=4 ;;
        configure_fn) field_index=5 ;;
        append_fn) field_index=6 ;;
        modify_fn) field_index=7 ;;
        summary_fn) field_index=8 ;;
        prompt_label) field_index=9 ;;
        menu_label) field_index=10 ;;
        *) return 1 ;;
    esac

    shoes_protocol_metadata | awk -F'|' -v key="$protocol_key" -v field_index="$field_index" '
        $1 == key { print $field_index; exit }
    '
}

shoes_protocol_enabled() {
    local var_name
    var_name="$(shoes_protocol_meta_value "$1" "enable_var")"
    [[ -n "$var_name" && "${!var_name}" == "y" ]]
}

shoes_set_protocol_enabled() {
    local protocol_key="$1"
    local value="$2"
    local var_name
    var_name="$(shoes_protocol_meta_value "$protocol_key" "enable_var")"
    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" '%s' "$value"
    fi
}

shoes_reset_shadowsocks_state() {
    ENABLE_SS="n"
    SS_ADDRESS="[::]:8388"
    SS_CIPHER="aes-256-gcm"
    SS_PASSWORD=""
    SS_UDP_ENABLED="true"
}

shoes_load_shadowsocks_config() {
    local block
    block="$(shoes_extract_protocol_block "shadowsocks")"
    if [[ -n "$block" ]]; then
        ENABLE_SS="y"
        SS_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        SS_CIPHER="$(shoes_extract_scalar_from_block "$block" "cipher")"
        SS_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        SS_UDP_ENABLED="$(shoes_extract_scalar_from_block "$block" "udp_enabled")"
    fi
}

shoes_configure_shadowsocks() {
    clear
    echo -e "${BLUE}===== Shadowsocks 配置 =====${PLAIN}"
    shoes_read_address_value "SS_ADDRESS" "监听地址(默认:${SS_ADDRESS}): " "$SS_ADDRESS"
    shoes_read_value "SS_CIPHER" "加密方式(默认:${SS_CIPHER}): " "$SS_CIPHER"
    shoes_read_value "SS_PASSWORD" "密码(回车随机): " "$SS_PASSWORD"
    if [[ -z "$SS_PASSWORD" ]]; then
        SS_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${SS_PASSWORD}"
    fi
    SS_UDP_ENABLED="true"
    shoes_print_ok "UDP: 已默认开启"
}

shoes_append_shadowsocks() {
    local out="$1"
    cat >> "$out" <<EOF
# shoes-managed: protocol=shadowsocks
- address: $(shoes_yaml_quote "$SS_ADDRESS")
  protocol:
    type: shadowsocks
    cipher: $(shoes_yaml_quote "$SS_CIPHER")
    password: $(shoes_yaml_quote "$SS_PASSWORD")
    udp_enabled: ${SS_UDP_ENABLED}

EOF
}

shoes_modify_shadowsocks() {
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
                1) shoes_apply_address_update "SS_ADDRESS" ;;
                2) shoes_apply_value_update "SS_CIPHER" "新加密方式" ;;
                3) shoes_apply_password_update "SS_PASSWORD" ;;
                4) shoes_apply_boolean_toggle "SS_UDP_ENABLED" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_SS" "Shadowsocks"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_SS" "shoes_configure_shadowsocks"; then
                break
            fi
        fi
    done
}

shoes_print_shadowsocks_summary() {
    echo -e "${GREEN}Shadowsocks${PLAIN}  地址: ${SS_ADDRESS}  密码: ${SS_PASSWORD}  cipher: ${SS_CIPHER}"
}

shoes_reset_trojan_state() {
    ENABLE_TROJAN="n"
    TROJAN_ADDRESS="[::]:4443"
    TROJAN_WS_PATH="/"
    TROJAN_PASSWORD=""
    TROJAN_CERT=""
    TROJAN_KEY=""
}

shoes_load_trojan_config() {
    local block
    block="$(shoes_extract_protocol_block "trojan")"
    if [[ -n "$block" ]]; then
        ENABLE_TROJAN="y"
        TROJAN_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        TROJAN_WS_PATH="$(shoes_extract_scalar_from_block "$block" "matching_path")"
        TROJAN_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        TROJAN_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        TROJAN_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
    fi
}

shoes_configure_trojan() {
    clear
    echo -e "${BLUE}===== Trojan over WebSocket 配置 =====${PLAIN}"
    shoes_read_address_value "TROJAN_ADDRESS" "监听地址(默认:${TROJAN_ADDRESS}): " "$TROJAN_ADDRESS"
    shoes_read_value "TROJAN_WS_PATH" "WebSocket 路径(默认:${TROJAN_WS_PATH}): " "$TROJAN_WS_PATH"
    shoes_read_value "TROJAN_PASSWORD" "密码(回车随机): " "$TROJAN_PASSWORD"
    if [[ -z "$TROJAN_PASSWORD" ]]; then
        TROJAN_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${TROJAN_PASSWORD}"
    fi
    shoes_select_cert "$TROJAN_CERT" "$TROJAN_KEY"
    TROJAN_CERT="$cert_path"
    TROJAN_KEY="$key_path"
}

shoes_append_trojan() {
    local out="$1"
    local trojan_sni
    trojan_sni="$(shoes_derive_name_from_cert_path "$TROJAN_CERT")"
    cat >> "$out" <<EOF
# shoes-managed: protocol=trojan
- address: $(shoes_yaml_quote "$TROJAN_ADDRESS")
  protocol:
    type: tls
    tls_targets:
      $(shoes_yaml_quote "$trojan_sni"):
        cert: $(shoes_yaml_quote "$TROJAN_CERT")
        key: $(shoes_yaml_quote "$TROJAN_KEY")
        protocol:
          type: websocket
          targets:
            - matching_path: $(shoes_yaml_quote "$TROJAN_WS_PATH")
              protocol:
                type: trojan
                password: $(shoes_yaml_quote "$TROJAN_PASSWORD")

EOF
}

shoes_modify_trojan() {
    while true; do
        clear
        echo -e "${BLUE}✦ Trojan_Conf ✦${PLAIN}"

        if [[ "$ENABLE_TROJAN" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改路径"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}修改证书"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "TROJAN_ADDRESS" ;;
                2) shoes_apply_value_update "TROJAN_WS_PATH" "新 WS 路径" ;;
                3) shoes_apply_password_update "TROJAN_PASSWORD" ;;
                4) shoes_apply_cert_update "TROJAN_CERT" "TROJAN_KEY" "y" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_TROJAN" "Trojan"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_TROJAN" "shoes_configure_trojan"; then
                break
            fi
        fi
    done
}

shoes_print_trojan_summary() {
    local trojan_sni
    trojan_sni="$(shoes_derive_name_from_cert_path "$TROJAN_CERT")"
    echo -e "${GREEN}Trojan+WS${PLAIN}   地址: ${TROJAN_ADDRESS}  SNI: ${trojan_sni}  Path: ${TROJAN_WS_PATH}  密码: ${TROJAN_PASSWORD}"
}

shoes_reset_hysteria2_state() {
    ENABLE_HY2="n"
    HY2_ADDRESS="[::]:8443"
    HY2_PASSWORD=""
    HY2_CERT=""
    HY2_KEY=""
    HY2_UDP_ENABLED="true"
}

shoes_load_hysteria2_config() {
    local block
    block="$(shoes_extract_protocol_block "hysteria2")"
    if [[ -n "$block" ]]; then
        ENABLE_HY2="y"
        HY2_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        HY2_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        HY2_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        HY2_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
        HY2_UDP_ENABLED="$(shoes_extract_scalar_from_block "$block" "udp_enabled")"
    fi
}

shoes_configure_hysteria2() {
    clear
    echo -e "${BLUE}===== Hysteria2 配置 =====${PLAIN}"
    shoes_read_address_value "HY2_ADDRESS" "监听地址(默认:${HY2_ADDRESS}): " "$HY2_ADDRESS"
    shoes_read_value "HY2_PASSWORD" "密码(回车随机): " "$HY2_PASSWORD"
    if [[ -z "$HY2_PASSWORD" ]]; then
        HY2_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${HY2_PASSWORD}"
    fi
    HY2_UDP_ENABLED="true"
    shoes_print_ok "UDP: 已默认开启"
    shoes_select_cert "$HY2_CERT" "$HY2_KEY"
    HY2_CERT="$cert_path"
    HY2_KEY="$key_path"
}

shoes_append_hysteria2() {
    local out="$1"
    cat >> "$out" <<EOF
# shoes-managed: protocol=hysteria2
- address: $(shoes_yaml_quote "$HY2_ADDRESS")
  transport: quic
  quic_settings:
    cert: $(shoes_yaml_quote "$HY2_CERT")
    key: $(shoes_yaml_quote "$HY2_KEY")
    alpn_protocols:
      - "h3"
  protocol:
    type: hysteria2
    password: $(shoes_yaml_quote "$HY2_PASSWORD")
    udp_enabled: ${HY2_UDP_ENABLED}

EOF
}

shoes_modify_hysteria() {
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
                1) shoes_apply_address_update "HY2_ADDRESS" ;;
                2) shoes_apply_password_update "HY2_PASSWORD" ;;
                3) shoes_apply_cert_update "HY2_CERT" "HY2_KEY" ;;
                4) shoes_apply_boolean_toggle "HY2_UDP_ENABLED" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_HY2" "Hysteria2"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_HY2" "shoes_configure_hysteria2"; then
                break
            fi
        fi
    done
}

shoes_print_hysteria2_summary() {
    echo -e "${GREEN}Hysteria2${PLAIN}  地址: ${HY2_ADDRESS}  密码: ${HY2_PASSWORD}"
}

shoes_reset_tuic_state() {
    ENABLE_TUIC="n"
    TUIC_ADDRESS="[::]:9443"
    TUIC_UUID=""
    TUIC_PASSWORD=""
    TUIC_CERT=""
    TUIC_KEY=""
}

shoes_load_tuic_config() {
    local block
    block="$(shoes_extract_protocol_block "tuic")"
    if [[ -n "$block" ]]; then
        ENABLE_TUIC="y"
        TUIC_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        TUIC_UUID="$(shoes_extract_scalar_from_block "$block" "uuid")"
        TUIC_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        TUIC_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        TUIC_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
    fi
}

shoes_configure_tuic() {
    clear
    echo -e "${BLUE}===== TUIC v5 配置 =====${PLAIN}"
    shoes_read_address_value "TUIC_ADDRESS" "监听地址(默认:${TUIC_ADDRESS}): " "$TUIC_ADDRESS"
    shoes_read_value "TUIC_UUID" "UUID(回车随机): " "$TUIC_UUID"
    if [[ -z "$TUIC_UUID" ]]; then
        TUIC_UUID="$(shoes_random_uuid)"
        shoes_print_ok "UUID: ${TUIC_UUID}"
    fi
    shoes_read_value "TUIC_PASSWORD" "密码(回车随机): " "$TUIC_PASSWORD"
    if [[ -z "$TUIC_PASSWORD" ]]; then
        TUIC_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${TUIC_PASSWORD}"
    fi
    shoes_select_cert "$TUIC_CERT" "$TUIC_KEY"
    TUIC_CERT="$cert_path"
    TUIC_KEY="$key_path"
}

shoes_append_tuic() {
    local out="$1"
    cat >> "$out" <<EOF
# shoes-managed: protocol=tuic
- address: $(shoes_yaml_quote "$TUIC_ADDRESS")
  transport: quic
  quic_settings:
    cert: $(shoes_yaml_quote "$TUIC_CERT")
    key: $(shoes_yaml_quote "$TUIC_KEY")
    alpn_protocols:
      - "h3"
  protocol:
    type: tuic
    uuid: $(shoes_yaml_quote "$TUIC_UUID")
    password: $(shoes_yaml_quote "$TUIC_PASSWORD")

EOF
}

shoes_modify_tuic() {
    while true; do
        clear
        echo -e "${BLUE}✦ TUIC_Conf ✦${PLAIN}"

        if [[ "$ENABLE_TUIC" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改UUID"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}修改证书"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "TUIC_ADDRESS" ;;
                2) shoes_apply_uuid_update "TUIC_UUID" ;;
                3) shoes_apply_password_update "TUIC_PASSWORD" ;;
                4) shoes_apply_cert_update "TUIC_CERT" "TUIC_KEY" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_TUIC" "TUIC v5"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_TUIC" "shoes_configure_tuic"; then
                break
            fi
        fi
    done
}

shoes_print_tuic_summary() {
    echo -e "${GREEN}TUIC v5${PLAIN}    地址: ${TUIC_ADDRESS}  UUID: ${TUIC_UUID}  密码: ${TUIC_PASSWORD}"
}

shoes_reset_anytls_state() {
    ENABLE_ANYTLS="n"
    ANYTLS_ADDRESS="[::]:443"
    ANYTLS_PASSWORD=""
    ANYTLS_CERT=""
    ANYTLS_KEY=""
    ANYTLS_UDP_ENABLED="true"
}

shoes_load_anytls_config() {
    local block
    block="$(shoes_extract_protocol_block "anytls")"
    if [[ -n "$block" ]]; then
        ENABLE_ANYTLS="y"
        ANYTLS_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        ANYTLS_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        ANYTLS_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        ANYTLS_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
        ANYTLS_UDP_ENABLED="$(shoes_extract_scalar_from_block "$block" "udp_enabled")"
    fi
}

shoes_configure_anytls() {
    clear
    echo -e "${BLUE}===== AnyTLS 配置 =====${PLAIN}"
    shoes_read_address_value "ANYTLS_ADDRESS" "监听地址(默认:${ANYTLS_ADDRESS}): " "$ANYTLS_ADDRESS"
    shoes_read_value "ANYTLS_PASSWORD" "密码(回车随机): " "$ANYTLS_PASSWORD"
    if [[ -z "$ANYTLS_PASSWORD" ]]; then
        ANYTLS_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${ANYTLS_PASSWORD}"
    fi
    ANYTLS_UDP_ENABLED="true"
    shoes_select_cert "$ANYTLS_CERT" "$ANYTLS_KEY"
    ANYTLS_CERT="$cert_path"
    ANYTLS_KEY="$key_path"
    shoes_print_ok "UDP: 已默认开启"
}

shoes_append_anytls() {
    local out="$1"
    local anytls_sni
    anytls_sni="$(shoes_derive_name_from_cert_path "$ANYTLS_CERT")"
    cat >> "$out" <<EOF
# shoes-managed: protocol=anytls
- address: $(shoes_yaml_quote "$ANYTLS_ADDRESS")
  protocol:
    type: tls
    tls_targets:
      $(shoes_yaml_quote "$anytls_sni"):
        cert: $(shoes_yaml_quote "$ANYTLS_CERT")
        key: $(shoes_yaml_quote "$ANYTLS_KEY")
        protocol:
          type: anytls
          users:
            - name: "user1"
              password: $(shoes_yaml_quote "$ANYTLS_PASSWORD")
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

shoes_modify_anytls() {
    while true; do
        clear
        echo -e "${BLUE}✦ AnyTLS_Conf ✦${PLAIN}"

        if [[ "$ENABLE_ANYTLS" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改密码"
            echo -e "${GREEN}  3.${PLAIN}修改证书"
            echo -e "${GREEN}  4.${PLAIN}切换UDP"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "ANYTLS_ADDRESS" ;;
                2) shoes_apply_password_update "ANYTLS_PASSWORD" ;;
                3) shoes_apply_cert_update "ANYTLS_CERT" "ANYTLS_KEY" "y" ;;
                4) shoes_apply_boolean_toggle "ANYTLS_UDP_ENABLED" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_ANYTLS" "AnyTLS"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_ANYTLS" "shoes_configure_anytls"; then
                break
            fi
        fi
    done
}

shoes_print_anytls_summary() {
    local anytls_sni
    anytls_sni="$(shoes_derive_name_from_cert_path "$ANYTLS_CERT")"
    echo -e "${GREEN}AnyTLS${PLAIN}     地址: ${ANYTLS_ADDRESS}  SNI: ${anytls_sni}  密码: ${ANYTLS_PASSWORD}"
}

shoes_protocol_count() {
    local count=0
    local protocol_key
    while IFS= read -r protocol_key; do
        if shoes_protocol_enabled "$protocol_key"; then
            ((count++))
        fi
    done < <(shoes_protocol_keys)
    echo "$count"
}

shoes_run_configuration_wizard() {
    local protocol_key enable_var configure_fn
    local protocol_keys_list=()
    mapfile -t protocol_keys_list < <(shoes_protocol_keys)

    while true; do
        clear
        echo -e "${BLUE}选择要启用的协议${PLAIN}"

        for protocol_key in "${protocol_keys_list[@]}"; do
            enable_var="$(shoes_protocol_meta_value "$protocol_key" "enable_var")"
            if shoes_ask_yes_no "启用 $(shoes_protocol_meta_value "$protocol_key" "prompt_label")" "${!enable_var}"; then
                shoes_set_protocol_enabled "$protocol_key" "y"
            else
                shoes_set_protocol_enabled "$protocol_key" "n"
            fi
        done

        if [[ "$(shoes_protocol_count)" -gt 0 ]]; then
            for protocol_key in "${protocol_keys_list[@]}"; do
                if shoes_protocol_enabled "$protocol_key"; then
                    configure_fn="$(shoes_protocol_meta_value "$protocol_key" "configure_fn")"
                    "$configure_fn"
                fi
            done

            break
        fi

        shoes_print_err "至少需要启用一个协议"
        sleep 1
    done
}

shoes_render_config_file() {
    local out="$1"
    local protocol_key append_fn
    : > "$out"

    while IFS= read -r protocol_key; do
        if shoes_protocol_enabled "$protocol_key"; then
            append_fn="$(shoes_protocol_meta_value "$protocol_key" "append_fn")"
            "$append_fn" "$out"
        fi
    done < <(shoes_protocol_keys)

    if [[ "$(shoes_protocol_count)" -eq 0 ]]; then
        return 1
    fi

    return 0
}

shoes_create_systemd_service() {
    cat > "$SHOES_SERVICE_FILE" <<EOF
[Unit]
Description=shoes proxy service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SHOES_EXEC_PATH} ${SHOES_CONFIG_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SHOES_SERVICE_FILE"
}

shoes_validate_config_file() {
    local config_file="$1"
    local dry_run_log="$2"
    "$SHOES_EXEC_PATH" --dry-run "$config_file" > "$dry_run_log" 2>&1
}

shoes_install_config_file() {
    local staged_config="$1"
    mkdir -p "$SHOES_CONFIG_DIR" || return 1
    mv "$staged_config" "$SHOES_CONFIG_PATH" || return 1
}

shoes_reload_service_unit() {
    shoes_create_systemd_service
    if ! systemctl daemon-reload; then
        shoes_print_err "systemd daemon-reload 失败"
        return 1
    fi
    if ! systemctl enable "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
        shoes_print_err "启用 shoes 服务失败"
        return 1
    fi
    return 0
}

shoes_run_service_action_checked() {
    local action="$1"
    local fail_message="$2"

    if ! systemctl "$action" "$SHOES_SERVICE_NAME"; then
        shoes_print_err "$fail_message"
        systemctl --no-pager --full status "$SHOES_SERVICE_NAME" || true
        return 1
    fi
    return 0
}

shoes_apply_configuration() {
    local tmp_config dry_run_log
    tmp_config="$(mktemp)"
    dry_run_log="$(mktemp)"

    if ! shoes_render_config_file "$tmp_config"; then
        rm -f "$tmp_config" "$dry_run_log"
        shoes_print_err "未生成任何协议配置"
        return 1
    fi

    if ! shoes_validate_config_file "$tmp_config" "$dry_run_log"; then
        shoes_print_err "配置校验失败"
        echo -e "${YELLOW}---------------- 生成的配置 ----------------${PLAIN}"
        cat "$tmp_config"
        echo -e "${YELLOW}--------------------------------------------${PLAIN}"
        cat "$dry_run_log"
        rm -f "$tmp_config" "$dry_run_log"
        return 1
    fi

    if ! shoes_install_config_file "$tmp_config"; then
        shoes_print_err "写入配置文件失败"
        rm -f "$tmp_config" "$dry_run_log"
        return 1
    fi
    rm -f "$dry_run_log"

    if ! shoes_reload_service_unit; then
        return 1
    fi

    shoes_run_service_action_checked "restart" "重启 shoes 服务失败"
}

shoes_show_summary() {
    local protocol_key summary_fn
    clear
    echo -e "${BLUE}部署信息${PLAIN}"

    while IFS= read -r protocol_key; do
        if shoes_protocol_enabled "$protocol_key"; then
            summary_fn="$(shoes_protocol_meta_value "$protocol_key" "summary_fn")"
            "$summary_fn"
        fi
    done < <(shoes_protocol_keys)

    echo
    systemctl --no-pager --full status "$SHOES_SERVICE_NAME" || true
    shoes_pause_and_return
}

shoes_get_release_json() {
    curl -fsSL "$SHOES_LATEST_API_URL"
}

shoes_select_release_asset_name() {
    local os_id version_id major_version

    source /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    major_version="${version_id%%.*}"

    if [[ "$os_id" == "debian" && "$major_version" == "$SHOES_CURRENT_DEBIAN_STABLE_MAJOR" ]]; then
        printf '%s\n' "$SHOES_RELEASE_ASSET_NAME_GNU"
    elif [[ "$os_id" == "ubuntu" && "$version_id" == "$SHOES_CURRENT_UBUNTU_RELEASE_VERSION" ]]; then
        printf '%s\n' "$SHOES_RELEASE_ASSET_NAME_GNU"
    else
        printf '%s\n' "$SHOES_RELEASE_ASSET_NAME_MUSL"
    fi
}

shoes_extract_tag_name() {
    awk -F '"' '/"tag_name":/ {print $4; exit}'
}

shoes_extract_download_url() {
    local asset_name="$1"
    awk -F '"' '/browser_download_url/ {print $4}' | grep -F "/${asset_name}" | head -n1
}

shoes_normalize_version() {
    echo "${1#v}"
}

shoes_extract_version_from_text() {
    local text="$1"
    local version=""
    version="$(printf '%s\n' "$text" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?' | head -n1)"
    if [[ -n "$version" ]]; then
        shoes_normalize_version "$version"
        return 0
    fi
    return 1
}

shoes_get_current_installed_version() {
    local output version

    output="$("$SHOES_EXEC_PATH" --version 2>&1 || true)"
    if version="$(shoes_extract_version_from_text "$output")"; then
        printf '%s\n' "$version"
        return 0
    fi

    output="$("$SHOES_EXEC_PATH" -V 2>&1 || true)"
    if version="$(shoes_extract_version_from_text "$output")"; then
        printf '%s\n' "$version"
        return 0
    fi

    return 1
}

shoes_install_binary_from_release() {
    local asset_name release_json download_url temp_dir bin_path latest_tag

    if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "amd64" ]]; then
        shoes_print_err "当前架构 $(uname -m) 不支持此预编译 shoes 二进制"
        return 1
    fi
    asset_name="$(shoes_select_release_asset_name)"

    shoes_print_info "[*] 获取 shoes 最新版本..."
    release_json="$(shoes_get_release_json)" || {
        shoes_print_err "获取 release 信息失败"
        return 1
    }
    latest_tag="$(printf '%s\n' "$release_json" | shoes_extract_tag_name)"

    download_url="$(printf '%s\n' "$release_json" | shoes_extract_download_url "$asset_name")"
    if [[ -z "$download_url" ]]; then
        shoes_print_err "未找到匹配的下载资产: ${asset_name}"
        return 1
    fi

    temp_dir="$(mktemp -d)"
    shoes_print_info "[*] 下载 ${asset_name}..."
    if ! curl -fL "$download_url" -o "${temp_dir}/shoes.tar.gz"; then
        rm -rf "$temp_dir"
        shoes_print_err "下载失败"
        return 1
    fi

    if ! tar -xzf "${temp_dir}/shoes.tar.gz" -C "$temp_dir"; then
        rm -rf "$temp_dir"
        shoes_print_err "解压失败"
        return 1
    fi

    bin_path="$(find "$temp_dir" -type f -name shoes | head -n1)"
    if [[ -z "$bin_path" ]]; then
        rm -rf "$temp_dir"
        shoes_print_err "压缩包中未找到 shoes 可执行文件"
        return 1
    fi

    install -m 755 "$bin_path" "$SHOES_EXEC_PATH"
    rm -rf "$temp_dir"
    return 0
}

shoes_install_shoes() {
    clear
    shoes_require_commands || {
        shoes_pause_and_return
        return
    }

    if [[ -x "$SHOES_EXEC_PATH" ]]; then
        shoes_print_warn "已安装，请使用管理服务功能"
        shoes_pause_and_return
        return
    fi

    shoes_load_current_config
    mkdir -p "$SHOES_CONFIG_DIR"
    if ! shoes_install_binary_from_release; then
        shoes_pause_and_return
        return
    fi
    shoes_print_ok "shoes 内核安装完成"
    shoes_run_configuration_wizard

    if ! shoes_apply_configuration; then
        shoes_pause_and_return
        return
    fi

    shoes_print_ok "安装完成"
    shoes_show_summary
}

shoes_protocol_status() {
    if [[ "$1" == "y" ]]; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

shoes_print_modify_protocol_entry() {
    local index="$1"
    local protocol_key="$2"
    local enable_var
    enable_var="$(shoes_protocol_meta_value "$protocol_key" "enable_var")"
    echo -e "${GREEN}  ${index}.${PLAIN}$(printf '%-12s' "$(shoes_protocol_meta_value "$protocol_key" "menu_label")") [${YELLOW}$(shoes_protocol_status "${!enable_var}")${PLAIN}]"
}

shoes_commit_changes() {
    if shoes_apply_configuration; then
        shoes_print_ok "配置已更新"
        sleep 1
        return 0
    fi

    shoes_load_current_config
    shoes_print_warn "未完成配置应用，已重新从当前配置文件加载状态"
    shoes_pause_here
    return 1
}

shoes_disable_protocol() {
    local __var="$1"

    if [[ "$(shoes_protocol_count)" -le 1 ]]; then
        shoes_print_err "至少保留一个已启用协议"
        sleep 1
        return 1
    fi

    printf -v "$__var" '%s' "n"
    return 0
}

shoes_apply_address_update() {
    local var_name="$1"
    local current_value="${!var_name}"
    shoes_read_address_value "$var_name" "新监听地址(当前:${current_value}): " "$current_value"
    shoes_commit_changes
}

shoes_apply_value_update() {
    local var_name="$1"
    local label="$2"
    local current_value="${!var_name}"
    shoes_read_value "$var_name" "${label}(当前:${current_value}): " "$current_value"
    shoes_commit_changes
}

shoes_apply_password_update() {
    local var_name="$1"
    shoes_read_password_or_random "$var_name" "新密码(回车随机): "
    shoes_commit_changes
}

shoes_apply_uuid_update() {
    local var_name="$1"
    shoes_read_uuid_or_random "$var_name" "新 UUID(回车随机): "
    shoes_commit_changes
}

shoes_apply_cert_update() {
    local cert_var="$1"
    local key_var="$2"
    local show_sni_sync="${3:-n}"

    shoes_select_cert "${!cert_var}" "${!key_var}"
    printf -v "$cert_var" '%s' "$cert_path"
    printf -v "$key_var" '%s' "$key_path"

    if [[ "$show_sni_sync" == "y" ]]; then
        shoes_print_ok "域名/SNI 已同步为: $(shoes_derive_name_from_cert_path "${!cert_var}")"
    fi

    shoes_commit_changes
}

shoes_apply_boolean_toggle() {
    local var_name="$1"

    if [[ "${!var_name}" == "true" ]]; then
        printf -v "$var_name" '%s' "false"
    else
        printf -v "$var_name" '%s' "true"
    fi

    shoes_commit_changes
}

shoes_disable_protocol_with_confirmation() {
    local enable_var="$1"
    local label="$2"

    if shoes_ask_yes_no "确定禁用 ${label}" "n" && shoes_disable_protocol "$enable_var"; then
        shoes_commit_changes
        return 0
    fi

    return 1
}

shoes_prompt_enable_protocol() {
    local enable_var="$1"
    local configure_fn="$2"

    if shoes_ask_yes_no "是否启用" "n"; then
        printf -v "$enable_var" '%s' "y"
        "$configure_fn"
        shoes_commit_changes
        return 0
    fi

    return 1
}

shoes_show_service_and_config() {
    clear
    echo -e "${BLUE}Shoes 服务状态:${PLAIN}"
    systemctl --no-pager --full status "$SHOES_SERVICE_NAME" || true
    read -rp "$(echo -e "${BLUE}按回车查看配置...${PLAIN}")"
    clear
    echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
    if [[ -f "$SHOES_CONFIG_PATH" ]]; then
        cat "$SHOES_CONFIG_PATH"
    else
        shoes_print_err "配置文件不存在"
    fi
    echo -e "${BLUE}------------------------------------------------------${PLAIN}"
    shoes_pause_and_return
}

shoes_modify_config() {
    local opt protocol_key index modify_fn
    shoes_load_current_config

    while true; do
        clear
        echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
        index=1
        while IFS= read -r protocol_key; do
            shoes_print_modify_protocol_entry "$index" "$protocol_key"
            ((index++))
        done < <(shoes_protocol_keys)
        echo -e "${GREEN}  0.${PLAIN}Return"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            0) break ;;
            *)
                if [[ "$opt" =~ ^[1-9][0-9]*$ ]]; then
                    protocol_key="$(shoes_protocol_keys | sed -n "${opt}p")"
                    if [[ -n "$protocol_key" ]]; then
                        modify_fn="$(shoes_protocol_meta_value "$protocol_key" "modify_fn")"
                        "$modify_fn"
                    else
                        shoes_print_warn "无效选项"
                        sleep 1
                    fi
                else
                    shoes_print_warn "无效选项"
                    sleep 1
                fi
                ;;
        esac
    done
}

shoes_manage_service() {
    while true; do
        shoes_load_current_config
        clear
        echo -e "${BLUE}✦ Shoes_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            1) shoes_show_service_and_config ;;
            2) shoes_modify_config ;;
            3)
                if shoes_run_service_action_checked "stop" "停止 shoes 服务失败"; then
                    shoes_print_ok "已停止"
                fi
                shoes_pause_and_return
                ;;
            4)
                if shoes_run_service_action_checked "restart" "重启 shoes 服务失败"; then
                    shoes_print_ok "已重启"
                fi
                shoes_pause_and_return
                ;;
            0) break ;;
            *) shoes_print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

shoes_update_shoes() {
    local current_version latest_tag latest_version release_json backup_path

    clear
    shoes_require_commands || {
        shoes_pause_and_return
        return
    }
    shoes_load_current_config

    if [[ ! -x "$SHOES_EXEC_PATH" ]]; then
        shoes_print_err "未安装 shoes"
        shoes_pause_and_return
        return
    fi

    current_version="$(shoes_get_current_installed_version || true)"
    current_version="${current_version:-未知}"

    release_json="$(shoes_get_release_json)" || {
        shoes_print_err "获取 release 信息失败"
        shoes_pause_and_return
        return
    }
    latest_tag="$(printf '%s\n' "$release_json" | shoes_extract_tag_name)"
    latest_version="$(shoes_normalize_version "$latest_tag")"

    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}最新版本: ${YELLOW}${latest_version}${PLAIN}"

    if [[ "$(shoes_normalize_version "$current_version")" == "$latest_version" ]]; then
        shoes_print_ok "已是最新版本"
        shoes_pause_and_return
        return
    fi

    if ! shoes_ask_yes_no "是否更新" "n"; then
        return
    fi

    backup_path="$(mktemp "${TMPDIR:-/tmp}/shoes-backup.XXXXXX")" || {
        shoes_print_err "创建旧版本备份失败"
        shoes_pause_and_return
        return
    }
    if ! cp -f "$SHOES_EXEC_PATH" "$backup_path"; then
        rm -f "$backup_path"
        shoes_print_err "备份当前 shoes 内核失败"
        shoes_pause_and_return
        return
    fi

    systemctl stop "$SHOES_SERVICE_NAME" 2>/dev/null || true
    if shoes_install_binary_from_release; then
        if shoes_run_service_action_checked "start" "更新后启动失败"; then
            rm -f "$backup_path"
            shoes_print_ok "更新完成"
        else
            shoes_print_err "更新后启动失败，正在回滚旧版本"
            if install -m 755 "$backup_path" "$SHOES_EXEC_PATH" && shoes_run_service_action_checked "start" "回滚后启动失败"; then
                shoes_print_warn "已回滚到旧版本"
            else
                shoes_print_err "回滚失败"
            fi
            rm -f "$backup_path"
        fi
    else
        install -m 755 "$backup_path" "$SHOES_EXEC_PATH" >/dev/null 2>&1 || true
        rm -f "$backup_path"
        if ! shoes_run_service_action_checked "start" "恢复旧版本后启动失败"; then
            shoes_print_err "更新失败，且恢复后的服务未成功启动"
            shoes_pause_and_return
            return
        fi
        shoes_print_err "更新失败"
    fi
    shoes_pause_and_return
}

shoes_delete_shoes() {
    clear
    if ! shoes_ask_yes_no "确定删除 shoes 服务和配置" "n"; then
        return
    fi

    systemctl stop "$SHOES_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SHOES_SERVICE_NAME" 2>/dev/null || true
    rm -f "$SHOES_SERVICE_FILE"
    rm -f "$SHOES_EXEC_PATH"
    rm -rf "$SHOES_CONFIG_DIR"
    systemctl daemon-reload
    shoes_print_ok "已删除"
    shoes_pause_and_return
}

shoes_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Shoes_Ver.1.0 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

        case "$option" in
            1) shoes_install_shoes ;;
            2)
                if [[ ! -x "$SHOES_EXEC_PATH" ]]; then
                    shoes_print_err "未安装"
                    shoes_pause_and_return
                    continue
                fi
                shoes_manage_service
                ;;
            3) shoes_update_shoes ;;
            4) shoes_delete_shoes ;;
            0) return ;;
            *) shoes_print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

shoes_check_supported_os || exit 1
shoes_menu
