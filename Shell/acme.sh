#!/bin/bash

set -euo pipefail

# ====== 颜色变量 ======
RED="\033[31m\033[01m"
GREEN="\033[32m\033[01m"
YELLOW="\033[33m\033[01m"
PLAIN='\033[0m'

# ====== Root 权限检查 ======
[[ $EUID -ne 0 ]] && echo -e "${RED}注意：请在 root 用户下运行脚本${PLAIN}" && exit 1

# ====== 检测 IPv4 函数 ======
has_ipv4() {
    ip -4 addr show scope global | grep -q inet
}

get_acme_download_url() {
    local url="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
    if ! has_ipv4; then
        url="${url/github.com/acme-cdn.pages.dev}"
    fi
    echo "$url"
}

# ====== 系统适配 ======
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu) echo "debian" ;;
            centos|rhel|rocky|alma|oracle) echo "centos" ;;
            fedora) echo "fedora" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

SYSTEM_TYPE=$(detect_system)
[[ "$SYSTEM_TYPE" == "unknown" ]] && echo -e "${RED}不支持当前 VPS 系统，请使用主流的操作系统${PLAIN}" && exit 1

# ====== 包管理器通用函数 ======
pkg_update() {
    case "$SYSTEM_TYPE" in
        debian) apt-get update ;;
        centos|fedora) yum -y update ;;
    esac
}

pkg_install() {
    case "$SYSTEM_TYPE" in
        debian) apt -y install "$@" ;;
        centos|fedora) yum -y install "$@" ;;
    esac
}

# ====== WARP 通用控制函数 ======
warp_down() {
    if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
        wg-quick down wgcf >/dev/null 2>&1 || true
    fi
    if [[ -f "/opt/warp-go/warp-go" ]]; then
        systemctl stop warp-go >/dev/null 2>&1 || true
    fi
}

warp_up() {
    if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
        wg-quick up wgcf >/dev/null 2>&1 || true
    fi
    if [[ -f "/opt/warp-go/warp-go" ]]; then
        systemctl start warp-go >/dev/null 2>&1 || true
    fi
}

# ====== 辅助函数 ======
back2menu() {
    echo ""
    echo -e "${YELLOW}操作完成！按 Enter 键返回主菜单，或按 Ctrl+C 退出脚本...${PLAIN}"
    read -r
    menu
}

check_ip() {
    local ipv4_result ipv6_result
    ipv4_result=$(curl -s4m8 ip.sb -k 2>/dev/null | sed -n 1p) || true
    ipv6_result=$(curl -s6m8 ip.sb -k 2>/dev/null | sed -n 1p) || true
    ipv4="$ipv4_result"
    ipv6="$ipv6_result"
}

validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

get_cf_credentials() {
    read -rp "请输入 CloudFlare Global API Key: " cfgak
    if [[ -z $cfgak ]]; then
        echo -e "${RED}未输入 CloudFlare Global API Key，无法执行操作!${PLAIN}"
        return 1
    fi
    export CF_Key="$cfgak"
    
    read -rp "请输入 CloudFlare 的登录邮箱: " cfemail
    if [[ -z $cfemail ]]; then
        echo -e "${RED}未输入 CloudFlare 的登录邮箱，无法执行操作!${PLAIN}"
        return 1
    fi
    export CF_Email="$cfemail"
    return 0
}

# ====== Acme 安装与卸载 ======
inst_acme() {
    if [[ "$SYSTEM_TYPE" != "centos" ]]; then
        pkg_update
    fi
    pkg_install curl wget socat openssl dnsutils

    if [[ "$SYSTEM_TYPE" == "centos" ]]; then
        pkg_install cronie
        systemctl start crond
        systemctl enable crond
    else
        pkg_install cron
        systemctl start cron
        systemctl enable cron
    fi

    read -rp "请输入注册邮箱 (留空自动生成一个 gmail 邮箱): " email
    if [[ -z $email ]]; then
        local automail
        automail=$(date +%s%N | md5sum | cut -c 1-16)
        email=$automail@gmail.com
        echo -e "${YELLOW}已取消设置邮箱，使用自动生成的 gmail 邮箱: $email${PLAIN}"
    fi

    local ACME_TAR_URL
    ACME_TAR_URL=$(get_acme_download_url)
    
    if wget --no-check-certificate -O master.tar.gz "$ACME_TAR_URL"; then
        tar zxvf master.tar.gz
        cd acme.sh-master || exit 1
        ./acme.sh --install --accountemail "$email"
        cd ..
        rm -rf acme.sh-master master.tar.gz
        source ~/.bashrc
        bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        switch_provider
        if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
            echo -e "${GREEN}Acme.sh 证书一键申请脚本安装成功!${PLAIN}"
        else
            echo -e "${RED}抱歉，Acme.sh 证书一键申请脚本安装失败${PLAIN}"
            echo -e "${GREEN}建议如下：${PLAIN}"
            echo -e "${YELLOW}检查 VPS 的网络环境${PLAIN}"
        fi
    else
        echo -e "${RED}Acme.sh 下载失败，请检查网络或稍后重试${PLAIN}"
    fi
    back2menu
}

unst_acme() {
    if [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        echo -e "${YELLOW}未安装 Acme.sh，卸载程序无法执行!${PLAIN}"
        back2menu
        return
    fi
    
    if ~/.acme.sh/acme.sh --uninstall; then
        sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1 || true
        rm -rf ~/.acme.sh
        echo -e "${GREEN}Acme.sh 证书一键申请脚本已彻底卸载!${PLAIN}"
    else
        echo -e "${RED}Acme.sh 卸载失败，请手动检查${PLAIN}"
    fi
    back2menu
}

# ====== 证书相关 ======
check_80() {
    if [[ -z $(type -P lsof) ]]; then
        if [[ "$SYSTEM_TYPE" != "centos" ]]; then
            pkg_update
        fi
        pkg_install lsof
    fi

    echo -e "${YELLOW}正在检测 80 端口状态...${PLAIN}"
    sleep 1

    local firewall_opened=false
   
    if command -v iptables &>/dev/null; then
        if ! iptables -L INPUT -n | grep -qE "dpt:80\s.*ACCEPT|dports.*80.*ACCEPT"; then
            echo -e "${YELLOW}检测到 iptables 未放行 80 端口，正在自动放行...${PLAIN}"
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            if command -v ip6tables &>/dev/null; then
                ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT
            fi
            firewall_opened=true
            echo -e "${GREEN}✓ 80 端口已放行 (iptables)${PLAIN}"
        fi
    fi
    
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        if ! firewall-cmd --list-ports 2>/dev/null | grep -q "80/tcp"; then
            echo -e "${YELLOW}检测到 firewalld 未放行 80 端口，正在自动放行...${PLAIN}"
            firewall-cmd --add-port=80/tcp --permanent
            firewall-cmd --reload
            firewall_opened=true
            echo -e "${GREEN}✓ 80 端口已放行 (firewalld)${PLAIN}"
        fi
    fi
    
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        if ! ufw status | grep -qE "80.*ALLOW"; then
            echo -e "${YELLOW}检测到 ufw 未放行 80 端口，正在自动放行...${PLAIN}"
            ufw allow 80/tcp
            firewall_opened=true
            echo -e "${GREEN}✓ 80 端口已放行 (ufw)${PLAIN}"
        fi
    fi
    
    if [[ "$firewall_opened" == "false" ]]; then
        echo -e "${GREEN}防火墙已放行 80 端口${PLAIN}"
    fi

    if [[ $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        echo -e "${GREEN}检测到目前 80 端口未被占用${PLAIN}"
        sleep 1
    else
        echo -e "${RED}检测到目前 80 端口被其他程序占用，以下为占用程序信息${PLAIN}"
        lsof -i:"80"
        read -rp "如需结束占用进程请按 Y，按其他键则退出 [Y/N]: " yn
        if [[ $yn =~ [Yy] ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

checktls() {
    local domain="$1"
    mkdir -p /root/cert

    if [[ -f /root/cert/$domain.crt && -f /root/cert/$domain.key ]]; then
        if [[ -s /root/cert/$domain.crt && -s /root/cert/$domain.key ]]; then
            warp_up

            sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1 || true
            echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab

            echo -e "${GREEN}证书申请成功! 证书 ($domain.crt) 和私钥 ($domain.key) 已保存到 /root/cert${PLAIN}"
            echo -e "${YELLOW}证书 crt 文件路径: /root/cert/$domain.crt${PLAIN}"
            echo -e "${YELLOW}私钥 key 文件路径: /root/cert/$domain.key${PLAIN}"
            return 0
        fi
    fi
    
    warp_up
    echo -e "${RED}抱歉，证书申请失败${PLAIN}"
    echo -e "${GREEN}建议如下:${PLAIN}"
    echo -e "${YELLOW}1. 请检查防火墙配置，80端口是否被占用${PLAIN}"
    echo -e "${YELLOW}2. 同一域名多次申请可能会触发风控，请尝试更换证书颁发机构，再重试申请${PLAIN}"
    return 1
}

acme_standalone() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    check_80

    local WARPv4Status WARPv6Status
    WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2) || true
    WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep warp | cut -d= -f2) || true
    if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
        warp_down
    fi

    check_ip

    echo ""
    echo -e "${YELLOW}在使用 80 端口申请模式时，请先将您的域名解析至您的 VPS 的真实 IP 地址，否则会导致证书申请失败${PLAIN}"
    echo ""
    if [[ -n $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真实 IPv4 地址为: ${GREEN}$ipv4${PLAIN}"
        echo -e "VPS 的真实 IPv6 地址为: ${GREEN}$ipv6${PLAIN}"
    elif [[ -n $ipv4 ]]; then
        echo -e "VPS 的真实 IPv4 地址为: ${GREEN}$ipv4${PLAIN}"
    elif [[ -n $ipv6 ]]; then
        echo -e "VPS 的真实 IPv6 地址为: ${GREEN}$ipv6${PLAIN}"
    fi
    echo ""

    local domain
    read -rp "请输入解析完成的域名: " domain
    if [[ -z $domain ]]; then
        echo -e "${RED}未输入域名，无法执行操作！${PLAIN}"
        back2menu
        return
    fi
    
    if ! validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确，请检查后重试！${PLAIN}"
        back2menu
        return
    fi
    
    echo -e "${GREEN}已输入的域名：$domain${PLAIN}" && sleep 1

    local domainIP
    domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | sed -n 1p) || true
    if echo "$domainIP" | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null | sed -n 1p) || true
    fi
    
    if echo "$domainIP" | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        echo -e "${RED}未解析出 IP，请检查域名是否输入有误${PLAIN}"
        echo -e "${YELLOW}是否尝试强行匹配？${PLAIN}"
        echo -e "${GREEN}1. 是，将使用强行匹配${PLAIN}"
        echo -e "${GREEN}2. 否，返回主菜单${PLAIN}"
        local ipChoice
        read -p "请输入选项 [1-2]：" ipChoice
        if [[ $ipChoice != 1 ]]; then
            echo -e "${RED}将返回主菜单${PLAIN}"
            back2menu
            return
        fi
        echo -e "${YELLOW}将尝试强行匹配以申请域名证书${PLAIN}"
    fi

    if [[ $domainIP == "$ipv6" ]]; then
        bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
    elif [[ $domainIP == "$ipv4" ]]; then
        bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
    fi

    if echo "$domainIP" | grep -q nginx; then
        warp_up
        echo -e "${YELLOW}域名解析失败，请检查域名是否正确填写或等待解析完成再执行脚本${PLAIN}"
        back2menu
        return
    elif [[ -n $(echo "$domainIP" | grep ":") || -n $(echo "$domainIP" | grep "\.") ]]; then
        if [[ $domainIP != "$ipv4" ]] && [[ $domainIP != "$ipv6" ]]; then
            warp_up
            echo -e "${GREEN}域名 ${domain} 目前解析的 IP: ($domainIP)${PLAIN}"
            echo -e "${RED}当前域名解析的 IP 与当前 VPS 使用的真实 IP 不匹配${PLAIN}"
            echo -e "${GREEN}建议如下：${PLAIN}"
            echo -e "${YELLOW}1. 请确保 CloudFlare 小云朵为关闭状态${PLAIN}"
            echo -e "${YELLOW}2. 请确保 DNS解析设置的 IP 为 VPS 的真实 IP${PLAIN}"
            back2menu
            return
        fi
    fi

    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/cert/"$domain".key --fullchain-file /root/cert/"$domain".crt --ecc
    checktls "$domain"
    back2menu
}

acme_cfapiTLD() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    local domain
    read -rp "请输入需要申请证书的域名: " domain
    
    if [[ -z $domain ]]; then
        echo -e "${RED}未输入域名，无法执行操作！${PLAIN}"
        back2menu
        return
    fi
    

    if ! get_cf_credentials; then
        back2menu
        return
    fi

    bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --insecure --force

    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/cert/"$domain".key --fullchain-file /root/cert/"$domain".crt --ecc
    checktls "$domain"
    back2menu
}

acme_cfapiNTLD() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    local domain
    read -rp "请输入需要申请证书的泛域名 (输入格式：example.com): " domain
    
    if [[ -z $domain ]]; then
        echo -e "${RED}未输入域名，无法执行操作！${PLAIN}"
        back2menu
        return
    fi
    

    if ! get_cf_credentials; then
        back2menu
        return
    fi

    bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --insecure --force

    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "*.${domain}" --key-file /root/cert/"$domain".key --fullchain-file /root/cert/"$domain".crt --ecc
    checktls "$domain"
    back2menu
}

view_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme
    bash ~/.acme.sh/acme.sh --list
    back2menu
}

revoke_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    bash ~/.acme.sh/acme.sh --list
    
    local domain
    read -rp "请输入要撤销的域名证书 (复制 Main_Domain 下显示的域名): " domain
    if [[ -z $domain ]]; then
        echo -e "${RED}未输入域名，无法执行操作!${PLAIN}"
        back2menu
        return
    fi

    if bash ~/.acme.sh/acme.sh --list | grep -q "$domain"; then
        bash ~/.acme.sh/acme.sh --revoke -d "${domain}" --ecc
        bash ~/.acme.sh/acme.sh --remove -d "${domain}" --ecc

        rm -rf ~/.acme.sh/"${domain}"_ecc
        rm -f /root/cert/"$domain".crt /root/cert/"$domain".key

        echo -e "${GREEN}撤销 ${domain} 的域名证书成功${PLAIN}"
    else
        echo -e "${RED}未找到 ${domain} 的域名证书，请检查后重新运行!${PLAIN}"
    fi
    back2menu
}

renew_cert() {
    if [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        echo -e "${YELLOW}未安装 acme.sh，无法执行操作!${PLAIN}"
        back2menu
        return
    fi
    bash ~/.acme.sh/acme.sh --cron -f
    back2menu
}

switch_provider() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    echo -e "${YELLOW}请选择证书提供商，默认通过 Letsencrypt.org 来申请证书${PLAIN}"
    echo -e "${YELLOW}如果证书申请失败，可选 BuyPass.com 或 ZeroSSL.com 来申请.${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org ${YELLOW}(默认)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com${PLAIN}"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com${PLAIN}"
    
    local provider
    read -rp "请选择证书提供商 [1-3]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && echo -e "${GREEN}切换证书提供商为 BuyPass.com 成功！${PLAIN}" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && echo -e "${GREEN}切换证书提供商为 ZeroSSL.com 成功！${PLAIN}" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && echo -e "${GREEN}切换证书提供商为 Letsencrypt.org 成功！${PLAIN}" ;;
    esac
    back2menu
}

generate_self_signed_cert() {
    echo ""
    echo -e "${YELLOW}开始生成自签名ECC证书...${PLAIN}"
    
    local DEFAULT_DOMAIN="bing.com"
    local DEFAULT_CERT_PATH="/etc/cert"
    local DEFAULT_DAYS=36500

    local domain cert_path days
    read -rp "请输入证书的域名（默认: ${DEFAULT_DOMAIN}）: " domain
    domain="${domain:-$DEFAULT_DOMAIN}"
    read -rp "请输入证书存放路径（默认: ${DEFAULT_CERT_PATH}）: " cert_path
    cert_path="${cert_path:-$DEFAULT_CERT_PATH}"
    read -rp "请输入证书有效天数（默认: ${DEFAULT_DAYS}）: " days
    days="${days:-$DEFAULT_DAYS}"

    local key_file="${cert_path}/server.key"
    local crt_file="${cert_path}/server.crt"

    mkdir -p "$cert_path"
    echo "生成 ECC 私钥..."
    openssl ecparam -name prime256v1 -genkey -noout -out "$key_file"
    echo "使用私钥生成自签证书..."
    openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain"
    chmod 644 "$crt_file"
    chmod 600 "$key_file"

    echo ""
    echo -e "${GREEN}自签名证书生成完成！${PLAIN}"
    echo "私钥位置: $key_file"
    echo "证书位置: $crt_file"
    back2menu
}

# ====== 主菜单 ======
menu() {
    clear
    echo "==============================="
    echo -e "         ${RED}证书申请 OR 自签${PLAIN}"
    echo "==============================="
    echo -e " ${GREEN} 1.${PLAIN}安装Acme"
    echo -e " ${GREEN} 2.${PLAIN}卸载Acme"
    echo " -------------"
    echo -e " ${GREEN} 3.${PLAIN}申请单域名证书 ${YELLOW}(80 端口申请)${PLAIN}"
    echo -e " ${GREEN} 4.${PLAIN}申请单域名证书 ${YELLOW}(CF API 申请)${PLAIN}"
    echo -e " ${GREEN} 5.${PLAIN}申请泛域名证书 ${YELLOW}(CF API 申请)${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN} 6.${PLAIN}查看已申请的证书"
    echo -e " ${GREEN} 7.${PLAIN}撤销已申请的证书"
    echo -e " ${GREEN} 8.${PLAIN}续期已申请的证书"
    echo -e " ${GREEN} 9.${PLAIN}切换证书颁发机构"
    echo -e " ${GREEN}10.${PLAIN}生成自签证书"
    echo " -------------"
    echo -e " ${GREEN} 0.${PLAIN}退出脚本"
    echo ""
    
    local menuInput
    read -rp "$(echo -e "${RED}请输入选项 [0-10]: ${PLAIN}")" menuInput
    case "$menuInput" in
        1) inst_acme ;;
        2) unst_acme ;;
        3) acme_standalone ;;
        4) acme_cfapiTLD ;;
        5) acme_cfapiNTLD ;;
        6) view_cert ;;
        7) revoke_cert ;;
        8) renew_cert ;;
        9) switch_provider ;;
        10) generate_self_signed_cert ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}"; sleep 1; menu ;;
    esac
}

menu
