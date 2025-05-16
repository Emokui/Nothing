#!/bin/bash

# 彩色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
PLAIN='\033[0m'
BOLD="\033[1m"

pause_and_return() {
    echo ""
    read -p "$(echo -e "${BLUE}请按回车键返回上一层...${PLAIN}")" temp
    clear
}

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "======================================"
    echo "        凤凰院凶真 - Trojan-Go"
    echo "        El Psy Kongroo. Version 1.4"
    echo "======================================"
    echo -e "${PLAIN}"
}

show_trojan_config() {
    CONFIG="/root/trojan/config.json"
    echo -e "${YELLOW}${BOLD}当前 Trojan-Go 配置如下:${PLAIN}"
    if [ -f "$CONFIG" ]; then
        echo -e "${CYAN}------------------------------------------------"
        cat "$CONFIG"
        echo -e "------------------------------------------------${PLAIN}"
    else
        echo -e "${RED}未检测到配置文件: $CONFIG${PLAIN}"
    fi
    pause_and_return
}

uninstall_acme() {
    echo -e "${RED}${BOLD}正在卸载 acme.sh 及相关证书...${PLAIN}"
    if [ -d ~/.acme.sh ]; then
        ~/.acme.sh/acme.sh --uninstall
        rm -rf ~/.acme.sh
        echo -e "${GREEN}acme.sh 已卸载。${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 acme.sh，无需卸载。${PLAIN}"
    fi

    read -p "$(echo -e "${YELLOW}是否同时删除 /root/cert 目录下所有证书？(y/n): ${PLAIN}")" del_cert
    if [[ "$del_cert" == "y" || "$del_cert" == "Y" ]]; then
        rm -rf /root/cert
        echo -e "${GREEN}/root/cert 目录及证书已删除。${PLAIN}"
    else
        echo -e "${YELLOW}/root/cert 目录保持不变。${PLAIN}"
    fi
    pause_and_return
}

modify_trojan_config() {
    CONFIG="/root/trojan/config.json"
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}未检测到配置文件: $CONFIG${PLAIN}"
        pause_and_return
        return
    fi
    echo -e "${YELLOW}${BOLD}当前 Trojan-Go 配置如下:${PLAIN}"
    echo -e "${CYAN}------------------------------------------------"
    cat "$CONFIG"
    echo -e "------------------------------------------------${PLAIN}"
    echo -e "${YELLOW}请交互输入新配置项（直接回车为保留原值）：${PLAIN}"

    old_local_port=$(grep -oP '"local_port":\s*\K[0-9]+' "$CONFIG")
    old_remote_addr=$(grep -oP '"remote_addr":\s*"\K[^"]+' "$CONFIG")
    old_remote_port=$(grep -oP '"remote_port":\s*\K[0-9]+' "$CONFIG")
    old_password=$(grep -oP '"password":\s*\[\s*"\K[^"]+' "$CONFIG")
    old_ws_path=$(grep -oP '"path":\s*"\K[^"]+' "$CONFIG" | head -n 1)
    old_domain=$(grep -oP '"host":\s*"\K[^"]+' "$CONFIG")
    old_cert=$(grep -oP '"cert":\s*"\K[^"]+' "$CONFIG")
    old_key=$(grep -oP '"key":\s*"\K[^"]+' "$CONFIG")

    # forward_proxy 旧值提取
    old_fp_enabled=$(grep -oP '"forward_proxy":\s*\{[^\}]*"enabled":\s*\K(true|false)' "$CONFIG")
    old_fp_addr=$(grep -oP '"proxy_addr":\s*"\K[^"]+' "$CONFIG")
    old_fp_port=$(grep -oP '"proxy_port":\s*\K[0-9]+' "$CONFIG")
    old_fp_username=$(grep -oP '"username":\s*"\K[^"]*' "$CONFIG")
    old_fp_password=$(grep -oP '"password":\s*"\K[^"]*' "$CONFIG")

    read -p "$(echo -e "${CYAN}请输入本地监听端口 (节点端口) [默认: $old_local_port]: ${PLAIN}")" local_port
    local_port=${local_port:-$old_local_port}

    read -p "$(echo -e "${CYAN}请输入转发目标地址 [默认: $old_remote_addr]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-$old_remote_addr}

    read -p "$(echo -e "${CYAN}请输入转发目标端口 [默认: $old_remote_port]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-$old_remote_port}

    read -p "$(echo -e "${CYAN}请输入密码 (回车随机8位数字字母) [默认: $old_password]: ${PLAIN}")" password
    if [ -z "$password" ]; then
        password=$old_password
        if [ -z "$password" ]; then
            password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
            echo -e "${GREEN}已自动生成密码: $password${PLAIN}"
        fi
    fi

    read -p "$(echo -e "${CYAN}请输入路径 [默认: $old_ws_path]: ${PLAIN}")" ws_path
    ws_path=${ws_path:-$old_ws_path}

    cert_dir="/root/cert"
    certs=($(ls $cert_dir/*.crt 2>/dev/null))
    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${YELLOW}检测到以下域名证书，请选择：${PLAIN}"
        select cert_path in "${certs[@]}"; do
            if [[ -n "$cert_path" ]]; then
                domain_base=$(basename "$cert_path" .crt)
                key_path="$cert_dir/${domain_base}.key"
                if [[ -f "$key_path" ]]; then
                    break
                else
                    echo -e "${RED}未找到对应私钥：$key_path，请重新选择。${PLAIN}"
                fi
            fi
        done
    else
        read -p "$(echo -e "${CYAN}请输入证书 cert 路径 [默认: $old_cert]: ${PLAIN}")" cert_path
        cert_path=${cert_path:-$old_cert}
        read -p "$(echo -e "${CYAN}请输入私钥 key 路径 [默认: $old_key]: ${PLAIN}")" key_path
        key_path=${key_path:-$old_key}
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi

    if [[ -z "$detected_domain" ]]; then
        read -p "$(echo -e "${CYAN}请输入你的域名 (证书域名) [默认: $old_domain]: ${PLAIN}")" domain
        domain=${domain:-$old_domain}
    else
        read -p "$(echo -e "${CYAN}请输入你的域名 (证书域名) [默认: $detected_domain]: ${PLAIN}")" domain
        domain=${domain:-$detected_domain}
    fi

    read -p "$(echo -e "${CYAN}请输入 WebSocket Host（默认为证书域名） [默认: $domain]: ${PLAIN}")" ws_host
    ws_host=${ws_host:-$domain}

    # forward_proxy 交互
    default_fp_text="n"
    if [[ "$old_fp_enabled" == "true" ]]; then
        default_fp_text="y"
    fi
    read -p "$(echo -e "${CYAN}是否启用 forward_proxy 转发代理？(y/n) [默认: $default_fp_text]: ${PLAIN}")" enable_fp
    if [[ -z "$enable_fp" ]]; then
        enable_fp=$default_fp_text
    fi
    if [[ "$enable_fp" == "y" || "$enable_fp" == "Y" ]]; then
        fp_enabled="true"
        read -p "$(echo -e "${CYAN}请输入代理地址 [默认: ${old_fp_addr:-127.0.0.1}]: ${PLAIN}")" proxy_addr
        proxy_addr=${proxy_addr:-${old_fp_addr:-127.0.0.1}}
        read -p "$(echo -e "${CYAN}请输入代理端口 [默认: ${old_fp_port:-18443}]: ${PLAIN}")" proxy_port
        proxy_port=${proxy_port:-${old_fp_port:-18443}}
        read -p "$(echo -e "${CYAN}请输入代理用户名（可留空） [默认: $old_fp_username]: ${PLAIN}")" fp_username
        fp_username=${fp_username:-$old_fp_username}
        read -p "$(echo -e "${CYAN}请输入代理密码（可留空） [默认: $old_fp_password]: ${PLAIN}")" fp_password
        fp_password=${fp_password:-$old_fp_password}
    else
        fp_enabled="false"
        proxy_addr="127.0.0.1"
        proxy_port="18443"
        fp_username=""
        fp_password=""
    fi

    cat > "$CONFIG" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": $local_port,
    "remote_addr": "$remote_addr",
    "remote_port": $remote_port,
    "password": [
        "$password"
    ],
    "websocket": {
        "enabled": true,
        "path": "$ws_path",
        "host": "$ws_host"
    },
    "ssl": {
        "cert": "$cert_path",
        "key": "$key_path",
        "sni": "$domain"
    },
    "mux": {
        "enabled": true,
        "concurrency": 8,
        "idle_timeout": 60
    },
    "forward_proxy": {
        "enabled": $fp_enabled,
        "proxy_addr": "$proxy_addr",
        "proxy_port": $proxy_port,
        "username": "$fp_username",
        "password": "$fp_password"
    }
}
EOF

    echo -e "${GREEN}新配置已保存，将重启 Trojan-Go 服务...${PLAIN}"
    echo -e "${CYAN}------------------------------------------------"
    cat "$CONFIG"
    echo -e "------------------------------------------------${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    pause_and_return
}

remove_trojan_go() {
    echo -e "${RED}${BOLD}准备彻底删除 Trojan-Go 及相关配置……${PLAIN}"
    systemctl stop trojan-go 2>/dev/null
    systemctl disable trojan-go 2>/dev/null

    if [ -f /etc/systemd/system/trojan-go.service ]; then
        rm -f /etc/systemd/system/trojan-go.service
    fi

    systemctl daemon-reload
    systemctl reset-failed

    if [ -d /root/trojan ]; then
        rm -rf /root/trojan
    fi

    read -p "$(echo -e "${YELLOW}是否删除 SSL 证书及私钥？(y/n): ${PLAIN}")" delete_ssl
    if [[ "$delete_ssl" == "y" || "$delete_ssl" == "Y" ]]; then
        rm -f /root/cert.crt
        rm -f /root/private.key
        rm -f /root/trojan/config.json
        echo -e "${RED}SSL 证书与私钥已被删除。${PLAIN}"
    else
        echo -e "${YELLOW}SSL 证书与私钥保持不变。${PLAIN}"
    fi

    echo -e "${GREEN}Trojan-Go 及相关配置已经彻底删除！${PLAIN}"
    pause_and_return
}

start_trojan_go() {
    echo -e "${GREEN}${BOLD}正在启动 Trojan-Go……${PLAIN}"
    systemctl start trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${GREEN}若你看见『Active: active (running)』，那么你已经成功打开世界线之门。${PLAIN}"
    pause_and_return
}

stop_trojan_go() {
    echo -e "${YELLOW}${BOLD}正在停止 Trojan-Go……${PLAIN}"
    systemctl stop trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${YELLOW}Trojan-Go 已经停止运行！${PLAIN}"
    pause_and_return
}

restart_trojan_go() {
    echo -e "${GREEN}${BOLD}正在重启 Trojan-Go……${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${GREEN}Trojan-Go 已经重启！${PLAIN}"
    pause_and_return
}

issue_acme_cert() {
    CERT_DIR="/root/cert"

    read -p "$(echo -e "${CYAN}请输入你的域名（例如 example.com）: ${PLAIN}")" domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}请输入域名参数，操作中止。${PLAIN}"
        pause_and_return
        return 1
    fi

    read -p "$(echo -e "${CYAN}请输入你的 Email（ACME 使用，直接回车将随机生成）: ${PLAIN}")" email
    if [ -z "$email" ]; then
        email="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)@gmail.com"
        echo -e "${YELLOW}[!] 未输入，已生成：$email${PLAIN}"
    fi

    mkdir -p "$CERT_DIR"

    if [[ -f "${CERT_DIR}/${domain}.crt" && -f "${CERT_DIR}/${domain}.key" ]]; then
        echo -e "${GREEN}[✓] 已检测到 ${domain} 证书，跳过签发步骤。${PLAIN}"
        pause_and_return
        return 0
    fi

    if ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}安装 curl...${PLAIN}"
        apt update -y && apt install -y curl
    fi

    if ! command -v socat &>/dev/null; then
        echo -e "${YELLOW}安装 socat...${PLAIN}"
        apt update -y && apt install -y socat
    fi

    if [ ! -d ~/.acme.sh ]; then
        echo -e "${YELLOW}[*] 安装 acme.sh ...${PLAIN}"
        curl https://get.acme.sh | sh
    fi

    ~/.acme.sh/acme.sh --register-account -m "$email"
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone
    if [ $? -ne 0 ]; then
        echo -e "${RED}[✘] 证书签发失败，请确认 DNS 或 80 端口可用性。${PLAIN}"
        pause_and_return
        return 2
    fi

    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "${CERT_DIR}/${domain}.key" \
        --fullchain-file "${CERT_DIR}/${domain}.crt"

    echo -e "${GREEN}[✓] 证书已申请并保存于 ${CERT_DIR}/${PLAIN}"
    pause_and_return
}

install_trojan_go() {
    echo -e "${GREEN}${BOLD}准备安装 Trojan-Go 并设置配置……${PLAIN}"
    mkdir -p /root/trojan && cd /root/trojan

    if [ -f ./trojan-go ]; then
        echo -e "${YELLOW}检测到 trojan-go 已存在，跳过下载。${PLAIN}"
    else
        wget https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/trojan-go && chmod +x trojan-go
        echo -e "${GREEN}trojan-go 已下载。${PLAIN}"
    fi

    echo -e "${YELLOW}请根据提示设置 Trojan-Go 配置${PLAIN}"

    read -p "$(echo -e "${CYAN}请输入本地监听端口 (节点端口) [默认: 443]: ${PLAIN}")" local_port
    local_port=${local_port:-443}

    read -p "$(echo -e "${CYAN}请输入转发目标地址 [默认: speedtest.tele2.net]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-speedtest.tele2.net}

    read -p "$(echo -e "${CYAN}请输入转发目标端口 [默认: 80]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-80}

    read -p "$(echo -e "${CYAN}请输入密码 (回车随机8位数字字母，建议更改): ${PLAIN}")" password
    if [ -z "$password" ]; then
        password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
        echo -e "${GREEN}已自动生成密码: $password${PLAIN}"
    fi

    read -p "$(echo -e "${CYAN}请输入路径 [默认: /]: ${PLAIN}")" ws_path
    ws_path=${ws_path:-/}

    cert_dir="/root/cert"
    certs=($(ls $cert_dir/*.crt 2>/dev/null))
    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${YELLOW}检测到以下域名证书，请选择：${PLAIN}"
        select cert_path in "${certs[@]}"; do
            if [[ -n "$cert_path" ]]; then
                domain_base=$(basename "$cert_path" .crt)
                key_path="$cert_dir/${domain_base}.key"
                if [[ -f "$key_path" ]]; then
                    break
                else
                    echo -e "${RED}未找到对应私钥：$key_path，请重新选择。${PLAIN}"
                fi
            fi
        done
    else
        echo -e "${YELLOW}⚠️ 未在 $cert_dir 中找到 .crt 文件，请手动输入证书路径。${PLAIN}"
        read -p "$(echo -e "${CYAN}请输入证书 cert 路径:${PLAIN}")" cert_path
        read -p "$(echo -e "${CYAN}请输入私钥 key 路径:${PLAIN}")" key_path
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi

    if [[ -z "$detected_domain" ]]; then
        echo -e "${YELLOW}⚠️ 无法自动从证书中提取域名，请手动输入.${PLAIN}"
        read -p "$(echo -e "${CYAN}请输入你的域名 (证书域名): ${PLAIN}")" domain
    else
        read -p "$(echo -e "${CYAN}请输入你的域名 (证书域名) [默认: $detected_domain]: ${PLAIN}")" domain
        domain=${domain:-$detected_domain}
    fi

    read -p "$(echo -e "${CYAN}请输入 WebSocket Host（默认为证书域名）: ${PLAIN}")" ws_host
    ws_host=${ws_host:-$domain}

    # forward_proxy 交互
    read -p "$(echo -e "${CYAN}是否启用 forward_proxy 转发代理？(y/n) [默认: n]: ${PLAIN}")" enable_fp
    if [[ "$enable_fp" == "y" || "$enable_fp" == "Y" ]]; then
        fp_enabled="true"
        read -p "$(echo -e "${CYAN}请输入代理地址 [默认: 127.0.0.1]: ${PLAIN}")" proxy_addr
        proxy_addr=${proxy_addr:-127.0.0.1}
        read -p "$(echo -e "${CYAN}请输入代理端口 [默认: 18443]: ${PLAIN}")" proxy_port
        proxy_port=${proxy_port:-18443}
        read -p "$(echo -e "${CYAN}请输入代理用户名（可留空）: ${PLAIN}")" fp_username
        read -p "$(echo -e "${CYAN}请输入代理密码（可留空）: ${PLAIN}")" fp_password
    else
        fp_enabled="false"
        proxy_addr="127.0.0.1"
        proxy_port="18443"
        fp_username=""
        fp_password=""
    fi

    cat > /root/trojan/config.json <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": $local_port,
    "remote_addr": "$remote_addr",
    "remote_port": $remote_port,
    "password": [
        "$password"
    ],
    "websocket": {
        "enabled": true,
        "path": "$ws_path",
        "host": "$ws_host"
    },
    "ssl": {
        "cert": "$cert_path",
        "key": "$key_path",
        "sni": "$domain"
    },
    "mux": {
        "enabled": true,
        "concurrency": 8,
        "idle_timeout": 60
    },
    "forward_proxy": {
        "enabled": $fp_enabled,
        "proxy_addr": "$proxy_addr",
        "proxy_port": $proxy_port,
        "username": "$fp_username",
        "password": "$fp_password"
    }
}
EOF

    cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go - An unidentifiable mechanism that helps you bypass GFW
Documentation=https://p4gefau1t.github.io/trojan-go/
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/root/trojan/trojan-go -config /root/trojan/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now trojan-go
    echo -e "${GREEN}✅ Trojan-Go 已安装并设置开机自启！${PLAIN}"
    pause_and_return
}

manage_trojan_go() {
    while true; do
        echo -e "${BLUE}${BOLD}========== Trojan-Go 管理菜单 ==========${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 启动 Trojan-Go"
        echo -e "${GREEN}2.${PLAIN} 停止 Trojan-Go"
        echo -e "${GREEN}3.${PLAIN} 重启 Trojan-Go"
        echo -e "${GREEN}4.${PLAIN} 查看 Trojan-Go 配置"
        echo -e "${GREEN}5.${PLAIN} 修改 Trojan-Go 配置"
        echo -e "${GREEN}6.${PLAIN} 删除 Trojan-Go"
        echo -e "${GREEN}0.${PLAIN} 返回主菜单"
        read -p "$(echo -e "${YELLOW}请选择操作 [0-6]: ${PLAIN}")" choice
        case "$choice" in
            1) start_trojan_go ;;
            2) stop_trojan_go ;;
            3) restart_trojan_go ;;
            4) show_trojan_config ;;
            5) modify_trojan_config ;;
            6) remove_trojan_go ;;
            0) clear; break ;;
            *) echo -e "${RED}无效选择，请重新尝试。${PLAIN}" ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        banner
        echo -e "${BOLD}${BLUE}========== 主菜单 ==========${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} Acme证书申请"
        echo -e "${GREEN}2.${PLAIN} 安装 Trojan-Go"
        echo -e "${GREEN}3.${PLAIN} 管理 Trojan-Go"
        echo -e "${GREEN}4.${PLAIN} 卸载 Acme 及证书"
        echo -e "${GREEN}0.${PLAIN} 离开命运石之门"
        echo ""
        read -p "$(echo -e "${YELLOW}请输入选项 [0-4]: ${PLAIN}")" choice

        case "$choice" in
            1) issue_acme_cert ;;
            2) install_trojan_go ;;
            3) manage_trojan_go ;;
            4) uninstall_acme ;;
            0) clear; echo -e "${CYAN}命运已中断，回归现实世界……${PLAIN}" && exit 0 ;;
            *) echo -e "${RED}错误的命运选择。请重新启动世界线。${PLAIN}"; pause_and_return ;;
        esac
    done
}

main_menu
