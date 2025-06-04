#!/bin/bash

# 彩色与格式化
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
PLAIN='\033[0m'

red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

pause_and_return() {
    echo ""
    read -p "$(echo -e "${BLUE}请按回车键返回上一层...${PLAIN}")" temp
    clear
}

# 检测系统架构
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

# 获取最新版下载地址
get_latest_download_url() {
    local arch="$1"
    local api_url="https://api.github.com/repos/apernet/hysteria/releases/latest"
    local asset_name
    case "$arch" in
        amd64) asset_name="hysteria-linux-amd64" ;;
        arm64) asset_name="hysteria-linux-arm64" ;;
        armv7) asset_name="hysteria-linux-armv7" ;;
        386)   asset_name="hysteria-linux-386" ;;
        *) asset_name="hysteria-linux-$arch" ;;
    esac
    curl -s "$api_url" | grep "browser_download_url" | grep "$asset_name\"" | head -n 1 | cut -d '"' -f 4
}

generate_self_signed_cert() {
    echo ""
    yellow "开始生成自签名证书..."
    DEFAULT_DOMAIN="bing.com"
    DEFAULT_CERT_PATH="/etc/cert"
    DEFAULT_DAYS=36500

    read -rp "$(echo -e "${YELLOW}请输入证书的域名${PLAIN}（默认: ${CYAN}${DEFAULT_DOMAIN}${PLAIN}）: ")" domain
    domain="${domain:-$DEFAULT_DOMAIN}"
    read -rp "$(echo -e "${YELLOW}请输入证书存放路径${PLAIN}（默认: ${CYAN}${DEFAULT_CERT_PATH}${PLAIN}）: ")" cert_path
    cert_path="${cert_path:-$DEFAULT_CERT_PATH}"
    read -rp "$(echo -e "${YELLOW}请输入证书有效天数${PLAIN}（默认: ${CYAN}${DEFAULT_DAYS}${PLAIN}）: ")" days
    days="${days:-$DEFAULT_DAYS}"

    key_file="${cert_path}/server.key"
    crt_file="${cert_path}/server.crt"

    sudo mkdir -p "$cert_path"
    echo -e "${BLUE}生成 ECC 私钥...${PLAIN}"
    sudo openssl ecparam -name prime256v1 -genkey -noout -out "$key_file"

    echo -e "${BLUE}使用私钥生成自签证书...${PLAIN}"
    sudo openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain"

    sudo chmod 644 "$crt_file"
    sudo chmod 600 "$key_file"

    echo ""
    green "自签名证书生成完成！"
    echo "私钥位置: $key_file"
    echo "证书位置: $crt_file"
    pause_and_return
}

issue_acme_cert() {
    CERT_DIR="/root/cert"
    ACME_SH="$HOME/.acme.sh/acme.sh"

    # 检查依赖
    for bin in jq dig lsof curl wget socat openssl; do
        if ! command -v $bin >/dev/null 2>&1; then
            echo -e "${YELLOW}缺少依赖 $bin，正在安装...${PLAIN}"
            apt update -y
            case $bin in
                jq) apt install -y jq ;;
                dig) apt install -y dnsutils ;;
                lsof) apt install -y lsof ;;
                curl) apt install -y curl ;;
                wget) apt install -y wget ;;
                socat) apt install -y socat ;;
                openssl) apt install -y openssl ;;
            esac
        fi
    done

    # 自动安装 acme.sh
    if [ ! -f "$ACME_SH" ]; then
        echo -e "${YELLOW}[*] 正在安装 acme.sh ...${PLAIN}"
        curl https://get.acme.sh | sh
        source ~/.bashrc
        bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    fi

    # 强制切换为 Let's Encrypt
    $ACME_SH --set-default-ca --server letsencrypt

    # 判断是否已注册邮箱，只在未注册时自动注册
    if ! $ACME_SH --list-account 2>/dev/null | grep -q letsencrypt; then
        auto_email="$(date +%s%N | md5sum | cut -c 1-16)@gmail.com"
        $ACME_SH --register-account -m "$auto_email"
    else
        # 获取已注册邮箱
        auto_email="$($ACME_SH --list-account 2>/dev/null | grep Registered | grep letsencrypt | awk '{print $4}')"
    fi

    mkdir -p "$CERT_DIR"

    # 获取本机IP
    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)

    echo -e "${YELLOW}请输入需要申请证书的域名，域名需解析到本机IP！${PLAIN}"
    read -p "$(echo -e "${CYAN}域名: ${PLAIN}")" domain
    [[ -z $domain ]] && echo -e "${RED}未输入域名，操作中止。${PLAIN}" && pause_and_return && return

    # 检查域名是否解析到本机IP
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

    if [[ -f "${CERT_DIR}/${domain}.crt" && -f "${CERT_DIR}/${domain}.key" ]]; then
        echo -e "${GREEN}[✓] 已检测到 ${domain} 证书，跳过签发步骤。${PLAIN}"
        pause_and_return
        return 0
    fi

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

show_hysteria_config() {
    HY2_DIR="/root/hysteria"
    CONFIG_PATH="${HY2_DIR}/config.yaml"
    if [ -f "$CONFIG_PATH" ]; then
        echo -e "${YELLOW}当前 Hysteria 配置如下:${PLAIN}"
        echo -e "${CYAN}------------------------------------------------"
        cat "$CONFIG_PATH"
        echo -e "------------------------------------------------${PLAIN}"
    else
        echo -e "${RED}未检测到配置文件: $CONFIG_PATH${PLAIN}"
    fi
    pause_and_return
}

cert_menu() {
    while true; do
        clear
        echo "#############################################"
        echo -e "#        ${GREEN}证书生成/申请辅助工具${PLAIN}           #"
        echo "#############################################"
        echo ""
        echo -e " ${GREEN}1.${PLAIN} 生成自签名证书"
        echo -e " ${GREEN}2.${PLAIN} 申请域名证书"
        echo -e " ${GREEN}0.${PLAIN} 返回主菜单"
        echo ""

        read -p "$(echo -e "${YELLOW}请输入选项 [0-2]: ${PLAIN}")" choice

        case "$choice" in
            1) generate_self_signed_cert ;;
            2) issue_acme_cert ;;
            0) break ;;
            *) red "无效选项，请重新输入。"; pause_and_return ;;
        esac
    done
}

random_pass() {
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10
}

select_cert_for_hysteria() {
    echo -e "${YELLOW}请选择证书配置方式：${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 自签证书"
    echo -e "${GREEN}2.${PLAIN} 域名证书"
    echo -e "${GREEN}3.${PLAIN} 手动输入证书路径"
    echo -e "${GREEN}0.${PLAIN} 返回主菜单"
    read -p "$(echo -e "${YELLOW}请选择 [0-3]: ${PLAIN}")" cert_option

    if [[ "$cert_option" == "1" ]]; then
        if [[ -f /etc/cert/server.crt && -f /etc/cert/server.key ]]; then
            cert_path="/etc/cert/server.crt"
            key_path="/etc/cert/server.key"
            return 0
        else
            red "未检测到 /etc/cert/server.crt 与 /etc/cert/server.key，请先生成自签证书！"
            pause_and_return
            return 1
        fi
    elif [[ "$cert_option" == "2" ]]; then
        if ! compgen -G "/root/cert/*.crt" > /dev/null; then
            red "未检测到 /root/cert 下任何证书，请先申请域名证书！"
            pause_and_return
            return 1
        fi
        echo -e "${YELLOW}检测到以下域名证书：${PLAIN}"
        select crtfile in /root/cert/*.crt; do
            [[ -z "$crtfile" ]] && echo "请输入有效选项。" && continue
            domain_base=$(basename "$crtfile" .crt)
            keyfile="/root/cert/${domain_base}.key"
            if [[ -f "$keyfile" ]]; then
                cert_path="$crtfile"
                key_path="$keyfile"
                break
            else
                echo "未找到对应私钥：$keyfile，请重新选择。"
            fi
        done
    elif [[ "$cert_option" == "3" ]]; then
        read -p "$(echo -e "${YELLOW}请输入证书(.crt/.pem)路径: ${PLAIN}")" cert_path
        read -p "$(echo -e "${YELLOW}请输入私钥(.key)路径: ${PLAIN}")" key_path
        if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
            red "自定义证书或私钥路径无效！"
            pause_and_return
            return 1
        fi
    else
        return 1
    fi
    return 0
}

port_jump_set() {
    echo -e "${CYAN}检查 iptables 是否已安装...${PLAIN}"
    if ! command -v iptables &> /dev/null; then
        yellow "未检测到 iptables，正在安装中..."
        if [ -f /etc/debian_version ]; then
            sudo apt-get update
            sudo apt-get install -y iptables
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y iptables
        else
            red "无法识别的系统，请手动安装 iptables！中止任务！"
            return 1
        fi
    fi

    interface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)
    if [ -z "$interface" ]; then
        red "未检测到有效的网卡，请检查网络配置。"
        return 1
    fi
    echo -e "${CYAN}检测到的网卡名称为: ${YELLOW}$interface${PLAIN}"
    echo -e "${YELLOW}如果需要更改网卡名称，请手动输入，默认为 $interface${PLAIN}"
    read -r user_interface
    user_interface=${user_interface:-$interface}

    read -p "$(echo -e "${YELLOW}请输入端口范围 (默认 18443:28444): ${PLAIN}")" port_range
    port_range=${port_range:-18443:28444}

    CONFIG_PATH="/root/hysteria/config.yaml"
    default_port=""
    if [[ -f "$CONFIG_PATH" ]]; then
        cfg_port=$(grep -E '^listen:' "$CONFIG_PATH" | awk '{print $2}' | sed 's/^://')
        if [[ -n "$cfg_port" ]]; then
            default_port="$cfg_port"
        fi
    fi
    if [[ -z "$default_port" ]]; then
        red "未检测到 Hysteria 配置文件或未设置 listen 端口，请先安装并配置 Hysteria 后再设置端口跳跃。"
        pause_and_return
        return
    fi
    read -p "$(echo -e "${YELLOW}请输入HY端口 (默认:${default_port}): ${PLAIN}")" target_port
    target_port=${target_port:-$default_port}

    echo -e "${CYAN}正在设置端口跳跃规则...${PLAIN}"
    sudo iptables -t nat -A PREROUTING -i $user_interface -p udp --dport $port_range -j REDIRECT --to-ports $target_port

    echo -e "${CYAN}以下是当前的 iptables 规则：${PLAIN}"
    sudo iptables -t nat -L -n

    echo -e "${CYAN}创建 systemd 自启服务: port-jump.service${PLAIN}"
    cat > /etc/systemd/system/port-jump.service << EOF
[Unit]
Description=UDP Port Jumping NAT Rule
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A PREROUTING -i $user_interface -p udp --dport $port_range -j REDIRECT --to-ports $target_port
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable port-jump.service
    sudo systemctl start port-jump.service

    green "端口跳跃规则已启用并设置为开机自动启动"
    pause_and_return
}

port_jump_modify() {
    echo -e "${CYAN}正在修改端口跳跃规则...${PLAIN}"
    sudo systemctl stop port-jump.service 2>/dev/null
    sudo systemctl disable port-jump.service 2>/dev/null
    sudo rm -f /etc/systemd/system/port-jump.service
    sudo iptables -t nat -F PREROUTING
    sudo systemctl daemon-reload
    port_jump_set
}

port_jump_view() {
    echo -e "${CYAN}当前 iptables 端口跳跃规则：${PLAIN}"
    sudo iptables -t nat -L -n --line-numbers | grep REDIRECT
    echo ""
    echo -e "${CYAN}当前 systemd port-jump.service 配置：${PLAIN}"
    if [ -f /etc/systemd/system/port-jump.service ]; then
        cat /etc/systemd/system/port-jump.service
    else
        yellow "未检测到 systemd 端口跳跃服务"
    fi
    pause_and_return
}

port_jump_delete() {
    echo -e "${CYAN}正在删除端口跳跃规则...${PLAIN}"
    sudo systemctl stop port-jump.service 2>/dev/null
    sudo systemctl disable port-jump.service 2>/dev/null
    sudo rm -f /etc/systemd/system/port-jump.service
    sudo iptables -t nat -F PREROUTING
    sudo systemctl daemon-reload
    green "端口跳跃规则已删除"
    pause_and_return
}

port_jump_menu() {
    while true; do
        clear
        echo -e "${CYAN}========= 端口跳跃设置 =========${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 设置端口跳跃"
        echo -e "${GREEN}2.${PLAIN} 修改端口跳跃"
        echo -e "${GREEN}3.${PLAIN} 查看端口跳跃"
        echo -e "${GREEN}4.${PLAIN} 删除端口跳跃"
        echo -e "${GREEN}0.${PLAIN} 返回主菜单"
        read -p "$(echo -e "${YELLOW}请选择操作: ${PLAIN}")" pjopt
        case "$pjopt" in
            1) port_jump_set ;;
            2) port_jump_modify ;;
            3) port_jump_view ;;
            4) port_jump_delete ;;
            0) break ;;
            *) red "无效选项，请重新输入。"; pause_and_return ;;
        esac
    done
}

while true; do
    clear
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${BLUE}====      Steins Gate - hysteria Ver.1.1    ==${PLAIN}"
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${CYAN}请选择你的命运石之门:${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 申请证书或自签证书"
    echo -e "${GREEN}2.${PLAIN} 安装 Hysteria"
    echo -e "${GREEN}3.${PLAIN} 管理 Hysteria"
    echo -e "${GREEN}4.${PLAIN} 设置端口跳跃规则"
    echo -e "${GREEN}0.${PLAIN} 离开 El Psy Kongroo"
    read -p "$(echo -e "${YELLOW}请选择操作: ${PLAIN}")" option

    if [ "$option" -eq 0 ]; then
        echo -e "${BLUE}退出脚本...${PLAIN}"
        exit 0

    elif [ "$option" -eq 1 ]; then
        cert_menu

    elif [ "$option" -eq 2 ]; then
        HY2_DIR="/root/hysteria"
        EXEC_PATH="${HY2_DIR}/hysteria"
        CONFIG_PATH="${HY2_DIR}/config.yaml"

        if [[ -f "$EXEC_PATH" && -f "$CONFIG_PATH" ]]; then
            yellow "检测到已安装且存在配置文件，无需重复安装。"
            echo -e "${CYAN}如需修改配置，请选择主菜单的【3. 管理 Hysteria】${PLAIN}"
            pause_and_return
            continue
        fi

        mkdir -p "$HY2_DIR"

        ARCH=$(get_arch)
        echo -e "${CYAN}检测到系统架构: $ARCH${PLAIN}"
        DOWNLOAD_URL=$(get_latest_download_url "$ARCH")
        if [ -z "$DOWNLOAD_URL" ]; then
            red "未找到适用于架构 $ARCH 的 Hysteria 内核，请手动安装。"
            exit 1
        fi
        echo -e "${CYAN}正在下载最新版本的 Hysteria ($ARCH)...${PLAIN}"
        wget -O "${EXEC_PATH}" "$DOWNLOAD_URL"

        if [ ! -s "$EXEC_PATH" ]; then
            red "下载的文件为空，请检查网络或下载链接是否正确。"
            exit 1
        fi

        chmod +x "$EXEC_PATH"
        green "Hysteria 内核已成功下载并赋予执行权限"

        while true; do
            select_cert_for_hysteria
            CERT_RTN=$?
            [[ $CERT_RTN -eq 0 ]] && break
            [[ $CERT_RTN -eq 1 ]] && break
        done
        [[ $CERT_RTN -ne 0 ]] && continue

        read -p "$(echo -e "${YELLOW}请输入监听端口 (默认:443): ${PLAIN}")" listen_port
        listen_port=${listen_port:-443}

        read -p "$(echo -e "${YELLOW}请输入认证密码 (回车自动随机): ${PLAIN}")" auth_password
        if [ -z "$auth_password" ]; then
            auth_password=$(random_pass)
            echo -e "${GREEN}已自动生成认证密码: $auth_password${PLAIN}"
        fi

        read -p "$(echo -e "${YELLOW}请输入伪装URL的域名 (默认 www.bing.com): ${PLAIN}")" masquerade_domain
        masquerade_domain=${masquerade_domain:-www.bing.com}
        masquerade_url="https://${masquerade_domain}"

        cat > "$HY2_DIR/config.yaml" << EOF
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

        echo -e "${CYAN}配置文件内容如下：${PLAIN}"
        cat "$HY2_DIR/config.yaml"

        # 交互添加 outbounds 配置
        echo -e "${YELLOW}是否添加 SOCKS5 出站配置？${PLAIN}"
        read -p "$(echo -e "${BLUE}添加请输入 y，不添加请输入 n [y/n]: ${PLAIN}")" enable_outbounds
        enable_outbounds=${enable_outbounds:-n}

        if [[ "$enable_outbounds" == "y" || "$enable_outbounds" == "Y" ]]; then
            read -p "$(echo -e "${YELLOW}请输入socks5地址 (默认:127.0.0.1): ${PLAIN}")" socks5_addr
            socks5_addr=${socks5_addr:-127.0.0.1}
            read -p "$(echo -e "${YELLOW}请输入socks5端口 (默认:18443): ${PLAIN}")" socks5_port
            socks5_port=${socks5_port:-18443}
            read -p "$(echo -e "${YELLOW}请输入 socks5 用户名（可留空）: ${PLAIN}")" socks5_username
            read -p "$(echo -e "${YELLOW}请输入 socks5 密码（可留空）: ${PLAIN}")" socks5_password
            OUTBOUNDS_CONFIG=$(cat <<EOF2

outbounds:
  - name: mihomo
    type: socks5
    socks5:
      addr: ${socks5_addr}:${socks5_port}
      username: ${socks5_username}
      password: ${socks5_password}
EOF2
)
            echo "$OUTBOUNDS_CONFIG" >> "$HY2_DIR/config.yaml"
        fi

        echo -e "${CYAN}正在创建 systemd 服务单元文件...${PLAIN}"

        cat > /etc/systemd/system/hysteria.service << EOF
[Unit]
Description=Hysteria Server Service
After=network.target

[Service]
ExecStart=/root/hysteria/hysteria server --config /root/hysteria/config.yaml
User=root
Group=root
Restart=always
Environment=PATH=/usr/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable hysteria.service
        sudo systemctl start hysteria.service

        echo -e "${CYAN}Hysteria 服务启动状态：${PLAIN}"
        sudo systemctl status hysteria.service
        green "已成功设置 Hysteria 开机自启并启动服务！"
        pause_and_return

    elif [ "$option" -eq 3 ]; then
        SERVICE_NAME="hysteria"
        HY2_DIR="/root/hysteria"
        EXEC_PATH="${HY2_DIR}/hysteria"
        CONFIG_PATH="${HY2_DIR}/config.yaml"
        SERVICE_FILE="/etc/systemd/system/hysteria.service"
        CERT_DIR="/etc/cert"
        PORT_JUMP_SERVICE="/etc/systemd/system/port-jump.service"

        while true; do
            clear
            echo -e "${BLUE}请选择你的命运石之门:${PLAIN}"
            echo -e "${GREEN}1.${PLAIN} 查看 Hysteria 状态"
            echo -e "${GREEN}2.${PLAIN} 查看 Hysteria 配置"
            echo -e "${GREEN}3.${PLAIN} 停止 Hysteria 服务"
            echo -e "${GREEN}4.${PLAIN} 重启 Hysteria 服务"
            echo -e "${GREEN}5.${PLAIN} 修改 Hysteria 配置"
            echo -e "${GREEN}6.${PLAIN} 更新 Hysteria 内核"
            echo -e "${GREEN}7.${PLAIN} 删除 Hysteria 服务"
            echo -e "${GREEN}0.${PLAIN} 返回主菜单"
            read -p "$(echo -e "${YELLOW}选择操作 (0-8): ${PLAIN}")" ACTION

            case "$ACTION" in
                1)
                    echo -e "${CYAN}Hysteria 服务当前状态：${PLAIN}"
                    sudo systemctl status $SERVICE_NAME
                    pause_and_return
                    ;;
                2)
                    show_hysteria_config
                    ;;
                3)
                    echo -e "${CYAN}正在停止 Hysteria 服务...${PLAIN}"
                    sudo systemctl stop $SERVICE_NAME
                    echo -e "${GREEN}已停止${PLAIN}"
                    pause_and_return
                    ;;
                4)
                    echo -e "${CYAN}正在重启 Hysteria 服务...${PLAIN}"
                    sudo systemctl restart $SERVICE_NAME
                    echo -e "${GREEN}已重启${PLAIN}"
                    pause_and_return
                    ;;
                5)
                    if [ ! -f "$CONFIG_PATH" ]; then
                        red "未检测到配置文件: $CONFIG_PATH"
                        pause_and_return
                        continue
                    fi
                    echo -e "${CYAN}当前 Hysteria 配置内容如下:${PLAIN}"
                    cat "$CONFIG_PATH"
                    echo -e "${YELLOW}请输入新的配置项（直接回车为保留原值）:${PLAIN}"

                    old_listen=$(grep -E '^listen:' "$CONFIG_PATH" | head -n1 | awk '{print $2}' | sed 's/://')
                    old_cert=$(grep -E '^\s*cert:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                    old_key=$(grep -E '^\s*key:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                    old_password=$(grep -E '^\s*password:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                    old_url=$(grep -E '^\s*url:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                    old_url_domain=$(echo "$old_url" | sed -E 's#https?://([^/]+).*#\1#')

                    read -p "$(echo -e "${YELLOW}请输入监听端口 (原值: ${old_listen:-443}): ${PLAIN}")" listen_port
                    listen_port=${listen_port:-$old_listen}
                    listen_port=${listen_port:-443}

                    read -p "$(echo -e "${YELLOW}请输入证书路径 (原值: ${old_cert}): ${PLAIN}")" cert_path_new
                    cert_path_new=${cert_path_new:-$old_cert}

                    read -p "$(echo -e "${YELLOW}请输入私钥路径 (原值: ${old_key}): ${PLAIN}")" key_path_new
                    key_path_new=${key_path_new:-$old_key}

                    read -p "$(echo -e "${YELLOW}请输入认证密码 (原值: ${old_password}): ${PLAIN}")" auth_password
                    if [ -z "$auth_password" ]; then
                        if [ -n "$old_password" ]; then
                            auth_password="$old_password"
                        else
                            auth_password=$(random_pass)
                            echo -e "${GREEN}已自动生成认证密码: $auth_password${PLAIN}"
                        fi
                    fi

                    read -p "$(echo -e "${YELLOW}请输入伪装URL的域名 (原值: ${old_url_domain:-www.bing.com}): ${PLAIN}")" masquerade_domain
                    masquerade_domain=${masquerade_domain:-$old_url_domain}
                    masquerade_domain=${masquerade_domain:-www.bing.com}
                    masquerade_url="https://${masquerade_domain}"

                    cat > "$CONFIG_PATH" << EOF
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

                    echo -e "${YELLOW}是否添加 SOCKS5 出站配置？${PLAIN}"
                    read -p "$(echo -e "${BLUE}添加请输入 y，不添加请输入 n [y/n]: ${PLAIN}")" enable_outbounds
                    enable_outbounds=${enable_outbounds:-n}

                    if [[ "$enable_outbounds" == "y" || "$enable_outbounds" == "Y" ]]; then
                        read -p "$(echo -e "${YELLOW}请输入socks5地址 (默认:127.0.0.1): ${PLAIN}")" socks5_addr
                        socks5_addr=${socks5_addr:-127.0.0.1}
                        read -p "$(echo -e "${YELLOW}请输入socks5端口 (默认:18443): ${PLAIN}")" socks5_port
                        socks5_port=${socks5_port:-18443}
                        read -p "$(echo -e "${YELLOW}请输入 socks5 用户名（可留空）: ${PLAIN}")" socks5_username
                        read -p "$(echo -e "${YELLOW}请输入 socks5 密码（可留空）: ${PLAIN}")" socks5_password
                        OUTBOUNDS_CONFIG=$(cat <<EOF2

outbounds:
  - name: mihomo
    type: socks5
    socks5:
      addr: ${socks5_addr}:${socks5_port}
      username: ${socks5_username}
      password: ${socks5_password}
EOF2
)
                        echo "$OUTBOUNDS_CONFIG" >> "$CONFIG_PATH"
                    fi

                    green "新配置已保存，将重启 Hysteria 服务..."
                    sudo systemctl restart $SERVICE_NAME
                    sudo systemctl status $SERVICE_NAME
                    pause_and_return
                    ;;
                6)
                    echo -e "${CYAN}正在更新 Hysteria 内核...${PLAIN}"
                    echo -e "${CYAN}先停止 Hysteria 服务...${PLAIN}"
                    sudo systemctl stop $SERVICE_NAME
                    ARCH=$(get_arch)
                    echo -e "${CYAN}检测到系统架构: $ARCH${PLAIN}"
                    DOWNLOAD_URL=$(get_latest_download_url "$ARCH")
                    if [ -z "$DOWNLOAD_URL" ]; then
                        red "未找到适用于架构 $ARCH 的 Hysteria 内核，请手动安装。"
                        pause_and_return
                        continue
                    fi
                    wget -O "$EXEC_PATH" "$DOWNLOAD_URL"
                    chmod +x "$EXEC_PATH"
                    echo -e "${CYAN}内核已更新，重启服务中...${PLAIN}"
                    sudo systemctl daemon-reload
                    sudo systemctl start $SERVICE_NAME
                    pause_and_return
                    ;;
                7)
                    echo -e "${CYAN}正在删除 Hysteria 相关资源...${PLAIN}"
                    sudo systemctl stop $SERVICE_NAME
                    sudo systemctl disable $SERVICE_NAME
                    sudo rm -f $SERVICE_FILE
                    sudo rm -rf $HY2_DIR
                    sudo rm -f $CERT_DIR/server.key
                    sudo rm -f $CERT_DIR/server.crt
                    if [ -f "$PORT_JUMP_SERVICE" ]; then
                        sudo systemctl stop port-jump.service
                        sudo systemctl disable port-jump.service
                        sudo rm -f "$PORT_JUMP_SERVICE"
                    fi
                    sudo systemctl daemon-reload
                    green "所有 Hysteria 相关资源已删除"
                    pause_and_return
                    ;;
                0)
                    clear
                    break
                    ;;
                *)
                    red "无效选项，请输入 0 到 8"
                    pause_and_return
                    ;;
            esac
        done

    elif [ "$option" -eq 4 ]; then
        port_jump_menu
    fi
done
