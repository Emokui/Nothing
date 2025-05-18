#!/bin/bash

set -euo pipefail

# ========== 颜色与输出 ==========
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
BOLD="\033[1m"
RESET="\033[0m"

print_red()    { echo -e "${RED}$*${RESET}"; }
print_green()  { echo -e "${GREEN}$*${RESET}"; }
print_yellow() { echo -e "${YELLOW}$*${RESET}"; }
print_blue()   { echo -e "${BLUE}$*${RESET}"; }
print_bold()   { echo -e "${BOLD}$*${RESET}"; }
print_separator() { echo -e "${BLUE}----------------------------------------${RESET}"; }

cls() { command -v clear >/dev/null 2>&1 && clear || printf "\n%.0s" {1..10}; }

# ========== 依赖检测与安装 ==========
DEPENDENCIES=(curl jq awk base64 wireguard-tools)
POSSIBLE_HEX=(xxd hexdump od)
INSTALL_MISSING_DEPS=()
DEPS_CHECKED=0

check_and_install_deps() {
    [[ "$DEPS_CHECKED" -eq 1 ]] && return
    DEPS_CHECKED=1
    for dep in "${DEPENDENCIES[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || INSTALL_MISSING_DEPS+=("$dep")
    done
    command -v wg >/dev/null 2>&1 || INSTALL_MISSING_DEPS+=("wireguard-tools")
    HEX_OK=false
    for hexdep in "${POSSIBLE_HEX[@]}"; do
        if command -v "$hexdep" >/dev/null 2>&1; then HEX_OK=true; break; fi
    done
    $HEX_OK || INSTALL_MISSING_DEPS+=("xxd")
    ((${#INSTALL_MISSING_DEPS[@]} > 0)) && install_deps "${INSTALL_MISSING_DEPS[@]}"
}

install_deps() {
    local deps=("$@")
    if command -v apt >/dev/null 2>&1; then
        sudo apt update >/dev/null 2>&1
        sudo apt install -y "${deps[@]}" >/dev/null 2>&1
    else
        print_red "仅支持 Debian/Ubuntu（apt），请手动安装依赖：${deps[*]}"
        exit 1
    fi
}

# ========== 全局配置 ==========
WG_DIR="${HOME}/warp"
FREE_CONF="${WG_DIR}/warp_free.conf"
TEAM_CONF="${WG_DIR}/warp_team.conf"
mkdir -p "$WG_DIR"
BASE_URL='https://api.cloudflareclient.com/v0a2483'

# ========== 工具函数 ==========
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

strip_port() { IFS= read -r str; printf '%s' "${str%:*}"; }

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

# ========== 配置输出 ==========
output_config() {
    reg="$1"
    wg_private_key="$2"
    wg_public_key="$3"
    out_file="$4"

    peer_public_key=$(printf %s "${reg}" | jq -r '.config.peers[0].public_key')
    endpoint_host=$(printf %s "${reg}" | jq -r '.config.peers[0].endpoint.host' | strip_port)":2408"
    endpoint_ipv4=$(printf %s "${reg}" | jq -r '.config.peers[0].endpoint.v4' | strip_port)":2408"
    endpoint_ipv6=$(printf %s "${reg}" | jq -r '.config.peers[0].endpoint.v6' | strip_port)":2408"
    address_ipv4=$(printf %s "${reg}" | jq -r '.config.interface.addresses.v4')
    address_ipv6=$(printf %s "${reg}" | jq -r '.config.interface.addresses.v6')
    [ -n "$address_ipv4" ] && address_ipv4="${address_ipv4}/32"
    [ -n "$address_ipv6" ] && address_ipv6="${address_ipv6}/128"

    client_id_b64=$(printf %s "${reg}" | jq -r '.config.peers[0].client_id // .config.peers[0].reserved // .config.client_id // ""')
    if [ -n "$client_id_b64" ]; then
        client_id_hex=$(printf %s "${client_id_b64}" | base64 -d 2>/dev/null | clientid_to_hex)
    else
        client_id_hex=""
    fi
    if [ -n "$client_id_hex" ]; then
        client_id_dec=$(printf '%s\n' "${client_id_hex}" | while read -r hex; do
            [ -n "$hex" ] && printf "%d," "0x${hex}"
        done)
        client_id_dec="[${client_id_dec%,}]"
    else
        client_id_dec="[N/A]"
    fi

    cat > "$out_file" <<-EOF
[Interface]
PrivateKey = ${wg_private_key}
PublicKey = ${wg_public_key}
Address = ${address_ipv4}, ${address_ipv6}
DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
MTU = 1280

CFClientIdDec = ${client_id_dec}

[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
Endpoint = ${endpoint_ipv4}
Endpoint = ${endpoint_ipv6}
Endpoint = ${endpoint_host}
EOF

    # 精简输出
    echo
    print_bold "[*] 精简配置内容如下："
    echo "[Interface]"
    echo "PrivateKey = ${wg_private_key}"
    echo "Address = ${address_ipv4}, ${address_ipv6}"
    echo "DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001"
    echo "MTU = 1280"
    echo "CFClientIdDec = ${client_id_dec}"
    echo "[Peer]"
    echo "PublicKey = ${peer_public_key}"
    echo "PersistentKeepalive = 25"
    echo "Endpoint = ${endpoint_ipv4}"
    echo "Endpoint = ${endpoint_ipv6}"
    echo "Endpoint = ${endpoint_host}"
}

# ========== 业务逻辑 ==========
generate_free_account_config() {
    print_separator
    print_bold "[*] 生成免费账户 WireGuard 配置"
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
    device_name=""
    model_name="rany2/warp.sh"
    wg_private_key="$(wg genkey)"
    wg_public_key="$(printf %s "${wg_private_key}" | wg pubkey)"
    print_blue "正在请求 Cloudflare API ..."
    reg=""
    api_error=0
    reg=$(cfcurl --header 'Content-Type: application/json' --request "POST" \
        --header "CF-Access-Jwt-Assertion: ${teams_token}" \
        --data '{"key":"'"${wg_public_key}"'","install_id":"","fcm_token":"","model":"'"${model_name}"'","serial_number":"","name":"'"${device_name}"'","locale":"en_US"}' \
        "${BASE_URL}/reg" 2>&1) || api_error=1
    if [[ $api_error -ne 0 ]] || [[ -z "$reg" ]] || echo "$reg" | grep -q "error"; then
        print_red "团队 Token 无效或 Cloudflare API 请求失败，请检查 Token 后重试。"
        sleep 2
        return
    fi
    output_config "$reg" "$wg_private_key" "$wg_public_key" "$TEAM_CONF"
    print_green "[*] 配置已保存至 $TEAM_CONF"
}

show_current_config() {
    while true; do
        cls
        print_separator
        print_bold "[*] 查看当前 WireGuard 配置"
        print_separator
        echo -e "${YELLOW}${BOLD}1.${RESET} ${GREEN}查看免费账户配置${RESET}"
        echo -e "${YELLOW}${BOLD}2.${RESET} ${BLUE}查看团队账户配置${RESET}"
        echo -e "${YELLOW}${BOLD}0.${RESET} 返回主菜单"
        print_separator
        printf "${BOLD}请选择要查看的配置 [0-2]: ${RESET}"
        read -r sub_choice
        case "$sub_choice" in
            1)
                if [ -f "$FREE_CONF" ]; then
                    print_separator
                    print_green "免费账户配置内容如下："
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
                    print_blue "团队账户配置内容如下："
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

delete_all() {
    cls
    print_separator
    print_red "[*] 警告：将删除warp文件夹及所有相关配置，并卸载依赖！"
    print_red "    此操作不可逆，请确认！"
    print_separator
    printf "${BOLD}确定要继续吗？(yes/no): ${RESET}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
        print_red "正在删除 ${WG_DIR} ..."
        rm -rf "${WG_DIR}"
        print_red "正在卸载依赖 ..."
        if command -v apt >/dev/null 2>&1; then
            sudo apt remove --purge -y jq awk base64 wireguard-tools xxd hexdump od
            sudo apt autoremove -y
        fi
        print_green "所有配置和依赖已删除！"
        print_yellow "按回车键退出..."
        read -r
        exit 0
    else
        print_yellow "操作已取消。"
        sleep 1
    fi
}

# ========== 主菜单 ==========
main_menu() {
    while true; do
        cls
        print_separator
        print_bold "${GREEN}Cloudflare WARP WireGuard 管理脚本${RESET}"
        print_separator
        echo -e "${YELLOW}${BOLD}1.${RESET} ${BLUE}生成免费账户配置${RESET}"
        echo -e "${YELLOW}${BOLD}2.${RESET} ${BLUE}获取团队账户配置${RESET}"
        echo -e "${YELLOW}${BOLD}3.${RESET} ${BLUE}查看当前配置${RESET}"
        echo -e "${YELLOW}${BOLD}4.${RESET} ${RED}删除所有配置及依赖${RESET}"
        echo -e "${YELLOW}${BOLD}0.${RESET} ${GREEN}退出${RESET}"
        print_separator
        printf "${BOLD}请输入选项 [0-4]: ${RESET}"
        read -r choice
        case "$choice" in
            1) check_and_install_deps; safe_call generate_free_account_config ;;
            2) check_and_install_deps; safe_call generate_team_account_config ;;
            3) safe_call show_current_config ;;
            4) safe_call delete_all ;;
            0) print_green "Bye!"; exit 0 ;;
            *) print_red "无效选项，请重新输入！"; sleep 1 ;;
        esac
        print_yellow "按回车键返回主菜单..."
        read -r
    done
}

# ========== 主菜单自动恢复 ==========
safe_call() {
    trap '' SIGINT
    "$@" || print_red "操作异常，中断或发生错误，已自动返回主菜单。"
    trap - SIGINT
}

# ========== 启动入口 ==========
check_and_install_deps
main_menu
