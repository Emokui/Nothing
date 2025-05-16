#!/bin/bash

# ====== 颜色变量 ======
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red()    { echo -e "\033[31m\033[01m$1\033[0m"; }
green()  { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

# ====== 系统适配 ======
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && red "注意：请在 root 用户下运行脚本" && exit 1

CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep -i description /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(uname -s)"
)
for i in "${CMD[@]}"; do
    SYS="$i"
    if [[ -n $SYS ]]; then
        break
    fi
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "不支持当前 VPS 系统，请使用主流的操作系统" && exit 1

# ====== 辅助函数 ======
back2menu() {
    echo ""
    yellow "操作完成！按 Enter 键返回主菜单，或按 Ctrl+C 退出脚本..."
    read -r
    menu
}

check_ip() {
    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)
}

# ====== Acme 安装与卸载 ======
inst_acme() {
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl dnsutils

    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} cronie
        systemctl start crond
        systemctl enable crond
    else
        ${PACKAGE_INSTALL[int]} cron
        systemctl start cron
        systemctl enable cron
    fi

    read -rp "请输入注册邮箱 (留空自动生成一个 gmail 邮箱): " email
    if [[ -z $email ]]; then
        automail=$(date +%s%N | md5sum | cut -c 1-16)
        email=$automail@gmail.com
        yellow "已取消设置邮箱，使用自动生成的 gmail 邮箱: $email"
    fi

    curl https://get.acme.sh | sh -s email=$email
    source ~/.bashrc
    bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade

    switch_provider

    if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        green "Acme.sh 证书一键申请脚本安装成功!"
    else
        red "抱歉，Acme.sh 证书一键申请脚本安装失败"
        green "建议如下："
        yellow "检查 VPS 的网络环境"
    fi
    back2menu
}

unst_acme() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装 Acme.sh，卸载程序无法执行!" && back2menu
    ~/.acme.sh/acme.sh --uninstall
    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
    rm -rf ~/.acme.sh
    green "Acme.sh 证书一键申请脚本已彻底卸载!"
    back2menu
}

# ====== 证书相关 ======
check_80() {
    if [[ -z $(type -P lsof) ]]; then
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        ${PACKAGE_INSTALL[int]} lsof
    fi

    yellow "正在检测 80 端口是否被占用..."
    sleep 1

    if [[ $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        green "检测到目前 80 端口未被占用"
        sleep 1
    else
        red "检测到目前 80 端口被其他程序占用，以下为占用程序信息"
        lsof -i:"80"
        read -rp "如需结束占用进程请按 Y，按其他键则退出 [Y/N]: " yn
        if [[ $yn =~ "Y"|"y" ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

checktls() {
    mkdir -p /root/cert

    if [[ -f /root/cert/$domain.crt && -f /root/cert/$domain.key ]]; then
        if [[ -s /root/cert/$domain.crt && -s /root/cert/$domain.key ]]; then
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go
            fi

            echo $domain > /root/cert/ca.log
            sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
            echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab

            green "证书申请成功! 证书 ($domain.crt) 和私钥 ($domain.key) 已保存到 /root/cert"
            yellow "证书 crt 文件路径: /root/cert/$domain.crt"
            yellow "私钥 key 文件路径: /root/cert/$domain.key"
        else
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go
            fi

            red "抱歉，证书申请失败"
            green "建议如下:"
            yellow "1. 请检查防火墙配置，80端口是否被占用"
            yellow "2. 同一域名多次申请可能会触发风控，请尝试更换证书颁发机构，再重试申请"
        fi
    fi
}

acme_standalone() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    check_80

    WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
    fi

    check_ip

    echo ""
    yellow "在使用 80 端口申请模式时，请先将您的域名解析至您的 VPS 的真实 IP 地址，否则会导致证书申请失败"
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

    read -rp "请输入解析完成的域名: " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && back2menu
    green "已输入的域名：$domain" && sleep 1

    domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | sed -n 1p)
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null | sed -n 1p)
    fi
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
        red "未解析出 IP，请检查域名是否输入有误"
        yellow "是否尝试强行匹配？"
        green "1. 是，将使用强行匹配"
        green "2. 否，返回主菜单"
        read -p "请输入选项 [1-2]：" ipChoice
        if [[ $ipChoice == 1 ]]; then
            yellow "将尝试强行匹配以申请域名证书"
        else
            red "将返回主菜单"
            back2menu
        fi
    fi

    if [[ $domainIP == $ipv6 ]]; then
        bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
    fi
    if [[ $domainIP == $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
    fi

    if [[ -n $(echo $domainIP | grep nginx) ]]; then
        if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
            wg-quick up wgcf >/dev/null 2>&1
        fi
        if [[ -a "/opt/warp-go/warp-go" ]]; then
            systemctl start warp-go
        fi
        yellow "域名解析失败，请检查域名是否正确填写或等待解析完成再执行脚本"
        back2menu
    elif [[ -n $(echo $domainIP | grep ":") || -n $(echo $domainIP | grep ".") ]]; then
        if [[ $domainIP != $ipv4 ]] && [[ $domainIP != $ipv6 ]]; then
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go
            fi
            green "域名 ${domain} 目前解析的 IP: ($domainIP)"
            red "当前域名解析的 IP 与当前 VPS 使用的真实 IP 不匹配"
            green "建议如下："
            yellow "1. 请确保 CloudFlare 小云朵为关闭状态"
            yellow "2. 请确保 DNS解析设置的 IP 为 VPS 的真实 IP"
            back2menu
        fi
    fi

    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/cert/$domain.key --fullchain-file /root/cert/$domain.crt --ecc
    checktls
    back2menu
}

acme_cfapiTLD() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    check_ip

    read -rp "请输入需要申请证书的域名: " domain
    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "检测为 Freenom 免费域名，由于 CloudFlare API 不支持，故无法使用本模式申请!"
        back2menu
    fi

    read -rp "请输入 CloudFlare Global API Key: " cfgak
    [[ -z $cfgak ]] && red "未输入 CloudFlare Global API Key，无法执行操作!" && back2menu
    export CF_Key="$cfgak"
    read -rp "请输入 CloudFlare 的登录邮箱: " cfemail
    [[ -z $cfemail ]] && red "未输入 CloudFlare 的登录邮箱，无法执行操作!" && back2menu
    export CF_Email="$cfemail"

    if [[ -z $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --insecure
    fi

    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/cert/$domain.key --fullchain-file /root/cert/$domain.crt --ecc
    checktls
    back2menu
}

acme_cfapiNTLD() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    check_ip

    read -rp "请输入需要申请证书的泛域名 (输入格式：example.com): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作！" && back2menu
    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "检测为 Freenom 免费域名，由于 CloudFlare API 不支持，故无法使用本模式申请!"
        back2menu
    fi

    read -rp "请输入 CloudFlare Global API Key: " cfgak
    [[ -z $cfgak ]] && red "未输入 CloudFlare Global API Key，无法执行操作！" && back2menu
    export CF_Key="$cfgak"
    read -rp "请输入 CloudFlare 的登录邮箱: " cfemail
    [[ -z $cfemail ]] && red "未输入 CloudFlare 的登录邮箱，无法执行操作！" && back2menu
    export CF_Email="$cfemail"

    if [[ -z $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --insecure
    fi

    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "*.${domain}" --key-file /root/cert/$domain.key --fullchain-file /root/cert/$domain.crt --ecc
    checktls
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
    read -rp "请输入要撤销的域名证书 (复制 Main_Domain 下显示的域名): " domain
    [[ -z $domain ]] && red "未输入域名，无法执行操作!" && back2menu

    if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $domain) ]]; then
        bash ~/.acme.sh/acme.sh --revoke -d ${domain} --ecc
        bash ~/.acme.sh/acme.sh --remove -d ${domain} --ecc

        rm -rf ~/.acme.sh/${domain}_ecc
        rm -f /root/cert/$domain.crt /root/cert/$domain.key

        green "撤销 ${domain} 的域名证书成功"
    else
        red "未找到 ${domain} 的域名证书，请检查后重新运行!"
    fi
    back2menu
}

renew_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安装 acme.sh，无法执行操作!" && back2menu
    bash ~/.acme.sh/acme.sh --cron -f
    back2menu
}

switch_provider() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    yellow "请选择证书提供商，默认通过 Letsencrypt.org 来申请证书"
    yellow "如果证书申请失败，可选 BuyPass.com 或 ZeroSSL.com 来申请."
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org ${YELLOW}(默认)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com"
    read -rp "请选择证书提供商 [1-3]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && green "切换证书提供商为 BuyPass.com 成功！" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && green "切换证书提供商为 ZeroSSL.com 成功！" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && green "切换证书提供商为 Letsencrypt.org 成功！" ;;
    esac
    back2menu
}

generate_self_signed_cert() {
    echo ""
    yellow "开始生成自签名ECC证书..."
    DEFAULT_DOMAIN="bing.com"
    DEFAULT_CERT_PATH="/etc/cert"
    DEFAULT_DAYS=36500

    read -rp "请输入证书的域名（默认: ${DEFAULT_DOMAIN}）: " domain
    domain="${domain:-$DEFAULT_DOMAIN}"
    read -rp "请输入证书存放路径（默认: ${DEFAULT_CERT_PATH}）: " cert_path
    cert_path="${cert_path:-$DEFAULT_CERT_PATH}"
    read -rp "请输入证书有效天数（默认: ${DEFAULT_DAYS}）: " days
    days="${days:-$DEFAULT_DAYS}"

    key_file="${cert_path}/server.key"
    crt_file="${cert_path}/server.crt"

    sudo mkdir -p "$cert_path"
    echo "生成 ECC 私钥..."
    sudo openssl ecparam -name prime256v1 -genkey -noout -out "$key_file"
    echo "使用私钥生成自签证书..."
    sudo openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain"
    sudo chmod 644 "$crt_file"
    sudo chmod 600 "$key_file"

    echo ""
    green "自签名证书生成完成！"
    echo "私钥位置: $key_file"
    echo "证书位置: $crt_file"
    back2menu
}

# ====== 主菜单 ======
menu() {
    clear
    echo "#############################################################"
    echo -e "#                   ${RED}证书申请 OR 自签证书${PLAIN}                  #"
    echo -e "#             ${GREEN}命运石之门的选择,El Psy Kongroo${PLAIN}             #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN}  安装 Acme.sh 域名证书申请脚本"
    echo -e " ${GREEN}2.${PLAIN} ${RED} 卸载 Acme.sh 域名证书申请脚本${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN}  申请单域名证书 ${YELLOW}(80 端口申请)${PLAIN}"
    echo -e " ${GREEN}4.${PLAIN}  申请单域名证书 ${YELLOW}(CF API 申请)${PLAIN} ${GREEN}(无需解析)${PLAIN}"
    echo -e " ${GREEN}5.${PLAIN}  申请泛域名证书 ${YELLOW}(CF API 申请)${PLAIN} ${GREEN}(无需解析)${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}6.${PLAIN}  查看已申请的证书"
    echo -e " ${GREEN}7.${PLAIN}  撤销并删除已申请的证书"
    echo -e " ${GREEN}8.${PLAIN}  手动续期已申请的证书"
    echo -e " ${GREEN}9.${PLAIN}  切换证书颁发机构"
    echo -e " ${GREEN}10.${PLAIN} 生成自签名证书"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN}  退出脚本"
    echo ""
    read -rp "请输入选项 [0-10]: " menuInput
    case "$menuInput" in
        1 ) inst_acme ;;
        2 ) unst_acme ;;
        3 ) acme_standalone ;;
        4 ) acme_cfapiTLD ;;
        5 ) acme_cfapiNTLD ;;
        6 ) view_cert ;;
        7 ) revoke_cert ;;
        8 ) renew_cert ;;
        9 ) switch_provider ;;
        10 ) generate_self_signed_cert ;;
        * ) exit 1 ;;
    esac
}

menu
