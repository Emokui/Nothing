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
    read -p "$(echo -e "${BLUE}請按回車鍵返回上一層...${PLAIN}")" temp
    clear
}

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "======================================"
    echo "        鳳凰院凶真 - Trojan-Go"
    echo "        El Psy Kongroo. Version 1.4"
    echo "======================================"
    echo -e "${PLAIN}"
}

show_trojan_config() {
    CONFIG="/root/trojan/config.json"
    echo -e "${YELLOW}${BOLD}當前 Trojan-Go 配置如下:${PLAIN}"
    if [ -f "$CONFIG" ]; then
        echo -e "${CYAN}------------------------------------------------"
        cat "$CONFIG"
        echo -e "------------------------------------------------${PLAIN}"
    else
        echo -e "${RED}未檢測到配置文件: $CONFIG${PLAIN}"
    fi
    pause_and_return
}

uninstall_acme() {
    echo -e "${RED}${BOLD}正在卸載 acme.sh 及相关证书...${PLAIN}"
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
        echo -e "${RED}未檢測到配置文件: $CONFIG${PLAIN}"
        pause_and_return
        return
    fi
    echo -e "${YELLOW}${BOLD}當前 Trojan-Go 配置如下:${PLAIN}"
    echo -e "${CYAN}------------------------------------------------"
    cat "$CONFIG"
    echo -e "------------------------------------------------${PLAIN}"
    echo -e "${YELLOW}請交互輸入新配置項（直接回車為保留原值）：${PLAIN}"

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

    read -p "$(echo -e "${CYAN}請輸入本地監聽端口 (節點端口) [預設: $old_local_port]: ${PLAIN}")" local_port
    local_port=${local_port:-$old_local_port}

    read -p "$(echo -e "${CYAN}請輸入轉發目標地址 [預設: $old_remote_addr]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-$old_remote_addr}

    read -p "$(echo -e "${CYAN}請輸入轉發目標端口 [預設: $old_remote_port]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-$old_remote_port}

    read -p "$(echo -e "${CYAN}請輸入密碼 (回車隨機8位數字字母) [預設: $old_password]: ${PLAIN}")" password
    if [ -z "$password" ]; then
        password=$old_password
        if [ -z "$password" ]; then
            password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
            echo -e "${GREEN}已自動生成密碼: $password${PLAIN}"
        fi
    fi

    read -p "$(echo -e "${CYAN}請輸入路徑 [預設: $old_ws_path]: ${PLAIN}")" ws_path
    ws_path=${ws_path:-$old_ws_path}

    cert_dir="/root/cert"
    certs=($(ls $cert_dir/*.crt 2>/dev/null))
    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${YELLOW}檢測到以下域名證書，請選擇：${PLAIN}"
        select cert_path in "${certs[@]}"; do
            if [[ -n "$cert_path" ]]; then
                domain_base=$(basename "$cert_path" .crt)
                key_path="$cert_dir/${domain_base}.key"
                if [[ -f "$key_path" ]]; then
                    break
                else
                    echo -e "${RED}未找到對應私鑰：$key_path，請重新選擇。${PLAIN}"
                fi
            fi
        done
    else
        read -p "$(echo -e "${CYAN}請輸入證書 cert 路徑 [預設: $old_cert]: ${PLAIN}")" cert_path
        cert_path=${cert_path:-$old_cert}
        read -p "$(echo -e "${CYAN}請輸入私鑰 key 路徑 [預設: $old_key]: ${PLAIN}")" key_path
        key_path=${key_path:-$old_key}
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi

    if [[ -z "$detected_domain" ]]; then
        read -p "$(echo -e "${CYAN}請輸入你的域名 (證書域名) [預設: $old_domain]: ${PLAIN}")" domain
        domain=${domain:-$old_domain}
    else
        read -p "$(echo -e "${CYAN}請輸入你的域名 (證書域名) [預設: $detected_domain]: ${PLAIN}")" domain
        domain=${domain:-$detected_domain}
    fi

    read -p "$(echo -e "${CYAN}請輸入 WebSocket Host（默認與證書域名相同） [預設: $domain]: ${PLAIN}")" ws_host
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

    echo -e "${GREEN}新配置已保存，將重啟 Trojan-Go 服務...${PLAIN}"
    echo -e "${CYAN}------------------------------------------------"
    cat "$CONFIG"
    echo -e "------------------------------------------------${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    pause_and_return
}

remove_trojan_go() {
    echo -e "${RED}${BOLD}準備徹底刪除 Trojan-Go 及相關配置……${PLAIN}"
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

    read -p "$(echo -e "${YELLOW}是否刪除 SSL 憑證及私鑰？(y/n): ${PLAIN}")" delete_ssl
    if [[ "$delete_ssl" == "y" || "$delete_ssl" == "Y" ]]; then
        rm -f /root/cert.crt
        rm -f /root/private.key
        rm -f /root/trojan/config.json
        echo -e "${RED}SSL 憑證與私鑰已被刪除。${PLAIN}"
    else
        echo -e "${YELLOW}SSL 憑證與私鑰保持不變。${PLAIN}"
    fi

    echo -e "${GREEN}Trojan-Go 及相關配置已經徹底刪除！${PLAIN}"
    pause_and_return
}

start_trojan_go() {
    echo -e "${GREEN}${BOLD}正在啟動 Trojan-Go……${PLAIN}"
    systemctl start trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${GREEN}若你看見『Active: active (running)』，那麼你已經成功打開世界線之門。${PLAIN}"
    pause_and_return
}

stop_trojan_go() {
    echo -e "${YELLOW}${BOLD}正在停止 Trojan-Go……${PLAIN}"
    systemctl stop trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${YELLOW}Trojan-Go 已經停止運行！${PLAIN}"
    pause_and_return
}

restart_trojan_go() {
    echo -e "${GREEN}${BOLD}正在重啟 Trojan-Go……${PLAIN}"
    systemctl restart trojan-go
    systemctl status trojan-go --no-pager
    echo ""
    echo -e "${GREEN}Trojan-Go 已經重啟！${PLAIN}"
    pause_and_return
}

issue_acme_cert() {
    CERT_DIR="/root/cert"

    read -p "$(echo -e "${CYAN}請輸入你的域名（例如 example.com）: ${PLAIN}")" domain
    if [[ -z "$domain" ]]; then
      echo -e "${RED}請輸入域名參數，操作中止。${PLAIN}"
      pause_and_return
      return 1
    fi

    read -p "$(echo -e "${CYAN}請輸入你的 Email（ACME 使用，直接回車將隨機生成）: ${PLAIN}")" email
    if [ -z "$email" ]; then
      email="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)@gmail.com"
      echo -e "${YELLOW}[!] 未輸入，已生成：$email${PLAIN}"
    fi

    mkdir -p "$CERT_DIR"

    if [[ -f "${CERT_DIR}/${domain}.crt" && -f "${CERT_DIR}/${domain}.key" ]]; then
      echo -e "${GREEN}[✓] 已檢測到 ${domain} 憑證，跳過簽發步驟。${PLAIN}"
      pause_and_return
      return 0
    fi

    if ! command -v curl &>/dev/null; then
      echo -e "${YELLOW}安裝 curl...${PLAIN}"
      apt update -y && apt install -y curl
    fi

    if ! command -v socat &>/dev/null; then
      echo -e "${YELLOW}安裝 socat...${PLAIN}"
      apt update -y && apt install -y socat
    fi

    if [ ! -d ~/.acme.sh ]; then
      echo -e "${YELLOW}[*] 安裝 acme.sh ...${PLAIN}"
      curl https://get.acme.sh | sh
    fi

    ~/.acme.sh/acme.sh --register-account -m "$email"

    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone
    if [ $? -ne 0 ]; then
      echo -e "${RED}[✘] 憑證簽發失敗，請確認 DNS 或 80 埠可用性。${PLAIN}"
      pause_and_return
      return 2
    fi

    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
      --key-file "${CERT_DIR}/${domain}.key" \
      --fullchain-file "${CERT_DIR}/${domain}.crt"

    echo -e "${GREEN}[✓] 憑證已申請並保存於 ${CERT_DIR}/${PLAIN}"
    pause_and_return
}

install_trojan_go() {
    echo -e "${GREEN}${BOLD}準備安裝 Trojan-Go 並設置配置……${PLAIN}"
    mkdir -p /root/trojan && cd /root/trojan

    if [ -f ./trojan-go ]; then
        echo -e "${YELLOW}檢測到 trojan-go 已存在，跳過下載。${PLAIN}"
    else
        wget https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/trojan-go && chmod +x trojan-go
        echo -e "${GREEN}trojan-go 已下載。${PLAIN}"
    fi

    echo -e "${YELLOW}請根據提示設置 Trojan-Go 配置${PLAIN}"

    read -p "$(echo -e "${CYAN}請輸入本地監聽端口 (節點端口) [預設: 443]: ${PLAIN}")" local_port
    local_port=${local_port:-443}

    read -p "$(echo -e "${CYAN}請輸入轉發目標地址 [預設: speedtest.tele2.net]: ${PLAIN}")" remote_addr
    remote_addr=${remote_addr:-speedtest.tele2.net}

    read -p "$(echo -e "${CYAN}請輸入轉發目標端口 [預設: 80]: ${PLAIN}")" remote_port
    remote_port=${remote_port:-80}

    read -p "$(echo -e "${CYAN}請輸入密碼 (回車隨機8位數字字母，建議更改): ${PLAIN}")" password
    if [ -z "$password" ]; then
        password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
        echo -e "${GREEN}已自動生成密碼: $password${PLAIN}"
    fi

    read -p "$(echo -e "${CYAN}請輸入路徑 [預設: /]: ${PLAIN}")" ws_path
    ws_path=${ws_path:-/}

    cert_dir="/root/cert"
    certs=($(ls $cert_dir/*.crt 2>/dev/null))
    if [[ ${#certs[@]} -gt 0 ]]; then
        echo -e "${YELLOW}檢測到以下域名證書，請選擇：${PLAIN}"
        select cert_path in "${certs[@]}"; do
            if [[ -n "$cert_path" ]]; then
                domain_base=$(basename "$cert_path" .crt)
                key_path="$cert_dir/${domain_base}.key"
                if [[ -f "$key_path" ]]; then
                    break
                else
                    echo -e "${RED}未找到對應私鑰：$key_path，請重新選擇。${PLAIN}"
                fi
            fi
        done
    else
        echo -e "${YELLOW}⚠️ 未在 $cert_dir 中找到 .crt 檔案，請手動輸入憑證路徑。${PLAIN}"
        read -p "$(echo -e "${CYAN}請輸入證書 cert 路徑:${PLAIN}")" cert_path
        read -p "$(echo -e "${CYAN}請輸入私鑰 key 路徑:${PLAIN}")" key_path
    fi

    detected_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/^subject=.*CN=\s*\([^,\/]*\).*/\1/p')
    if [[ -z "$detected_domain" ]]; then
        detected_domain=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -oE "DNS:[^, ]+" | head -n 1 | cut -d ":" -f2)
    fi

    if [[ -z "$detected_domain" ]]; then
        echo -e "${YELLOW}⚠️ 無法自動從憑證中提取域名，請手動輸入.${PLAIN}"
        read -p "$(echo -e "${CYAN}請輸入你的域名 (證書域名): ${PLAIN}")" domain
    else
        read -p "$(echo -e "${CYAN}請輸入你的域名 (證書域名) [預設: $detected_domain]: ${PLAIN}")" domain
        domain=${domain:-$detected_domain}
    fi

    read -p "$(echo -e "${CYAN}請輸入 WebSocket Host（默認與證書域名相同）: ${PLAIN}")" ws_host
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
    echo -e "${GREEN}✅ Trojan-Go 已安裝並設置開機自啟！${PLAIN}"
    pause_and_return
}

manage_trojan_go() {
    while true; do
        echo -e "${BLUE}${BOLD}========== Trojan-Go 管理選單 ==========${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 啟動 Trojan-Go"
        echo -e "${GREEN}2.${PLAIN} 停止 Trojan-Go"
        echo -e "${GREEN}3.${PLAIN} 重啟 Trojan-Go"
        echo -e "${GREEN}4.${PLAIN} 查看 Trojan-Go 配置"
        echo -e "${GREEN}5.${PLAIN} 修改 Trojan-Go 配置"
        echo -e "${GREEN}6.${PLAIN} 刪除 Trojan-Go"
        echo -e "${GREEN}0.${PLAIN} 返回主菜單"
        read -p "$(echo -e "${YELLOW}請選擇操作 [0-6]: ${PLAIN}")" choice
        case "$choice" in
            1) start_trojan_go ;;
            2) stop_trojan_go ;;
            3) restart_trojan_go ;;
            4) show_trojan_config ;;
            5) modify_trojan_config ;;
            6) remove_trojan_go ;;
            0) clear; break ;;
            *) echo -e "${RED}無效選擇，請重新嘗試。${PLAIN}" ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        banner
        echo -e "${BOLD}${BLUE}========== 主 選 單 ==========${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} Acme證書申请"
        echo -e "${GREEN}2.${PLAIN} 安裝 Trojan-Go"
        echo -e "${GREEN}3.${PLAIN} 管理 Trojan-Go"
        echo -e "${GREEN}4.${PLAIN} 卸載 Acme 及證書"
        echo -e "${GREEN}0.${PLAIN} 離開命運石之門"
        echo ""
        read -p "$(echo -e "${YELLOW}請輸入選項 [0-4]: ${PLAIN}")" choice

        case "$choice" in
            1) issue_acme_cert ;;
            2) install_trojan_go ;;
            3) manage_trojan_go ;;
            4) uninstall_acme ;;
            0) clear; echo -e "${CYAN}命運已中斷，回歸現實世界……${PLAIN}" && exit 0 ;;
            *) echo -e "${RED}錯誤的命運選擇。請重新啟動世界線。${PLAIN}"; pause_and_return ;;
        esac
    done
}

main_menu
