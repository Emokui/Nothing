#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && red "注意：請在 root 用戶下運行腳本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i"
    if [[ -n $SYS ]]; then
        break
    fi
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "不支持當前 VPS 系統，請使用主流的操作系統" && exit 1

# 新增返回主菜單函數
back2menu() {
    echo ""
    yellow "操作完成！按 Enter 鍵返回主菜單，或按 Ctrl+C 退出腳本..."
    read -r
    menu
}

check_ip(){
    ipv4=$(curl -s4m8 ip.sb -k | sed -n 1p)
    ipv6=$(curl -s6m8 ip.sb -k | sed -n 1p)
}

inst_acme(){
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

    read -rp "請輸入註冊郵箱 (留空自動生成一個 gmail 郵箱): " email
    if [[ -z $email ]]; then
        automail=$(date +%s%N | md5sum | cut -c 1-16)
        email=$automail@gmail.com
        yellow "已取消設置郵箱，使用自動生成的 gmail 郵箱: $email"
    fi

    curl https://get.acme.sh | sh -s email=$email
    source ~/.bashrc
    bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    
    switch_provider

    if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        green "Acme.sh 證書一鍵申請腳本安裝成功!"
    else
        red "抱歉，Acme.sh 證書一鍵申請腳本安裝失敗"
        green "建議如下："
        yellow "檢查 VPS 的網絡環境"
    fi
    back2menu
}

unst_acme() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安裝 Acme.sh，卸載程序無法執行!" && back2menu
    ~/.acme.sh/acme.sh --uninstall
    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
    rm -rf ~/.acme.sh
    green "Acme.sh 證書一鍵申請腳本已徹底卸載!"
    back2menu
}

check_80(){
    if [[ -z $(type -P lsof) ]]; then
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        ${PACKAGE_INSTALL[int]} lsof
    fi
    
    yellow "正在檢測 80 端口是否被占用..."
    sleep 1
    
    if [[  $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        green "檢測到目前 80 端口未被占用"
        sleep 1
    else
        red "檢測到目前 80 端口被其他程序占用，以下為占用程序信息"
        lsof -i:"80"
        read -rp "如需結束占用進程請按 Y，按其他鍵則退出 [Y/N]: " yn
        if [[ $yn =~ "Y"|"y" ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

checktls() {
    # 確保 /root/cert 目錄存在
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

            green "證書申請成功! 腳本申請到的證書 ($domain.crt) 和私鑰 ($domain.key) 文件已保存到 /root/cert 文件夾下"
            yellow "證書 crt 文件路徑如下: /root/cert/$domain.crt"
            yellow "私鑰 key 文件路徑如下: /root/cert/$domain.key"
        else
            if [[ -n $(type -P wg-quick) && -n $(type -P wgcf) ]]; then
                wg-quick up wgcf >/dev/null 2>&1
            fi
            if [[ -a "/opt/warp-go/warp-go" ]]; then
                systemctl start warp-go 
            fi

            red "抱歉，證書申請失敗"
            green "建議如下: "
            yellow "1. 自行檢測防火牆配置，80端口是否被占用"
            yellow "2. 同一域名多次申請可能會觸發風控，請嘗試更換證書頒發機構，再重試申請證書"
        fi
    fi
}

acme_standalone(){
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
    yellow "在使用 80 端口申請模式時，請先將您的域名解析至您的 VPS 的真實 IP 地址，否則會導致證書申請失敗"
    echo ""
    if [[ -n $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真實 IPv4 地址為: ${GREEN}$ipv4${PLAIN}"
        echo -e "VPS 的真實 IPv6 地址為: ${GREEN}$ipv6${PLAIN}"
    elif [[ -n $ipv4 && -z $ipv6 ]]; then
        echo -e "VPS 的真實 IPv4 地址為: ${GREEN}$ipv4${PLAIN}"
    elif [[ -z $ipv4 && -n $ipv6 ]]; then
        echo -e "VPS 的真實 IPv6 地址為: ${GREEN}$ipv6${PLAIN}"
    fi
    echo ""

    read -rp "請輸入解析完成的域名: " domain
    [[ -z $domain ]] && red "未輸入域名，無法執行操作！" && back2menu
    green "已輸入的域名：$domain" && sleep 1

    domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | sed -n 1p)
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null | sed -n 1p)
    fi
    if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
        red "未解析出 IP，請檢查域名是否輸入有誤" 
        yellow "是否嘗試強行匹配？"
        green "1. 是，將使用強行匹配"
        green "2. 否，返回主菜單"
        read -p "請輸入選項 [1-2]：" ipChoice
        if [[ $ipChoice == 1 ]]; then
            yellow "將嘗試強行匹配以申請域名證書"
        else
            red "將返回主菜單"
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
        yellow "域名解析失敗，請檢查域名是否正確填寫或等待解析完成再執行腳本"
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
            red "當前域名解析的 IP 與當前 VPS 使用的真實 IP 不匹配"
            green "建議如下："
            yellow "1. 請確保 CloudFlare 小雲朵為關閉狀態"
            yellow "2. 請確保 DNS解析設置的 IP 為 VPS 的真實 IP"
            back2menu
        fi
    fi
    
    # 修改證書保存路徑和文件名
    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/cert/$domain.key --fullchain-file /root/cert/$domain.crt --ecc
    checktls
    back2menu
}

acme_cfapiTLD(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme
    
    check_ip

    read -rp "請輸入需要申請證書的域名: " domain
    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "檢測為 Freenom 免費域名，由於 CloudFlare API 不支持，故無法使用本模式申請!"
        back2menu
    fi

    read -rp "請輸入 CloudFlare Global API Key: " cfgak
    [[ -z $cfgak ]] && red "未輸入 CloudFlare Global API Key，無法執行操作!" && back2menu
    export CF_Key="$cfgak"
    read -rp "請輸入 CloudFlare 的登錄郵箱: " cfemail
    [[ -z $cfemail ]] && red "未輸入 CloudFlare 的登錄郵箱，無法執行操作!" && back2menu
    export CF_Email="$cfemail"
    
    if [[ -z $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256 --insecure
    fi

    # 修改證書保存路徑和文件名
    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/cert/$domain.key --fullchain-file /root/cert/$domain.crt --ecc
    checktls
    back2menu
}

acme_cfapiNTLD(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme
    
    check_ip
    
    read -rp "請輸入需要申請證書的泛域名 (輸入格式：example.com): " domain
    [[ -z $domain ]] && red "未輸入域名，無法執行操作！" && back2menu
    if [[ $(echo ${domain:0-2}) =~ cf|ga|gq|ml|tk ]]; then
        red "檢測為 Freenom 免費域名，由於 CloudFlare API 不支持，故無法使用本模式申請!"
        back2menu
    fi

    read -rp "請輸入 CloudFlare Global API Key: " cfgak
    [[ -z $cfgak ]] && red "未輸入 CloudFlare Global API Key，無法執行操作！" && back2menu
    export CF_Key="$cfgak"
    read -rp "請輸入 CloudFlare 的登錄郵箱: " cfemail
    [[ -z $cfemail ]] && red "未輸入 CloudFlare 的登錄郵箱，無法執行操作!" && back2menu
    export CF_Email="$cfemail"

    if [[ -z $ipv4 ]]; then
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --listen-v6 --insecure
    else
        bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "*.${domain}" -d "${domain}" -k ec-256 --insecure
    fi

    # 修改證書保存路徑和文件名（泛域名使用 domain 作為文件名）
    mkdir -p /root/cert
    bash ~/.acme.sh/acme.sh --install-cert -d "*.${domain}" --key-file /root/cert/$domain.key --fullchain-file /root/cert/$domain.crt --ecc
    checktls
    back2menu
}

view_cert(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme
    bash ~/.acme.sh/acme.sh --list
    back2menu
}

revoke_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    bash ~/.acme.sh/acme.sh --list
    read -rp "請輸入要撤銷的域名證書 (複製 Main_Domain 下顯示的域名): " domain
    [[ -z $domain ]] && red "未輸入域名，無法執行操作!" && back2menu

    if [[ -n $(bash ~/.acme.sh/acme.sh --list | grep $domain) ]]; then
        bash ~/.acme.sh/acme.sh --revoke -d ${domain} --ecc
        bash ~/.acme.sh/acme.sh --remove -d ${domain} --ecc

        rm -rf ~/.acme.sh/${domain}_ecc
        rm -f /root/cert/$domain.crt /root/cert/$domain.key

        green "撤銷 ${domain} 的域名證書成功"
    else
        red "未找到 ${domain} 的域名證書，請檢查後重新運行!"
    fi
    back2menu
}

renew_cert() {
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && yellow "未安裝 acme.sh，無法執行操作!" && back2menu
    bash ~/.acme.sh/acme.sh --cron -f
    back2menu
}

switch_provider(){
    [[ -z $(~/.acme.sh/acme.sh -v 2>/dev/null) ]] && inst_acme

    yellow "請選擇證書提供商，默認通過 Letsencrypt.org 來申請證書"
    yellow "如果證書申請失敗，例如一天內通過 Letsencrypt.org 申請次數過多，可選 BuyPass.com 或 ZeroSSL.com 來申請."
    echo -e " ${GREEN}1.${PLAIN} Letsencrypt.org ${YELLOW}(默認)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} BuyPass.com"
    echo -e " ${GREEN}3.${PLAIN} ZeroSSL.com"
    read -rp "請選擇證書提供商 [1-3]: " provider
    case $provider in
        2) bash ~/.acme.sh/acme.sh --set-default-ca --server buypass && green "切換證書提供商為 BuyPass.com 成功！" ;;
        3) bash ~/.acme.sh/acme.sh --set-default-ca --server zerossl && green "切換證書提供商為 ZeroSSL.com 成功！" ;;
        *) bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt && green "切換證書提供商為 Letsencrypt.org 成功！" ;;
    esac
    back2menu
}

generate_self_signed_cert() {
    echo ""
    yellow "开始生成自签名ECC证书..."
    # 默认参数
    DEFAULT_DOMAIN="bing.com"
    DEFAULT_CERT_PATH="/etc/cert"
    DEFAULT_DAYS=36500
    
    # 获取用户输入
    read -rp "请输入证书的域名（默认: ${DEFAULT_DOMAIN}）: " domain
    domain="${domain:-$DEFAULT_DOMAIN}"
    read -rp "请输入证书存放路径（默认: ${DEFAULT_CERT_PATH}）: " cert_path
    cert_path="${cert_path:-$DEFAULT_CERT_PATH}"
    read -rp "请输入证书有效天数（默认: ${DEFAULT_DAYS}）: " days
    days="${days:-$DEFAULT_DAYS}"
    
    # 文件路径
    key_file="${cert_path}/server.key"
    crt_file="${cert_path}/server.crt"
    
    # 创建目录
    sudo mkdir -p "$cert_path"
    
    # 生成 ECC 私钥
    echo "生成 ECC 私钥..."
    sudo openssl ecparam -name prime256v1 -genkey -noout -out "$key_file"
    
    # 使用私钥生成自签证书
    echo "使用私钥生成自签证书..."
    sudo openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain"
    
    # 设置适当的权限
    sudo chmod 644 "$crt_file"
    sudo chmod 600 "$key_file"
    
    echo ""
    green "自签名证书生成完成！"
    echo "私钥位置: $key_file"
    echo "证书位置: $crt_file"
    
    back2menu
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                   ${RED}证书申请 OR 自签证书${PLAIN}                  #"
    echo -e "#             ${GREEN}運命石之扉の選択,El Psy Kongroo${PLAIN}             #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN}  安裝 Acme.sh 域名證書申請腳本"
    echo -e " ${GREEN}2.${PLAIN} ${RED} 卸載 Acme.sh 域名證書申請腳本${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN}  申請單域名證書 ${YELLOW}(80 端口申請)${PLAIN}"
    echo -e " ${GREEN}4.${PLAIN}  申請單域名證書 ${YELLOW}(CF API 申請)${PLAIN} ${GREEN}(無需解析)${PLAIN}"
    echo -e " ${GREEN}5.${PLAIN}  申請泛域名證書 ${YELLOW}(CF API 申請)${PLAIN} ${GREEN}(無需解析)${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}6.${PLAIN}  查看已申請的證書"
    echo -e " ${GREEN}7.${PLAIN}  撤銷並刪除已申請的證書"
    echo -e " ${GREEN}8.${PLAIN}  手動續期已申請的證書"
    echo -e " ${GREEN}9.${PLAIN}  切換證書頒發機構"
    echo -e " ${GREEN}10.${PLAIN} 生成自簽名證書"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN}  退出腳本"
    echo ""
    read -rp "請輸入選項 [0-10]: " menuInput
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
