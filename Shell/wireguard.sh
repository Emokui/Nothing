#!/bin/bash

set -euo pipefail

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

# 清屏函数
cls() {
    command -v clear >/dev/null 2>&1 && clear || printf "\n%.0s" {1..10}
}

# 彩色打印
print_red()    { echo -e "${RED}$*${RESET}"; }
print_green()  { echo -e "${GREEN}$*${RESET}"; }
print_yellow() { echo -e "${YELLOW}$*${RESET}"; }
print_blue()   { echo -e "${BLUE}$*${RESET}"; }
print_bold()   { echo -e "${BOLD}$*${RESET}"; }

# 分割线
print_separator() {
    echo -e "${BLUE}----------------------------------------${RESET}"
}

# 依赖检查与安装
DEPENDENCIES=(curl jq awk base64 wireguard-tools)
POSSIBLE_HEX=(xxd hexdump od)
INSTALL_MISSING_DEPS=()

check_and_install_deps() {
    print_blue "[*] 检查依赖..."
    for dep in "${DEPENDENCIES[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            INSTALL_MISSING_DEPS+=("$dep")
        fi
    done
    # wg 命令检查（兼容性安全兜底）
    if ! command -v wg >/dev/null 2>&1; then
        INSTALL_MISSING_DEPS+=("wireguard-tools")
    fi
    # HEX 工具检测
    HEX_OK=false
    for hexdep in "${POSSIBLE_HEX[@]}"; do
        if command -v "$hexdep" >/dev/null 2>&1; then
            HEX_OK=true
            break
        fi
    done
    if ! $HEX_OK; then
        INSTALL_MISSING_DEPS+=("xxd")
    fi
    if ((${#INSTALL_MISSING_DEPS[@]} > 0)); then
        print_yellow "[*] 检测到缺少依赖: ${INSTALL_MISSING_DEPS[*]}"
        install_deps "${INSTALL_MISSING_DEPS[@]}"
    fi
}

install_deps() {
    local deps=("$@")
    print_blue "[*] 正在尝试自动安装缺失组件..."
    if command -v apt >/dev/null 2>&1; then
        # wireguard-tools、xxd 都有官方包
        sudo apt update
        if ! sudo apt install -y "${deps[@]}"; then
            print_red "依赖安装失败，脚本退出。"
            exit 1
        fi
    else
        print_red "仅支持 Debian/Ubuntu（apt），请手动安装依赖：${deps[*]}"
        exit 1
    fi
}

# 配置目录与常量
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WG_DIR="${BASE_DIR}/WireGuard"
FREE_CONF="${WG_DIR}/warp_free.conf"
TEAM_CONF="${WG_DIR}/warp_team.conf"
mkdir -p "$WG_DIR"
BASE_URL='https://api.cloudflareclient.com/v0a2483'

# 工具函数
cfcurl() {
    curl \
        --header 'User-Agent: 1.1.1.1/6.81' \
        --header 'CF-Client-Version: a-6.81-2410012252.0' \
        --header 'Accept: application/json; charset=UTF-8' \
        --tls-max 1.2 \
        --ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-CCM:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256' \
        --disable \
        --silent \
        --show-error \
        --fail \
        "$@"
}

strip_port() {
    IFS= read -r str
    printf '%s' "${str%:*}"
}

clientid_to_hex() {
    if command -v xxd >/dev/null 2>&1; then
        xxd -p -c 1
    elif command -v hexdump >/dev/null 2>&1; then
        hexdump -v -e '/1 "%02x\n"'
    elif command -v od >/dev/null 2>&1; then
        od -An -v -t x1 -w1 | awk '{$1=$1; print}'
    else
        print_red "Error: No suitable command found to convert client ID to hex."
        exit 1
    fi
}

# 主菜单
main_menu() {
    while true; do
        cls
        print_separator
        print_bold "${GREEN}Cloudflare WARP WireGuard 管理脚本${RESET}"
        print_separator
        echo -e "${YELLOW} 1)${RESET} 生成${GREEN}免费账户${RESET}配置（${FREE_CONF}）"
        echo -e "${YELLOW} 2)${RESET} 获取${BLUE}团队账户${RESET}配置（${TEAM_CONF}）"
        echo -e "${YELLOW} 3)${RESET} 查看${GREEN}当前配置${RESET}"
        echo -e "${YELLOW} 0)${RESET} 退出"
        print_separator
        printf "${BOLD}请输入选项 [0-3]: ${RESET}"
        read -r choice
        case "$choice" in
            1) generate_free_account_config ;;
            2) generate_team_account_config ;;
            3) show_current_config ;;
            0) print_green "Bye!"; exit 0 ;;
            *) print_red "无效选项，请重新输入！"; sleep 1 ;;
        esac
        print_yellow "按回车键返回主菜单..."
        read -r
    done
}

# 选项功能
generate_free_account_config() {
    print_separator
    print_bold "[*] 生成免费账户 WireGuard 配置"
    # 自动设定设备名和模型名
    device_name=""
    model_name="rany2/warp.sh"
    wg_private_key="$(wg genkey)"
    wg_public_key="$(printf %s "${wg_private_key}" | wg pubkey)"
    print_blue "正在请求 Cloudflare API ..."
    reg="$(cfcurl --header 'Content-Type: application/json' --request "POST" \
        --data '{"key":"'"${wg_public_key}"'","install_id":"","fcm_token":"","model":"'"${model_name}"'","serial_number":"","name":"'"${device_name}"'","locale":"en_US"}' \
        "${BASE_URL}/reg")"
    output_config "$reg" "$wg_private_key" "$wg_public_key" "$FREE_CONF"
    print_green "[*] 配置已保存至 $FREE_CONF"
}

generate_team_account_config() {
    print_separator
    print_bold "[*] 生成团队账户 WireGuard 配置"
    printf "${BOLD}请输入团队 JWT Token:${RESET} "
    read -r teams_token
    # 自动设定设备名和模型名
    device_name=""
    model_name="rany2/warp.sh"
    wg_private_key="$(wg genkey)"
    wg_public_key="$(printf %s "${wg_private_key}" | wg pubkey)"
    print_blue "正在请求 Cloudflare API ..."
    reg="$(cfcurl --header 'Content-Type: application/json' --request "POST" \
        --header 'CF-Access-Jwt-Assertion: '"${teams_token}" \
        --data '{"key":"'"${wg_public_key}"'","install_id":"","fcm_token":"","model":"'"${model_name}"'","serial_number":"","name":"'"${device_name}"'","locale":"en_US"}' \
        "${BASE_URL}/reg")"
    output_config "$reg" "$wg_private_key" "$wg_public_key" "$TEAM_CONF"
    print_green "[*] 配置已保存至 $TEAM_CONF"
}

show_current_config() {
    while true; do
        cls
        print_separator
        print_bold "[*] 查看当前 WireGuard 配置"
        print_separator
        echo -e "${YELLOW} 1)${RESET} 查看${GREEN}免费账户${RESET}配置（${FREE_CONF}）"
        echo -e "${YELLOW} 2)${RESET} 查看${BLUE}团队账户${RESET}配置（${TEAM_CONF}）"
        echo -e "${YELLOW} 0)${RESET} 返回主菜单"
        print_separator
        printf "${BOLD}请选择要查看的配置 [0-2]: ${RESET}"
        read -r sub_choice
        case "$sub_choice" in
            1)
                if [ -f "$FREE_CONF" ]; then
                    print_separator
                    print_green "免费账户配置($FREE_CONF):"
                    print_separator
                    cat "$FREE_CONF"
                    print_separator
                else
                    print_yellow "未找到免费账户配置文件。"
                fi
                print_yellow "按回车键返回..."
                read -r
                ;;
            2)
                if [ -f "$TEAM_CONF" ]; then
                    print_separator
                    print_blue "团队账户配置($TEAM_CONF):"
                    print_separator
                    cat "$TEAM_CONF"
                    print_separator
                else
                    print_yellow "未找到团队账户配置文件。"
                fi
                print_yellow "按回车键返回..."
                read -r
                ;;
            0)
                break
                ;;
            *)
                print_red "无效选项，请重新输入！"
                sleep 1
                ;;
        esac
    done
}

output_config() {
    reg="$1"
    wg_private_key="$2"
    wg_public_key="$3"
    out_file="$4"

    wg_config=$(printf %s "${reg}" | jq -r '
.config as $c |
$c.peers[0].public_key + "\n" +
$c.peers[0].endpoint.host + "\n" +
$c.peers[0].endpoint.v4 + "\n" +
$c.peers[0].endpoint.v6 + "\n" +
$c.peers[0].interface.addresses.v4 + "\n" +
$c.peers[0].interface.addresses.v6 + "\n" +
($c.peers[0].client_id // $c.peers[0].reserved // $c.client_id // "")
')
    endpoint_port=2408
    peer_public_key=$(printf %s "${wg_config}" | awk 'NR==1')
    endpoint_host=$(printf %s "${wg_config}" | awk 'NR==2' | strip_port)":${endpoint_port}"
    endpoint_ipv4=$(printf %s "${wg_config}" | awk 'NR==3' | strip_port)":${endpoint_port}"
    endpoint_ipv6=$(printf %s "${wg_config}" | awk 'NR==4' | strip_port)":${endpoint_port}"
    address_ipv4=$(printf %s "${wg_config}" | awk 'NR==5')
    address_ipv6=$(printf %s "${wg_config}" | awk 'NR==6')
    client_id_b64=$(printf %s "${wg_config}" | awk 'NR==7')
    if [ -n "$client_id_b64" ]; then
        client_id_hex=$(printf %s "${client_id_b64}" | base64 -d 2>/dev/null | clientid_to_hex)
    else
        client_id_hex=""
    fi
    if [ -n "$client_id_hex" ]; then
        client_id_dec=$(printf '%s\n' "${client_id_hex}" | while read -r hex; do
            [ -n "$hex" ] && printf "%d, " "0x${hex}"
        done)
        client_id_dec="[${client_id_dec%, }]"
        client_id_hex_full=$(printf %s "${client_id_hex}" | awk 'BEGIN { ORS=""; print "0x" } { print }')
    else
        client_id_dec="[N/A]"
        client_id_hex_full="N/A"
    fi

    cf_creds=$(printf %s "${reg}" | jq -r '
        .id+"\n"+
        .account.id+"\n"+
        .account.license+"\n"+
        .token
    ')
    device_id=$(printf %s "${cf_creds}" | awk 'NR==1')
    account_id=$(printf %s "${cf_creds}" | awk 'NR==2')
    account_license=$(printf %s "${cf_creds}" | awk 'NR==3')
    [ -z "${account_license}" ] && account_license="Unknown"
    token=$(printf %s "${cf_creds}" | awk 'NR==4')
    cat > "$out_file" <<-EOF
[Interface]
PrivateKey = ${wg_private_key}
#PublicKey = ${wg_public_key}
Address = ${address_ipv4}, ${address_ipv6}
DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
MTU = 1280

# To refresh the config, 请重新生成配置

# Cloudflare Warp specific variables
#CFDeviceId = ${device_id}
#CFAccountId = ${account_id}
#CFAccountLicense = ${account_license}
#CFToken = ${token}
#CFClientIdB64 = ${client_id_b64}
#CFClientIdHex = ${client_id_hex_full}
#CFClientIdDec = ${client_id_dec}

[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
Endpoint = ${endpoint_ipv4}
#Endpoint = ${endpoint_ipv6}
#Endpoint = ${endpoint_host}
EOF
}

# 主体逻辑
check_and_install_deps
main_menu
