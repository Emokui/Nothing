#!/bin/bash

set -uo pipefail

# ====== 颜色变量 ======
RED="\033[31m\033[01m"
GREEN="\033[32m\033[01m"
YELLOW="\033[33m\033[01m"
BLUE="\033[34m\033[01m"
PLAIN='\033[0m'

# ====== 证书路径 ======
CERT_PATH="/etc/cert"
mkdir -p "$CERT_PATH"

# ====== 检测IPv4 ======
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

# ====== 包管理器 ======
pkg_update() {
    apt-get update
}

pkg_install() {
    apt -y install "$@"
}

# ====== 辅助函数 ======
back2menu() {
    echo ""
    echo -e "${YELLOW}操作完成！按 Enter 键返回主菜单${PLAIN}"
    read -r
}

ensure_acme_installed() {
    if [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        echo -e "${YELLOW}检测到尚未安装 acme.sh，正在自动安装...${PLAIN}"
        install_acme_core
        if [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
            echo -e "${RED}acme.sh 安装失败，无法继续操作${PLAIN}"
            return 1
        fi
    fi
    return 0
}

display_cert_list() {
    local cert_list
    cert_list=$(get_cert_list)
    
    if [[ -z "$cert_list" ]]; then
        echo -e "${YELLOW}暂无已申请的证书${PLAIN}"
        return 1
    fi
    
    printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | ${GREEN}%-15s${PLAIN}\n" "序号" "域名" "到期时间"
    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"
    
    local index=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local main_domain expire_time
        main_domain=$(echo "$line" | awk '{print $1}')
        expire_time=$(echo "$line" | awk '{print $6}' | cut -d'T' -f1)
        
        if [[ "$main_domain" == \** ]]; then
            printf "${YELLOW}%-4s${PLAIN} | ${YELLOW}%-40s${PLAIN} | %-15s\n" "$index" "$main_domain" "$expire_time"
        else
            printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | %-15s\n" "$index" "$main_domain" "$expire_time"
        fi
        ((index++))
    done <<< "$cert_list"
    
    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"
    return 0
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

# ====== 获取证书列表 ======
get_cert_list() {
    local output
    output=$(~/.acme.sh/acme.sh --list 2>/dev/null | tail -n +2) || true
    echo "$output"
}

# ====== Acme 安装与卸载 ======
install_acme_core() {
    pkg_update
    pkg_install curl wget socat openssl dnsutils cron
    
    systemctl start cron
    systemctl enable cron

    local automail
    automail=$(date +%s%N | md5sum | cut -c 1-16)
    local email=$automail@gmail.com

    local ACME_TAR_URL
    ACME_TAR_URL=$(get_acme_download_url)
    
    if wget --no-check-certificate -O master.tar.gz "$ACME_TAR_URL"; then
        tar zxvf master.tar.gz
        (cd acme.sh-master && ./acme.sh --install --accountemail "$email")
        rm -rf acme.sh-master master.tar.gz
        bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        
        bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

        if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
            echo -e "${GREEN}Acme 安装成功!${PLAIN}"
        else
            echo -e "${RED}Acme 安装失败${PLAIN}"
        fi

    fi
}

inst_acme() {
    install_acme_core
    back2menu
}

unst_acme() {
    if [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        echo -e "${YELLOW}未安装 Acme.sh，卸载程序无法执行!${PLAIN}"
        back2menu
        return
    fi
    
    if ~/.acme.sh/acme.sh --uninstall; then
        rm -rf ~/.acme.sh
        echo -e "${GREEN}Acme 已彻底卸载!${PLAIN}"
    else
        echo -e "${RED}Acme 卸载失败，请手动检查${PLAIN}"
    fi
    back2menu
}

# ====== 证书相关 ======
check_80() {
    if [[ -z $(type -P lsof) ]]; then
        pkg_update
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
        read -rp "如需结束占用进程请按 Y，按其他键则返回菜单 [Y/N]: " yn
        if [[ $yn =~ [Yy] ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            back2menu
            return 1
        fi
    fi
    return 0
}

checktls() {
    local domain="$1"
    mkdir -p "$CERT_PATH"

    if [[ -f "$CERT_PATH/$domain.crt" && -f "$CERT_PATH/$domain.key" ]]; then
        if [[ -s "$CERT_PATH/$domain.crt" && -s "$CERT_PATH/$domain.key" ]]; then
            echo -e "${GREEN}证书申请成功! 证书 ($domain.crt) 和私钥 ($domain.key) 已保存到 $CERT_PATH${PLAIN}"
            echo -e "${YELLOW}证书 crt 文件路径: $CERT_PATH/$domain.crt${PLAIN}"
            echo -e "${YELLOW}私钥 key 文件路径: $CERT_PATH/$domain.key${PLAIN}"
            return 0
        fi
    fi
    
    echo -e "${RED}证书申请失败${PLAIN}"
    return 1
}

acme_standalone() {
    ensure_acme_installed || return

    if ! check_80; then
        return
    fi

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

    if ! has_ipv4; then
        bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
    fi

    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file "$CERT_PATH/$domain.key" --fullchain-file "$CERT_PATH/$domain.crt" --ecc
    checktls "$domain"
    back2menu
}

acme_cfapiTLD() {
    ensure_acme_installed || return

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

    bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --insecure

    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file "$CERT_PATH/$domain.key" --fullchain-file "$CERT_PATH/$domain.crt" --ecc
    checktls "$domain"
    back2menu
}

acme_cfapiNTLD() {
    ensure_acme_installed || return

    local domain
    read -rp "请输入需要申请证书的泛域名: " domain
    
    if [[ -z $domain ]]; then
        echo -e "${RED}未输入域名，无法执行操作！${PLAIN}"
        back2menu
        return
    fi

    if ! get_cf_credentials; then
        back2menu
        return
    fi

    bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --insecure

    bash ~/.acme.sh/acme.sh --install-cert -d "*.${domain}" --key-file "$CERT_PATH/$domain.key" --fullchain-file "$CERT_PATH/$domain.crt" --ecc
    checktls "$domain"
    back2menu
}



revoke_cert() {
    ensure_acme_installed || return
    
    echo ""
    clear
    echo -e "${BLUE}==================== 已申请的证书列表 ====================${PLAIN}"
    
    local cert_list
    cert_list=$(get_cert_list)
    
    if [[ -z "$cert_list" ]]; then
        echo -e "${YELLOW}暂无已申请的证书${PLAIN}"
        back2menu
        return
    fi
    
    declare -a domains
    local index=1
    
    printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | ${GREEN}%-15s${PLAIN}\n" "序号" "域名" "到期时间"
    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local main_domain expire_time
        main_domain=$(echo "$line" | awk '{print $1}')
        expire_time=$(echo "$line" | awk '{print $6}' | cut -d'T' -f1)
        
        domains+=("$main_domain")
        
        if [[ "$main_domain" == \** ]]; then
            printf "${YELLOW}%-4s${PLAIN} | ${YELLOW}%-40s${PLAIN} | %-15s\n" "$index" "$main_domain" "$expire_time"
        else
            printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | %-15s\n" "$index" "$main_domain" "$expire_time"
        fi
        ((index++))
    done <<< "$cert_list"
    
    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"
    echo ""
    
    local choice
    read -rp "请输入要撤销的证书序号(输入0返回): " choice
    
    if [[ "$choice" == "0" ]]; then
        back2menu
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#domains[@]}" ]]; then
        echo -e "${RED}无效的序号！${PLAIN}"
        back2menu
        return
    fi
    
    local selected_domain="${domains[$((choice-1))]}"
    
    echo -e "${YELLOW}即将撤销证书: $selected_domain${PLAIN}"
    read -rp "确认撤销? [y/N]: " confirm
    
    if [[ ! $confirm =~ [Yy] ]]; then
        echo -e "${YELLOW}已取消操作${PLAIN}"
        back2menu
        return
    fi
    
    bash ~/.acme.sh/acme.sh --revoke -d "${selected_domain}" --ecc
    bash ~/.acme.sh/acme.sh --remove -d "${selected_domain}" --ecc
    
    rm -rf ~/.acme.sh/"${selected_domain}"_ecc
    
    local base_domain="${selected_domain#\*.}"
    rm -f "$CERT_PATH/$base_domain.crt" "$CERT_PATH/$base_domain.key"
    rm -f "$CERT_PATH/$selected_domain.crt" "$CERT_PATH/$selected_domain.key" 2>/dev/null || true
    
    echo -e "${GREEN}✓ 证书 ${selected_domain} 已成功撤销${PLAIN}"
    back2menu
}

renew_cert() {
    ensure_acme_installed || return
    
    bash ~/.acme.sh/acme.sh --cron
    back2menu
}

select_provider_core() {
    echo -e "${YELLOW}证书颁发机构${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com${PLAIN}"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com${PLAIN}"
    
    local provider
    read -rp "请选择 [1-3]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && echo -e "${GREEN}切换证书颁发机构为 BuyPass.com 成功！${PLAIN}" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && echo -e "${GREEN}切换证书颁发机构为 ZeroSSL.com 成功！${PLAIN}" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && echo -e "${GREEN}切换证书颁发机构为 Letsencrypt.org 成功！${PLAIN}" ;;
    esac
}

switch_provider() {
    ensure_acme_installed || return

    select_provider_core
    back2menu
}

generate_self_signed_cert() {
    echo ""
    echo -e "${YELLOW}开始生成自签证书...${PLAIN}"
    
    local DEFAULT_DOMAIN="icloud.com.cn"
    local days=3650

    local domain
    read -rp "请输入证书的域名（默认: ${DEFAULT_DOMAIN}）: " domain
    domain="${domain:-$DEFAULT_DOMAIN}"

    local key_file="$CERT_PATH/${domain}.key"
    local crt_file="$CERT_PATH/${domain}.crt"

    openssl ecparam -name prime256v1 -genkey -noout -out "$key_file"
    openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain"
    chmod 644 "$crt_file"
    chmod 600 "$key_file"

    echo ""
    echo -e "${GREEN}自签证书生成完成！${PLAIN}"
    echo "私钥位置: $key_file"
    echo "证书位置: $crt_file"
    back2menu
}

# ====== 主菜单 ======
menu() {
    while true; do
        clear
        echo "==============================="
        echo -e "         ${RED}证书申请${PLAIN}"
        echo "==============================="
        echo -e " ${GREEN} 1.${PLAIN}安装Acme"
        echo -e " ${GREEN} 2.${PLAIN}卸载Acme"
        echo " -------------"
        echo -e " ${GREEN} 3.${PLAIN}申请单域名证书 ${YELLOW}(80 端口申请)${PLAIN}"
        echo -e " ${GREEN} 4.${PLAIN}申请单域名证书 ${YELLOW}(CF API 申请)${PLAIN}"
        echo -e " ${GREEN} 5.${PLAIN}申请泛域名证书 ${YELLOW}(CF API 申请)${PLAIN}"
        echo " -------------"
        echo -e " ${GREEN} 6.${PLAIN}撤销已申请的证书"
        echo -e " ${GREEN} 7.${PLAIN}续期已申请的证书"
        echo -e " ${GREEN} 8.${PLAIN}切换证书颁发机构"
        echo -e " ${GREEN} 9.${PLAIN}生成自签证书"
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
            6) revoke_cert ;;
            7) renew_cert ;;
            8) switch_provider ;;
            9) generate_self_signed_cert ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu
