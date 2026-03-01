#!/bin/bash

set -euo pipefail

# ======== 全局变量 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

EXEC_PATH="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
SERVICE_NAME="hysteria"
SERVICE_FILE="/etc/systemd/system/hysteria.service"
PORT_JUMP_SERVICE="/etc/systemd/system/port-jump.service"

# ======== Root 权限检查 ========
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本${PLAIN}"
    exit 1
fi

# ======== 包管理器检测 ========
get_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_package() {
    local pkg="$1"
    local pkg_manager
    pkg_manager=$(get_pkg_manager)
    
    case "$pkg_manager" in
        apt)
            apt-get update -y && apt-get install -y "$pkg"
            ;;
        yum)
            yum install -y "$pkg"
            ;;
        dnf)
            dnf install -y "$pkg"
            ;;
        pacman)
            pacman -Sy --noconfirm "$pkg"
            ;;
        *)
            echo -e "${RED}无法识别的包管理器,请手动安装 $pkg${PLAIN}"
            return 1
            ;;
    esac
}

# ======== 通用函数 ========
pause_and_return() {
    read -rp "$(echo -e "${BLUE}按回车返回上一层...${PLAIN}")"
    clear
}

get_local_ip() {
    local ip
    ip=$(curl -s4 ip.sb 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        i386|i686) echo "386" ;;
        *) echo "$arch" ;;
    esac
}

random_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10
}

has_ipv4() {
    ip -4 addr show scope global 2>/dev/null | grep -q inet || return 1
}

get_latest_download_url() {
    local arch="$1"
    local api_url asset_name download_url

    if has_ipv4; then
        api_url="https://api.github.com/repos/apernet/hysteria/releases/latest"
    else
        api_url="https://hysteria-cdn.pages.dev/repos/apernet/hysteria/releases/latest"
    fi

    case "$arch" in
        amd64) asset_name="hysteria-linux-amd64" ;;
        arm64) asset_name="hysteria-linux-arm64" ;;
        armv7) asset_name="hysteria-linux-armv7" ;;
        386)   asset_name="hysteria-linux-386" ;;
        *) asset_name="hysteria-linux-$arch" ;;
    esac

    download_url=$(curl -s "$api_url" | grep "browser_download_url" | grep "$asset_name\"" | head -n 1 | cut -d '"' -f 4) || true

    if ! has_ipv4 && [ -n "$download_url" ]; then
        download_url=$(echo "$download_url" | sed 's#https://github.com/#https://hysteria-cdn2.pages.dev/#')
    fi

    echo "$download_url"
}

# ======== 申请证书 ========
cert_menu() {
    clear
    bash <(curl -sL https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/acme.sh) || true
}

# ======== 证书选择 ========

list_etc_certs() {
    cert_files=()
    if compgen -G "/etc/cert/*.crt" > /dev/null 2>&1; then
        mapfile -t cert_files < <(ls /etc/cert/*.crt 2>/dev/null | sort)
    fi
}

prompt_choose_cert_from_list() {
    while true; do
        list_etc_certs
        clear
        local cert_count=${#cert_files[@]}
        if (( cert_count == 0 )); then
            echo -e "${YELLOW}未检测到 /etc/cert 下任何证书文件${PLAIN}"
            echo -e "${YELLOW}请先使用证书配置功能申请证书${PLAIN}"
            sleep 1
            return 1
        fi

        echo -e "${BLUE}检测到以下证书: ${PLAIN}"
        for ((i=0; i<cert_count; i++)); do
            local idx=$((i+1))
            local crt_name
            crt_name=$(basename "${cert_files[$i]}")
            echo -e "${GREEN}${idx}.${PLAIN} ${crt_name}"
        done
        echo -e "${GREEN}0.${PLAIN} 返回上级"
        read -p "$(echo -e "${BLUE}请选择证书(1-${cert_count}): ${PLAIN}")" crt_idx

        if [[ "$crt_idx" == "0" ]]; then
            return 2
        fi

        if [[ "$crt_idx" =~ ^[0-9]+$ ]] && (( crt_idx >= 1 && crt_idx <= cert_count )); then
            local crtfile="${cert_files[$((crt_idx-1))]}"
            local domain_base
            domain_base=$(basename "$crtfile" .crt)
            local keyfile="/etc/cert/${domain_base}.key"
            if [[ -f "$keyfile" ]]; then
                cert_path="$crtfile"
                key_path="$keyfile"
                echo -e "${GREEN}已选择证书: $crtfile${PLAIN}"
                sleep 0.5
                return 0
            else
                echo -e "${RED}未找到对应私钥: $keyfile${PLAIN}"
                echo -e "${YELLOW}请确保证书和私钥文件名一致(如: domain.crt 和 domain.key)${PLAIN}"
                sleep 1
                continue
            fi
        else
            echo -e "${RED}请输入有效编号${PLAIN}"
            sleep 0.4
            continue
        fi
    done
}

prompt_custom_paths() {
    while true; do
        clear
        read -p "$(echo -e "${BLUE}请输入证书路径(输入0返回): ${PLAIN}")" cert_path_input
        if [[ "$cert_path_input" == "0" ]]; then
            return 2
        fi
        read -p "$(echo -e "${BLUE}请输入私钥路径: ${PLAIN}")" key_path_input
        if [[ "$key_path_input" == "0" ]]; then
            return 2
        fi

        cert_path="$cert_path_input"
        key_path="$key_path_input"

        if [[ -f "$cert_path" && -f "$key_path" ]]; then
            return 0
        else
            echo -e "${RED}证书或私钥路径无效!请重新输入或输入0返回${PLAIN}"
            sleep 0.4
            continue
        fi
    done
}

select_cert_for_hysteria_install() {
    while true; do
        clear
        echo -e "${BLUE}✦ Choice_Cert ✦ : ${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}扫描证书(/etc/cert)"
        echo -e "${GREEN}  2.${PLAIN}自定义路径"
        echo -e "${GREEN}  0.${PLAIN}退出返回"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" cert_option

        case "$cert_option" in
            1)
                prompt_choose_cert_from_list
                rc=$?
                if [[ $rc -eq 0 ]]; then
                    return 0
                elif [[ $rc -eq 2 ]]; then
                    continue
                else
                    continue
                fi
                ;;
            2)
                prompt_custom_paths
                rc=$?
                if [[ $rc -eq 0 ]]; then
                    return 0
                elif [[ $rc -eq 2 ]]; then
                    continue
                else
                    continue
                fi
                ;;
            0)
                return 1
                ;;
            *)
                echo -e "${RED}无效输入${PLAIN}"
                sleep 0.4
                continue
                ;;
        esac
    done
}

select_cert_for_hysteria_modify() {
    local old_cert="$1"
    local old_key="$2"

    while true; do
        clear
        echo -e "${BLUE}✦ Choice_Cert ✦ : ${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}扫描证书(/etc/cert)"
        echo -e "${GREEN}  2.${PLAIN}自定义路径"
        echo -e "${YELLOW}(回车保持原配置)${PLAIN}"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" cert_option

        if [[ -z "$cert_option" ]]; then
            cert_path="$old_cert"
            key_path="$old_key"
            return 0
        fi

        case "$cert_option" in
            1)
                prompt_choose_cert_from_list
                rc=$?
                if [[ $rc -eq 0 ]]; then
                    return 0
                else
                    continue
                fi
                ;;
            2)
                prompt_custom_paths
                rc=$?
                if [[ $rc -eq 0 ]]; then
                    return 0
                elif [[ $rc -eq 2 ]]; then
                    continue
                else
                    continue
                fi
                ;;
            *)
                echo -e "${RED}无效输入${PLAIN}"
                sleep 0.4
                continue
                ;;
        esac
    done
}

# ======== 显示配置 ========
show_hysteria_config() {
    clear
    if [ -f "$CONFIG_PATH" ]; then
        echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
        cat "$CONFIG_PATH"
        echo -e "${BLUE}-----------------------------------------------------${PLAIN}"
        local listen_port auth_password cert_file masquerade_domain subject sni_domain local_ip node_link
        listen_port=$(grep -E '^listen:' "$CONFIG_PATH" | awk '{print $2}' | sed 's/://') || true
        auth_password=$(grep -E '^\s*password:' "$CONFIG_PATH" | awk '{print $2}') || true
        cert_file=$(grep -E '^\s*cert:' "$CONFIG_PATH" | awk '{print $2}') || true
        masquerade_domain=$(grep -E '^\s*url:' "$CONFIG_PATH" | awk -F[/:] '{print $4}') || true
        subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null) || true
        sni_domain=$(echo "$subject" | grep -oE 'CN[ =]*[a-zA-Z0-9\.\-]+' | head -n1 | sed 's/CN[ =]*//') || true
        [ -z "$sni_domain" ] && sni_domain="$masquerade_domain"
        local_ip=$(get_local_ip)
        listen_port=${listen_port:-443}
        node_link="hysteria2://${auth_password}@${local_ip}:${listen_port}?insecure=1&sni=${sni_domain}&fastopen=1#Hysteria"
        echo -e "${BLUE}Hysteria 节点链接:${PLAIN}\n${GREEN}${node_link}${PLAIN}"
    else
        echo -e "${RED}未检测到配置文件:$CONFIG_PATH${PLAIN}"
    fi
    pause_and_return
}

# ======== 端口跳跃 ========
port_jump_set() {
    clear
    echo -e "${BLUE}检查 iptables/ip6tables 是否已安装...${PLAIN}"
    for bin in iptables ip6tables; do
        if ! command -v "$bin" &> /dev/null; then
            echo -e "${YELLOW}未检测到 $bin,正在安装中...${PLAIN}"
            install_package "$bin" || {
                echo -e "${RED}安装 $bin 失败,请手动安装后重试${PLAIN}"
                pause_and_return
                return 1
            }
        fi
    done

    local EXIST_RULE_V4 EXIST_RULE_V6
    EXIST_RULE_V4=$(iptables -t nat -S PREROUTING | grep -E 'REDIRECT --to-ports') || true
    EXIST_RULE_V6=$(ip6tables -t nat -S PREROUTING | grep -E 'REDIRECT --to-ports') || true

    if [[ -n "$EXIST_RULE_V4" ]] || [[ -n "$EXIST_RULE_V6" ]]; then
        echo -e "${GREEN}已检测到存在端口跳跃配置:${PLAIN}"
        [[ -n "$EXIST_RULE_V4" ]] && echo -e "${YELLOW}IPv4: $EXIST_RULE_V4${PLAIN}"
        [[ -n "$EXIST_RULE_V6" ]] && echo -e "${YELLOW}IPv6: $EXIST_RULE_V6${PLAIN}"
        pause_and_return
        return
    fi

    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    if [ -z "$interface" ]; then
        interface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)
    fi
    if [ -z "$interface" ]; then
        echo -e "${RED}未检测到有效的网卡,请检查网络配置${PLAIN}"
        pause_and_return
        return 1
    fi

    local user_interface
    read -p "$(echo -e "${YELLOW}请输入网卡名称(默认:$interface): ${PLAIN}")" user_interface
    user_interface=${user_interface:-$interface}

    local port_range
    read -p "$(echo -e "${YELLOW}请输入端口范围(默认18443:28444): ${PLAIN}")" port_range
    port_range=${port_range:-18443:28444}

    if ! [[ "$port_range" =~ ^[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}端口范围格式错误${PLAIN}"
        pause_and_return
        return 1
    fi

    local default_port="" cfg_port
    if [[ -f "$CONFIG_PATH" ]]; then
        cfg_port=$(grep -E '^listen:' "$CONFIG_PATH" | awk '{print $2}' | sed 's/^://') || true
        if [[ -n "$cfg_port" ]]; then
            default_port="$cfg_port"
        fi
    fi
    
    local target_port
    if [[ -n "$default_port" ]]; then
        read -p "$(echo -e "${YELLOW}请输入源端口(默认:${default_port}): ${PLAIN}")" target_port
        target_port=${target_port:-$default_port}
    else
        read -p "$(echo -e "${YELLOW}请输入源端口: ${PLAIN}")" target_port
        if [[ -z "$target_port" ]]; then
            echo -e "${RED}源端口不能为空${PLAIN}"
            pause_and_return
            return 1
        fi
    fi
    
    if ! [[ "$target_port" =~ ^[0-9]+$ ]] || (( target_port < 1 || target_port > 65535 )); then
        echo -e "${RED}无效的端口号,请输入1-65535之间的数字${PLAIN}"
        pause_and_return
        return 1
    fi

    echo -e "${BLUE}正在设置 IPv4 端口跳跃规则...${PLAIN}"
    if ! iptables -t nat -A PREROUTING -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port"; then
        echo -e "${RED}IPv4 端口跳跃规则设置失败${PLAIN}"
        pause_and_return
        return 1
    fi

    echo -e "${BLUE}正在设置 IPv6 端口跳跃规则...${PLAIN}"
    if ! ip6tables -t nat -A PREROUTING -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port"; then
        echo -e "${RED}IPv6 端口跳跃规则设置失败${PLAIN}"
        iptables -t nat -D PREROUTING -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null
        pause_and_return
        return 1
    fi

    echo -e "${BLUE}当前 iptables 规则:${PLAIN}"
    iptables -t nat -L -n
    echo -e "${BLUE}当前 ip6tables 规则:${PLAIN}"
    ip6tables -t nat -L -n

    local iptables_path ip6tables_path
    iptables_path=$(command -v iptables)
    ip6tables_path=$(command -v ip6tables)

    echo -e "${BLUE}创建 systemd 自启服务: port-jump.service${PLAIN}"
    tee "$PORT_JUMP_SERVICE" > /dev/null <<EOF
[Unit]
Description=UDP Port Jumping NAT Rule (IPv4/IPv6)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "${iptables_path} -t nat -C PREROUTING -i ${user_interface} -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port} 2>/dev/null || ${iptables_path} -t nat -A PREROUTING -i ${user_interface} -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port}; ${ip6tables_path} -t nat -C PREROUTING -i ${user_interface} -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port} 2>/dev/null || ${ip6tables_path} -t nat -A PREROUTING -i ${user_interface} -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port}"
ExecStop=/bin/bash -c "while ${iptables_path} -t nat -D PREROUTING -i ${user_interface} -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port} 2>/dev/null; do :; done; while ${ip6tables_path} -t nat -D PREROUTING -i ${user_interface} -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port} 2>/dev/null; do :; done"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable port-jump.service
    systemctl start port-jump.service

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null
    fi

    echo -e "${GREEN}IPv4/IPv6 端口跳跃规则已启用并设置为开机自动启动${PLAIN}"
    pause_and_return
}

port_jump_modify() {
    clear
    echo -e "${BLUE}正在清除旧规则...${PLAIN}"
    
    while iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'REDIRECT'; do
        iptables -t nat -D PREROUTING $(iptables -t nat -S PREROUTING | grep 'REDIRECT' | head -n1 | sed 's/-A PREROUTING//') 2>/dev/null || break
    done
    while ip6tables -t nat -S PREROUTING 2>/dev/null | grep -q 'REDIRECT'; do
        ip6tables -t nat -D PREROUTING $(ip6tables -t nat -S PREROUTING | grep 'REDIRECT' | head -n1 | sed 's/-A PREROUTING//') 2>/dev/null || break
    done
    
    systemctl stop port-jump.service 2>/dev/null || true
    systemctl disable port-jump.service 2>/dev/null || true
    rm -f "$PORT_JUMP_SERVICE"
    systemctl daemon-reload
    
    port_jump_set
}

port_jump_view() {
    clear
    echo -e "${BLUE}当前 iptables (IPv4) 端口跳跃规则: ${PLAIN}"
    iptables -t nat -L -n --line-numbers | grep REDIRECT || true
    echo -e "${BLUE}当前 ip6tables (IPv6) 端口跳跃规则: ${PLAIN}"
    ip6tables -t nat -L -n --line-numbers | grep REDIRECT || true
    echo -e "${BLUE}当前 systemd port-jump.service 配置: ${PLAIN}"
    if [ -f "$PORT_JUMP_SERVICE" ]; then
        cat "$PORT_JUMP_SERVICE"
    else
        echo -e "${YELLOW}未检测到 systemd 端口跳跃服务${PLAIN}"
    fi
    pause_and_return
}

port_jump_delete() {
    clear
    echo -e "${BLUE}正在删除端口跳跃规则...${PLAIN}"
    
    iptables -t nat -F PREROUTING 2>/dev/null || true
    ip6tables -t nat -F PREROUTING 2>/dev/null || true
    
    echo -e "${GREEN}已清空 PREROUTING 链所有规则${PLAIN}"
    
    if command -v netfilter-persistent &>/dev/null; then
        echo -e "${BLUE}正在更新 iptables-persistent 保存的规则...${PLAIN}"
        netfilter-persistent save 2>/dev/null
        echo -e "${GREEN}已更新持久化规则${PLAIN}"
    fi
    
    systemctl stop port-jump.service 2>/dev/null || true
    systemctl disable port-jump.service 2>/dev/null || true
    rm -f "$PORT_JUMP_SERVICE"
    systemctl daemon-reload
    
    echo -e "${GREEN}端口跳跃配置已删除${PLAIN}"
    pause_and_return
}

port_jump_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Ports_Jump ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}设置跳跃"
        echo -e "${GREEN}  2.${PLAIN}修改跳跃"
        echo -e "${GREEN}  3.${PLAIN}查看跳跃"
        echo -e "${GREEN}  4.${PLAIN}删除跳跃"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" pjopt
        
        local has_config=0
        if iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'REDIRECT' || \
           ip6tables -t nat -S PREROUTING 2>/dev/null | grep -q 'REDIRECT' || \
           [ -f "$PORT_JUMP_SERVICE" ]; then
            has_config=1
        fi
        
        case "$pjopt" in
            1) port_jump_set || true ;;
            2) 
                if [[ $has_config -eq 0 ]]; then
                    echo -e "${YELLOW}未配置端口跳跃,请先设置${PLAIN}"
                    sleep 1
                else
                    port_jump_modify
                fi
                ;;
            3) 
                if [[ $has_config -eq 0 ]]; then
                    echo -e "${YELLOW}未配置端口跳跃${PLAIN}"
                    sleep 1
                else
                    port_jump_view
                fi
                ;;
            4) 
                if [[ $has_config -eq 0 ]]; then
                    echo -e "${YELLOW}未配置端口跳跃${PLAIN}"
                    sleep 1
                else
                    port_jump_delete
                fi
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项,请重新输入${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

# ======== 生成 SOCKS5 出站配置 ========
append_socks5_outbound() {
    local socks5_addr socks5_port socks5_username socks5_password
    read -p "$(echo -e "${BLUE}请输入Socks地址(默认:127.0.0.1): ${PLAIN}")" socks5_addr
    socks5_addr=${socks5_addr:-127.0.0.1}
    read -p "$(echo -e "${BLUE}请输入Socks端口(默认:18443): ${PLAIN}")" socks5_port
    socks5_port=${socks5_port:-18443}
    read -p "$(echo -e "${BLUE}请输入Socks5用户名(若无则留空): ${PLAIN}")" socks5_username
    read -p "$(echo -e "${BLUE}请输入Socks5密码(若无则留空): ${PLAIN}")" socks5_password

    cat >> "$CONFIG_PATH" <<EOF2

outbounds:
  - name: mihomo
    type: socks5
    socks5:
      addr: ${socks5_addr}:${socks5_port}
      username: ${socks5_username}
      password: ${socks5_password}
EOF2
}

append_socks5_outbound_with_defaults() {
    local old_addr="$1"
    local old_port="$2"
    local old_user="$3"
    local old_pass="$4"

    local socks5_addr socks5_port socks5_username socks5_password
    read -p "$(echo -e "${BLUE}请输入Socks地址(原值:${old_addr:-127.0.0.1}): ${PLAIN}")" socks5_addr
    socks5_addr=${socks5_addr:-${old_addr:-127.0.0.1}}
    read -p "$(echo -e "${BLUE}请输入Socks端口(原值:${old_port:-18443}): ${PLAIN}")" socks5_port
    socks5_port=${socks5_port:-${old_port:-18443}}
    read -p "$(echo -e "${BLUE}请输入Socks用户名(原值:${old_user}): ${PLAIN}")" socks5_username
    socks5_username=${socks5_username:-$old_user}
    read -p "$(echo -e "${BLUE}请输入Socks密码(原值:${old_pass}): ${PLAIN}")" socks5_password
    socks5_password=${socks5_password:-$old_pass}

    cat >> "$CONFIG_PATH" <<EOF2

outbounds:
  - name: mihomo
    type: socks5
    socks5:
      addr: ${socks5_addr}:${socks5_port}
      username: ${socks5_username}
      password: ${socks5_password}
EOF2
}

# ======== 生成节点链接 ========
print_node_link() {
    local listen_port="$1"
    local auth_password="$2"
    local used_cert="$3"
    local masquerade_domain="$4"

    local local_ip subject sni_domain node_link
    local_ip=$(get_local_ip)
    subject=$(openssl x509 -in "$used_cert" -noout -subject 2>/dev/null) || true
    sni_domain=$(echo "$subject" | grep -oE 'CN[ =]*[a-zA-Z0-9\.\-]+' | head -n1 | sed 's/CN[ =]*//') || true
    [ -z "$sni_domain" ] && sni_domain="$masquerade_domain"
    listen_port=${listen_port:-443}
    node_link="hysteria2://${auth_password}@${local_ip}:${listen_port}?insecure=1&sni=${sni_domain}&fastopen=1#Hysteria"
    echo -e "\n${BLUE}Hysteria节点链接:${PLAIN}\n${GREEN}${node_link}${PLAIN}"
}

# ======== 安装 Hysteria ========
install_hysteria() {
    clear

    if [[ -f "$EXEC_PATH" && -f "$CONFIG_PATH" ]]; then
        echo -e "${YELLOW}检测到已安装且存在配置${PLAIN}"
        pause_and_return
        return
    fi

    mkdir -p "$CONFIG_DIR"

    local ARCH DOWNLOAD_URL
    ARCH=$(get_arch)
    echo -e "${BLUE}检测到系统架构: $ARCH${PLAIN}"
    DOWNLOAD_URL=$(get_latest_download_url "$ARCH")
    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}未找到适用于架构 $ARCH 的 Hysteria 内核,请手动安装${PLAIN}"
        pause_and_return
        return 1
    fi

    echo -e "${BLUE}正在下载最新版本的 Hysteria ($ARCH)...${PLAIN}"
    if ! wget -O "${EXEC_PATH}" "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败,请检查网络连接${PLAIN}"
        rm -f "${EXEC_PATH}"
        pause_and_return
        return 1
    fi

    if [ ! -s "$EXEC_PATH" ]; then
        echo -e "${RED}下载的文件为空,请检查网络或下载链接是否正确${PLAIN}"
        rm -f "${EXEC_PATH}"
        pause_and_return
        return 1
    fi

    chmod +x "$EXEC_PATH"
    echo -e "${GREEN}Hysteria 内核已成功下载并赋予执行权限${PLAIN}"

    clear
    if ! select_cert_for_hysteria_install; then
        echo -e "${YELLOW}证书未选择,安装中止${PLAIN}"
        pause_and_return
        return
    fi

    local listen_port error_msg=""
    while true; do
        clear
        echo -e "${BLUE}请输入Hysteria服务配置参数:${PLAIN}"
        if [[ -n "$error_msg" ]]; then
            echo -e "${RED}${error_msg}${PLAIN}"
        fi
        read -p "$(echo -e "${BLUE}请输入监听端口(默认:443): ${PLAIN}")" listen_port
        listen_port=${listen_port:-443}
        if [[ "$listen_port" =~ ^[0-9]+$ ]] && ((listen_port >= 1 && listen_port <= 65535)); then
            break
        else
            error_msg="端口必须为1-65535的数字！"
        fi
    done

    local auth_password
    read -p "$(echo -e "${BLUE}请输入密码(回车随机生成): ${PLAIN}")" auth_password
    if [ -z "$auth_password" ]; then
        auth_password=$(random_pass)
        echo -e "${GREEN}已自动生成密码: $auth_password${PLAIN}"
    fi

    local masquerade_domain masquerade_url
    read -p "$(echo -e "${BLUE}请输入伪装URL域名(默认:www.bing.com): ${PLAIN}")" masquerade_domain
    masquerade_domain=${masquerade_domain:-www.bing.com}
    masquerade_url="https://${masquerade_domain}"

    cat > "$CONFIG_PATH" <<EOF
listen: :${listen_port}

tls:
  cert: ${cert_path}
  key: ${key_path}

auth:
  type: password
  password: ${auth_password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}
    rewriteHost: true
EOF

    local enable_outbounds
    echo -e "${BLUE}是否添加 SOCKS5 出站${PLAIN}"
    read -p "$(echo -e "${BLUE}添加y,不添加n(默认:n) [y/n]: ${PLAIN}")" enable_outbounds
    enable_outbounds=${enable_outbounds:-n}

    if [[ "$enable_outbounds" == "y" || "$enable_outbounds" == "Y" ]]; then
        append_socks5_outbound
    fi

    clear
    echo -e "${BLUE}正在创建 systemd 服务单元文件...${PLAIN}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria Server Service
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
User=root
Group=root
Restart=always
Environment=PATH=/usr/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria.service
    systemctl start hysteria.service

    echo -e "${BLUE}Hysteria 服务启动状态: ${PLAIN}"
    systemctl status --no-pager hysteria.service
    echo -e "${GREEN}已成功设置 Hysteria 开机自启并启动服务!${PLAIN}"

    print_node_link "$listen_port" "$auth_password" "$cert_path" "$masquerade_domain"
    pause_and_return
}

# ======== 修改配置 ========
modify_hysteria() {
    clear
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}未检测到配置文件:$CONFIG_PATH${PLAIN}"
        pause_and_return
        return
    fi

    local old_listen old_cert old_key old_password old_url old_url_domain
    old_listen=$(grep -E '^listen:' "$CONFIG_PATH" | head -n1 | awk '{print $2}' | sed 's/://') || true
    old_cert=$(grep -E '^\s*cert:' "$CONFIG_PATH" | head -n1 | awk '{print $2}') || true
    old_key=$(grep -E '^\s*key:' "$CONFIG_PATH" | head -n1 | awk '{print $2}') || true
    old_password=$(grep -E '^\s*password:' "$CONFIG_PATH" | head -n1 | awk '{print $2}') || true
    old_url=$(grep -E '^\s*url:' "$CONFIG_PATH" | head -n1 | awk '{print $2}') || true
    old_url_domain=$(echo "$old_url" | sed -E 's#https?://([^/]+).*#\1#')

    local old_socks5_addr old_socks5_port old_socks5_username old_socks5_password default_outbounds
    old_socks5_addr=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'addr:' | awk '{print $2}' | head -n1 | cut -d: -f1) || true
    old_socks5_port=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'addr:' | awk '{print $2}' | head -n1 | cut -d: -f2) || true
    old_socks5_username=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'username:' | awk '{print $2}' | head -n1) || true
    old_socks5_password=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'password:' | awk '{print $2}' | head -n1) || true

    if [[ -n "$old_socks5_addr" ]]; then
        default_outbounds="y"
    else
        default_outbounds="n"
    fi

    local listen_port error_msg=""
    while true; do
        clear
        echo -e "${BLUE}请输配置参数(回车不变):${PLAIN}"
        if [[ -n "$error_msg" ]]; then
            echo -e "${RED}${error_msg}${PLAIN}"
        fi
        read -p "$(echo -e "${BLUE}请输入监听端口(原值: ${old_listen:-443}): ${PLAIN}")" listen_port
        listen_port=${listen_port:-$old_listen}
        listen_port=${listen_port:-443}
        if [[ "$listen_port" =~ ^[0-9]+$ ]] && ((listen_port >= 1 && listen_port <= 65535)); then
            break
        else
            error_msg="端口必须为1-65535的数字!"
        fi
    done

    local cert_path_new key_path_new
    echo -e "${BLUE}请选择新的证书及私钥:${PLAIN}"
    if select_cert_for_hysteria_modify "$old_cert" "$old_key"; then
        cert_path_new="$cert_path"
        key_path_new="$key_path"
    else
        cert_path_new="$old_cert"
        key_path_new="$old_key"
    fi

    local auth_password
    read -p "$(echo -e "${BLUE}请输入认证密码(原值: ${old_password}): ${PLAIN}")" auth_password
    if [ -z "$auth_password" ]; then
        if [ -n "$old_password" ]; then
            auth_password="$old_password"
        else
            auth_password=$(random_pass)
            echo -e "${GREEN}已自动生成认证密码:$auth_password${PLAIN}"
        fi
    fi

    local masquerade_domain masquerade_url
    read -p "$(echo -e "${BLUE}请输入伪装URL的域名(原值: ${old_url_domain:-www.bing.com}): ${PLAIN}")" masquerade_domain
    masquerade_domain=${masquerade_domain:-$old_url_domain}
    masquerade_domain=${masquerade_domain:-www.bing.com}
    masquerade_url="https://${masquerade_domain}"

    cat > "$CONFIG_PATH" <<EOF
listen: :${listen_port}

tls:
  cert: ${cert_path_new}
  key: ${key_path_new}

auth:
  type: password
  password: ${auth_password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}
    rewriteHost: true
EOF

    local enable_outbounds
    echo -e "${BLUE}是否添加 SOCKS5 出站配置${PLAIN}"
    read -p "$(echo -e "${BLUE}添加y,不添加 n [y/n](原值:${default_outbounds}): ${PLAIN}")" enable_outbounds
    enable_outbounds=${enable_outbounds:-$default_outbounds}

    if [[ "$enable_outbounds" == "y" || "$enable_outbounds" == "Y" ]]; then
        append_socks5_outbound_with_defaults "$old_socks5_addr" "$old_socks5_port" "$old_socks5_username" "$old_socks5_password"
    fi

    clear
    echo -e "${GREEN}新配置已保存,将重启 Hysteria 服务...${PLAIN}"
    systemctl restart "$SERVICE_NAME" || true
    systemctl status --no-pager "$SERVICE_NAME" || true
    pause_and_return
}

# ======== 更新内核 ========
update_hysteria() {
    clear
    echo -e "${BLUE}正在更新 Hysteria 内核...${PLAIN}"
    echo -e "${BLUE}先停止 Hysteria 服务...${PLAIN}"
    systemctl stop "$SERVICE_NAME" || true

    local ARCH DOWNLOAD_URL
    ARCH=$(get_arch)
    echo -e "${BLUE}检测到系统架构: $ARCH${PLAIN}"
    DOWNLOAD_URL=$(get_latest_download_url "$ARCH")
    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}未找到适用于架构 $ARCH 的 Hysteria 内核,请手动安装${PLAIN}"
        systemctl start "$SERVICE_NAME"
        pause_and_return
        return
    fi

    if ! wget -O "$EXEC_PATH" "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败,请检查网络连接${PLAIN}"
        rm -f "$EXEC_PATH"
        systemctl start "$SERVICE_NAME"
        pause_and_return
        return
    fi

    if [ ! -s "$EXEC_PATH" ]; then
        echo -e "${RED}下载的文件为空${PLAIN}"
        rm -f "$EXEC_PATH"
        systemctl start "$SERVICE_NAME"
        pause_and_return
        return
    fi

    chmod +x "$EXEC_PATH"
    echo -e "${GREEN}内核已更新,重启服务中...${PLAIN}"
    systemctl daemon-reload
    systemctl start "$SERVICE_NAME"
    pause_and_return
}

# ======== 删除服务 ========
delete_hysteria() {
    clear
    read -rp "$(echo -e "${RED}确定要删除 Hysteria 及其相关配置? [y/N]: ${PLAIN}")" confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}操作已取消${PLAIN}"
        pause_and_return
        return
    fi

    echo -e "${BLUE}正在删除 Hysteria 相关资源...${PLAIN}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$EXEC_PATH"
    rm -rf "$CONFIG_DIR"

    if [ -f "$PORT_JUMP_SERVICE" ]; then
        systemctl stop port-jump.service 2>/dev/null || true
        systemctl disable port-jump.service 2>/dev/null || true
        rm -f "$PORT_JUMP_SERVICE"
    fi

    systemctl daemon-reload
    echo -e "${GREEN}Hysteria 及相关资源已删除${PLAIN}"
    pause_and_return
}

# ======== 管理服务 ========
manage_hysteria() {
    if [[ ! -f "$EXEC_PATH" || ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}未检测到配置及执行文件,请先安装并配置!${PLAIN}"
        pause_and_return
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}✦ Hysteria_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}停止服务"
        echo -e "${GREEN}  3.${PLAIN}重启服务"
        echo -e "${GREEN}  4.${PLAIN}修改配置"
        echo -e "${GREEN}  5.${PLAIN}更新内核"
        echo -e "${GREEN}  6.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" ACTION

        case "$ACTION" in
            1)
                clear
                echo -e "${BLUE}Hysteria 服务当前状态: ${PLAIN}"
                systemctl status --no-pager hysteria || true
                read -p "$(echo -e "${BLUE}按回车查看配置...${PLAIN}")"
                clear
                show_hysteria_config
                ;;
            2)
                clear
                echo -e "${BLUE}正在停止 Hysteria 服务...${PLAIN}"
                systemctl stop "$SERVICE_NAME" || true
                echo -e "${GREEN}已停止${PLAIN}"
                systemctl status --no-pager "$SERVICE_NAME" || true
                pause_and_return
                ;;
            3)
                clear
                echo -e "${BLUE}正在重启 Hysteria 服务...${PLAIN}"
                systemctl restart "$SERVICE_NAME" || true
                echo -e "${GREEN}已重启${PLAIN}"
                systemctl status --no-pager "$SERVICE_NAME" || true
                pause_and_return
                ;;
            4)
                modify_hysteria || true
                ;;
            5)
                update_hysteria || true
                ;;
            6)
                delete_hysteria || true
                break
                ;;
            0)
                clear
                break
                ;;
            *)
                echo -e "${RED}无效选项,重新输入${PLAIN}"
                pause_and_return
                ;;
        esac
    done
}

# ======== 主菜单 ========
while true; do
    clear
    echo -e "${BLUE}✦ Hysteria_Ver.1.7 ✦${PLAIN}"
    echo -e "${GREEN}  1.${PLAIN}证书配置"
    echo -e "${GREEN}  2.${PLAIN}安装服务"
    echo -e "${GREEN}  3.${PLAIN}管理服务"
    echo -e "${GREEN}  4.${PLAIN}端口跳跃"
    echo -e "${GREEN}  0.${PLAIN}退出脚本"
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

    case "$option" in
        1) cert_menu || true ;;
        2) install_hysteria || true ;;
        3) manage_hysteria || true ;;
        4) port_jump_menu || true ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入,重新输入${PLAIN}"; pause_and_return ;;
    esac
done
