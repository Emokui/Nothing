#!/bin/bash

# ======== 1. 全局变量和设置 ========
RED="\033[31m\033[01m"
GREEN="\033[32m\033[01m"
PURPLE='\033[35m\033[01m'
YELLOW="\033[33m\033[01m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
PLAIN='\033[0m'
BOLD="\033[1m"

# ======== 2. 通用函数 ========
check_dependencies() {
    local missing=()
    for bin in jq dig lsof curl wget socat openssl; do
        if ! command -v $bin >/dev/null 2>&1; then
            missing+=($bin)
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}检测到缺少依赖：${missing[*]}，正在自动安装...${PLAIN}"
        apt update -y
        for dep in "${missing[@]}"; do
            case $dep in
                jq) apt install -y jq ;;
                dig) apt install -y dnsutils ;;
                lsof) apt install -y lsof ;;
                curl) apt install -y curl ;;
                wget) apt install -y wget ;;
                socat) apt install -y socat ;;
                openssl) apt install -y openssl ;;
            esac
        done
    fi
}

pause_and_return() {
    echo ""
    read -p "$(echo -e "${BLUE}请按回车键返回上一层...${PLAIN}")" temp
    clear
}

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "✦ Trojan Go - Ver 1.5 ✦"
}

# ======== 3. Trojan-Go 功能相关 ========
install_trojan_go() {
    check_dependencies
    if [ -f "/root/trojan/trojan-go" ] && [ -f "/root/trojan/config.json" ]; then
        echo -e "${YELLOW}${BOLD}检测到已安装并存在配置文件，无需重复安装。${PLAIN}"
        echo -e "${CYAN}如需修改配置，请选择主菜单的【3. 管理 Trojan-Go】${PLAIN}"
        pause_and_return
        return
    fi

    echo -e "${GREEN}${BOLD}准备安装 Trojan-Go 并设置配置……${PLAIN}"
    mkdir -p /root/trojan && cd /root/trojan

    if [ -f ./trojan-go ]; then
        echo -e "${YELLOW}检测到 trojan-go 已存在，跳过下载。${PLAIN}"
    else
        wget https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/trojan-go && chmod +x trojan-go
        echo -e "${GREEN}trojan-go 已下载。${PLAIN}"
    fi

    read -p "$(echo -e "${CYAN}请输入节点端口 [默认: 443]: ${PLAIN}")" local_port
    local_port=${local_port:-443}

    read -p "$(echo -e "${CYAN}请输入转发目标地址 [默认: speedtest.tele2.net]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-speedtest.tele2.net}

    read -p "$(echo -e "${CYAN}请输入转发目标端口 [默认: 80]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-80}

    read -p "$(echo -e "${CYAN}请输入密码 (回车随机): ${PLAIN}")" password
    if [ -z "$password" ]; then
        password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
        echo -e "${GREEN}已自动生成密码: $password${PLAIN}"
    fi

    cert_dir="/root/cert"
    certs=($(ls "$cert_dir"/*.crt 2>/dev/null))

    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${GREEN}检测到以下域名证书，请选择：${PLAIN}"
        echo -e "${GREEN}0.${PLAIN} 手动输入证书路径"
        for i in "${!certs[@]}"; do
            num=$((i+1))
            echo -e "${YELLOW}${num}.${PLAIN} ${certs[$i]}"
        done

        while true; do
            echo -ne "${GREEN}请输入序号: ${PLAIN}"
            read choice
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if [[ "$choice" == "0" ]]; then
                    read -p "请输入完整证书路径: " cert_path
                    read -p "请输入完整私钥路径: " key_path
                    if [[ -f "$cert_path" && -f "$key_path" ]]; then
                        break
                    else
                        echo -e "${RED}证书或私钥文件不存在,请重新输入${PLAIN}"
                    fi
                elif (( choice >= 1 && choice <= ${#certs[@]} )); then
                    cert_path="${certs[$((choice-1))]}"
                    domain_base=$(basename "$cert_path" .crt)
                    key_path="$cert_dir/${domain_base}.key"
                    if [[ -f "$key_path" ]]; then
                        break
                    else
                        echo -e "${RED}未找到对应私钥：$key_path,请重新选择${PLAIN}"
                    fi
                else
                    echo -e "${RED}输入无效,请重新输入${PLAIN}"
                fi
            else
                echo -e "${RED}输入无效,请重新输入${PLAIN}"
            fi
        done
    else
        echo -e "${YELLOW} 未在 $cert_dir 中找到 .crt 文件,请手动输入证书路径 ${PLAIN}"
        read -p "$(echo -e "${CYAN}请输入证书 cert 路径:${PLAIN}")" cert_path
        read -p "$(echo -e "${CYAN}请输入私钥 key 路径:${PLAIN}")" key_path
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi
    domain="$detected_domain"

    if [[ -z "$domain" ]]; then
        echo -e "${RED}无法从证书中提取域名，请检查证书文件！${PLAIN}"
        pause_and_return
        return
    else
        echo -e "${GREEN}证书域名自动识别为: $domain${PLAIN}"
    fi

    read -p "$(echo -e "${CYAN}是否启用 WebSocket？(y/n) [默认: y]: ${PLAIN}")" enable_ws
    if [[ -z "$enable_ws" || "$enable_ws" == "y" || "$enable_ws" == "Y" ]]; then
        ws_enabled=true
        read -p "$(echo -e "${CYAN}请输入 WebSocket 路径 [默认: /]: ${PLAIN}")" ws_path
        ws_path=${ws_path:-/}
        read -p "$(echo -e "${CYAN}请输入 WebSocket Host（默认为证书域名）: ${PLAIN}")" ws_host
        ws_host=${ws_host:-$domain}
    else
        ws_enabled=false
        ws_path="/"
        ws_host="$domain"
    fi

    read -p "$(echo -e "${CYAN}是否启用 forward_proxy 转发代理？(y/n) [默认: n]: ${PLAIN}")" enable_fp
    if [[ "$enable_fp" == "y" || "$enable_fp" == "Y" ]]; then
        fp_enabled=true
        read -p "$(echo -e "${CYAN}请输入代理地址 [默认: 127.0.0.1]: ${PLAIN}")" proxy_addr
        proxy_addr=${proxy_addr:-127.0.0.1}
        read -p "$(echo -e "${CYAN}请输入代理端口 [默认: 18443]: ${PLAIN}")" proxy_port
        proxy_port=${proxy_port:-18443}
        read -p "$(echo -e "${CYAN}请输入代理用户名（可留空）: ${PLAIN}")" fp_username
        read -p "$(echo -e "${CYAN}请输入代理密码（可留空）: ${PLAIN}")" fp_password
    else
        fp_enabled=false
        proxy_addr="127.0.0.1"
        proxy_port="18443"
        fp_username=""
        fp_password=""
    fi

    jq -n \
        --argjson local_port "$local_port" \
        --arg remote_addr "$remote_addr" \
        --argjson remote_port "$remote_port" \
        --arg password "$password" \
        --arg ws_enabled "$ws_enabled" \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        --arg cert_path "$cert_path" \
        --arg key_path "$key_path" \
        --arg domain "$domain" \
        --arg fp_enabled "$fp_enabled" \
        --arg proxy_addr "$proxy_addr" \
        --argjson proxy_port "$proxy_port" \
        --arg fp_username "$fp_username" \
        --arg fp_password "$fp_password" \
        '
        {
            "run_type": "server",
            "local_addr": "0.0.0.0",
            "local_port": ($local_port | tonumber),
            "remote_addr": $remote_addr,
            "remote_port": ($remote_port | tonumber),
            "password": [ $password ],
            "websocket": {
                "enabled": ($ws_enabled == "true"),
                "path": $ws_path,
                "host": $ws_host
            },
            "ssl": {
                "cert": $cert_path,
                "key": $key_path,
                "sni": $domain
            },
            "mux": {
                "enabled": true,
                "concurrency": 8,
                "idle_timeout": 60
            },
            "forward_proxy": {
                "enabled": ($fp_enabled == "true"),
                "proxy_addr": $proxy_addr,
                "proxy_port": ($proxy_port | tonumber),
                "username": $fp_username,
                "password": $fp_password
            }
        }
        ' > /root/trojan/config.json

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

    systemctl daemon-reload
    systemctl enable --now trojan-go
    echo -e "${GREEN} Trojan-Go 已安装并设置开机自启 ${PLAIN}"
    pause_and_return
}

modify_trojan_config() {
    check_dependencies
    clear
    CONFIG="/root/trojan/config.json"
    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}未检测到配置文件: $CONFIG${PLAIN}"
        pause_and_return
        return
    fi
    echo -e "${YELLOW}请交互输入新配置项（直接回车为保留原值）：${PLAIN}"
    old_local_port=$(jq -r '.local_port' "$CONFIG" 2>/dev/null)
    old_remote_addr=$(jq -r '.remote_addr' "$CONFIG" 2>/dev/null)
    old_remote_port=$(jq -r '.remote_port' "$CONFIG" 2>/dev/null)
    old_password=$(jq -r '.password[0]' "$CONFIG" 2>/dev/null)

    old_ws_enabled=$(jq -r '.websocket.enabled' "$CONFIG" 2>/dev/null)
    old_ws_path=$(jq -r '.websocket.path' "$CONFIG" 2>/dev/null)
    old_ws_host=$(jq -r '.websocket.host' "$CONFIG" 2>/dev/null)

    old_cert=$(jq -r '.ssl.cert' "$CONFIG" 2>/dev/null)
    old_key=$(jq -r '.ssl.key' "$CONFIG" 2>/dev/null)

    old_fp_enabled=$(jq -r '.forward_proxy.enabled' "$CONFIG" 2>/dev/null)
    old_fp_addr=$(jq -r '.forward_proxy.proxy_addr' "$CONFIG" 2>/dev/null)
    old_fp_port=$(jq -r '.forward_proxy.proxy_port' "$CONFIG" 2>/dev/null)
    old_fp_username=$(jq -r '.forward_proxy.username' "$CONFIG" 2>/dev/null)
    old_fp_password=$(jq -r '.forward_proxy.password' "$CONFIG" 2>/dev/null)

    read -p "$(echo -e "${CYAN}请输入节点端口 [默认: $old_local_port]: ${PLAIN}")" local_port
    local_port=${local_port:-$old_local_port}

    read -p "$(echo -e "${CYAN}请输入转发目标地址 [默认: $old_remote_addr]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-$old_remote_addr}

    read -p "$(echo -e "${CYAN}请输入转发目标端口 [默认: $old_remote_port]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-$old_remote_port}

    read -p "$(echo -e "${CYAN}请输入新密码 [回车保持不变,输入r/R随机生成]: ${PLAIN}")" password
    if [[ "$password" == "r" || "$password" == "R" ]]; then
        password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
        echo -e "${GREEN}已自动生成密码: $password${PLAIN}"
    elif [ -z "$password" ]; then
        password=$old_password
        echo -e "${YELLOW}密码保持不变${PLAIN}"
    else
        echo -e "${GREEN}密码已修改${PLAIN}"
    fi

    cert_dir="/root/cert"
    certs=($(ls "$cert_dir"/*.crt 2>/dev/null))

    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${GREEN}检测到以下域名证书，请选择：${PLAIN}"
        echo -e "${GREEN}0.${PLAIN} 手动输入证书路径"
        for i in "${!certs[@]}"; do
            num=$((i+1))
            echo -e "${YELLOW}${num}.${PLAIN} ${certs[$i]}"
        done

        while true; do
            echo -ne "${GREEN}请输入序号: ${PLAIN}"
            read choice
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if [[ "$choice" == "0" ]]; then
                    read -p "请输入完整证书路径: " cert_path
                    read -p "请输入完整私钥路径: " key_path
                    if [[ -f "$cert_path" && -f "$key_path" ]]; then
                        break
                    else
                        echo -e "${RED}证书或私钥文件不存在,请重新输入${PLAIN}"
                    fi
                elif (( choice >= 1 && choice <= ${#certs[@]} )); then
                    cert_path="${certs[$((choice-1))]}"
                    domain_base=$(basename "$cert_path" .crt)
                    key_path="$cert_dir/${domain_base}.key"
                    if [[ -f "$key_path" ]]; then
                        break
                    else
                        echo -e "${RED}未找到对应私钥：$key_path,请重新选择${PLAIN}"
                    fi
                else
                    echo -e "${RED}输入无效,请重新输入${PLAIN}"
                fi
            else
                echo -e "${RED}输入无效,请重新输入${PLAIN}"
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
    domain="$detected_domain"

    if [[ -z "$domain" ]]; then
        echo -e "${RED}无法从证书中提取域名，请检查证书文件！${PLAIN}"
        pause_and_return
        return
    else
        echo -e "${GREEN}证书域名自动识别为: $domain（sni自动设置）${PLAIN}"
    fi

    read -p "$(echo -e "${CYAN}是否启用 WebSocket？(y/n) [默认: $( [[ "$old_ws_enabled" == "true" ]] && echo y || echo n ) ]: ${PLAIN}")" enable_ws
    if [[ -z "$enable_ws" ]]; then
        if [[ "$old_ws_enabled" == "true" ]]; then
            ws_enabled=true
        else
            ws_enabled=false
        fi
    elif [[ "$enable_ws" == "y" || "$enable_ws" == "Y" ]]; then
        ws_enabled=true
    else
        ws_enabled=false
    fi

    if [[ "$ws_enabled" == true ]]; then
        read -p "$(echo -e "${CYAN}请输入 WebSocket 路径 [默认: $old_ws_path]: ${PLAIN}")" ws_path
        ws_path=${ws_path:-$old_ws_path}
        read -p "$(echo -e "${CYAN}请输入 WebSocket Host（默认为证书域名） [默认: $old_ws_host]: ${PLAIN}")" ws_host
        ws_host=${ws_host:-$domain}
    else
        ws_path="${old_ws_path:-/}"
        ws_host="$domain"
    fi

    default_fp_text="n"
    if [[ "$old_fp_enabled" == "true" ]]; then
        default_fp_text="y"
    fi
    read -p "$(echo -e "${CYAN}是否启用 forward_proxy 转发代理？(y/n) [默认: $default_fp_text]: ${PLAIN}")" enable_fp
    if [[ -z "$enable_fp" ]]; then
        enable_fp=$default_fp_text
    fi
    if [[ "$enable_fp" == "y" || "$enable_fp" == "Y" ]]; then
        fp_enabled=true
        read -p "$(echo -e "${CYAN}请输入代理地址 [默认: ${old_fp_addr:-127.0.0.1}]: ${PLAIN}")" proxy_addr
        proxy_addr=${proxy_addr:-${old_fp_addr:-127.0.0.1}}
        read -p "$(echo -e "${CYAN}请输入代理端口 [默认: ${old_fp_port:-18443}]: ${PLAIN}")" proxy_port
        proxy_port=${proxy_port:-${old_fp_port:-18443}}
        read -p "$(echo -e "${CYAN}请输入代理用户名（可留空） [默认: $old_fp_username]: ${PLAIN}")" fp_username
        fp_username=${fp_username:-$old_fp_username}
        read -p "$(echo -e "${CYAN}请输入代理密码（可留空） [默认: $old_fp_password]: ${PLAIN}")" fp_password
        fp_password=${fp_password:-$old_fp_password}
    else
        fp_enabled=false
        proxy_addr="127.0.0.1"
        proxy_port="18443"
        fp_username=""
        fp_password=""
    fi

    jq -n \
        --argjson local_port "$local_port" \
        --arg remote_addr "$remote_addr" \
        --argjson remote_port "$remote_port" \
        --arg password "$password" \
        --arg ws_enabled "$ws_enabled" \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        --arg cert_path "$cert_path" \
        --arg key_path "$key_path" \
        --arg domain "$domain" \
        --arg fp_enabled "$fp_enabled" \
        --arg proxy_addr "$proxy_addr" \
        --argjson proxy_port "$proxy_port" \
        --arg fp_username "$fp_username" \
        --arg fp_password "$fp_password" \
        '
        {
            "run_type": "server",
            "local_addr": "0.0.0.0",
            "local_port": ($local_port | tonumber),
            "remote_addr": $remote_addr,
            "remote_port": ($remote_port | tonumber),
            "password": [ $password ],
            "websocket": {
                "enabled": ($ws_enabled == "true"),
                "path": $ws_path,
                "host": $ws_host
            },
            "ssl": {
                "cert": $cert_path,
                "key": $key_path,
                "sni": $domain
            },
            "mux": {
                "enabled": true,
                "concurrency": 8,
                "idle_timeout": 60
            },
            "forward_proxy": {
                "enabled": ($fp_enabled == "true"),
                "proxy_addr": $proxy_addr,
                "proxy_port": ($proxy_port | tonumber),
                "username": $fp_username,
                "password": $fp_password
            }
        }
        ' > "$CONFIG"

    clear
    echo -e "${GREEN}新配置已保存，将重启 Trojan-Go 服务...${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    pause_and_return
}

show_trojan_config() {
    clear
    CONFIG="/root/trojan/config.json"
    echo -e "${YELLOW}${BOLD}当前 Trojan 配置如下:${PLAIN}"
    if [ -f "$CONFIG" ]; then
        echo -e "${CYAN}------------------------------------------------"
        cat "$CONFIG"
        echo -e "------------------------------------------------${PLAIN}"
    else
        echo -e "${RED}未检测到配置文件: $CONFIG${PLAIN}"
    fi
    pause_and_return
}

remove_trojan_go() {
    clear
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
        rm -rf /root/cert
        rm -f /root/trojan/config.json
        echo -e "${RED}SSL 证书与私钥已被删除。${PLAIN}"
    else
        echo -e "${YELLOW}SSL 证书与私钥保持不变。${PLAIN}"
    fi

    echo -e "${GREEN}Trojan-Go 及相关配置已经彻底删除！${PLAIN}"
    pause_and_return
}

start_trojan_go() {
    clear
    echo -e "${GREEN}${BOLD}正在启动 Trojan-Go……${PLAIN}"
    systemctl start trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${GREEN}若你看见『Active: active (running)』，那么你已经成功打开世界线之门。${PLAIN}"
    pause_and_return
}

stop_trojan_go() {
    clear
    echo -e "${YELLOW}${BOLD}正在停止 Trojan-Go……${PLAIN}"
    systemctl stop trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${YELLOW}Trojan-Go 已经停止运行！${PLAIN}"
    pause_and_return
}

restart_trojan_go() {
    clear
    echo -e "${GREEN}${BOLD}正在重启 Trojan-Go……${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${GREEN}Trojan-Go 已经重启！${PLAIN}"
    pause_and_return
}

manage_trojan_go() {
    if [ ! -f "/root/trojan/trojan-go" ] || [ ! -f "/root/trojan/config.json" ]; then
        echo -e "${RED}未检测到配置文件或执行文件,请先安装并配置 Trojan ${PLAIN}"
        pause_and_return
        return
    fi
    while true; do
        clear
        echo -e "${BLUE}${BOLD}✦ Trojan-Go Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}启动 Trojan"
        echo -e "${GREEN}  2.${PLAIN}停止 Trojan"
        echo -e "${GREEN}  3.${PLAIN}重启 Trojan"
        echo -e "${GREEN}  4.${PLAIN}查看 Trojan 配置"
        echo -e "${GREEN}  5.${PLAIN}修改 Trojan 配置"
        echo -e "${GREEN}  6.${PLAIN}删除 Trojan"
        echo -e "${GREEN}  0.${PLAIN}返回 El Psy Kongroo"
        read -p "$(echo -e "${PURPLE}✦ Steins Gate ✦ : ${PLAIN}")" choice
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

# ======== 4. Acme 证书相关 ========
issue_acme_cert() {
    check_dependencies
    clear
    CERT_DIR="/root/cert"
    ACME_SH=~/.acme.sh/acme.sh

    if [[ ! -f "$ACME_SH" ]]; then
        echo -e "${YELLOW}正在安装 acme.sh ...${PLAIN}"
        apt update -y && apt install -y curl wget socat openssl dnsutils jq
        curl https://get.acme.sh | sh
        source ~/.bashrc
        bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    fi

    $ACME_SH --set-default-ca --server letsencrypt

    if ! $ACME_SH --list-account 2>/dev/null | grep -q letsencrypt; then
        auto_email="$(date +%s%N | md5sum | cut -c 1-16)@gmail.com"
        $ACME_SH --register-account -m "$auto_email"
    else
        auto_email="$($ACME_SH --list-account 2>/dev/null | grep Registered | grep letsencrypt | awk '{print $4}')"
    fi

    if [[ -z $(type -P lsof) ]]; then
        apt update -y && apt install -y lsof
    fi
    echo -e "${YELLOW}检测 80 端口占用...${PLAIN}"
    if [[ $(lsof -i:"80" | grep -i -c "listen") -ne 0 ]]; then
        echo -e "${RED}80 端口被占用，以下是占用程序：${PLAIN}"
        lsof -i:"80"
        read -p "$(echo -e "${YELLOW}是否结束占用进程？(y/N): ${PLAIN}")" yn
        if [[ $yn =~ [Yy] ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
        else
            echo -e "${RED}申请中止。${PLAIN}"
            pause_and_return
            return
        fi
    fi

    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)

    echo -e "${YELLOW}请输入需要申请证书的域名(直接回车退出申请)${PLAIN}"
    read -p "$(echo -e "${CYAN}域名: ${PLAIN}")" domain
    [[ -z $domain ]] && echo -e "${RED}未输入域名，操作中止。${PLAIN}" && pause_and_return && return

    domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | sed -n 1p)
    if [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null | sed -n 1p)
    fi
    
    ip_match=false
    if [[ -n "$ipv4" && "$domainIP" == "$ipv4" ]]; then
        ip_match=true
    fi
    if [[ -n "$ipv6" && "$domainIP" == "$ipv6" ]]; then
        ip_match=true
    fi

    if [[ "$ip_match" != "true" ]]; then
        echo -e "${RED}域名解析 IP 与本机 IP 不符。${PLAIN}"
        echo -e "${YELLOW}域名解析IP: $domainIP, 本机IPv4: $ipv4, IPv6: $ipv6${PLAIN}"
        echo -e "${YELLOW}请检查域名解析后重试。${PLAIN}"
        pause_and_return
        return
    fi

    mkdir -p "$CERT_DIR"
    $ACME_SH --issue -d "${domain}" --standalone -k ec-256 --insecure
    $ACME_SH --install-cert -d "${domain}" --key-file "${CERT_DIR}/${domain}.key" --fullchain-file "${CERT_DIR}/${domain}.crt" --ecc

    if [[ -f "${CERT_DIR}/${domain}.crt" && -f "${CERT_DIR}/${domain}.key" ]]; then
        echo -e "${GREEN}证书申请成功！${PLAIN}"
        echo -e "${YELLOW}证书: ${CERT_DIR}/${domain}.crt${PLAIN}"
        echo -e "${YELLOW}私钥: ${CERT_DIR}/${domain}.key${PLAIN}"
        echo -e "${YELLOW}注册邮箱: $auto_email${PLAIN}"
    else
        echo -e "${RED}证书申请失败，请检查网络和域名解析！${PLAIN}"
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

    CERT_DIR="/root/cert"
    if [ -d "$CERT_DIR" ]; then
        echo -e "${YELLOW}检测到证书目录 $CERT_DIR${PLAIN}"
        read -p "$(echo -e "${YELLOW}是否删除该目录下所有证书文件？(y/N): ${PLAIN}")" del_cert
        if [[ "$del_cert" =~ ^[Yy]$ ]]; then
            read -p "$(echo -e "${RED}确定要删除 $CERT_DIR 下的所有证书文件吗？此操作不可恢复！(yes/NO): ${PLAIN}")" double_check
            if [[ "$double_check" == "yes" ]]; then
                rm -rf "$CERT_DIR"
                echo -e "${GREEN}$CERT_DIR 目录及证书已删除。${PLAIN}"
            else
                echo -e "${YELLOW}已取消删除证书操作，$CERT_DIR 保持不变。${PLAIN}"
            fi
        else
            echo -e "${YELLOW}$CERT_DIR 目录保持不变。${PLAIN}"
        fi
    else
        echo -e "${YELLOW}未检测到 $CERT_DIR，无需删除。${PLAIN}"
    fi
    pause_and_return
}

# ======== 5. 主菜单 ========
main_menu() {
    while true; do
        clear
        banner
        echo -e "${GREEN}  1.${PLAIN}Acme 证书申请"
        echo -e "${GREEN}  2.${PLAIN}安装 Trojan-Go"
        echo -e "${GREEN}  3.${PLAIN}管理 Trojan-Go"
        echo -e "${GREEN}  4.${PLAIN}卸载 Acme及证书"
        echo -e "${GREEN}  0.${PLAIN}离开 El Psy Kongroo"
        read -p "$(echo -e "${PURPLE}✦ Steins Gate ✦ : ${PLAIN}")" choice

        case "$choice" in
            1) issue_acme_cert ;;
            2) install_trojan_go ;;
            3) manage_trojan_go ;;
            4) uninstall_acme ;;
            0) clear; echo -e "${CYAN}「运命石之扉の选择,El Psy Kongroo」${PLAIN}"; sleep 1; clear; exit 0 ;;
            *) echo -e "${RED}错误的命运抉择,请重新寻觅世界线。${PLAIN}"; pause_and_return ;;
        esac
    done
}

main_menu