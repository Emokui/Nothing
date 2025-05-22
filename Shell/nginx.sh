#!/bin/bash

# 彩色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m' # 无色

NGINX_CONF="/etc/nginx/conf.d/reverse_proxy.conf"

clear_screen() {
    # 兼容不同终端
    command -v clear &>/dev/null && clear || printf "\033c"
}

setup_reverse_proxy() {
    clear_screen
    echo -e "${CYAN}\n===== 建立 Nginx 反代配置 =====\n${NC}"

    local api_addr ext_port allowed_ip crt_path key_path proxy_pass_header ip_allow secret is_mihomo

    read -p "請輸入後端服務地址 (如 127.0.0.1:9090): " api_addr

    while true; do
        read -p "請輸入外部訪問端口 (如 8443): " ext_port
        if [[ ! "$ext_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[X] 端口格式錯誤，請重新輸入數字。${NC}"
            continue
        fi
        if ss -tuln | grep -q ":${ext_port}[[:space:]]"; then
            echo -e "${RED}[X] 端口 ${ext_port} 已被佔用，請更換其他端口。${NC}"
        else
            break
        fi
    done

    read -p "請輸入允許訪問的 IP（留空表示允許全部）: " allowed_ip

    echo -e "${YELLOW}\n檢測 /root/cert/ 目錄中的憑證...${NC}"
    crt_path=""
    key_path=""
    if [[ -d /root/cert/ ]]; then
        mapfile -t certs < <(find /root/cert -type f -name "*.crt" | sort)
        mapfile -t keys < <(find /root/cert -type f -name "*.key" | sort)
        if [[ ${#certs[@]} -gt 0 && ${#keys[@]} -gt 0 ]]; then
            echo -e "${GREEN}發現以下憑證：${NC}"
            for i in "${!certs[@]}"; do
                echo -e "${BLUE}$((i+1)). ${certs[i]}${NC}"
            done
            read -p "請選擇憑證序號（或按 Enter 手動輸入）: " cert_index
            if [[ "$cert_index" =~ ^[0-9]+$ && "$cert_index" -ge 1 && "$cert_index" -le ${#certs[@]} ]]; then
                crt_path="${certs[$((cert_index-1))]}"
                key_guess="${crt_path%.crt}.key"
                if [[ -f "$key_guess" ]]; then
                    key_path="$key_guess"
                else
                    echo -e "${YELLOW}未找到與此 crt 同名的 key，請手動輸入 key 路徑。${NC}"
                fi
            fi
        fi
    fi

    while [[ -z "$crt_path" ]]; do
        read -p "請輸入 .crt 憑證完整路徑: " crt_path
        [[ ! -f "$crt_path" ]] && echo -e "${RED}[X] 憑證文件不存在，請重試。${NC}" && crt_path=""
    done
    while [[ -z "$key_path" ]]; do
        read -p "請輸入 .key 金鑰完整路徑: " key_path
        [[ ! -f "$key_path" ]] && echo -e "${RED}[X] 金鑰文件不存在，請重試。${NC}" && key_path=""
    done

    read -p "是否反代 Mihomo API？(y/n): " is_mihomo
    if [[ "${is_mihomo,,}" == "y" ]]; then
        read -p "請輸入 Secret 值: " secret
        proxy_pass_header="proxy_set_header Authorization \"Bearer $secret\";"
    else
        proxy_pass_header=""
    fi

    ip_allow=""
    if [[ -n "$allowed_ip" ]]; then
        ip_allow="allow $allowed_ip;
        deny all;"
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${YELLOW}安裝 Nginx...${NC}"
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y nginx
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nginx
        else
            echo -e "${RED}[X] 未知包管理器，請手動安裝 Nginx。${NC}" && return 1
        fi
    fi

    echo -e "${CYAN}建立反代配置...${NC}"

    cat > "$NGINX_CONF" <<EOF
server {
    listen ${ext_port} ssl;
    server_name localhost;

    ssl_certificate ${crt_path};
    ssl_certificate_key ${key_path};

    location / {
        proxy_pass http://${api_addr};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${proxy_pass_header}
$( [[ -n "$ip_allow" ]] && echo "$ip_allow" )
    }
}
EOF

    echo -e "${YELLOW}重新啟動 Nginx...${NC}"
    nginx -t && systemctl restart nginx

    if [[ $? -eq 0 ]]; then
        echo -e "\n${GREEN}✅ 反代完成，可通過 https://[伺服器IP]:${ext_port} 訪問${NC}"
    else
        echo -e "\n${RED}[X] Nginx 配置有誤，請檢查。${NC}"
    fi
}

view_and_modify_proxy() {
    clear_screen
    echo -e "${CYAN}\n==== 反代配置預覽 ====${NC}"
    if [[ ! -f "$NGINX_CONF" ]]; then
        echo -e "${RED}未找到反代配置${NC}"
        return
    fi
    grep -E "listen|proxy_pass|ssl_certificate|allow|Authorization" "$NGINX_CONF"

    read -p "是否要修改当前反代配置？(y/n): " do_modify
    if [[ "$do_modify" != "y" && "$do_modify" != "Y" ]]; then
        return
    fi

    current_port=$(grep -oP 'listen \K[0-9]+' "$NGINX_CONF")
    current_backend=$(grep -oP 'proxy_pass http://\K[^;]+' "$NGINX_CONF")
    current_crt=$(grep -oP 'ssl_certificate \K[^;]+' "$NGINX_CONF")
    current_key=$(grep -oP 'ssl_certificate_key \K[^;]+' "$NGINX_CONF")
    current_ip=$(grep -oP 'allow \K[^\;]+' "$NGINX_CONF" | head -n 1)
    current_secret=$(grep -oP 'proxy_set_header Authorization "Bearer \K[^"]+' "$NGINX_CONF")

    read -p "后端服务地址 [$current_backend]: " new_backend
    [ -z "$new_backend" ] && new_backend="$current_backend"

    while true; do
        read -p "外部访问端口 [$current_port]: " new_port
        [ -z "$new_port" ] && new_port="$current_port"
        if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[X] 端口格式错误，请重新输入数字。${NC}"
            continue
        fi
        if ss -tuln | grep -q ":${new_port}[[:space:]]" && [[ "$new_port" != "$current_port" ]]; then
            echo -e "${RED}[X] 端口 ${new_port} 已被占用，请更换其他端口。${NC}"
        else
            break
        fi
    done

    read -p "证书路径 [$current_crt]: " new_crt
    [ -z "$new_crt" ] && new_crt="$current_crt"
    while [[ ! -f "$new_crt" ]]; do
        echo -e "${RED}[X] 证书文件不存在，请重新输入。${NC}"
        read -p "证书路径 [$current_crt]: " new_crt
        [ -z "$new_crt" ] && new_crt="$current_crt"
    done

    read -p "密钥路径 [$current_key]: " new_key
    [ -z "$new_key" ] && new_key="$current_key"
    while [[ ! -f "$new_key" ]]; do
        echo -e "${RED}[X] 金钥文件不存在，请重新输入。${NC}"
        read -p "密钥路径 [$current_key]: " new_key
        [ -z "$new_key" ] && new_key="$current_key"
    done

    read -p "允许访问的 IP（留空允许全部） [$current_ip]: " new_ip
    [ -z "$new_ip" ] && new_ip="$current_ip"

    read -p "Mihomo Secret（如没有配置Mihomo API请留空）[$current_secret]: " new_secret
    if [[ -n "$new_secret" ]]; then
        proxy_pass_header="proxy_set_header Authorization \"Bearer $new_secret\";"
    elif [[ -n "$current_secret" ]]; then
        proxy_pass_header="proxy_set_header Authorization \"Bearer $current_secret\";"
    else
        proxy_pass_header=""
    fi

    ip_allow=""
    if [[ -n "$new_ip" ]]; then
        ip_allow="allow $new_ip;
        deny all;"
    fi

    cat > "$NGINX_CONF" <<EOF
server {
    listen ${new_port} ssl;
    server_name localhost;

    ssl_certificate ${new_crt};
    ssl_certificate_key ${new_key};

    location / {
        proxy_pass http://${new_backend};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${proxy_pass_header}
$( [[ -n "$ip_allow" ]] && echo "$ip_allow" )
    }
}
EOF

    echo -e "${YELLOW}重新加载 Nginx...${NC}"
    nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ 配置已更新并重载${NC}"
}

restart_proxy() {
    clear_screen
    echo -e "${CYAN}重啟 Nginx...${NC}"
    systemctl restart nginx && echo -e "${GREEN}✅ Nginx 已重啟${NC}"
}

stop_proxy() {
    clear_screen
    echo -e "${YELLOW}停止 Nginx...${NC}"
    systemctl stop nginx && echo -e "${GREEN}✅ Nginx 已停止${NC}"
}

remove_proxy() {
    clear_screen
    echo -e "${RED}移除 Nginx 反代...${NC}"
    rm -f "$NGINX_CONF"
    if command -v apt >/dev/null 2>&1; then
        apt purge -y nginx nginx-common && apt autoremove -y
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y nginx
    fi
    echo -e "${GREEN}✅ Nginx 及反代已完全移除${NC}"
}

show_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}===== Nginx 反代菜單 =====${NC}"
        echo -e "${GREEN}1${NC}. 建立反代"
        echo -e "${GREEN}2${NC}. 查看及修改反代配置"
        echo -e "${YELLOW}3${NC}. 停止反代"
        echo -e "${YELLOW}4${NC}. 重啟反代"
        echo -e "${RED}5${NC}. 卸載反代與 Nginx"
        echo -e "${BLUE}0${NC}. 退出"
        echo -ne "${CYAN}請選擇操作: ${NC}"
        read opt

        case "$opt" in
            1) setup_reverse_proxy ;;
            2) view_and_modify_proxy ;;
            3) stop_proxy ;;
            4) restart_proxy ;;
            5) remove_proxy ;;
            0) clear_screen; exit 0 ;;
            *) echo -e "${RED}請輸入正確選項。${NC}"; sleep 1 ;;
        esac
    done
}

show_menu
