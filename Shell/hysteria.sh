#!/bin/bash

# ======== 1. 全局变量 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

# ======== 2. 通用函数 ========
pause_and_return() {
    read -p "$(echo -e "${BLUE}按回车返回上一层...${PLAIN}")" temp
    clear
}

get_local_ip() {
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
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10
}

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

# ======== 3. 证书相关函数 ========
generate_self_signed_cert() {
    DEFAULT_DOMAIN="bing.com"
    DEFAULT_CERT_PATH="/etc/cert"
    DEFAULT_DAYS=36500

    read -rp "$(echo -e "${GREEN}自签证书域名${PLAIN} ${BLUE}(默认:${DEFAULT_DOMAIN})${PLAIN}: ")" domain
    domain="${domain:-$DEFAULT_DOMAIN}"
    read -rp "$(echo -e "${GREEN}证书存放路径${PLAIN}${BLUE}(默认:${DEFAULT_CERT_PATH})${PLAIN}: ")" cert_path
    cert_path="${cert_path:-$DEFAULT_CERT_PATH}"
    read -rp "$(echo -e "${GREEN}证书有效天数${PLAIN}${BLUE}(默认:${DEFAULT_DAYS})${PLAIN}: ")" days
    days="${days:-$DEFAULT_DAYS}"

    key_file="${cert_path}/server.key"
    crt_file="${cert_path}/server.crt"

    sudo mkdir -p "$cert_path"
    sudo openssl ecparam -name prime256v1 -genkey -noout -out "$key_file"

    sudo openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain"

    sudo chmod 644 "$crt_file"
    sudo chmod 600 "$key_file"

    echo -e "${YELLOW}私钥位置:$key_file${PLAIN}"
    echo -e "${YELLOW}证书位置:$crt_file${PLAIN}"
    pause_and_return
}

issue_acme_cert() {
    clear
    CERT_DIR="/root/cert"
    ACME_SH="$HOME/.acme.sh/acme.sh"

    for bin in jq dig lsof curl wget socat openssl; do
        if ! command -v $bin >/dev/null 2>&1; then
            echo -e "${YELLOW}缺少依赖 $bin,正在安装...${PLAIN}"
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

    if [ ! -f "$ACME_SH" ]; then
        echo -e "${YELLOW}[*] 正在安装 acme.sh ...${PLAIN}"
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

    mkdir -p "$CERT_DIR"

    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)

    clear
    echo -e "${YELLOW}请输入需要申请证书的域名${PLAIN}"
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
        echo -e "${RED}域名解析IP与本机不符${PLAIN}"
        echo -e "${YELLOW}域名解析IP: $domainIP, 本机IPv4: $ipv4, IPv6: $ipv6${PLAIN}"
        echo -e "${YELLOW}请检查域名解析后重试${PLAIN}"
        pause_and_return
        return
    fi

    if [[ -f "${CERT_DIR}/${domain}.crt" && -f "${CERT_DIR}/${domain}.key" ]]; then
        echo -e "${GREEN}[✓] 已检测到 ${domain} 证书,跳过签发步骤${PLAIN}"
        pause_and_return
        return 0
    fi

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

cert_menu() {
    while true; do
        clear
        echo -e " ${BLUE}✦ Hysteria_Cert ✦${PLAIN}"
        echo -e " ${GREEN}  1.${PLAIN}自签证书"
        echo -e " ${GREEN}  2.${PLAIN}域名证书"
        echo -e " ${GREEN}  0.${PLAIN}返回Kongroo"

        read -p "$(echo -e "${BLUE} ✦ Steins Gate ✦ : ${PLAIN}")" choice

        case "$choice" in
            1) generate_self_signed_cert ;;
            2) issue_acme_cert ;;
            0) break ;;
            *) echo -e "${RED}无效选项,请重新输入${PLAIN}"; pause_and_return ;;
        esac
    done
}

select_cert_for_hysteria() {
    local allow_exit=$1
    while true; do
        echo -e "${BLUE}✦ 请选择证书 ✦ : ${PLAIN}"
        echo -e "${GREEN}  1.自签证书${PLAIN}"
        echo -e "${BLUE}  2.域名证书${PLAIN}"
        echo -e "${YELLOW}  3.输入路径${PLAIN}"
        echo -e "${RED}  0.退出/默认${PLAIN}"

        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" cert_option

        if [[ -z "$cert_option" ]]; then
            if [[ "$allow_exit" == "0" ]]; then
                echo -e "${RED}无效输入,请重新选择!${PLAIN}"
                read -p "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
                continue
            else
                return 1
            fi
        fi

        case "$cert_option" in
            1)
                if [[ -f /etc/cert/server.crt && -f /etc/cert/server.key ]]; then
                    cert_path="/etc/cert/server.crt"
                    key_path="/etc/cert/server.key"
                    return 0
                else
                    echo -e "${RED}未检测到 /etc/cert 下任何自签证书${PLAIN}"
                    read -p "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
                    continue
                fi
                ;;
            2)
                if ! compgen -G "/root/cert/*.crt" > /dev/null; then
                    echo -e "${BLUE}未检测到 /root/cert 下任何域名证书${PLAIN}"
                    pause_and_return
                    return 1
                fi
                echo -e "${BLUE}检测到以下域名证书: ${PLAIN}"

                cert_files=($(ls /root/cert/*.crt 2>/dev/null | sort))
                cert_count=${#cert_files[@]}

                for ((i=0; i<cert_count; i++)); do
                    idx=$((i+1))
                    echo -e "${GREEN}${idx}.${PLAIN} ${GREEN}${cert_files[$i]}${PLAIN}"
                done

                while true; do
                    read -p "$(echo -e "${BLUE}请输入证书编号(1-${cert_count}): ${PLAIN}")" crt_idx
                    if [[ "$crt_idx" =~ ^[0-9]+$ ]] && (( crt_idx >= 1 && crt_idx <= cert_count )); then
                        crtfile="${cert_files[$((crt_idx-1))]}"
                        domain_base=$(basename "$crtfile" .crt)
                        keyfile="/root/cert/${domain_base}.key"
                        if [[ -f "$keyfile" ]]; then
                            cert_path="$crtfile"
                            key_path="$keyfile"
                            return 0
                        else
                            echo -e "${RED}未找到对应私钥: $keyfile,请重新选择${PLAIN}"
                            read -p "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
                        fi
                    else
                        echo -e "${RED}请输入有效编号${PLAIN}"
                        read -p "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
                    fi
                done
                ;;
            3)
                read -p "$(echo -e "${BLUE}请输入证书路径: ${PLAIN}")" cert_path
                read -p "$(echo -e "${BLUE}请输入私钥路径: ${PLAIN}")" key_path
                if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                    echo -e "${RED}自定义证书或私钥路径无效!${PLAIN}"
                    pause_and_return
                    return 1
                fi
                return 0
                ;;
            0)
                return 1
                ;;
            *)
                echo -e "${RED}无效输入,请重新选择!${PLAIN}"
                read -p "$(echo -e "${BLUE}按回车继续...${PLAIN}")"
                ;;
        esac
    done
}

# ======== 4. Hysteria 相关函数 ========
show_hysteria_config() {
    clear
    HY2_DIR="/root/hysteria"
    CONFIG_PATH="${HY2_DIR}/config.yaml"
    if [ -f "$CONFIG_PATH" ]; then
        echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
        cat "$CONFIG_PATH"
        echo -e "${BLUE}-----------------------------------------------------${PLAIN}"
        listen_port=$(grep -E '^listen:' "$CONFIG_PATH" | awk '{print $2}' | sed 's/://')
        auth_password=$(grep -E '^\s*password:' "$CONFIG_PATH" | awk '{print $2}')
        cert_path=$(grep -E '^\s*cert:' "$CONFIG_PATH" | awk '{print $2}')
        masquerade_domain=$(grep -E '^\s*url:' "$CONFIG_PATH" | awk -F[/:] '{print $4}')
        subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null)
        sni_domain=$(echo "$subject" | grep -oE 'CN[ =]*[a-zA-Z0-9\.\-]+' | head -n1 | sed 's/CN[ =]*//')
        [ -z "$sni_domain" ] && sni_domain="$masquerade_domain"
        local_ip=$(get_local_ip)
        listen_port=${listen_port:-443}
        node_link="hysteria2://${auth_password}@${local_ip}:${listen_port}?insecure=1&sni=${sni_domain}&fastopen=1#Hysteria"
        echo -e "\n${BLUE}Hysteria 节点链接：${PLAIN}\n${GREEN}${node_link}${PLAIN}"
    else
        echo -e "${RED}未检测到配置文件: $CONFIG_PATH${PLAIN}"
    fi
    pause_and_return
}

# ======== 5. 端口跳跃相关函数 ========
port_jump_set() {
    clear
    echo -e "${BLUE}检查 iptables 是否已安装...${PLAIN}"
    if ! command -v iptables &> /dev/null; then
        echo -e "${YELLOW}未检测到 iptables,正在安装中...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            sudo apt-get update
            sudo apt-get install -y iptables
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y iptables
        else
            echo -e "${RED}无法识别的系统,请手动安装 iptables！中止任务!${PLAIN}"
            return 1
        fi
    fi

    EXIST_RULE=$(sudo iptables -t nat -S PREROUTING | grep -E 'REDIRECT --to-ports')
    if [[ -n "$EXIST_RULE" ]]; then
        echo -e "${GREEN}已检测到存在端口跳跃配置:${PLAIN}"
        echo -e "${YELLOW}$EXIST_RULE${PLAIN}"
        echo -e "${BLUE}如需修改,请选择【2.修改端口跳跃】${PLAIN}"
        pause_and_return
        return
    fi

    interface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)
    if [ -z "$interface" ]; then
        echo -e "${RED}未检测到有效的网卡,请检查网络配置${PLAIN}"
        return 1
    fi
    echo -e "${YELLOW}检测到的网卡名称为: ${YELLOW}$interface${PLAIN}"
    read -p "$(echo -e "${YELLOW}如果需要更改网卡名称,请手动输入,默认为 $interface: ${PLAIN}")" user_interface
    user_interface=${user_interface:-$interface}

    read -p "$(echo -e "${YELLOW}请输入端口范围(默认18443:28444): ${PLAIN}")" port_range
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
        echo -e "${RED}未检测到 Hysteria 配置文件或未设置 listen 端口,请先安装并配置 Hysteria 后再设置端口跳跃${PLAIN}"
        pause_and_return
        return
    fi
    read -p "$(echo -e "${YELLOW}请输入HY端口(默认:${default_port}): ${PLAIN}")" target_port
    target_port=${target_port:-$default_port}

    echo -e "${BLUE}正在设置端口跳跃规则...${PLAIN}"
    sudo iptables -t nat -A PREROUTING -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port"

    echo -e "${BLUE}以下是当前的 iptables 规则:${PLAIN}"
    sudo iptables -t nat -L -n

    echo -e "${BLUE}创建 systemd 自启服务: port-jump.service${PLAIN}"
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

    echo -e "${GREEN}端口跳跃规则已启用并设置为开机自动启动${PLAIN}"
    pause_and_return
}

port_jump_modify() {
    clear
    echo -e "${BLUE}正在修改端口跳跃规则...${PLAIN}"
    sudo systemctl stop port-jump.service 2>/dev/null
    sudo systemctl disable port-jump.service 2>/dev/null
    sudo rm -f /etc/systemd/system/port-jump.service
    sudo iptables -t nat -F PREROUTING
    sudo systemctl daemon-reload
    port_jump_set
}

port_jump_view() {
    clear
    echo -e "${BLUE}当前 iptables 端口跳跃规则: ${PLAIN}"
    sudo iptables -t nat -L -n --line-numbers | grep REDIRECT
    echo -e "${BLUE}当前 systemd port-jump.service 配置: ${PLAIN}"
    if [ -f /etc/systemd/system/port-jump.service ]; then
        cat /etc/systemd/system/port-jump.service
    else
        echo -e "${YELLOW}未检测到 systemd 端口跳跃服务${PLAIN}"
    fi
    pause_and_return
}

port_jump_delete() {
    clear
    echo -e "${BLUE}正在删除端口跳跃规则...${PLAIN}"
    sudo systemctl stop port-jump.service 2>/dev/null
    sudo systemctl disable port-jump.service 2>/dev/null
    sudo rm -f /etc/systemd/system/port-jump.service
    sudo iptables -t nat -F PREROUTING
    sudo systemctl daemon-reload
    echo -e "${GREEN}端口跳跃规则已删除${PLAIN}"
    pause_and_return
}

port_jump_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Port jump ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}设置端口跳跃"
        echo -e "${GREEN}  2.${PLAIN}修改端口跳跃"
        echo -e "${GREEN}  3.${PLAIN}查看端口跳跃"
        echo -e "${GREEN}  4.${PLAIN}删除端口跳跃"
        echo -e "${GREEN}  0.${PLAIN}返回Kongroo"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" pjopt
        case "$pjopt" in
            1) port_jump_set ;;
            2) port_jump_modify ;;
            3) port_jump_view ;;
            4) port_jump_delete ;;
            0) break ;;
            *) echo -e "${RED}无效选项,请重新输入${PLAIN}"; pause_and_return ;;
        esac
    done
}

# ======== 6. 主菜单循环 ========
while true; do
    clear
    echo -e "${BLUE}✦ Hysteria_v1.5 ✦${PLAIN}"
    echo -e "${GREEN}  1.${PLAIN}配置证书"
    echo -e "${GREEN}  2.${PLAIN}安装服务"
    echo -e "${GREEN}  3.${PLAIN}管理服务"
    echo -e "${GREEN}  4.${PLAIN}端口跳跃"
    echo -e "${GREEN}  0.${PLAIN}退出Kongroo"
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

    case "$option" in
        0)
            exit 0 ;;
        1)
            cert_menu
            ;;
        2)
            clear
            HY2_DIR="/root/hysteria"
            EXEC_PATH="${HY2_DIR}/hysteria"
            CONFIG_PATH="${HY2_DIR}/config.yaml"

            if [[ -f "$EXEC_PATH" && -f "$CONFIG_PATH" ]]; then
                echo -e "${YELLOW}检测到已安装且存在配置文件,无需重复安装${PLAIN}"
                echo -e "${BLUE}如需修改配置,请选择主菜单的【3.管理 Hysteria】${PLAIN}"
                pause_and_return
                continue
            fi

            mkdir -p "$HY2_DIR"

            ARCH=$(get_arch)
            echo -e "${BLUE}检测到系统架构: $ARCH${PLAIN}"
            DOWNLOAD_URL=$(get_latest_download_url "$ARCH")
            if [ -z "$DOWNLOAD_URL" ]; then
                echo -e "${RED}未找到适用于架构 $ARCH 的 Hysteria 内核,请手动安装${PLAIN}"
                exit 1
            fi
            echo -e "${BLUE}正在下载最新版本的 Hysteria ($ARCH)...${PLAIN}"
            wget -O "${EXEC_PATH}" "$DOWNLOAD_URL"

            if [ ! -s "$EXEC_PATH" ]; then
                echo -e "${RED}下载的文件为空,请检查网络或下载链接是否正确${PLAIN}"
                exit 1
            fi

            chmod +x "$EXEC_PATH"
            echo -e "${GREEN}Hysteria 内核已成功下载并赋予执行权限${PLAIN}"

            clear
            select_cert_for_hysteria 0
            CERT_RTN=$?
            if [[ $CERT_RTN -ne 0 ]]; then
                continue
            fi

        error_msg=""
            while true; do
            clear
            echo -e "${BLUE}请输入Hysteria服务配置参数（回车为默认值）:${PLAIN}"
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
        unset error_msg

            read -p "$(echo -e "${BLUE}请输入认证密码(回车随机生成): ${PLAIN}")" auth_password
            if [ -z "$auth_password" ]; then
                auth_password=$(random_pass)
                echo -e "${GREEN}已自动生成认证密码: $auth_password${PLAIN}"
            fi

            read -p "$(echo -e "${BLUE}请输入伪装URL的域名(默认:www.bing.com): ${PLAIN}")" masquerade_domain
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

            echo -e "${BLUE}是否添加 SOCKS5 出站${PLAIN}"
            read -p "$(echo -e "${BLUE}添加y,不添加n(默认:n) [y/n]: ${PLAIN}")" enable_outbounds
            enable_outbounds=${enable_outbounds:-n}

            if [[ "$enable_outbounds" == "y" || "$enable_outbounds" == "Y" ]]; then
                read -p "$(echo -e "${BLUE}请输入socks5地址 (默认:127.0.0.1): ${PLAIN}")" socks5_addr
                socks5_addr=${socks5_addr:-127.0.0.1}
                read -p "$(echo -e "${BLUE}请输入socks5端口 (默认:18443): ${PLAIN}")" socks5_port
                socks5_port=${socks5_port:-18443}
                read -p "$(echo -e "${BLUE}请输入socks5 用户名（可留空）: ${PLAIN}")" socks5_username
                read -p "$(echo -e "${BLUE}请输入socks5 密码（可留空）: ${PLAIN}")" socks5_password
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

            clear
            echo -e "${BLUE}正在创建 systemd 服务单元文件...${PLAIN}"

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

            echo -e "${BLUE}Hysteria 服务启动状态: ${PLAIN}"
            sudo systemctl status --no-pager hysteria.service
            echo -e "${GREEN}已成功设置 Hysteria 开机自启并启动服务!${PLAIN}"
            
            listen_port=${listen_port:-443}
            local_ip=$(get_local_ip)
            subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null)
            sni_domain=$(echo "$subject" | grep -oE 'CN[ =]*[a-zA-Z0-9\.\-]+' | head -n1 | sed 's/CN[ =]*//')
            [ -z "$sni_domain" ] && sni_domain="$masquerade_domain"
            node_link="hysteria2://${auth_password}@${local_ip}:${listen_port}?insecure=1&sni=${sni_domain}&fastopen=1#Hysteria"
            echo -e "\n${BLUE}Hysteria 节点链接：${PLAIN}\n${GREEN}${node_link}${PLAIN}"

            pause_and_return
            ;;
        3)
            SERVICE_NAME="hysteria"
            HY2_DIR="/root/hysteria"
            EXEC_PATH="${HY2_DIR}/hysteria"
            CONFIG_PATH="${HY2_DIR}/config.yaml"
            SERVICE_FILE="/etc/systemd/system/hysteria.service"
            CERT_DIR="/etc/cert"
            PORT_JUMP_SERVICE="/etc/systemd/system/port-jump.service"

            if [[ ! -f "$EXEC_PATH" || ! -f "$CONFIG_PATH" ]]; then
                echo -e "${RED}未检测到配置及执行文件，请先安装并配置!${PLAIN}"
                pause_and_return
                continue
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
                echo -e "${GREEN}  0.${PLAIN}返回Kongroo"
                read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" ACTION

                case "$ACTION" in
                    1)
                        clear
                        echo -e "${BLUE}Hysteria 服务当前状态: ${PLAIN}"
                        sudo systemctl status --no-pager hysteria
                        read -p "$(echo -e "${BLUE}按回车查看配置...${PLAIN}")"
                        clear
                        show_hysteria_config
                        ;;
                    2)
                        clear
                         echo -e "${BLUE}正在停止 Hysteria 服务...${PLAIN}"
                         sudo systemctl stop $SERVICE_NAME
                         echo -e "${GREEN}已停止${PLAIN}"
                         echo
                         sudo systemctl status --no-pager $SERVICE_NAME
                         pause_and_return
                         ;;
                    3)
                        clear
                        echo -e "${BLUE}正在重启 Hysteria 服务...${PLAIN}"
                        sudo systemctl restart $SERVICE_NAME
                        echo -e "${GREEN}已重启${PLAIN}"
                        echo
                        sudo systemctl status --no-pager $SERVICE_NAME
                        pause_and_return
                        ;;
                    4)
                        clear
                        if [ ! -f "$CONFIG_PATH" ]; then
                            echo -e "${RED}未检测到配置文件: $CONFIG_PATH${PLAIN}"
                            pause_and_return
                            continue
                        fi
                        echo -e "${BLUE}请输配置参数（回车为保留原值）:${PLAIN}"

                        old_listen=$(grep -E '^listen:' "$CONFIG_PATH" | head -n1 | awk '{print $2}' | sed 's/://')
                        old_cert=$(grep -E '^\s*cert:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                        old_key=$(grep -E '^\s*key:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                        old_password=$(grep -E '^\s*password:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                        old_url=$(grep -E '^\s*url:' "$CONFIG_PATH" | head -n1 | awk '{print $2}')
                        old_url_domain=$(echo "$old_url" | sed -E 's#https?://([^/]+).*#\1#')

                        old_socks5_addr=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'addr:' | awk '{print $2}' | head -n1 | cut -d: -f1)
                        old_socks5_port=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'addr:' | awk '{print $2}' | head -n1 | cut -d: -f2)
                        old_socks5_username=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'username:' | awk '{print $2}' | head -n1)
                        old_socks5_password=$(grep -A5 'outbounds:' "$CONFIG_PATH" | grep 'password:' | awk '{print $2}' | head -n1)

                        if [[ -n "$old_socks5_addr" ]]; then
                            default_outbounds="y"
                        else
                            default_outbounds="n"
                        fi

                    error_msg=""
                    while true; do
                        clear
                        echo -e "${BLUE}请输配置参数（回车为保留原值）:${PLAIN}"
                        if [[ -n "$error_msg" ]]; then
                            echo -e "${RED}${error_msg}${PLAIN}"
                        fi
                        read -p "$(echo -e "${BLUE}请输入监听端口 (原值: ${old_listen:-443}): ${PLAIN}")" listen_port
                        listen_port=${listen_port:-$old_listen}
                        listen_port=${listen_port:-443}
                        if [[ "$listen_port" =~ ^[0-9]+$ ]] && ((listen_port >= 1 && listen_port <= 65535)); then
                            break
                        else
                            error_msg="端口必须为1-65535的数字！"
                        fi
                    done
                    unset error_msg

                        echo -e "${BLUE}请选择新的证书及私钥，或选0直接回车保留原值:${PLAIN}"
                        select_cert_for_hysteria
                        SELECT_CERT_STATUS=$?
                        if [[ $SELECT_CERT_STATUS -eq 0 ]]; then
                            cert_path_new="$cert_path"
                            key_path_new="$key_path"
                        else
                            cert_path_new="$old_cert"
                            key_path_new="$old_key"
                        fi

                        read -p "$(echo -e "${BLUE}请输入认证密码 (原值: ${old_password}): ${PLAIN}")" auth_password
                        if [ -z "$auth_password" ]; then
                            if [ -n "$old_password" ]; then
                                auth_password="$old_password"
                            else
                                auth_password=$(random_pass)
                                echo -e "${GREEN}已自动生成认证密码: $auth_password${PLAIN}"
                            fi
                        fi

                        read -p "$(echo -e "${BLUE}请输入伪装URL的域名(原值: ${old_url_domain:-www.bing.com}): ${PLAIN}")" masquerade_domain
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

                        echo -e "${BLUE}是否添加 SOCKS5 出站配置${PLAIN}"
                        read -p "$(echo -e "${BLUE}添加y，不添加 n [y/n] (原值:${default_outbounds}): ${PLAIN}")" enable_outbounds
                        enable_outbounds=${enable_outbounds:-$default_outbounds}

                        if [[ "$enable_outbounds" == "y" || "$enable_outbounds" == "Y" ]]; then
                            read -p "$(echo -e "${BLUE}请输入socks5地址 (原值:${old_socks5_addr:-127.0.0.1}): ${PLAIN}")" socks5_addr
                            socks5_addr=${socks5_addr:-${old_socks5_addr:-127.0.0.1}}
                            read -p "$(echo -e "${BLUE}请输入socks5端口 (原值:${old_socks5_port:-18443}): ${PLAIN}")" socks5_port
                            socks5_port=${socks5_port:-${old_socks5_port:-18443}}
                            read -p "$(echo -e "${BLUE}请输入socks5 用户名（可留空，原值:${old_socks5_username}）: ${PLAIN}")" socks5_username
                            socks5_username=${socks5_username:-$old_socks5_username}
                            read -p "$(echo -e "${BLUE}请输入socks5 密码（可留空，原值:${old_socks5_password}）: ${PLAIN}")" socks5_password
                            socks5_password=${socks5_password:-$old_socks5_password}
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

                        clear
                        echo -e "${GREEN}新配置已保存,将重启 Hysteria 服务...${PLAIN}"
                        sudo systemctl restart $SERVICE_NAME
                        sudo systemctl status --no-pager $SERVICE_NAME
                        pause_and_return
                        ;;
                    5)
                        clear
                        echo -e "${BLUE}正在更新 Hysteria 内核...${PLAIN}"
                        echo -e "${BLUE}先停止 Hysteria 服务...${PLAIN}"
                        sudo systemctl stop $SERVICE_NAME
                        ARCH=$(get_arch)
                        echo -e "${BLUE}检测到系统架构: $ARCH${PLAIN}"
                        DOWNLOAD_URL=$(get_latest_download_url "$ARCH")
                        if [ -z "$DOWNLOAD_URL" ]; then
                            echo -e "${RED}未找到适用于架构 $ARCH 的 Hysteria 内核,请手动安装${PLAIN}"
                            pause_and_return
                            continue
                        fi
                        wget -O "$EXEC_PATH" "$DOWNLOAD_URL"
                        chmod +x "$EXEC_PATH"
                        echo -e "${BLUE}内核已更新,重启服务中...${PLAIN}"
                        sudo systemctl daemon-reload
                        sudo systemctl start $SERVICE_NAME
                        pause_and_return
                        ;;
                    6)
                        clear
                        echo -e "${BLUE}正在删除 Hysteria 相关资源...${PLAIN}"
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
                        echo -e "${GREEN}Hysteria 及相关资源已删除${PLAIN}"
                        read -p "$(echo -e "${BLUE}按回车返回主菜单...${PLAIN}")"
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
            ;;
        4)
            port_jump_menu
            ;;
        *)
            echo -e "${RED}无效输入,重新输入${PLAIN}"
            pause_and_return
            ;;
    esac
done
