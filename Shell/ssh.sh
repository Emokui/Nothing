#!/bin/bash

set -euo pipefail

# ====== 必须以 root 权限运行 ======
if [[ $EUID -ne 0 ]]; then
  echo -e "\033[31m请用 root 用户运行本脚本\033[0m"
  exit 1
fi

# ====== 颜色变量统一管理 ======
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PURPLE='\033[35m'
CYAN='\033[36m'
WHITE='\033[97m'
RESET='\033[0m'
BOLD='\033[1m'
LIGHTCYAN='\033[96m'
GRAY='\033[37m'

# ====== 通用工具函数 ======
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
    echo -e "${GRAY}执行选项: $action${WHITE}" >&2
}

# ====== 系统管理功能 ======
is_gcp_instance() {
    org=$(curl -s --max-time 3 https://ipinfo.io/org)
    if [[ -z "$org" ]]; then
        return 1
    fi
    grep -qi 'Google' <<< "$org"
}

linux_update() {
    send_stats "系统更新"
    echo -e "${YELLOW}正在更新系统...${WHITE}"

    if is_gcp_instance; then
        echo -e "${BLUE}检测为GCP实例,跳过更新。${WHITE}"
        read -n 1 -s -r -p "按任意键继续..."
        echo ""
        return 0
    fi

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
        echo -e "${RED}未知的包管理器!${WHITE}"
        return 1
    fi

    echo -e "${GREEN}系统更新完成${WHITE}"
    press_any_key_to_continue
}

linux_clean() {
    send_stats "系统清理"
    echo -e "${YELLOW}正在清理系统垃圾...${WHITE}"

    # ------ 权限检查 ------
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请以root权限运行本脚本以获得最佳清理效果！${WHITE}"
        return 1
    fi

    # ------ 包管理器缓存清理 ------
    if command -v apt &>/dev/null; then
        apt autoremove -y && apt autoclean -y && apt clean
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
        pacman -Scc --noconfirm
    elif command -v zypper &>/dev/null; then
        zypper clean --all
    elif command -v emerge &>/dev/null; then
        emerge --depclean && eclean-dist --deep
    else
        echo -e "${RED}未知的包管理器!${WHITE}"
    fi

    # ------ 清理Docker垃圾 ------
    if command -v docker &>/dev/null; then
        echo -e "${YELLOW}清理Docker垃圾...${WHITE}"
        docker system prune -af
        docker volume prune -f
    fi

    # ------ 清理系统日志（保留3天） ------
    echo -e "${YELLOW}正在清理系统日志...${WHITE}"
    if command -v journalctl &>/dev/null; then
        journalctl --vacuum-time=3d --vacuum-size=100M
    fi
    find /var/log -type f -name "*.log" -mtime +3 -exec rm -f {} \;
    find /var/log -type f -name "*.gz" -mtime +3 -exec rm -f {} \;
    find /var/log -type f -name "*.1" -mtime +3 -exec rm -f {} \;

    # ------ 清理临时目录 ------
    echo -e "${YELLOW}正在清理临时目录...${WHITE}"
    rm -rf /tmp/* /var/tmp/*

    # ------ 清理用户缓存 ------
    echo -e "${YELLOW}正在清理用户缓存...${WHITE}"
    if [ -d "$HOME/.cache" ]; then
        rm -rf "$HOME/.cache/"*
    fi
    #------ 清理非root用户缓存 ------
    for uhome in /home/*; do
        [ -d "$uhome/.cache" ] && rm -rf "$uhome/.cache/"*
    done

    echo -e "${GREEN}系统清理完成${WHITE}"
    press_any_key_to_continue
}

# ====== 虚拟内存（Swap）管理 ======
swapfile_path="/swapfile"

set_swap_menu() {
    while true; do
        clear
        # 获取当前 Swap 总大小（MB）
        current_swap=$(free -m | awk '/Swap:/ {print $2}')
        swap_info="无"
        if (( current_swap > 0 )); then
            swap_info="${current_swap} MB"
        fi
        echo -e "${LIGHTCYAN}========= 虚拟内存(Swap)管理 =========${WHITE}"
        echo -e "${YELLOW}当前虚拟内存（Swap）大小：$swap_info${WHITE}"
        echo
        echo -e "${GREEN}1.${WHITE} 设置为 1024 MB (1GB)"
        echo -e "${GREEN}2.${WHITE} 设置为 2048 MB (2GB)"
        echo -e "${GREEN}3.${WHITE} 手动输入 Swap 大小"
        echo -e "${YELLOW}0.${WHITE} 返回主菜单"
        echo
        read -rp "请输入选项 [0-3]: " opt
        opt=$(echo "$opt" | xargs)
        case "$opt" in
            1)
                set_swap 1024
                ;;
            2)
                set_swap 2048
                ;;
            3)
                read -rp "请输入你想要的 Swap 大小 (单位 MB): " custom
                if [[ "$custom" =~ ^[0-9]+$ ]] && (( custom >= 128 )); then
                    set_swap "$custom"
                else
                    echo -e "${RED}输入无效，请输入大于等于128的数字。${WHITE}"
                    press_any_key_to_continue
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重试。${WHITE}"
                press_any_key_to_continue
                ;;
        esac
    done
}

set_swap() {
    size_mb="$1"

    send_stats "设置Swap为 ${size_mb} MB"

    sudo swapoff "$swapfile_path" 2>/dev/null || true
    sudo rm -f "$swapfile_path"

    echo -e "${YELLOW}正在创建 ${size_mb}MB 的 Swap 文件...${WHITE}"
    if ! sudo fallocate -l "${size_mb}M" "$swapfile_path" 2>/dev/null; then
        sudo dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress
    fi

    sudo chmod 600 "$swapfile_path"
    sudo mkswap "$swapfile_path"
    sudo swapon "$swapfile_path"

    sudo sed -i '/^\/swapfile/d' /etc/fstab
    echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null

    echo
    echo -e "${GREEN}Swap 设置完成，当前情况：${WHITE}"
    free -h
    swapon --show
    press_any_key_to_continue
}

# ====== SSH 管理 ======
enable_root_login() {
    send_stats "开启root登录并设置密码"

    echo "==== 设置 Root 密码 ===="
    passwd root
    echo "[✓] Root 密码已成功设置"

    echo "==== 开启 Root 登录并启用密码登录 ===="
    if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
        echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    else
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    fi

    if ! grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
        echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
    else
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    fi

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


# ====== 时区管理 ======
change_timezone() {
    send_stats "更改时区"
    if ! command -v timedatectl >/dev/null; then
        echo -e "${RED}未安装timedatectl，无法自动设置时区${WHITE}"
        echo -e "${YELLOW}请手动安装 systemd 相关组件。常用安装命令如下：${WHITE}"
        if [ -f /etc/debian_version ]; then
            echo -e "  sudo apt update && sudo apt install systemd"
        elif [ -f /etc/redhat-release ]; then
            echo -e "  sudo yum install systemd"
        else
            echo -e "  请根据你的系统类型安装 systemd"
        fi
        press_any_key_to_continue
        return
    fi

    ipinfo=$(curl -s ipinfo.io)
    current_tz=$(echo "$ipinfo" | grep -oP '"timezone":\s*"\K[^"]+"')
    current_tz=${current_tz//\"/}

    while true; do
        clear
        echo -e "${LIGHTCYAN}✦ 更改时区 ✦${WHITE}"
        echo -e "${YELLOW}当前系统时间: $(date)${WHITE}"
        echo -e "${YELLOW}当前时区: $(timedatectl | grep 'Time zone' | awk '{print $3}')${WHITE}"
        echo -e "${GREEN}1.${WHITE} 推荐时区 (${YELLOW}$current_tz${WHITE})"
        echo -e "${GREEN}2.${WHITE} 按国家代码选择"
        echo -e "${YELLOW}0.${WHITE} 返回主菜单"
        read -rp "请选择: " choice
        choice=$(echo "$choice" | xargs)
        case "$choice" in
            1)
                if [ -n "$current_tz" ]; then
                    echo -e "${YELLOW}正在设置时区为 $current_tz...${WHITE}"
                    if output=$(timedatectl set-timezone "$current_tz" 2>&1); then
                        echo -e "${GREEN}时区已成功设为 $current_tz，当前时间: $(date)${WHITE}"
                    else
                        echo -e "${RED}设置失败，详细信息如下：${WHITE}"
                        echo "$output"
                    fi
                else
                    echo -e "${RED}未检测到推荐时区！${WHITE}"
                fi
                press_any_key_to_continue
                continue
                ;;
            2)
                read -rp "请输入国家代码（如 CN、JP、US）: " input_code
                input_code=$(echo "$input_code" | tr a-z A-Z | xargs)
                if [ -z "$input_code" ]; then
                    echo -e "${RED}输入不能为空${WHITE}"
                    sleep 1
                    continue
                fi

                if [ ! -f /usr/share/zoneinfo/zone.tab ]; then
                    echo -e "${RED}未找到 zone.tab，无法匹配国家代码到时区${WHITE}"
                    sleep 1
                    continue
                fi
                mapfile -t lines < <(grep -E "^$input_code\s" /usr/share/zoneinfo/zone.tab | awk '{print $3}' | sort)
                if [ "${#lines[@]}" -eq 0 ]; then
                    echo -e "${RED}未找到该国家代码对应的时区${WHITE}"
                    sleep 1
                    continue
                fi
                echo -e "${LIGHTCYAN}========= 可选时区 =========${WHITE}"
                for i in "${!lines[@]}"; do
                    echo -e "${GREEN}$((i+1)).${WHITE} ${LIGHTCYAN}${lines[$i]}${WHITE}"
                done
                read -rp "请选择时区编号: " tz_choice
                tz_choice=$(echo "$tz_choice" | xargs)
                if ! [[ "$tz_choice" =~ ^[0-9]+$ ]] || [ "$tz_choice" -lt 1 ] || [ "$tz_choice" -gt "${#lines[@]}" ]; then
                    echo -e "${RED}无效选项${WHITE}"
                    sleep 1
                    continue
                fi
                sel_tz="${lines[$((tz_choice-1))]}"
                echo -e "${YELLOW}正在设置时区为 $sel_tz...${WHITE}"
                if timedatectl set-timezone "$sel_tz" 2>err.log; then
                    echo -e "${GREEN}时区已成功设为 $sel_tz，当前时间: $(date)${WHITE}"
                else
                    echo -e "${RED}设置失败，详细信息如下：${WHITE}"
                    cat err.log
                fi
                press_any_key_to_continue
                continue
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重试${WHITE}"
                sleep 1
                ;;
        esac
    done
}


# ====== 基础工具安装 ======
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


# ====== 第三方工具/服务安装 ======
run_install_script() {
    set +e
    bash <(curl -sL "$1")
    set -e
    press_any_key_to_continue
}

install_acme()      { send_stats "配置Acme";      run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/acme.sh"; }
install_snell()     { send_stats "配置Snell";     run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/snell.sh"; }
install_mihomo()    { send_stats "配置Mihomo";    run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/mihomo.sh"; }
install_trojan()    { send_stats "配置Trojan";    run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/trojan.sh"; }
install_hysteria()  { send_stats "配置Hysteria";  run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/hysteria.sh"; }
install_substore()  { send_stats "配置SubStore";  run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/substore.sh"; }
install_install()   { send_stats "一键DDSystem";  run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/Install.sh"; }
install_nginx()     { send_stats "反代Nginx";     run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/nginx.sh"; }
install_snell-pro() { send_stats "超级Snell";     run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/snell-pro.sh"; }
bbr_menu()          { send_stats "管理BBR";       run_install_script "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh"; }
warp_menu()         { send_stats "管理WARP";      run_install_script "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"; }
install_wireguard() { send_stats "提取WireGuard"; run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/wireguard.sh"; }

# ====== VPS 重启 ======
reboot_vps() {
    send_stats "重启VPS"
    echo "即将重启系统..."
    reboot
}

# ====== 防火墙配置 ======
configure_firewall() {
    echo -e "${BLUE}[*] 检查 iptables 是否安装...${RESET}"
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}[!] 未检测到 iptables，开始安装...${RESET}"
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
            echo -e "${RED}[!] 无法安装 iptables，请手动安装。${RESET}"
            press_any_key_to_continue
            return 1
        fi
        echo -e "${GREEN}[✓] iptables 已安装${RESET}"
    else
        echo -e "${GREEN}[✓] iptables 已存在${RESET}"
    fi

    while true; do
        clear
        echo -e "${BOLD}${CYAN}========= iptables 防火墙管理 =========${RESET}"
        echo -e "${GREEN}1. 开启端口${RESET}"
        echo -e "${RED}2. 关闭端口${RESET}"
        echo -e "${GREEN}3. 开启全部端口${RESET}"
        echo -e "${RED}4. 关闭全部端口(保留SSH)${RESET}"
        echo -e "${BLUE}5. 显示已开启的端口${RESET}"
        echo -e "${YELLOW}0. 返回主菜单${RESET}"
        echo -e "${BOLD}${CYAN}======================================${RESET}"
        read -rp "请输入选项(0-5): " action_choice
        action_choice=$(echo "$action_choice" | xargs)
        [[ "$action_choice" == "0" ]] && return
        case "$action_choice" in
            1|2)
                read -rp "请输入端口（如 443 或 1000-2000）: " ports
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
                            echo -e "${GREEN}[✓] 端口范围 $port 已开启${RESET}"
                        else
                            [[ "$start_port" -le 22 && "$end_port" -ge 22 ]] && { echo -e "${YELLOW}[!] 警告: 不允许关闭 SSH 端口 (22)${RESET}"; continue; }
                            iptables -A INPUT -p tcp --dport $start_port:$end_port -j DROP
                            iptables -A INPUT -p udp --dport $start_port:$end_port -j DROP
                            echo -e "${RED}[✓] 端口范围 $port 已关闭${RESET}"
                        fi
                    else
                        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
                            echo -e "${RED}[!] 无效端口: $port${RESET}"
                            continue
                        fi
                        if [[ "$port" == "22" && "$action_choice" == "2" ]]; then
                            echo -e "${YELLOW}[!] 警告: 不允许关闭 SSH 端口 (22)${RESET}"
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
                            echo -e "${GREEN}[✓] 端口 $port 已开启${RESET}"
                        else
                            iptables -A INPUT -p tcp --dport $port -j DROP
                            iptables -A INPUT -p udp --dport $port -j DROP
                            echo -e "${RED}[✓] 端口 $port 已关闭${RESET}"
                        fi
                    fi
                done
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save
                elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                    service iptables save
                fi
                if [[ "$action_choice" == "1" ]]; then
                    echo -e "${GREEN}[✓] 所有指定端口已开启完成${RESET}"
                else
                    echo -e "${RED}[✓] 所有指定端口已关闭完成${RESET}"
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
                echo -e "${GREEN}[✓] 所有端口已开启${RESET}"
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
                echo -e "${RED}[✓] 所有端口已关闭 (22端口除外)${RESET}"
                press_any_key_to_continue
                ;;
            5)
                iptables_output=$(iptables -L INPUT -n -v)
                echo -e "${BLUE}$iptables_output${RESET}"
                press_any_key_to_continue
                ;;
            *)
                echo -e "${RED}[!] 无效选项，请重新选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ====== 安全修改 /etc/resolv.conf 工具函数 ======
safe_update_resolv_conf() {
    local primary_dns="$1"
    local secondary_dns="$2"
    # 解锁
    chattr -i /etc/resolv.conf 2>/dev/null
    # 写入DNS
    {
        echo "nameserver $primary_dns"
        [ -n "$secondary_dns" ] && echo "nameserver $secondary_dns"
    } > /etc/resolv.conf
    # 上锁
    chattr +i /etc/resolv.conf 2>/dev/null
}

# ====== DNS 配置 ======
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
    echo -e "${YELLOW}当前DNS配置:${WHITE}"
    echo "================="
    grep "nameserver" /etc/resolv.conf || echo "未找到DNS配置"
    echo "================="
    network_manager=$(detect_network_manager)
    case $network_manager in
        "NetworkManager")
            echo -e "${YELLOW}NetworkManager配置:${WHITE}"
            nmcli dev show | grep DNS || echo "未找到NetworkManager DNS配置"
            ;;
        "systemd-resolved")
            echo -e "${YELLOW}systemd-resolved配置:${WHITE}"
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
                echo -e "${RED}错误: 未找到活动的网络连接${WHITE}"
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
                echo -e "${RED}错误: 未找到默认网络接口${WHITE}"
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
                echo -e "${RED}错误: 未找到netplan配置文件${WHITE}"
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
            safe_update_resolv_conf "$primary_dns" "$secondary_dns"
            ;;
    esac
    echo -e "${GREEN}DNS设置已更新并已持久化${WHITE}"
}

set_predefined_dns() {
    echo -e "${YELLOW}正在设置DNS为 8.8.8.8 和 1.1.1.1...${WHITE}"
    persistent_set_dns "8.8.8.8" "1.1.1.1"
}

set_manual_dns() {
    echo -e "${YELLOW}请输入主要DNS服务器:${WHITE}"
    read primary_dns
    echo -e "${YELLOW}请输入次要DNS服务器(可选，直接按回车跳过):${WHITE}"
    read secondary_dns
    if [ -z "$primary_dns" ]; then
        echo -e "${RED}错误: 主要DNS服务器不能为空${WHITE}"
        return
    fi
    persistent_set_dns "$primary_dns" "$secondary_dns"
}

dns_config_menu() {
    while true; do
        clear
        echo -e "${LIGHTCYAN}DNS配置工具${WHITE}"
        echo "================="
        show_current_dns
        echo -e "${YELLOW}请选择操作:${WHITE}"
        echo "1. 修改DNS为8.8.8.8和1.1.1.1"
        echo "2. 手动修改DNS"
        echo -e "0. 返回主菜单"
        read -rp "请选择操作: " option
        option=$(echo "$option" | xargs)
        case "$option" in
            1) set_predefined_dns ;;
            2) set_manual_dns ;;
            0) return ;;
            *) echo -e "${RED}无效选项，请重试${WHITE}"; sleep 1 ;;
        esac
        press_any_key_to_continue "按任意键继续..."
    done
}

# ====== 主菜单 ======
main_menu() {
    while true; do
        clear
        echo -e "${LIGHTCYAN}✦ Steins Gate - Ver 2.1 ✦${WHITE}"
        echo -e "${GREEN}01.${WHITE} 系统更新"
        echo -e "${GREEN}02.${WHITE} 系统清理"
        echo -e "${GREEN}03.${WHITE} 设置时区"
        echo -e "${GREEN}04.${WHITE} 设置防火墙"
        echo -e "${GREEN}05.${WHITE} 设置虚拟内存"
        echo -e "${GREEN}06.${WHITE} 修改 SSH端口"
        echo -e "${GREEN}07.${WHITE} 开启 root登录"
        echo -e "${GREEN}08.${WHITE} 修改 root密码"
        echo -e "${GREEN}09.${WHITE} 重启 VPS"
        echo -e "${GREEN}10.${WHITE} 配置 DNS"
        echo -e "${GREEN}11.${WHITE} 管理 BBR"
        echo -e "${GREEN}12.${WHITE} 管理 WARP"
        echo -e "${GREEN}13.${WHITE} 安装 Wget"
        echo -e "${GREEN}14.${WHITE} 配置 Acme"
        echo -e "${GREEN}15.${WHITE} 反代 Nginx"
        echo -e "${GREEN}16.${WHITE} 配置 Snell"
        echo -e "${GREEN}17.${WHITE} 超级 Snell"
        echo -e "${GREEN}18.${WHITE} 配置 Mihomo"
        echo -e "${GREEN}19.${WHITE} 配置 Trojan"
        echo -e "${GREEN}20.${WHITE} 配置 Hysteria"
        echo -e "${GREEN}21.${WHITE} 配置 SubStore"
        echo -e "${GREEN}22.${WHITE} 一键 DDsystem"
        echo -e "${GREEN}23.${WHITE} 提取 WireGuard"
        echo -e "${GREEN} 0.${WHITE} 离开 El Psy Kongroo"
        read -rp "请选择操作: " choice
        choice=$(echo "$choice" | xargs)
        case "$choice" in
            1)  linux_update ;;
            2)  linux_clean ;;
            3)  change_timezone ;;
            4)  configure_firewall ;;
            5)  set_swap_menu ;;
            6)  change_ssh_port ;;
            7)  enable_root_login ;;
            8)  change_root_password ;;
            9)  echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps ;;
            10) dns_config_menu ;;
            11) bbr_menu ;;
            12) warp_menu ;; 
            13) install_base_tools ;;
            14) install_acme ;;
            15) install_nginx ;;
            16) install_snell ;;
            17) install_snell-pro ;;
            18) install_mihomo ;;
            19) install_trojan ;;
            20) install_hysteria ;;
            21) install_substore ;;
            22) install_install ;;
            23) install_wireguard ;;
            0)  clear; echo -e "${PURPLE}「运命石之扉の选择,El Psy Kongroo」${WHITE}"; sleep 1; clear; break ;;
            *)  clear; echo -e "${RED}[!] 无效选项，请重新选择${WHITE}"; sleep 2 ;;
        esac
    done
}

main_menu
