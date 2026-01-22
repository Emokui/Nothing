#!/bin/bash

# 脚本下载的执行文件来自此仓库,是原仓库的一个分支,升级了utls,版本为v1.2.0
# https://github.com/gfw-report/trojan-go

# ======== 全局变量 ========
RED="\033[1;31m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

# ========  以Root运行 ========
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请以 root 身份运行本脚本${PLAIN}"
    exit 1
fi

# ======== 通用函数 ========
check_dependencies() {
    local missing=()
    for bin in jq dig lsof curl wget socat openssl; do
        if ! command -v $bin >/dev/null 2>&1; then
            missing+=($bin)
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}检测到缺少依赖: ${missing[*]},正在自动安装...${PLAIN}"
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
    read -p "$(echo -e "${BLUE}请按回车键返回上一层...${PLAIN}")" temp
    clear
}

# ======== Trojan安装 ========
install_trojan_go() {
    check_dependencies
    if [ -f "/root/trojan/trojan-go" ] && [ -f "/root/trojan/config.json" ]; then
        echo -e "${YELLOW}检测到已安装并存在配置文件,无需重复安装${PLAIN}"
        echo -e "${BLUE}如需修改配置,请选择主菜单的【3.管理 Trojan-Go】${PLAIN}"
        pause_and_return
        return
    fi

    echo -e "${GREEN}准备安装 Trojan-Go 并配置……${PLAIN}"
    mkdir -p /root/trojan && cd /root/trojan

    if [ -f ./trojan-go ]; then
        echo -e "${YELLOW}检测到 trojan-go 已存在,跳过下载${PLAIN}"
    else
        echo -e "${YELLOW}正在检测并下载安装适合当前系统的版本${PLAIN}"
        arch=""
        uname_arch=$(uname -m)
        case "$uname_arch" in
          x86_64) arch="linux-amd64" ;;
          aarch64 | arm64) arch="linux-arm64" ;;
          armv7l) arch="linux-armv7" ;;
          i386 | i686) arch="linux-386" ;;
          *) echo "不支持的架构: $uname_arch"; exit 1 ;;
        esac

        repo="gfw-report/trojan-go"
        api_url="https://api.github.com/repos/$repo/releases/latest"
        asset_url=$(curl -s $api_url \
          | jq -r --arg arch "$arch" '.assets[] | select(.name|test($arch+".zip$")) | .browser_download_url' | head -n 1)

        if [ -z "$asset_url" ]; then
            echo "找不到适合 $arch 的trojan-go release！"
            exit 1
        fi

        wget -O trojan-go.zip "$asset_url"
        unzip -j trojan-go.zip 'trojan-go/trojan-go' -d . 2>/dev/null || unzip -j trojan-go.zip 'trojan-go' -d .
        chmod +x trojan-go
        rm -f trojan-go.zip
        echo -e "${GREEN}trojan-go 已下载${PLAIN}"
    fi

    clear
    read -p "$(echo -e "${BLUE}请输入节点端口 [默认:443]: ${PLAIN}")" local_port
    local_port=${local_port:-443}

    read -p "$(echo -e "${BLUE}请输入转发目标地址 [默认:speedtest.tele2.net]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-speedtest.tele2.net}

    read -p "$(echo -e "${BLUE}请输入转发目标端口 [默认:80]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-80}

    read -p "$(echo -e "${BLUE}请输入密码 ${GREEN}(回车随机生成)${BLUE}: ${PLAIN}")" psk
    [[ -z "$psk" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    echo -e "${GREEN}已自动生成密码: $psk${PLAIN}"

    cert_dir="/root/cert"
    certs=($(ls "$cert_dir"/*.crt 2>/dev/null))

    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${BLUE}检测到以下域名证书,请选择: ${PLAIN}"
        echo -e "${GREEN}0.手动输入证书路径${PLAIN}"
        for i in "${!certs[@]}"; do
            num=$((i+1))
            echo -e "${GREEN}${num}.${certs[$i]}"
        done

        while true; do
            echo -ne "${BLUE}请输入序号: ${PLAIN}"
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
                        echo -e "${RED}未找到对应私钥: $key_path,请重新选择${PLAIN}"
                    fi
                else
                    echo -e "${RED}输入无效,请重新输入${PLAIN}"
                fi
            else
                echo -e "${RED}输入无效,请重新输入${PLAIN}"
            fi
        done
    else
        echo -e "${BLUE} 未在 $cert_dir 中找到 .crt 文件,请手动输入证书路径 ${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入证书 cert 路径:${PLAIN}")" cert_path
        read -p "$(echo -e "${BLUE}请输入私钥 key 路径:${PLAIN}")" key_path
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi
    domain="$detected_domain"

    if [[ -z "$domain" ]]; then
        echo -e "${RED}无法从证书中提取域名,请检查证书文件!${PLAIN}"
        pause_and_return
        return
    else
        echo -e "${GREEN}证书域名自动识别为: $domain${PLAIN}"
    fi

    read -p "$(echo -e "${BLUE}是否启用 WebSocket(y/n) [默认:y]: ${PLAIN}")" enable_ws
    if [[ -z "$enable_ws" || "$enable_ws" == "y" || "$enable_ws" == "Y" ]]; then
        ws_enabled=true
        ws_enabled_json=true
        read -p "$(echo -e "${BLUE}请输入 ws 路径 [默认:/]: ${PLAIN}")" ws_path
        ws_path=${ws_path:-/}
        read -p "$(echo -e "${BLUE}请输入 ws Host（默认:证书域名）: ${PLAIN}")" ws_host
        ws_host=${ws_host:-$domain}
    else
        ws_enabled=false
        ws_enabled_json=false
        ws_path="/"
        ws_host="$domain"
    fi

    read -p "$(echo -e "${BLUE}是否启用 socks5 代理转发(y/n) [默认:n]: ${PLAIN}")" enable_fp
    if [[ "$enable_fp" == "y" || "$enable_fp" == "Y" ]]; then
        fp_enabled=true
        fp_enabled_json=true
        read -p "$(echo -e "${BLUE}请输入代理地址 [默认:127.0.0.1]: ${PLAIN}")" proxy_addr
        proxy_addr=${proxy_addr:-127.0.0.1}
        read -p "$(echo -e "${BLUE}请输入代理端口 [默认:18443]: ${PLAIN}")" proxy_port
        proxy_port=${proxy_port:-18443}
        read -p "$(echo -e "${BLUE}请输入代理用户名（可留空）: ${PLAIN}")" fp_username
        fp_username=${fp_username:-""}
        read -p "$(echo -e "${BLUE}请输入代理密码（可留空）: ${PLAIN}")" fp_password
        fp_password=${fp_password:-""}
    else
        fp_enabled=false
        fp_enabled_json=false
        proxy_addr="127.0.0.1"
        proxy_port="18443"
        fp_username=""
        fp_password=""
    fi

    local_port_json="$local_port"
    remote_port_json="$remote_port"
    proxy_port_json="$proxy_port"

    jq -n \
        --argjson local_port "$local_port_json" \
        --arg remote_addr "$remote_addr" \
        --argjson remote_port "$remote_port_json" \
        --arg password "$psk" \
        --argjson ws_enabled "$ws_enabled_json" \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        --arg cert_path "$cert_path" \
        --arg key_path "$key_path" \
        --arg domain "$domain" \
        --argjson fp_enabled "$fp_enabled_json" \
        --arg proxy_addr "$proxy_addr" \
        --argjson proxy_port "$proxy_port_json" \
        --arg fp_username "$fp_username" \
        --arg fp_password "$fp_password" \
        '
        {
            "run_type": "server",
            "local_addr": "0.0.0.0",
            "local_port": $local_port,
            "remote_addr": $remote_addr,
            "remote_port": $remote_port,
            "password": [ $password ],
            "websocket": {
                "enabled": $ws_enabled,
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
                "enabled": $fp_enabled,
                "proxy_addr": $proxy_addr,
                "proxy_port": $proxy_port,
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
    clear
    echo -e "${GREEN}Trojan-Go 已安装并设置开机自启 ${PLAIN}"

    password="$psk"
    local_port="$local_port"
    sni="$domain"
    ws_enabled="$ws_enabled"
    ws_path="$ws_path"
    ws_host="$ws_host"
    node_ip=$(curl -s4m6 ip.sb)
    if [[ -z "$node_ip" ]]; then
        node_ip=$(hostname -I | awk '{print $1}')
    fi
    ws_path_enc=$(echo -n "$ws_path" | sed 's/\//%2F/g')
    if [[ "$ws_enabled" == "true" || "$ws_enabled" == "True" || "$ws_enabled" == "1" ]]; then
        node_link="trojan://$password@$node_ip:$local_port?sni=$sni&type=ws&path=$ws_path_enc&host=$ws_host#Trojan"
    else
        node_link="trojan://$password@$node_ip:$local_port?sni=$sni#Trojan"
    fi
    echo -e "${BLUE}您的 Trojan 节点链接: ${PLAIN}"
    echo -e "${GREEN}$node_link${PLAIN}"

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
    echo -e "${GREEN}请输设置参数(回车不变): ${PLAIN}"
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

    read -p "$(echo -e "${BLUE}请输入节点端口 [默认:$old_local_port]: ${PLAIN}")" local_port
    local_port=${local_port:-$old_local_port}

    read -p "$(echo -e "${BLUE}请输入转发目标地址 [默认:$old_remote_addr]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-$old_remote_addr}

    read -p "$(echo -e "${BLUE}请输入转发目标端口 [默认:$old_remote_port]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-$old_remote_port}

    read -p "$(echo -e "${BLUE}请输入新密码 ${GREEN}[回车保持不变,输入r/R随机生成]${BLUE}: ${PLAIN}")" psk
    if [[ "$psk" == "r" || "$psk" == "R" ]]; then
        psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        echo -e "${GREEN}已自动生成密码: $psk${PLAIN}"
    elif [ -z "$psk" ]; then
        psk=$old_password
        echo -e "${GREEN}密码保持不变${PLAIN}"
    else
        echo -e "${GREEN}密码已修改${PLAIN}"
    fi

    cert_dir="/root/cert"
    certs=($(ls "$cert_dir"/*.crt 2>/dev/null))
    changed_cert=false

    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${BLUE}检测到以下域名证书,请选择: ${PLAIN}"
        echo -e "${GREEN}0.手动输入证书路径 ${PLAIN}"
        for i in "${!certs[@]}"; do
            num=$((i+1))
            echo -e "${GREEN}${num}.${certs[$i]}"
        done

        while true; do
            echo -ne "${BLUE}请输入序号: ${PLAIN}"
            read choice
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if [[ "$choice" == "0" ]]; then
                    read -p "请输入完整证书路径: " cert_path
                    read -p "请输入完整私钥路径: " key_path
                    if [[ -f "$cert_path" && -f "$key_path" ]]; then
                        changed_cert=true
                        break
                    else
                        echo -e "${RED}证书或私钥文件不存在,请重新输入${PLAIN}"
                    fi
                elif (( choice >= 1 && choice <= ${#certs[@]} )); then
                    cert_path="${certs[$((choice-1))]}"
                    domain_base=$(basename "$cert_path" .crt)
                    key_path="$cert_dir/${domain_base}.key"
                    if [[ -f "$key_path" ]]; then
                        changed_cert=true
                        break
                    else
                        echo -e "${RED}未找到对应私钥: $key_path,请重新选择${PLAIN}"
                    fi
                else
                    echo -e "${RED}输入无效,请重新输入${PLAIN}"
                fi
            else
                echo -e "${RED}输入无效,请重新输入${PLAIN}"
            fi
        done
    else
        read -p "$(echo -e "${BLUE}请输入证书 cert 路径 [默认:$old_cert]: ${PLAIN}")" cert_path
        if [ -z "$cert_path" ]; then
            cert_path=$old_cert
            changed_cert=false
        else
            changed_cert=true
        fi
        read -p "$(echo -e "${BLUE}请输入私钥 key 路径 [默认:$old_key]: ${PLAIN}")" key_path
        if [ -z "$key_path" ]; then
            key_path=$old_key
        fi
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi
    domain="$detected_domain"

    if [[ -z "$domain" ]]; then
        echo -e "${RED}无法从证书中提取域名,请检查证书文件!${PLAIN}"
        pause_and_return
        return
    else
        echo -e "${GREEN}证书域名自动识别为: $domain ${PLAIN}"
    fi

    ws_host_default="$domain"

    read -p "$(echo -e "${BLUE}是否启用 WebSocket (y/n) [默认:$( [[ "$old_ws_enabled" == "true" ]] && echo y || echo n ) ]: ${PLAIN}")" enable_ws
    if [[ -z "$enable_ws" ]]; then
        if [[ "$old_ws_enabled" == "true" ]]; then
            ws_enabled=true
            ws_enabled_json=true
        else
            ws_enabled=false
            ws_enabled_json=false
        fi
    elif [[ "$enable_ws" == "y" || "$enable_ws" == "Y" ]]; then
        ws_enabled=true
        ws_enabled_json=true
    else
        ws_enabled=false
        ws_enabled_json=false
    fi

    if [[ "$ws_enabled" == true ]]; then
        read -p "$(echo -e "${BLUE}请输入 ws 路径 [默认:$old_ws_path]: ${PLAIN}")" ws_path
        ws_path=${ws_path:-$old_ws_path}

        read -p "$(echo -e "${BLUE}请输入 ws Host（默认:证书域名） [默认: $ws_host_default]: ${PLAIN}")" ws_host
        ws_host=${ws_host:-$ws_host_default}
    else
        ws_path="${old_ws_path:-/}"
        ws_host="$ws_host_default"
    fi

    default_fp_text="n"
    if [[ "$old_fp_enabled" == "true" ]]; then
        default_fp_text="y"
    fi
    read -p "$(echo -e "${BLUE}是否启用 socks5 代理转发 (y/n) [默认:$default_fp_text]: ${PLAIN}")" enable_fp
    if [[ -z "$enable_fp" ]]; then
        enable_fp=$default_fp_text
    fi
    if [[ "$enable_fp" == "y" || "$enable_fp" == "Y" ]]; then
        fp_enabled=true
        fp_enabled_json=true
        read -p "$(echo -e "${BLUE}请输入代理地址 [默认:${old_fp_addr:-127.0.0.1}]: ${PLAIN}")" proxy_addr
        proxy_addr=${proxy_addr:-${old_fp_addr:-127.0.0.1}}
        read -p "$(echo -e "${BLUE}请输入代理端口 [默认:${old_fp_port:-18443}]: ${PLAIN}")" proxy_port
        proxy_port=${proxy_port:-${old_fp_port:-18443}}
        read -p "$(echo -e "${BLUE}请输入代理用户名（可留空） [默认:$old_fp_username]: ${PLAIN}")" fp_username
        fp_username=${fp_username:-$old_fp_username}
        read -p "$(echo -e "${BLUE}请输入代理密码（可留空） [默认:$old_fp_password]: ${PLAIN}")" fp_password
        fp_password=${fp_password:-$old_fp_password}
    else
        fp_enabled=false
        fp_enabled_json=false
        proxy_addr="127.0.0.1"
        proxy_port="18443"
        fp_username=""
        fp_password=""
    fi

    local_port_json="$local_port"
    remote_port_json="$remote_port"
    proxy_port_json="$proxy_port"

    jq -n \
        --argjson local_port "$local_port_json" \
        --arg remote_addr "$remote_addr" \
        --argjson remote_port "$remote_port_json" \
        --arg password "$psk" \
        --argjson ws_enabled "$ws_enabled_json" \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        --arg cert_path "$cert_path" \
        --arg key_path "$key_path" \
        --arg domain "$domain" \
        --argjson fp_enabled "$fp_enabled_json" \
        --arg proxy_addr "$proxy_addr" \
        --argjson proxy_port "$proxy_port_json" \
        --arg fp_username "$fp_username" \
        --arg fp_password "$fp_password" \
        '
        {
            "run_type": "server",
            "local_addr": "0.0.0.0",
            "local_port": $local_port,
            "remote_addr": $remote_addr,
            "remote_port": $remote_port,
            "password": [ $password ],
            "websocket": {
                "enabled": $ws_enabled,
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
                "enabled": $fp_enabled,
                "proxy_addr": $proxy_addr,
                "proxy_port": $proxy_port,
                "username": $fp_username,
                "password": $fp_password
            }
        }
        ' > "$CONFIG"

    clear
    echo -e "${GREEN}新配置已保存,将重启 Trojan-Go 服务...${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    pause_and_return
}

show_trojan_config() {
    clear
    CONFIG="/root/trojan/config.json"
    if [ -f "$CONFIG" ]; then
        echo -e "${BLUE}------------------------------------------------"
        cat "$CONFIG"
        echo -e "------------------------------------------------${PLAIN}"

        password=$(jq -r '.password[0]' "$CONFIG")
        local_port=$(jq -r '.local_port' "$CONFIG")
        sni=$(jq -r '.ssl.sni' "$CONFIG")
        ws_enabled=$(jq -r '.websocket.enabled' "$CONFIG")
        ws_path=$(jq -r '.websocket.path' "$CONFIG")
        ws_host=$(jq -r '.websocket.host' "$CONFIG")

        node_ip=$(curl -s4m6 ip.sb)
        if [[ -z "$node_ip" ]]; then
            node_ip=$(hostname -I | awk '{print $1}')
        fi

        ws_path_enc=$(echo -n "$ws_path" | sed 's/\//%2F/g')

        if [[ "$ws_enabled" == "true" ]]; then
            node_link="trojan://$password@$node_ip:$local_port?sni=$sni&type=ws&path=$ws_path_enc&host=$ws_host#Trojan"
        else
            node_link="trojan://$password@$node_ip:$local_port?sni=$sni#Trojan"
        fi
        echo -e "${BLUE}您的 Trojan 节点链接: ${PLAIN}"
        echo -e "${GREEN}$node_link${PLAIN}"
        # ---------------------------------
    else
        echo -e "${RED}未检测到配置文件: $CONFIG${PLAIN}"
    fi
    pause_and_return
}

remove_trojan_go() {
    clear
    echo -e "${RED}准备彻底删除 Trojan-Go 及相关配置……${PLAIN}"
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
        echo -e "${RED}SSL 证书与私钥已被删除${PLAIN}"
    else
        echo -e "${GREEN}SSL 证书与私钥保持不变${PLAIN}"
    fi

    echo -e "${GREEN}Trojan-Go 及相关配置已经彻底删除!${PLAIN}"
    read -p "$(echo -e "${BLUE}请按回车键返回主菜单...${PLAIN}")"
    return 123
}

stop_trojan_go() {
    clear
    echo -e "${RED}正在停止 Trojan-Go……${PLAIN}"
    systemctl stop trojan-go
    systemctl status trojan-go --no-pager
    echo -e "${RED}Trojan-Go 已经停止运行!${PLAIN}"
    pause_and_return
}

restart_trojan_go() {
    clear
    echo -e "${GREEN}正在重启 Trojan-Go……${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    echo -e "${GREEN}Trojan-Go 已经重启!${PLAIN}"
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
        echo -e "${BLUE}✦ Trojan_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看配置"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  5.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" choice
        case "$choice" in
            1) show_trojan_config ;;
            2) modify_trojan_config ;;
            3) stop_trojan_go ;;
            4) restart_trojan_go ;;
            5) remove_trojan_go; ret=$?; if [[ $ret -eq 123 ]]; then break; fi ;;
            0) clear; break ;;
            *) echo -e "${RED}无效选择,请重新尝试${PLAIN}" ;;
        esac
    done
}

# ======== Acme证书 ========
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

    read -p "$(echo -e "${BLUE}请输入用于注册 acme 的邮箱（回车使用随机邮箱）: ${PLAIN}")" acme_email
    if [[ -z "$acme_email" ]]; then
        auto_email="$(date +%s%N | md5sum | cut -c 1-16)@gmail.com"
        $ACME_SH --register-account -m "$auto_email"
    else
        $ACME_SH --register-account -m "$acme_email" 2>/dev/null || true
        auto_email="$acme_email"
    fi

    if [[ -z $(type -P lsof) ]]; then
        apt update -y && apt install -y lsof
    fi
    clear
    echo -e "${YELLOW}检测 80 端口占用...${PLAIN}"

    if lsof -i:80 | grep LISTEN >/dev/null 2>&1; then
        echo -e "${RED}80端口被占用,请释放80端口后再申请证书${PLAIN}"
        lsof -i:80
        pause_and_return
        return
    fi

    echo -e "${YELLOW}检测防火墙是否放行80端口...${PLAIN}"
    port_open=false

    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(ufw status | grep -i '80/tcp' | grep -i 'allow')
        if [[ -n "$ufw_status" ]]; then
            port_open=true
        else
            ufw allow 80/tcp
            ufw reload
            port_open=true
            echo -e "${GREEN}已通过 ufw 放行 80 端口${PLAIN}"
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && pgrep -x firewalld >/dev/null 2>&1; then
        fw_status=$(firewall-cmd --list-ports | grep -w '80/tcp')
        if [[ -n "$fw_status" ]]; then
            port_open=true
        else
            firewall-cmd --add-port=80/tcp --permanent
            firewall-cmd --reload
            port_open=true
            echo -e "${GREEN}已通过 firewalld 放行 80 端口${PLAIN}"
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables_status=$(iptables -L INPUT -n | grep 'tcp dpt:80' | grep ACCEPT)
        if [[ -n "$iptables_status" ]]; then
            port_open=true
        else
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save
            elif command -v service >/dev/null 2>&1; then
                service iptables save
            fi
            port_open=true
            echo -e "${GREEN}已通过 iptables 放行 80 端口${PLAIN}"
        fi
    fi

    if ! $port_open; then
        echo -e "${RED}未检测到常见防火墙或未能自动放行80端口,请手动检查防火墙规则${PLAIN}"
        pause_and_return
        return
    fi

    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)

    echo -e "${YELLOW}请输入需要申请证书的域名(直接回车退出申请)${PLAIN}"
    read -p "$(echo -e "${BLUE}域名: ${PLAIN}")" domain
    [[ -z $domain ]] && echo -e "${RED}未输入域名,操作中止${PLAIN}" && pause_and_return && return

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
        echo -e "${RED}域名解析 IP 与本机 IP 不符${PLAIN}"
        echo -e "${YELLOW}域名解析IP: $domainIP, 本机IPv4: $ipv4, IPv6: $ipv6${PLAIN}"
        echo -e "${YELLOW}请检查域名解析后重试${PLAIN}"
        pause_and_return
        return
    fi

    mkdir -p "$CERT_DIR"
    $ACME_SH --issue -d "${domain}" --standalone -k ec-256 --insecure
    $ACME_SH --install-cert -d "${domain}" --key-file "${CERT_DIR}/${domain}.key" --fullchain-file "${CERT_DIR}/${domain}.crt" --ecc

    if [[ -f "${CERT_DIR}/${domain}.crt" && -f "${CERT_DIR}/${domain}.key" ]]; then
        clear
        echo -e "${GREEN}证书申请成功!${PLAIN}"
        echo -e "${YELLOW}证书: ${CERT_DIR}/${domain}.crt${PLAIN}"
        echo -e "${YELLOW}私钥: ${CERT_DIR}/${domain}.key${PLAIN}"
        echo -e "${YELLOW}注册邮箱: $auto_email${PLAIN}"
    else
        echo -e "${RED}证书申请失败,请检查网络和域名解析!${PLAIN}"
    fi
    pause_and_return
}

uninstall_acme() {
    clear
    echo -e "${RED}正在卸载 acme.sh 及相关证书...${PLAIN}"

    if [ -d ~/.acme.sh ]; then
        ~/.acme.sh/acme.sh --uninstall
        rm -rf ~/.acme.sh
        echo -e "${GREEN}acme.sh 已卸载${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 acme.sh,无需卸载${PLAIN}"
    fi

    CERT_DIR="/root/cert"
    if [ -d "$CERT_DIR" ]; then
        echo -e "${YELLOW}检测到证书目录 $CERT_DIR${PLAIN}"
        read -p "$(echo -e "${YELLOW}是否删除该目录下所有证书文件?(y/N): ${PLAIN}")" del_cert
        if [[ "$del_cert" =~ ^[Yy]$ ]]; then
            read -p "$(echo -e "${RED}确定要删除 $CERT_DIR 下的所有证书文件吗?此操作不可恢复!(yes/NO): ${PLAIN}")" double_check
            if [[ "$double_check" == "yes" ]]; then
                rm -rf "$CERT_DIR"
                echo -e "${GREEN}$CERT_DIR 目录及证书已删除${PLAIN}"
            else
                echo -e "${YELLOW}已取消删除证书操作,$CERT_DIR 保持不变${PLAIN}"
            fi
        else
            echo -e "${YELLOW}$CERT_DIR 目录保持不变${PLAIN}"
        fi
    else
        echo -e "${YELLOW}未检测到 $CERT_DIR,无需删除${PLAIN}"
    fi
    pause_and_return
}

# ======== 证书管理 ========
cert_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Trojan_Acme ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}申请证书"
        echo -e "${GREEN}  2.${PLAIN}卸载证书"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" cchoice
        case "$cchoice" in
            1) issue_acme_cert ;;
            2) uninstall_acme ;;
            0) break ;;
            *) echo -e "${RED}无效选择,请重新输入${PLAIN}"; pause_and_return ;;
        esac
    done
}

# ======== 伪装网页 ========
web_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Trojan_Nginx ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}配置Nginx"
        echo -e "${GREEN}  2.${PLAIN}修改Nginx"
        echo -e "${GREEN}  3.${PLAIN}重启Nginx"
        echo -e "${GREEN}  4.${PLAIN}删除Nginx"
        echo -e "${GREEN}  0.${PLAIN}离开Nginx"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" sub_choice
        case "$sub_choice" in
            1) install_fake_web ;;
            2) modify_nginx_conf ;;
            3) restart_nginx ;;
            4) remove_nginx ;;
            0) break ;;
            *) echo -e "${RED}无效选择，请重新输入${PLAIN}"; pause_and_return ;;
        esac
    done
}

install_fake_web() {
    clear
    if [[ -f /etc/nginx/conf.d/trojan.conf ]]; then
        echo -e "${YELLOW}trojan.conf 已存在，已配置过伪装网页。如需重新配置请先删除。${PLAIN}"
        pause_and_return
        return
    fi
    echo -e "${GREEN}开始安装并配置伪装静态网页...${PLAIN}"
    read -p "$(echo -e "${BLUE}请输入 Nginx 监听端口 [默认:80]: ${PLAIN}")" web_port
    web_port=${web_port:-80}

    mkdir -p /var/www/trojan
    if ! cd /var/www/trojan; then
        echo -e "${RED}无法进入 /var/www/trojan 目录${PLAIN}"
        pause_and_return
        return
    fi

    if ! wget -q -O index.html https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/index.html; then
        echo -e "${YELLOW}下载 index.html 失败，请检查网络或 URL${PLAIN}"
    fi

    cat > /etc/nginx/conf.d/trojan.conf <<'EOF'
server {
    listen 127.0.0.1:8080 default_server;
    root /var/www/trojan;
    index index.html;

    location = / {
        try_files /index.html =444;
    }

    location / {
        return 444;
    }
}
EOF

    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 Nginx...${PLAIN}"
        apt update -y
        apt install -y nginx
    fi
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}伪装网页已部署, Nginx 配置完成并已启动${PLAIN}"
    pause_and_return
}

modify_nginx_conf() {
    clear
    conf_path="/etc/nginx/conf.d/trojan.conf"
    if [[ ! -f "$conf_path" ]]; then
        echo -e "${RED}未找到 Nginx 配置文件: $conf_path，未安装或未配置，请先选择1进行配置。${PLAIN}"
        pause_and_return
        return
    fi
    echo -e "${BLUE}当前 Nginx 配置如下:${PLAIN}"
    cat "$conf_path"
    echo -e "${YELLOW}请修改上面内容,在编辑器中保存并退出"
    echo -e "${YELLOW}nano编辑器操作: Ctrl+O 保存,Ctrl+X 退出${PLAIN}"
    read -p "按回车键继续编辑..." temp
    ${EDITOR:-nano} "$conf_path"
    echo -e "${YELLOW}正在重载 Nginx 服务...${PLAIN}"
    systemctl reload nginx
    echo -e "${GREEN}Nginx 配置已修改并重载${PLAIN}"
    pause_and_return
}

restart_nginx() {
    clear
    echo -e "${YELLOW}正在重启 Nginx 服务...${PLAIN}"
    systemctl restart nginx
    systemctl status nginx --no-pager
    echo -e "${GREEN}Nginx 已重启。${PLAIN}"
    pause_and_return
}

remove_nginx() {
    clear
    echo -e "${RED}即将卸载 Nginx 及伪装网页配置...${PLAIN}"
    read -p "$(echo -e "${YELLOW}确定删除 Nginx 及伪装网页吗？(y/n): ${PLAIN}")" yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        systemctl stop nginx
        apt purge -y nginx
        apt autoremove -y
        rm -rf /etc/nginx/conf.d/trojan.conf
        rm -rf /var/www/trojan
        echo -e "${GREEN}Nginx 及伪装网页已删除${PLAIN}"
    else
        echo -e "${YELLOW}取消删除操作${PLAIN}"
    fi
    pause_and_return
}

# ======== 主菜单 ========
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Trojan_Ver.1.6 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}证书管理"
        echo -e "${GREEN}  2.${PLAIN}安装服务"
        echo -e "${GREEN}  3.${PLAIN}管理服务"
        echo -e "${GREEN}  4.${PLAIN}伪装网页"
        echo -e "${GREEN}  0.${PLAIN}退出脚本"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" choice

        case "$choice" in
            1) cert_menu ;;
            2) install_trojan_go ;;
            3) manage_trojan_go ;;
            4) web_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}错误的命运抉择,请重新寻觅世界线。${PLAIN}"; pause_and_return ;;
        esac
    done
}

main_menu
