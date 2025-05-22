#!/bin/bash

# 彩色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m' # 无色

CONF_DIR="/etc/nginx/conf.d/"
PROXY_PREFIX="multi_reverse_proxy_"

clear_screen() {
    command -v clear &>/dev/null && clear || printf "\033c"
}

list_proxies() {
    find "$CONF_DIR" -maxdepth 1 -type f -name "${PROXY_PREFIX}*.conf" | while read -r f; do
        domain=$(basename "$f" | sed -r "s/^${PROXY_PREFIX}(.*)\.conf/\1/")
        echo -e "${GREEN}${domain}${NC} ($f)"
    done
}

choose_proxy_conf() {
    configs=( $(find "$CONF_DIR" -maxdepth 1 -type f -name "${PROXY_PREFIX}*.conf") )
    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${RED}没有已存在的反代配置。${NC}"
        return 1
    fi
    echo -e "${CYAN}已有反代配置：${NC}"
    for i in "${!configs[@]}"; do
        domain=$(basename "${configs[$i]}" | sed -r "s/^${PROXY_PREFIX}(.*)\.conf/\1/")
        echo -e "${GREEN}$((i+1))${NC}. ${domain} (${configs[$i]})"
    done
    echo -e "${BLUE}0${NC}. 返回主菜单"
    while true; do
        read -p "请选择序号: " sel
        if [[ "$sel" == "0" ]]; then
            return 1   # 返回主菜单
        elif [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#configs[@]} ]]; then
            CHOSEN_CONF="${configs[$((sel-1))]}"
            break
        else
            echo -e "${RED}输入无效，请重新选择。${NC}"
        fi
    done
}

setup_reverse_proxy() {
    clear_screen
    echo -e "${CYAN}\n===== 新建 Nginx 反代配置 =====\n${NC}"

    local api_addr ext_port allowed_ip crt_path key_path proxy_pass_header ip_allow secret is_mihomo domain

    while true; do
        read -p "请输入要反代的域名（如 clash.example.com）: " domain
        [[ -z "$domain" ]] && echo -e "${RED}域名不能为空。${NC}" && continue
        conf_file="${CONF_DIR}${PROXY_PREFIX}${domain}.conf"
        if [[ -e "$conf_file" ]]; then
            echo -e "${RED}该域名已存在反代配置，请更换域名。${NC}"
            continue
        fi
        break
    done

    read -p "请输入后端服务地址 (如 127.0.0.1:9090): " api_addr

    while true; do
        read -p "请输入外部访问端口 (如 8443): " ext_port
        if [[ ! "$ext_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[X] 端口格式错误，请重新输入数字。${NC}"
            continue
        fi
        if ss -tuln | grep -q ":${ext_port}[[:space:]]"; then
            echo -e "${RED}[X] 端口 ${ext_port} 已被占用，请更换其他端口。${NC}"
        else
            break
        fi
    done

    read -p "请输入允许访问的 IP（留空表示允许全部）: " allowed_ip

    echo -e "${YELLOW}\n检测 /root/cert/ 目录中的证书...${NC}"
    crt_path=""
    key_path=""
    if [[ -d /root/cert/ ]]; then
        mapfile -t certs < <(find /root/cert -type f -name "*.crt" | sort)
        mapfile -t keys < <(find /root/cert -type f -name "*.key" | sort)
        if [[ ${#certs[@]} -gt 0 && ${#keys[@]} -gt 0 ]]; then
            echo -e "${GREEN}发现以下证书：${NC}"
            for i in "${!certs[@]}"; do
                echo -e "${BLUE}$((i+1)). ${certs[i]}${NC}"
            done
            read -p "请选择证书序号（或按 Enter 手动输入）: " cert_index
            if [[ "$cert_index" =~ ^[0-9]+$ && "$cert_index" -ge 1 && "$cert_index" -le ${#certs[@]} ]]; then
                crt_path="${certs[$((cert_index-1))]}"
                key_guess="${crt_path%.crt}.key"
                if [[ -f "$key_guess" ]]; then
                    key_path="$key_guess"
                else
                    echo -e "${YELLOW}未找到与此 crt 同名的 key，请手动输入 key 路径。${NC}"
                fi
            fi
        fi
    fi

    while [[ -z "$crt_path" ]]; do
        read -p "请输入 .crt 证书完整路径: " crt_path
        [[ ! -f "$crt_path" ]] && echo -e "${RED}[X] 证书文件不存在，请重试。${NC}" && crt_path=""
    done
    while [[ -z "$key_path" ]]; do
        read -p "请输入 .key 密钥完整路径: " key_path
        [[ ! -f "$key_path" ]] && echo -e "${RED}[X] 密钥文件不存在，请重试。${NC}" && key_path=""
    done

    read -p "是否反代 Mihomo API？(y/n): " is_mihomo
    if [[ "${is_mihomo,,}" == "y" ]]; then
        read -p "请输入 Secret 值: " secret
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
        echo -e "${YELLOW}正在安装 Nginx...${NC}"
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y nginx
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nginx
        else
            echo -e "${RED}[X] 未知包管理器，请手动安装 Nginx。${NC}" && return 1
        fi
    fi

    echo -e "${CYAN}生成反代配置...${NC}"

    cat > "$conf_file" <<EOF
server {
    listen ${ext_port} ssl;
    server_name ${domain};

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

    echo -e "${YELLOW}重启 Nginx...${NC}"
    nginx -t && systemctl reload nginx

    if [[ $? -eq 0 ]]; then
        echo -e "\n${GREEN}✅ 反代完成，可通过 https://${domain}:${ext_port} 访问${NC}"
    else
        echo -e "\n${RED}[X] Nginx 配置有误，请检查。${NC}"
    fi
}

view_and_modify_proxy() {
    clear_screen
    if ! choose_proxy_conf; then return; fi
    conf_file="$CHOSEN_CONF"

    echo -e "${CYAN}\n==== 反代配置预览 ====${NC}"
    grep -E "server_name|listen|proxy_pass|ssl_certificate|allow|Authorization" "$conf_file"

    read -p "是否要修改当前反代配置？(y/n): " do_modify
    if [[ "$do_modify" != "y" && "$do_modify" != "Y" ]]; then
        return
    fi

    current_domain=$(grep -oP 'server_name\s+\K[^\s;]+' "$conf_file")
    current_port=$(grep -oP 'listen\s+\K[0-9]+' "$conf_file")
    current_backend=$(grep -oP 'proxy_pass http://\K[^;]+' "$conf_file")
    current_crt=$(grep -oP 'ssl_certificate\s+\K[^;]+' "$conf_file")
    current_key=$(grep -oP 'ssl_certificate_key\s+\K[^;]+' "$conf_file")
    current_ip=$(grep -oP 'allow\s+\K[^\;]+' "$conf_file" | head -n 1)
    current_secret=$(grep -oP 'proxy_set_header Authorization "Bearer \K[^"]+' "$conf_file")

    read -p "域名 [$current_domain]: " new_domain
    [ -z "$new_domain" ] && new_domain="$current_domain"
    new_conf_file="${CONF_DIR}${PROXY_PREFIX}${new_domain}.conf"
    if [[ "$new_domain" != "$current_domain" && -e "$new_conf_file" ]]; then
        echo -e "${RED}该域名已存在反代配置，请更换域名。${NC}"
        return
    fi

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
        echo -e "${RED}[X] 密钥文件不存在，请重新输入。${NC}"
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

    cat > "$new_conf_file" <<EOF
server {
    listen ${new_port} ssl;
    server_name ${new_domain};

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

    if [[ "$new_conf_file" != "$conf_file" ]]; then
        rm -f "$conf_file"
    fi

    echo -e "${YELLOW}重载 Nginx...${NC}"
    nginx -t && systemctl reload nginx && echo -e "${GREEN}✅ 配置已更新并重载${NC}"
}

remove_proxy() {
    while true; do
        clear_screen
        configs=( $(find "$CONF_DIR" -maxdepth 1 -type f -name "${PROXY_PREFIX}*.conf") )
        if [[ ${#configs[@]} -eq 0 ]]; then
            echo -e "${RED}没有已存在的反代配置。${NC}"
            read -p "按回车返回主菜单..." && return
        fi
        echo -e "${CYAN}已有反代配置：${NC}"
        for i in "${!configs[@]}"; do
            domain=$(basename "${configs[$i]}" | sed -r "s/^${PROXY_PREFIX}(.*)\.conf/\1/")
            echo -e "${GREEN}$((i+1))${NC}. ${domain} (${configs[$i]})"
        done
        echo -e "${BLUE}0${NC}. 返回主菜单"
        echo -e "${RED}99${NC}. 删除所有反代配置及Nginx"
        read -p "请选择序号: " sel
        if [[ "$sel" == "0" ]]; then
            return
        elif [[ "$sel" == "99" ]]; then
            remove_all_proxies
            read -p "按回车返回主菜单..." && return
        elif [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#configs[@]} ]]; then
            conf_file="${configs[$((sel-1))]}"
            echo -e "${RED}移除反代配置：${conf_file}${NC}"
            rm -f "$conf_file"
            nginx -t && systemctl reload nginx
            echo -e "${GREEN}✅ 配置已移除并重载${NC}"
            read -p "按回车继续..." 
        else
            echo -e "${RED}输入无效，请重新选择。${NC}"
            sleep 1
        fi
    done
}

remove_all_proxies() {
    clear_screen
    echo -e "${RED}将删除所有反代配置文件及Nginx本体！${NC}"
    read -p "确认删除所有反代及Nginx？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}已取消操作。${NC}"
        return
    fi
    find "$CONF_DIR" -maxdepth 1 -type f -name "${PROXY_PREFIX}*.conf" -exec rm -f {} \;
    if command -v apt >/dev/null 2>&1; then
        apt purge -y nginx nginx-common && apt autoremove -y
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y nginx
    fi
    echo -e "${GREEN}✅ 已删除所有反代配置及Nginx${NC}"
}

restart_proxy() {
    clear_screen
    echo -e "${CYAN}重启 Nginx...${NC}"
    systemctl restart nginx && echo -e "${GREEN}✅ Nginx 已重启${NC}"
}

stop_proxy() {
    clear_screen
    echo -e "${YELLOW}停止 Nginx...${NC}"
    systemctl stop nginx && echo -e "${GREEN}✅ Nginx 已停止${NC}"
}

show_menu() {
    while true; do
        clear_screen
        echo -e "${CYAN}===== Nginx 多反代管理菜单 =====${NC}"
        echo -e "${GREEN}1${NC}. 新建反代"
        echo -e "${YELLOW}2${NC}. 列出所有反代"
        echo -e "${GREEN}3${NC}. 查看及修改反代配置"
        echo -e "${RED}4${NC}. 删除反代"
        echo -e "${RED}5${NC}. 删除所有反代及Nginx"
        echo -e "${YELLOW}6${NC}. 重启所有反代"
        echo -e "${YELLOW}7${NC}. 停止所有反代"
        echo -e "${BLUE}0${NC}. 退出"
        echo -ne "${CYAN}请选择操作: ${NC}"
        read opt

        case "$opt" in
            1) setup_reverse_proxy ;;
            2) clear_screen; echo -e "${CYAN}当前所有反代：${NC}"; list_proxies; read -p "按回车返回菜单..." ;;
            3) view_and_modify_proxy ;;
            4) remove_proxy ;;
            5) remove_all_proxies; read -p "按回车返回菜单..." ;;
            6) restart_proxy; read -p "按回车返回菜单..." ;;
            7) stop_proxy; read -p "按回车返回菜单..." ;;
            0) clear_screen; exit 0 ;;
            *) echo -e "${RED}请输入正确选项。${NC}"; sleep 1 ;;
        esac
    done
}

show_menu
