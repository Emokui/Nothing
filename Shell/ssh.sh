#!/bin/bash

set -euo pipefail

# ====== 必须以 root 权限运行 ======
if [[ $EUID -ne 0 ]]; then
  echo -e "\033[31m请用 root 用户运行本脚本\033[0m"
  exit 1
fi

# ====== 颜色变量统一管理 ======
declare -A COLOR
COLOR[gray]='\033[37m'
COLOR[red]='\033[31m'
COLOR[green]='\033[32m'
COLOR[yellow]='\033[33m'
COLOR[blue]='\033[34m'
COLOR[white]='\033[97m'
COLOR[reset]='\033[0m'
COLOR[purple]='\033[35m'
COLOR[lightcyan]='\033[96m'
COLOR[cyan]='\033[36m'
COLOR[bold]='\033[1m'

gl_hui=${COLOR[gray]}
gl_hong=${COLOR[red]}
gl_lv=${COLOR[green]}
gl_huang=${COLOR[yellow]}
gl_lan=${COLOR[blue]}
gl_bai=${COLOR[white]}
gl_zi=${COLOR[purple]}
gl_kjlan=${COLOR[lightcyan]}
gl_rst=${COLOR[reset]}

press_any_key_to_continue() {
    if [ -t 0 ]; then
        local msg="${1:-按任意键返回菜单...}"
        read -n 1 -s -r -p "$msg"
        echo
    else
        echo
    fi
}

send_stats() {
    local action="$1"
    echo -e "${gl_hui}执行选项: $action${gl_bai}" >&2
}

linux_update() {
    send_stats "系统更新"
    echo -e "${gl_huang}正在更新系统...${gl_bai}"
    if command -v apt &>/dev/null; then
        apt update && apt upgrade -y
    elif command -v dnf &>/dev/null; then
        dnf upgrade --refresh -y
    elif command -v yum &>/dev/null; then
        yum update -y
    elif command -v apk &>/dev/null; then
        apk update && apk upgrade
    elif command -v pacman &>/dev/null; then
        pacman -Syu --noconfirm
    elif command -v zypper &>/dev/null; then
        zypper refresh && zypper update -y
    else
        echo -e "${gl_hong}未知的包管理器!${gl_bai}"
        return 1
    fi
    echo -e "${gl_lv}系统更新完成${gl_bai}"
    press_any_key_to_continue
}

linux_clean() {
    send_stats "系统清理"
    echo -e "${gl_huang}正在清理系统垃圾...${gl_bai}"
    if command -v apt &>/dev/null; then
        apt autoremove -y && apt autoclean -y
    elif command -v dnf &>/dev/null; then
        dnf autoremove -y && dnf clean all
    elif command -v yum &>/dev/null; then
        yum autoremove -y && yum clean all
    elif command -v apk &>/dev/null; then
        apk cache clean
    elif command -v pacman &>/dev/null; then
        orphans=$(pacman -Qtdq 2>/dev/null || true)
        if [[ -n "$orphans" ]]; then
            pacman -Rns $orphans --noconfirm
        fi
    elif command -v zypper &>/dev/null; then
        zypper clean
    else
        echo -e "${gl_hong}未知的包管理器!${gl_bai}"
        return 1
    fi
    echo -e "${gl_lv}系统清理完成${gl_bai}"
    press_any_key_to_continue
}

enable_root_login() {
    send_stats "开启root登录并设置密码"

    # 设置 Root 密码
    echo "==== 设置 Root 密码 ===="
    passwd root
    echo "[✓] Root 密码已成功设置"

    # 修改 SSH 配置文件
    echo "==== 开启 Root 登录并启用密码登录 ===="
    if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
        echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    else
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    fi

    # 确保密码登录被启用
    if ! grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
        echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
    else
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    fi

    # 重启 SSH 服务以应用更改
    systemctl restart sshd
    echo "[✓] Root 登录和密码登录已启用，请尝试使用密码登录"
    press_any_key_to_continue
}
change_root_password() {
    send_stats "修改root密码"
    echo "==== 修改 root 密码 ===="
    passwd root
    press_any_key_to_continue
}

change_ssh_port() {
    send_stats "修改SSH端口"
    echo "==== 修改 SSH 端口 ===="
    read -rp "请输入新的 SSH 端口: " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )); then
        if ! grep -q '^Port' /etc/ssh/sshd_config; then
            echo "Port $new_port" >> /etc/ssh/sshd_config
        else
            sed -i "s/^#\?Port .*/Port $new_port/" /etc/ssh/sshd_config
        fi
        systemctl restart sshd
        echo "[✓] SSH 端口已修改为 $new_port"
    else
        echo "[!] 无效的端口格式"
    fi
    press_any_key_to_continue
}

change_timezone() {
    send_stats "更改时区"
    if ! command -v timedatectl >/dev/null; then
        echo -e "${gl_hong}未安装timedatectl，无法自动设置时区${gl_bai}"
        press_any_key_to_continue
        return
    fi
    while true; do
        clear
        echo -e "${gl_kjlan}========= 更改时区 =========${gl_bai}"
        echo -e "${gl_huang}当前时区: $(timedatectl | grep 'Time zone' | awk '{print $3}')${gl_bai}"
        zones=("Asia" "Europe" "America" "Africa" "Australia" "Etc")
        for i in "${!zones[@]}"; do
            echo -e "${gl_lv}$((i+1)).${gl_bai} ${zones[$i]}"
        done
        echo -e "${gl_huang}0.${gl_bai} 返回主菜单"
        read -rp "请选择大区(数字): " zone_choice
        zone_choice=$(echo "$zone_choice" | xargs)
        [[ "$zone_choice" == "0" ]] && return
        if ! [[ "$zone_choice" =~ ^[1-6]$ ]]; then
            echo -e "${gl_hong}无效选项，请重试${gl_bai}"; sleep 1; continue
        fi
        zone="${zones[$((zone_choice-1))]}"
        # 查询所有子时区
        mapfile -t options < <(timedatectl list-timezones | grep "^$zone/")
        while true; do
            clear
            echo -e "${gl_kjlan}========= $zone 的时区列表 =========${gl_bai}"
            for i in "${!options[@]}"; do
                printf "%2d. %s\n" $((i+1)) "${options[$i]}"
            done
            echo -e "${gl_huang}0.${gl_bai} 返回上级"
            read -rp "请选择时区(数字): " city_choice
            city_choice=$(echo "$city_choice" | xargs)
            [[ "$city_choice" == "0" ]] && break
            if ! [[ "$city_choice" =~ ^[0-9]+$ ]] || [ "$city_choice" -lt 1 ] || [ "$city_choice" -gt "${#options[@]}" ]; then
                echo -e "${gl_hong}无效选项，请重试${gl_bai}"; sleep 1; continue
            fi
            city="${options[$((city_choice-1))]}"
            echo -e "${gl_huang}正在设置时区为 $city...${gl_bai}"
            if timedatectl set-timezone "$city"; then
                echo -e "${gl_lv}时区已成功设为 $city${gl_bai}"
            else
                echo -e "${gl_hong}设置失败，请重试${gl_bai}"
            fi
            press_any_key_to_continue
            return
        done
    done
}

install_base_tools() {
    send_stats "安装wget unzip"
    if command -v apt &>/dev/null; then
        apt update && apt install -y wget unzip
    elif command -v dnf &>/dev/null; then
        dnf install -y wget unzip
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip
    elif command -v apk &>/dev/null; then
        apk add wget unzip
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm wget unzip
    elif command -v zypper &>/dev/null; then
        zypper --non-interactive install wget unzip
    else
        echo -e "[!] 无法识别的系统"
    fi
    press_any_key_to_continue
}

install_acme() {
    send_stats "配置Acme"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/acme.sh)
    set -e
    press_any_key_to_continue
}
install_snell() {
    send_stats "配置Snell"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/snell.sh)
    set -e
    press_any_key_to_continue
}
install_mihomo() {
    send_stats "配置Mihomo"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/mihomo.sh)
    set -e
    press_any_key_to_continue
}
install_trojan() {
    send_stats "配置Trojan"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/trojan.sh)
    set -e
    press_any_key_to_continue
}
install_hysteria() {
    send_stats "配置Hysteria"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/hysteria.sh)
    set -e
    press_any_key_to_continue
}
install_substore() {
    send_stats "配置SubStore"
    set +e
    bash <(curl -fsSL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/substore.sh)
    set -e
    press_any_key_to_continue
}
install_install() {
    send_stats "一键DDSystem"
    set +e
    bash <(curl -sL https://csnm.pages.dev/chiakge/installNET/master/Install.sh)
    set -e
    press_any_key_to_continue
}
install_debian12() {
    send_stats "一键Debian12"
    set +e
    bash <(curl -sL https://csnm.pages.dev/bin456789/reinstall/main/reinstall.sh) debian 12
    set -e
    press_any_key_to_continue
}
install_nginx() {
    send_stats "反代Nginx"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/nginx.sh)
    set -e
    press_any_key_to_continue
}
install_snell-pro() {
    send_stats "超级Snell"
    set +e
    bash <(curl -sL https://csnm.pages.dev/Emokui/Nothing/Zero/Shell/snell-pro.sh)
    set -e
    press_any_key_to_continue
}
bbr_menu() {
    send_stats "管理BBR"
    set +e
    bash <(wget -O - https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh)
    set -e
    press_any_key_to_continue
}
warp_menu() {
    send_stats "管理WARP"
    set +e
    bash <(curl -sL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh)
    set -e
    press_any_key_to_continue
}
reboot_vps() {
    send_stats "重启VPS"
    echo "即将重启系统..."
    reboot
}

# ====== 防火墙配置 ======
configure_firewall() {
    echo -e "${COLOR[blue]}[*] 检查 iptables 是否安装...${COLOR[reset]}"
    if ! command -v iptables &>/dev/null; then
        echo -e "${COLOR[yellow]}[!] 未检测到 iptables，开始安装...${COLOR[reset]}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y iptables iptables-persistent
        elif command -v dnf &>/dev/null; then
            dnf install -y iptables-services
            systemctl enable iptables
            systemctl start iptables
        elif command -v yum &>/dev/null; then
            yum install -y iptables-services
            systemctl enable iptables
            systemctl start iptables
        elif command -v zypper &>/dev/null; then
            zypper --non-interactive install iptables
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm iptables
        elif command -v apk &>/dev/null; then
            apk add iptables
        else
            echo -e "${COLOR[red]}[!] 无法安装 iptables，请手动安装。${COLOR[reset]}"
            press_any_key_to_continue
            return 1
        fi
        echo -e "${COLOR[green]}[✓] iptables 已安装${COLOR[reset]}"
    else
        echo -e "${COLOR[green]}[✓] iptables 已存在${COLOR[reset]}"
    fi

    while true; do
        clear
        echo -e "${COLOR[bold]}${COLOR[cyan]}========= iptables 防火墙管理 =========${COLOR[reset]}"
        echo -e "${COLOR[green]}1. 开启端口${COLOR[reset]}"
        echo -e "${COLOR[red]}2. 关闭端口${COLOR[reset]}"
        echo -e "${COLOR[green]}3. 开启全部端口${COLOR[reset]}"
        echo -e "${COLOR[red]}4. 关闭全部端口(保留SSH)${COLOR[reset]}"
        echo -e "${COLOR[blue]}5. 显示已开启的端口${COLOR[reset]}"
        echo -e "${COLOR[yellow]}0. 返回主菜单${COLOR[reset]}"
        echo -e "${COLOR[bold]}${COLOR[cyan]}======================================${COLOR[reset]}"
        read -rp "请输入选项(0-5): " action_choice
        action_choice=$(echo "$action_choice" | xargs)
        [[ "$action_choice" == "0" ]] && return
        case "$action_choice" in
            1|2)
                read -rp "请输入端口（如 22 443 或 1000-2000）: " ports
                for port in $ports; do
                    if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start_port=${BASH_REMATCH[1]}
                        end_port=${BASH_REMATCH[2]}
                        # 先删除旧规则（tcp/udp）
                        iptables -D INPUT -p tcp --dport $start_port:$end_port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p tcp --dport $start_port:$end_port -j DROP 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $start_port:$end_port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $start_port:$end_port -j DROP 2>/dev/null || true
                        if [[ "$action_choice" == "1" ]]; then
                            iptables -A INPUT -p tcp --dport $start_port:$end_port -j ACCEPT
                            iptables -A INPUT -p udp --dport $start_port:$end_port -j ACCEPT
                            echo -e "${COLOR[green]}[✓] 端口范围 $port 已开启${COLOR[reset]}"
                        else
                            [[ "$start_port" -le 22 && "$end_port" -ge 22 ]] && { echo -e "${COLOR[yellow]}[!] 警告: 不允许关闭 SSH 端口 (22)，已跳过。${COLOR[reset]}"; continue; }
                            iptables -A INPUT -p tcp --dport $start_port:$end_port -j DROP
                            iptables -A INPUT -p udp --dport $start_port:$end_port -j DROP
                            echo -e "${COLOR[red]}[✓] 端口范围 $port 已关闭${COLOR[reset]}"
                        fi
                    else
                        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
                            echo -e "${COLOR[red]}[!] 无效端口: $port${COLOR[reset]}"
                            continue
                        fi
                        if [[ "$port" == "22" && "$action_choice" == "2" ]]; then
                            echo -e "${COLOR[yellow]}[!] 警告: 不允许关闭 SSH 端口 (22)，跳过${COLOR[reset]}"
                            continue
                        fi
                        # 先删除旧规则（tcp/udp）
                        iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null || true
                        if [[ "$action_choice" == "1" ]]; then
                            iptables -A INPUT -p tcp --dport $port -j ACCEPT
                            iptables -A INPUT -p udp --dport $port -j ACCEPT
                            echo -e "${COLOR[green]}[✓] 端口 $port 已开启${COLOR[reset]}"
                        else
                            iptables -A INPUT -p tcp --dport $port -j DROP
                            iptables -A INPUT -p udp --dport $port -j DROP
                            echo -e "${COLOR[red]}[✓] 端口 $port 已关闭${COLOR[reset]}"
                        fi
                    fi
                done
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save
                elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                    service iptables save
                fi
                if [[ "$action_choice" == "1" ]]; then
                    echo -e "${COLOR[green]}[✓] 所有指定端口已开启完成${COLOR[reset]}"
                else
                    echo -e "${COLOR[red]}[✓] 所有指定端口已关闭完成${COLOR[reset]}"
                fi
                press_any_key_to_continue
                ;;
            3)
                iptables -F
                iptables -P INPUT ACCEPT
                iptables -P FORWARD ACCEPT
                iptables -P OUTPUT ACCEPT
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save
                elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                    service iptables save
                fi
                echo -e "${COLOR[green]}[✓] 所有端口已开启${COLOR[reset]}"
                press_any_key_to_continue
                ;;
            4)
                iptables -F
                iptables -P INPUT DROP
                iptables -P FORWARD DROP
                iptables -P OUTPUT ACCEPT
                iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                iptables -A INPUT -i lo -j ACCEPT
                iptables -A INPUT -p tcp --dport 22 -j ACCEPT
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save
                elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                    service iptables save
                fi
                echo -e "${COLOR[red]}[✓] 所有端口已关闭 (SSH 端口除外)${COLOR[reset]}"
                press_any_key_to_continue
                ;;
            5)
                iptables_output=$(iptables -L INPUT -n -v)
                echo -e "${COLOR[blue]}$iptables_output${COLOR[reset]}"
                press_any_key_to_continue
                ;;
            *)
                echo -e "${COLOR[red]}[!] 无效选项，请重新选择${COLOR[reset]}"
                sleep 1
                ;;
        esac
    done
}

# ====== DNS配置 ======
detect_network_manager() {
    if command -v systemctl > /dev/null && systemctl is-active --quiet systemd-resolved; then
        echo "systemd-resolved"
    elif command -v nmcli > /dev/null; then
        echo "NetworkManager"
    elif [ -d "/etc/netplan" ]; then
        echo "netplan"
    else
        echo "traditional"
    fi
}

show_current_dns() {
    echo -e "${gl_huang}当前DNS配置:${gl_bai}"
    echo "================="
    grep "nameserver" /etc/resolv.conf || echo "未找到DNS配置"
    echo "================="
    network_manager=$(detect_network_manager)
    case $network_manager in
        "NetworkManager")
            echo -e "${gl_huang}NetworkManager配置:${gl_bai}"
            nmcli dev show | grep DNS || echo "未找到NetworkManager DNS配置"
            ;;
        "systemd-resolved")
            echo -e "${gl_huang}systemd-resolved配置:${gl_bai}"
            resolvectl status | grep "DNS Servers" || echo "未找到systemd-resolved DNS配置"
            ;;
    esac
}

persistent_set_dns() {
    local primary_dns=$1
    local secondary_dns=$2
    network_manager=$(detect_network_manager)
    case $network_manager in
        "NetworkManager")
            CONNECTION=$(nmcli -t -f NAME c show --active | head -n1)
            if [ -z "$CONNECTION" ]; then
                echo -e "${gl_hong}错误: 未找到活动的网络连接${gl_bai}"
                return 1
            fi
            if [ -z "$secondary_dns" ]; then
                nmcli con mod "$CONNECTION" ipv4.dns "$primary_dns"
            else
                nmcli con mod "$CONNECTION" ipv4.dns "$primary_dns,$secondary_dns"
            fi
            nmcli con mod "$CONNECTION" ipv4.ignore-auto-dns yes
            nmcli con up "$CONNECTION"
            ;;
        "systemd-resolved")
            INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
            if [ -z "$INTERFACE" ]; then
                echo -e "${gl_hong}错误: 未找到默认网络接口${gl_bai}"
                return 1
            fi
            if [ -z "$secondary_dns" ]; then
                resolvectl dns "$INTERFACE" "$primary_dns"
            else
                resolvectl dns "$INTERFACE" "$primary_dns" "$secondary_dns"
            fi
            ;;
        "netplan")
            NETPLAN_FILE=$(find /etc/netplan -name "*.yaml" | head -n1)
            if [ -z "$NETPLAN_FILE" ]; then
                echo -e "${gl_hong}错误: 未找到netplan配置文件${gl_bai}"
                return 1
            fi
            cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
            addresses="['$primary_dns'"
            [ -n "$secondary_dns" ] && addresses+=", '$secondary_dns'"
            addresses+="]"
            if grep -q "nameservers:" "$NETPLAN_FILE"; then
                sed -i "/nameservers:/,/addresses:/c\      nameservers:\n        addresses: $addresses" "$NETPLAN_FILE"
            else
                sed -i "/dhcp4: true/a\      nameservers:\n        addresses: $addresses" "$NETPLAN_FILE"
            fi
            netplan apply
            ;;
        *)
            cp /etc/resolv.conf /etc/resolv.conf.bak
            chattr -i /etc/resolv.conf 2>/dev/null || true
            echo "nameserver $primary_dns" > /etc/resolv.conf
            [ -n "$secondary_dns" ] && echo "nameserver $secondary_dns" >> /etc/resolv.conf
            chattr +i /etc/resolv.conf 2>/dev/null || true
            ;;
    esac
    echo -e "${gl_lv}DNS设置已更新并已持久化${gl_bai}"
}

set_predefined_dns() {
    echo -e "${gl_huang}正在设置DNS为 8.8.8.8 和 1.1.1.1...${gl_bai}"
    persistent_set_dns "8.8.8.8" "1.1.1.1"
}

set_manual_dns() {
    echo -e "${gl_huang}请输入主要DNS服务器:${gl_bai}"
    read primary_dns
    echo -e "${gl_huang}请输入次要DNS服务器(可选，直接按回车跳过):${gl_bai}"
    read secondary_dns
    if [ -z "$primary_dns" ]; then
        echo -e "${gl_hong}错误: 主要DNS服务器不能为空${gl_bai}"
        return
    fi
    persistent_set_dns "$primary_dns" "$secondary_dns"
}

dns_config_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}DNS配置工具${gl_bai}"
        echo "================="
        show_current_dns
        echo -e "${gl_huang}请选择操作:${gl_bai}"
        echo "1. 修改DNS为8.8.8.8和1.1.1.1"
        echo "2. 手动修改DNS"
        echo -e "0. 返回主菜单"
        read -rp "请选择操作: " option
        option=$(echo "$option" | xargs)
        case "$option" in
            1) set_predefined_dns;;
            2) set_manual_dns;;
            0) return;;
            *) echo -e "${gl_hong}无效选项，请重试${gl_bai}"; sleep 1;;
        esac
        press_any_key_to_continue "按任意键继续..."
    done
}

main_menu() {
    while true; do
        clear
        echo
        echo -e "${gl_kjlan}==== Steins Gate - 凤凰院凶真 Ver.1.0 ==== ${gl_bai}"
        echo -e "${gl_lv}01.${gl_bai} 系统更新"
        echo -e "${gl_lv}02.${gl_bai} 系统清理"
        echo -e "${gl_lv}03.${gl_bai} 开启root 登录"
        echo -e "${gl_lv}04.${gl_bai} 修改root 密码"
        echo -e "${gl_lv}05.${gl_bai} 修改SSH 端口"
        echo -e "${gl_lv}06.${gl_bai} 更改时区"
        echo -e "${gl_lv}07.${gl_bai} 设置防火墙"
        echo -e "${gl_lv}08.${gl_bai} 配置 DNS"
        echo -e "${gl_lv}09.${gl_bai} 管理 BBR"
        echo -e "${gl_lv}10.${gl_bai} 管理 WARP"
        echo -e "${gl_lv}11.${gl_bai} 重启 VPS"
        echo -e "${gl_lv}12.${gl_bai} 安装 wget/unzip"
        echo -e "${gl_lv}13.${gl_bai} 配置 Acme"
        echo -e "${gl_lv}14.${gl_bai} 配置 Snell"
        echo -e "${gl_lv}15.${gl_bai} 超级 Snell"
        echo -e "${gl_lv}16.${gl_bai} 配置 Mihomo"
        echo -e "${gl_lv}17.${gl_bai} 配置 Trojan"
        echo -e "${gl_lv}18.${gl_bai} 配置 Hysteria"
        echo -e "${gl_lv}19.${gl_bai} 配置 SubStore"
        echo -e "${gl_lv}20.${gl_bai} 一键 DDSystem"
        echo -e "${gl_lv}21.${gl_bai} 一键 Debian12"
        echo -e "${gl_lv}22.${gl_bai} 反代 Nginx"
        echo -e "${gl_lv} 0.${gl_bai} 离开 El Psy Kongroo"
        read -rp "请选择操作: " choice
        choice=$(echo "$choice" | xargs)
        case "$choice" in
            1) linux_update;;
            2) linux_clean;;
            3) enable_root_login;;
            4) change_root_password;;
            5) change_ssh_port;;
            6) change_timezone;;
            7) configure_firewall;;
            8) dns_config_menu;;
            9) bbr_menu;;
            10) warp_menu;;
            11) echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps;;
            12) install_base_tools;;
            13) install_acme;;
            14) install_snell;;
            15) install_snell-pro;;
            16) install_mihomo;;
            17) install_trojan;;
            18) install_hysteria;;
            19) install_substore;;
            20) install_install;;
            21) install_debian12;;
            22) install_nginx;;
            0) clear; echo -e "${gl_zi}「运命石之扉の选择,El Psy Kongroo」${gl_bai}"; sleep 1; clear; break;;
            *) clear; echo -e "${gl_hong}[!] 无效选项，请重新选择${gl_bai}"; sleep 2;;
        esac
    done
}

main_menu
