#!/bin/bash

set -euo pipefail

# ====== 颜色变量 ======
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
PLAIN="\033[0m"

# ====== Root权限 ======
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请用 root 用户运行本脚本${PLAIN}"
  exit 1
fi

# ====== 通用函数 ======
press_any_key_to_continue() {
    if [ -t 0 ]; then
        local msg="${1:-按任意键返回菜单...}"
        echo -ne "${GREEN}${msg}\033[0m"
        read -n 1 -s -r
        echo
    else
        echo
    fi
}

# ====== 安装wget ======
install_wget_if_missing() {
    if ! command -v wget &>/dev/null; then
        echo -e "${YELLOW}未检测到 wget，正在自动安装...${PLAIN}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y wget
        elif command -v dnf &>/dev/null; then
            dnf install -y wget
        elif command -v yum &>/dev/null; then
            yum install -y wget
        elif command -v apk &>/dev/null; then
            apk add wget
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm wget
        elif command -v zypper &>/dev/null; then
            zypper --non-interactive install wget
        else
            echo -e "${RED}无法识别的包管理器，wget 安装失败，请手动安装！${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}wget 安装完成${PLAIN}"
    fi
}

install_wget_if_missing

# ====== 系统管理 ======
is_gcp_instance() {
    org=$(curl -s --max-time 3 https://ipinfo.io/org)
    if [[ -z "$org" ]]; then
        return 1
    fi
    grep -qi 'Google' <<< "$org"
}

linux_update() {
    clear
    echo -e "${YELLOW}正在更新系统...${PLAIN}"

    if is_gcp_instance; then
        echo -e "${BLUE}检测为GCP实例,跳过更新。${PLAIN}"
        press_any_key_to_continue
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
        echo -e "${RED}未知的包管理器!${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}系统更新完成${PLAIN}"
    press_any_key_to_continue
}

linux_clean() {
    clear
    echo -e "${YELLOW}正在清理系统垃圾...${PLAIN}"

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
        echo -e "${RED}未知的包管理器!${PLAIN}"
    fi

    if command -v docker &>/dev/null; then
        echo -e "${YELLOW}清理Docker垃圾...${PLAIN}"
        docker system prune -af
        docker volume prune -f
    fi

    echo -e "${YELLOW}正在清理系统日志...${PLAIN}"
    if command -v journalctl &>/dev/null; then
        journalctl --vacuum-time=3d --vacuum-size=100M
    fi
    find /var/log -type f -name "*.log" -mtime +1 -exec rm -f {} \;
    find /var/log -type f -name "*.gz" -mtime +1 -exec rm -f {} \;
    find /var/log -type f -name "*.1" -mtime +1 -exec rm -f {} \;

    echo -e "${YELLOW}正在清理临时目录...${PLAIN}"
    rm -rf /tmp/* /var/tmp/*

    echo -e "${YELLOW}正在清理用户缓存...${PLAIN}"
    if [ -d "$HOME/.cache" ]; then
        rm -rf "$HOME/.cache/"*
    fi
    
    for uhome in /home/*; do
        [ -d "$uhome/.cache" ] && rm -rf "$uhome/.cache/"*
    done

    echo -e "${GREEN}系统清理完成${PLAIN}"
    press_any_key_to_continue
}

# ====== Swap管理 ======
swapfile_path="/swapfile"

set_swap_menu() {
    while true; do
        clear
        current_swap=$(free -m | awk '/Swap:/ {print $2}')
        swap_info="无"
        if (( current_swap > 0 )); then
            swap_info="${current_swap} MB"
        fi
        echo -e "${BLUE}===== 虚拟内存(Swap)管理 ====${PLAIN}"
        echo -e "${YELLOW} 当前 Swap 大小：$swap_info${PLAIN}"
        echo -e "${GREEN} 1.设置为 1024 MB ${PLAIN} "
        echo -e "${GREEN} 2.设置为 2048 MB ${PLAIN} "
        echo -e "${GREEN} 3.输入设置 Swap 大小${PLAIN} "
        echo -e "${YELLOW} 0.返回主菜单${PLAIN}"
        echo -e "${BLUE}=============================${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" opt
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
                    echo -e "${RED}输入无效，请输入大于等于128的数字。${PLAIN}"
                    press_any_key_to_continue
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重试。${PLAIN}"
                press_any_key_to_continue
                ;;
        esac
    done
}

set_swap() {
    local size_mb="$1"
    local avail_kb avail_mb

    if ! [[ "$size_mb" =~ ^[0-9]+$ ]] || (( size_mb < 128 )); then
        echo -e "${RED}无效的 Swap 大小（必须为大于等于128的整数）${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024))
    if (( avail_mb < size_mb )); then
        echo -e "${RED}磁盘空间不足，无法创建${size_mb} MB的swap文件！${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    sudo swapoff "$swapfile_path" 2>/dev/null || true
    sudo rm -f "$swapfile_path"

    echo -e "${YELLOW}正在创建 ${size_mb}MB 的 Swap 文件...${PLAIN}"
    if command -v fallocate >/dev/null 2>&1; then
        if ! sudo fallocate -l "${size_mb}M" "$swapfile_path" 2>/dev/null; then
            echo -e "${YELLOW}fallocate 失败，尝试使用 dd...${PLAIN}"
            sudo dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress
        fi
    else
        sudo dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress
    fi

    sudo chmod 600 "$swapfile_path"
    sudo mkswap "$swapfile_path"
    sudo swapon "$swapfile_path"

    sudo sed -i '\|^/swapfile |d' /etc/fstab
    echo "$swapfile_path none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null

    echo
    echo -e "${GREEN}Swap 设置完成，当前情况：${PLAIN}"
    free -h
    swapon --show
    press_any_key_to_continue
}

# ====== SSH管理 ======
ssh_config_menu() {
    while true; do
        clear
        echo -e "${BLUE}====== SSH配置 ======${PLAIN}"
        echo -e "${GREEN} 1.设置root密码${PLAIN}"
        echo -e "${GREEN} 2.设置root密钥${PLAIN}"
        echo -e "${GREEN} 3.修改登录端口${PLAIN}"
        echo -e "${GREEN} 4.关闭登录方式${PLAIN}"
        echo -e "${GREEN} 0.返回主菜单${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入选项 [0-4]: ${PLAIN}")" ssh_choice
        ssh_choice=$(echo "$ssh_choice" | xargs)
        case "$ssh_choice" in
            1) enable_or_change_root_password ;;
            2) enable_root_key_login ;;
            3) change_ssh_port ;;
            4) disable_ssh_login_menu ;;
            0) return ;;
            *) echo -e "${RED}无效选项，请重试${PLAIN}"; sleep 0.3 ;;
        esac
    done
}

change_ssh_port() {
    while true; do
        clear
        read -rp "$(echo -e "${BLUE}请输入新的SSH端口(输入0返回): ${PLAIN}")" new_port
        new_port=$(echo "$new_port" | xargs)
        if [[ "$new_port" == "0" ]]; then
            return
        fi
        if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )); then
            sed -i '/^[#[:space:]]*Port[[:space:]]\+[0-9]\+/Id' /etc/ssh/sshd_config
            echo "Port $new_port" >> /etc/ssh/sshd_config
            if ! sshd -t 2>/dev/null; then
                echo -e "${RED}sshd 配置有误,未重启sshd请检查/etc/ssh/sshd_config${PLAIN}"
                press_any_key_to_continue
                return
            fi
            systemctl restart sshd
            echo -e "${YELLOW}[✓]SSH端口已修改为 $new_port${PLAIN}"
            press_any_key_to_continue
            return
        else
            echo "[!] 无效的端口格式"
            press_any_key_to_continue
        fi
    done
}

enable_or_change_root_password() {
    local sshd_conf="/etc/ssh/sshd_config"
    local pass_auth="no"
    local line

    if grep -Ei '^[#[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)' "$sshd_conf" >/dev/null; then
        line=$(grep -Ei '^[#[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)' "$sshd_conf" | tail -1)
        pass_auth=$(echo "$line" | awk '{print tolower($2)}')
    fi

    clear
    read -rp "$(echo -e "${BLUE}按回车继续,输入0返回:${PLAIN}")" input
    input=$(echo "$input" | xargs)
    if [[ "$input" == "0" ]]; then
        return
    fi

    passwd root
    if [[ "$pass_auth" != "yes" ]]; then
        sed -i '/^[#[:space:]]*PermitRootLogin[[:space:]]\+\w\+/Id' "$sshd_conf"
        echo 'PermitRootLogin yes' >> "$sshd_conf"
        sed -i '/^[#[:space:]]*PasswordAuthentication[[:space:]]\+\w\+/Id' "$sshd_conf"
        echo 'PasswordAuthentication yes' >> "$sshd_conf"
        if ! sshd -t 2>/dev/null; then
            echo -e "${RED}sshd 配置有误,未重启sshd请检查/etc/ssh/sshd_config${PLAIN}"
            press_any_key_to_continue
            return
        fi
        systemctl restart sshd
        echo -e "${GREEN}[✓]Root密码登陆已启用${PLAIN}"
    else
        echo -e "${GREEN}[✓]Root密码已修改${PLAIN}"
    fi
    press_any_key_to_continue
}

enable_root_key_login() {
    clear
    ROOT_HOME="/root"
    SSH_DIR="$ROOT_HOME/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"
    TMP_KEY="$SSH_DIR/id_ed25519"
    TMP_PUB="$SSH_DIR/id_ed25519.pub"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    echo -e "${BLUE}是否需要为私钥设置密码？${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}是"
    echo -e "${GREEN}2.${PLAIN}否"
    read -p "$(echo -e "${BLUE}choice [1/2]: ${PLAIN}")" set_passwd

    if [[ "$set_passwd" != "1" && "$set_passwd" != "2" ]]; then
        echo -e "${RED}输入无效,已返回主菜单${PLAIN}"
        sleep 0.3
        return
    fi

    if [ "$set_passwd" = "1" ]; then
        clear
        echo -e "${BLUE}请输入私钥密码(不显示):${PLAIN}"
        read -s key_passphrase
        echo
        rm -f "$TMP_KEY" "$TMP_PUB"
        ssh-keygen -t ed25519 -N "$key_passphrase" -f "$TMP_KEY"
    else
        rm -f "$TMP_KEY" "$TMP_PUB"
        ssh-keygen -t ed25519 -N "" -f "$TMP_KEY"
    fi

    PUB_CONTENT=$(cat "$TMP_PUB")
    if ! grep -qxF "$PUB_CONTENT" "$AUTH_KEYS"; then
        echo "$PUB_CONTENT" >> "$AUTH_KEYS"
    fi

    if [ -f "$TMP_KEY" ]; then
        clear
        echo -e "${GREEN}请复制以下私钥内容(显示后立即删除):${PLAIN}"
        echo "-----------------------------------------------------"
        cat "$TMP_KEY"
        echo "-----------------------------------------------------"
        rm -f "$TMP_KEY"
        rm -f "$TMP_PUB"
    else
        echo -e "${RED}私钥生成失败！${PLAIN}"
    fi

    echo -e "${YELLOW}私钥内容已显示并删除。请务必妥善保存！${PLAIN}"

    sed -i '/^[#[:space:]]*PermitRootLogin[[:space:]]\+\w\+/Id' /etc/ssh/sshd_config
    sed -i '/^[#[:space:]]*PubkeyAuthentication[[:space:]]\+\w\+/Id' /etc/ssh/sshd_config
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config

    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}sshd 配置有误,未重启 sshd 请检查 /etc/ssh/sshd_config${PLAIN}"
        read -n 1 -s -r -p "按任意键继续..."
        echo
        return
    fi
    systemctl restart sshd
    echo -e "${GREEN}root ed25519 密钥登录已配置完成。${PLAIN}"
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

disable_ssh_login_menu() {
    clear
    local has_password=0
    local has_pubkey=0
    local sshd_conf="/etc/ssh/sshd_config"
    local pass_auth="yes"
    local pubkey_auth="yes"
    local line

    if grep -Ei '^[#[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)' "$sshd_conf" >/dev/null; then
        line=$(grep -Ei '^[#[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)' "$sshd_conf" | tail -1)
        pass_auth=$(echo "$line" | awk '{print tolower($2)}')
    fi

    if grep -Ei '^[#[:space:]]*PubkeyAuthentication[[:space:]]+(yes|no)' "$sshd_conf" >/dev/null; then
        line=$(grep -Ei '^[#[:space:]]*PubkeyAuthentication[[:space:]]+(yes|no)' "$sshd_conf" | tail -1)
        pubkey_auth=$(echo "$line" | awk '{print tolower($2)}')
    fi

    [[ "$pass_auth" == "yes" ]] && has_password=1
    [[ "$pubkey_auth" == "yes" ]] && has_pubkey=1

    local enabled_count=$((has_password + has_pubkey))

    if [[ $enabled_count -le 1 ]]; then
        echo -e "${RED}当前仅剩一种登录方式,禁止关闭全部登录方式 ${PLAIN}"
        press_any_key_to_continue
        return
    fi

    echo -e "${BLUE}关闭哪种登录方式${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}关闭密码登录"
    echo -e "${GREEN}2.${PLAIN}关闭密钥登录"
    read -p "$(echo -e "${BLUE}choice [1-2]: ${PLAIN}")" disable_choice
    disable_choice=$(echo "$disable_choice" | xargs)
    case "$disable_choice" in
        1)
            if [[ $has_password -eq 1 ]]; then
                sed -i '/^[#[:space:]]*PasswordAuthentication[[:space:]]\+\w\+/Id' "$sshd_conf"
                echo 'PasswordAuthentication no' >> "$sshd_conf"
                systemctl restart sshd
                echo -e "${GREEN}[✓]密码登录已关闭${PLAIN}"
            else
                echo -e "${YELLOW}密码登录本就已关闭,无需操作${PLAIN}"
            fi
            press_any_key_to_continue
            ;;
        2)
            if [[ $has_pubkey -eq 1 ]]; then
                sed -i '/^[#[:space:]]*PubkeyAuthentication[[:space:]]\+\w\+/Id' "$sshd_conf"
                echo 'PubkeyAuthentication no' >> "$sshd_conf"
                systemctl restart sshd
                echo -e "${GREEN}[✓]密钥登录已关闭${PLAIN}"
            else
                echo -e "${YELLOW}密钥登录本就已关闭,无需操作${PLAIN}"
            fi
            press_any_key_to_continue
            ;;
        *)
            return
            ;;
    esac
}

# ====== 时区管理 ======
change_timezone() {
    if ! command -v timedatectl >/dev/null; then
        echo -e "${RED}未安装timedatectl，无法自动设置时区${PLAIN}"
        echo -e "${YELLOW}请手动安装 systemd 相关组件。常用安装命令如下：${PLAIN}"
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
        echo -e "${BLUE}========= 更改时区 ========${PLAIN}"
        echo -e "${YELLOW} 当前时区:$(timedatectl | grep 'Time zone' | awk '{print $3}')${PLAIN}"
        echo -e "${GREEN} 1.推荐时区${PLAIN} (${YELLOW}$current_tz${PLAIN})"
        echo -e "${GREEN} 2.按国家代码选择${PLAIN}"
        echo -e "${GREEN} 0.返回主菜单${PLAIN}"
        echo -e "${BLUE}===========================${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入选项 [0-2]: ${PLAIN}")" choice
        choice=$(echo "$choice" | xargs)
        case "$choice" in
            1)
                if [ -n "$current_tz" ]; then
                    echo -e "${YELLOW}正在设置时区为 $current_tz...${PLAIN}"
                    if output=$(timedatectl set-timezone "$current_tz" 2>&1); then
                        echo -e "${GREEN}时区已成功设为 $current_tz，当前时间: $(date)${PLAIN}"
                    else
                        echo -e "${RED}设置失败，详细信息如下：${PLAIN}"
                        echo "$output"
                    fi
                else
                    echo -e "${RED}未检测到推荐时区！${PLAIN}"
                fi
                press_any_key_to_continue
                continue
                ;;
            2)
                clear
                read -rp "$(echo -e "${BLUE}请输入国家代码:${PLAIN}")" input_code
                input_code=$(echo "$input_code" | tr a-z A-Z | xargs)
                if [ -z "$input_code" ]; then
                    echo -e "${RED}输入不能为空${PLAIN}"
                    sleep 0.3
                    continue
                fi

                if [ ! -f /usr/share/zoneinfo/zone.tab ]; then
                    echo -e "${RED}未找到zone.tab,无法匹配国家代码到时区${PLAIN}"
                    sleep 1
                    continue
                fi
                mapfile -t lines < <(grep -E "^$input_code\s" /usr/share/zoneinfo/zone.tab | awk '{print $3}' | sort)
                if [ "${#lines[@]}" -eq 0 ]; then
                    echo -e "${RED}未找到该国家代码对应的时区${PLAIN}"
                    sleep 1
                    continue
                fi
                clear
                echo -e "${BLUE}========= 可选时区 =========${PLAIN}"
                for i in "${!lines[@]}"; do
                    echo -e "  ${GREEN}$((i+1)).${PLAIN}${BLUE}${lines[$i]}${PLAIN}"
                done
                echo -e "${BLUE}==========================${PLAIN}"
                read -rp "$(echo -e "${BLUE}请选择时区编号: ${PLAIN}")" tz_choice
                tz_choice=$(echo "$tz_choice" | xargs)
                if ! [[ "$tz_choice" =~ ^[0-9]+$ ]] || [ "$tz_choice" -lt 1 ] || [ "$tz_choice" -gt "${#lines[@]}" ]; then
                    echo -e "${RED}无效选项${PLAIN}"
                    sleep 1
                    continue
                fi
                sel_tz="${lines[$((tz_choice-1))]}"
                echo -e "${YELLOW}正在设置时区为 $sel_tz...${PLAIN}"
                if timedatectl set-timezone "$sel_tz" 2>err.log; then
                    echo -e "${GREEN}时区已成功设为 $sel_tz，当前时间: $(date)${PLAIN}"
                else
                    echo -e "${RED}设置失败，详细信息如下：${PLAIN}"
                    cat err.log
                fi
                press_any_key_to_continue
                continue
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重试${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# ====== 同仓其他脚本 ======
run_install_script() {
    set +e
    bash <(curl -sL "$1")
    set -e
}

install_acme()      { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/acme.sh"; }
install_snell()     { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/snell.sh"; }
install_mihomo()    { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/mihomo.sh"; }
install_trojan()    { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/trojan.sh"; }
install_hysteria()  { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/hysteria.sh"; }
install_substore()  { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/substore.sh"; }
install_install()   { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/Install.sh"; }
install_nginx()     { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/nginx.sh"; }
install_wireguard() { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/wireguard.sh"; }

# ====== VPS重启 ======
reboot_vps() {
    echo "即将重启系统..."
    reboot
}

# ====== 防火墙配置 ======
configure_firewall() {
    echo -e "${BLUE}[*] 检查 iptables 是否安装...${PLAIN}"
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}[!] 未检测到 iptables，开始安装...${PLAIN}"
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
            echo -e "${RED}[!] 无法安装 iptables，请手动安装。${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
        echo -e "${GREEN}[✓] iptables 已安装${PLAIN}"
    else
        echo -e "${GREEN}[✓] iptables 已存在${PLAIN}"
    fi

    while true; do
        clear
        echo -e "${BLUE}========= iptables 防火墙管理 =========${PLAIN}"
        echo -e "${GREEN}1. 开启端口${PLAIN}"
        echo -e "${RED}2. 关闭端口${PLAIN}"
        echo -e "${GREEN}3. 开启全部端口${PLAIN}"
        echo -e "${RED}4. 关闭全部端口(保留SSH)${PLAIN}"
        echo -e "${BLUE}5. 显示已开启的端口${PLAIN}"
        echo -e "${YELLOW}0. 返回主菜单${PLAIN}"
        echo -e "${BLUE}======================================${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入选项 [0-5]: ${PLAIN}")" action_choice
        action_choice=$(echo "$action_choice" | xargs)
        [[ "$action_choice" == "0" ]] && return
        case "$action_choice" in
            1|2)
                read -rp "请输入端口（如 443 或 1000-2000）: " ports
                for port in $ports; do
                    if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start_port=${BASH_REMATCH[1]}
                        end_port=${BASH_REMATCH[2]}
                        iptables -D INPUT -p tcp --dport $start_port:$end_port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p tcp --dport $start_port:$end_port -j DROP 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $start_port:$end_port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $start_port:$end_port -j DROP 2>/dev/null || true
                        if [[ "$action_choice" == "1" ]]; then
                            iptables -A INPUT -p tcp --dport $start_port:$end_port -j ACCEPT
                            iptables -A INPUT -p udp --dport $start_port:$end_port -j ACCEPT
                            echo -e "${GREEN}[✓] 端口范围 $port 已开启${PLAIN}"
                        else
                            [[ "$start_port" -le 22 && "$end_port" -ge 22 ]] && { echo -e "${YELLOW}[!] 警告: 不允许关闭 SSH 端口 (22)${PLAIN}"; continue; }
                            iptables -A INPUT -p tcp --dport $start_port:$end_port -j DROP
                            iptables -A INPUT -p udp --dport $start_port:$end_port -j DROP
                            echo -e "${RED}[✓] 端口范围 $port 已关闭${PLAIN}"
                        fi
                    else
                        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
                            echo -e "${RED}[!] 无效端口: $port${PLAIN}"
                            continue
                        fi
                        if [[ "$port" == "22" && "$action_choice" == "2" ]]; then
                            echo -e "${YELLOW}[!] 警告: 不允许关闭 SSH 端口 (22)${PLAIN}"
                            continue
                        fi
                        iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
                        iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null || true
                        if [[ "$action_choice" == "1" ]]; then
                            iptables -A INPUT -p tcp --dport $port -j ACCEPT
                            iptables -A INPUT -p udp --dport $port -j ACCEPT
                            echo -e "${GREEN}[✓] 端口 $port 已开启${PLAIN}"
                        else
                            iptables -A INPUT -p tcp --dport $port -j DROP
                            iptables -A INPUT -p udp --dport $port -j DROP
                            echo -e "${RED}[✓] 端口 $port 已关闭${PLAIN}"
                        fi
                    fi
                done
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save
                elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                    service iptables save
                fi
                if [[ "$action_choice" == "1" ]]; then
                    echo -e "${GREEN}[✓] 所有指定端口已开启完成${PLAIN}"
                else
                    echo -e "${RED}[✓] 所有指定端口已关闭完成${PLAIN}"
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
                echo -e "${GREEN}[✓] 所有端口已开启${PLAIN}"
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
                echo -e "${RED}[✓] 所有端口已关闭 (22端口除外)${PLAIN}"
                press_any_key_to_continue
                ;;
            5)
                iptables_output=$(iptables -L INPUT -n -v)
                echo -e "${BLUE}$iptables_output${PLAIN}"
                press_any_key_to_continue
                ;;
            *)
                echo -e "${RED}[!] 无效选项，请重新选择${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# ===== DNS配置 =====
get_primary_iface() {
    ip route 2>/dev/null | awk '/^default/{print $5; exit}'
}

resolv_conf_managed_by_resolved() {
    if [ -L /etc/resolv.conf ]; then
        target="$(readlink -f /etc/resolv.conf 2>/dev/null)"
        case "$target" in
            /run/systemd/resolve/stub-resolv.conf|/run/systemd/resolve/resolv.conf) return 0 ;;
        esac
    fi
    grep -qE '(^|\s)nameserver\s+127\.0\.0\.53(\s|$)' /etc/resolv.conf 2>/dev/null
}

safe_update_resolv_conf() {
    local primary_dns="$1"
    local secondary_dns="$2"

    if resolv_conf_managed_by_resolved; then
        return 1
    fi

    if [ -L /etc/resolv.conf ]; then
        return 1
    fi

    if command -v chattr >/dev/null 2>&1; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    {
        echo "nameserver $primary_dns"
        [ -n "$secondary_dns" ] && echo "nameserver $secondary_dns"
    } > /etc/resolv.conf

    if command -v chattr >/dev/null 2>&1; then
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
    return 0
}

detect_network_manager() {
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet systemd-resolved 2>/dev/null \
       && command -v resolvectl >/dev/null 2>&1; then
        echo "systemd-resolved"
    elif command -v nmcli >/dev/null 2>&1; then
        echo "NetworkManager"
    elif [ -d "/etc/netplan" ] && command -v netplan >/dev/null 2>&1; then
        echo "netplan"
    else
        echo "traditional"
    fi
}

show_current_dns() {
    echo -e "${YELLOW} 当前DNS:${PLAIN}"
    grep -E "^\s*nameserver" /etc/resolv.conf 2>/dev/null || echo "未找到DNS配置"
    network_manager=$(detect_network_manager)
    case $network_manager in
        "NetworkManager")
            echo -e "${YELLOW}NetworkManager配置:${PLAIN}"
            nmcli dev show 2>/dev/null | grep -E "^\s*IP4.DNS" || echo "未找到NetworkManager DNS配置"
            ;;
        "systemd-resolved")
            echo -e "${YELLOW}systemd-resolved配置:${PLAIN}"
            resolvectl status 2>/dev/null | grep -E "DNS Servers|Current DNS Server" || echo "未找到systemd-resolved DNS配置"
            ;;
    esac
}

show_error() {
    echo -e "${RED}错误: $1${PLAIN}"
    return 1
}

persistent_set_dns() {
    local primary_dns="$1"
    local secondary_dns="$2"
    local network_manager
    network_manager=$(detect_network_manager)

    case "$network_manager" in
        "NetworkManager")
            command -v nmcli >/dev/null 2>&1 || { show_error "未找到 nmcli"; return 1; }

            local CONNECTION
            CONNECTION=$(nmcli -t -f NAME c show --active 2>/dev/null | head -n1)
            [ -z "$CONNECTION" ] && { show_error "未找到活动的网络连接"; return 1; }

            if [ -n "$secondary_dns" ]; then
                nmcli con mod "$CONNECTION" ipv4.dns "$primary_dns,$secondary_dns" || { show_error "设置 NetworkManager DNS 失败"; return 1; }
            else
                nmcli con mod "$CONNECTION" ipv4.dns "$primary_dns" || { show_error "设置 NetworkManager DNS 失败"; return 1; }
            fi
            nmcli con mod "$CONNECTION" ipv4.ignore-auto-dns yes 2>/dev/null || true

            nmcli con up "$CONNECTION" 2>/dev/null || true
            nmcli general reload 2>/dev/null || true
            systemctl restart NetworkManager 2>/dev/null || true

            ;;

        "systemd-resolved")
            command -v resolvectl >/dev/null 2>&1 || { show_error "未找到 resolvectl"; return 1; }

            local IFACE
            IFACE=$(get_primary_iface)
            [ -z "$IFACE" ] && { show_error "未找到默认网络接口"; return 1; }

            if [ -n "$secondary_dns" ]; then
                resolvectl dns "$IFACE" "$primary_dns" "$secondary_dns" || { show_error "设置 systemd-resolved DNS 失败"; return 1; }
            else
                resolvectl dns "$IFACE" "$primary_dns" || { show_error "设置 systemd-resolved DNS 失败"; return 1; }
            fi

            resolvectl flush-caches 2>/dev/null || systemd-resolve --flush-caches 2>/dev/null || true

            if [ ! -L /etc/resolv.conf ] && command -v ln >/dev/null 2>&1; then
                :
            fi
            ;;

        "netplan")
            command -v netplan >/dev/null 2>&1 || { show_error "未找到 netplan"; return 1; }

            local NETPLAN_FILE
            NETPLAN_FILE=$(find /etc/netplan -maxdepth 1 -type f -name "*.yaml" -o -name "*.yml" 2>/dev/null | head -n1)
            [ -z "$NETPLAN_FILE" ] && { show_error "未找到 netplan 配置文件"; return 1; }

            cp -f "$NETPLAN_FILE" "${NETPLAN_FILE}.bak" 2>/dev/null || true

            local IFACE
            IFACE=$(get_primary_iface)
            if [ -n "$IFACE" ]; then
                if netplan help 2>&1 | grep -q "set"; then
                    if [ -n "$secondary_dns" ]; then
                        netplan set "network.ethernets.${IFACE}.nameservers.addresses=[${primary_dns}, ${secondary_dns}]" 2>/dev/null \
                        || netplan set "network.bridges.${IFACE}.nameservers.addresses=[${primary_dns}, ${secondary_dns}]" 2>/dev/null \
                        || netplan set "network.wifis.${IFACE}.nameservers.addresses=[${primary_dns}, ${secondary_dns}]" 2>/dev/null || true
                    else
                        netplan set "network.ethernets.${IFACE}.nameservers.addresses=[${primary_dns}]" 2>/dev/null \
                        || netplan set "network.bridges.${IFACE}.nameservers.addresses=[${primary_dns}]" 2>/dev/null \
                        || netplan set "network.wifis.${IFACE}.nameservers.addresses=[${primary_dns}]" 2>/dev/null || true
                    fi
                fi
            fi

            if ! grep -q "nameservers:" "$NETPLAN_FILE"; then
                if [ -n "$secondary_dns" ]; then
                    sed -i "/dhcp4:\s*true/a\ \ \ \ \ \ nameservers:\n\ \ \ \ \ \ \ \ addresses: [${primary_dns}, ${secondary_dns}]" "$NETPLAN_FILE"
                else
                    sed -i "/dhcp4:\s*true/a\ \ \ \ \ \ nameservers:\n\ \ \ \ \ \ \ \ addresses: [${primary_dns}]" "$NETPLAN_FILE"
                fi
            else
                if [ -n "$secondary_dns" ]; then
                    sed -i "/nameservers:/,/addresses:/c\ \ \ \ \ \ nameservers:\n\ \ \ \ \ \ \ \ addresses: [${primary_dns}, ${secondary_dns}]" "$NETPLAN_FILE"
                else
                    sed -i "/nameservers:/,/addresses:/c\ \ \ \ \ \ nameservers:\n\ \ \ \ \ \ \ \ addresses: [${primary_dns}]" "$NETPLAN_FILE"
                fi
            fi

            if ! netplan try 2>/dev/null; then
                cp -f "${NETPLAN_FILE}.bak" "$NETPLAN_FILE" 2>/dev/null || true
                show_error "netplan 配置应用失败"
                return 1
            fi
            ;;

        *)
            if ! safe_update_resolv_conf "$primary_dns" "$secondary_dns"; then
                show_error "/etc/resolv.conf 由其他服务管理，无法直接写入"
                return 1
            fi
            ;;
    esac

    echo -e "${GREEN}DNS设置已更新并已持久化${PLAIN}"
    return 0
}

set_predefined_dns() {
    echo -e "${YELLOW}正在设置DNS为 8.8.8.8 和 1.1.1.1...${PLAIN}"
    persistent_set_dns "8.8.8.8" "1.1.1.1"
}

set_manual_dns() {
    while true; do
        clear
        echo -e "${YELLOW}请输入主要DNS服务器:${PLAIN}"
        read primary_dns
        primary_dns="$(echo "$primary_dns" | xargs)"
        [ -n "$primary_dns" ] && break
        echo -e "${RED}主要DNS服务器不能为空，请重新输入${PLAIN}"
    done
    echo -e "${YELLOW}请输入次要DNS服务器(可选，直接按回车跳过):${PLAIN}"
    read secondary_dns
    secondary_dns="$(echo "$secondary_dns" | xargs)"
    persistent_set_dns "$primary_dns" "$secondary_dns"
}

dns_config_menu() {
    while true; do
        clear
        echo -e "${BLUE}======== DNS配置工具 =======${PLAIN}"
        show_current_dns
        echo -e "${YELLOW} 请选择操作:${PLAIN}"
        echo -e "${GREEN} 1.修改DNS为8.8.8.8和1.1.1.1${PLAIN}"
        echo -e "${GREEN} 2.手动修改DNS${PLAIN}"
        echo -e "${GREEN} 0.返回主菜单${PLAIN}"
        echo -e "${BLUE}============================${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入选项 [0-2]: ${PLAIN}")" option
        option="$(echo "$option" | xargs)"
        case "$option" in
            1) set_predefined_dns ;;
            2) set_manual_dns ;;
            0) return ;;
            *) echo -e "${RED}无效选项，请重试${PLAIN}"; sleep 1 ;;
        esac
        press_any_key_to_continue "按任意键继续...${PLAIN}"
    done
}

# ====== 主菜单 ======
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Steins Gate_Ver.2.2 ✦${PLAIN}"
        echo -e "${GREEN}  01.${PLAIN}系统更新"
        echo -e "${GREEN}  02.${PLAIN}系统清理"
        echo -e "${GREEN}  03.${PLAIN}重装系统"
        echo -e "${GREEN}  04.${PLAIN}设置时区"
        echo -e "${GREEN}  05.${PLAIN}配置DNS"
        echo -e "${GREEN}  06.${PLAIN}配置SSH"
        echo -e "${GREEN}  07.${PLAIN}重启VPS"
        echo -e "${GREEN}  08.${PLAIN}配置SWAP"
        echo -e "${GREEN}  09.${PLAIN}配置ACME"
        echo -e "${GREEN}  10.${PLAIN}配置Nginx"
        echo -e "${GREEN}  11.${PLAIN}安装Snell"
        echo -e "${GREEN}  12.${PLAIN}安装Mihomo"
        echo -e "${GREEN}  13.${PLAIN}安装Trojan"
        echo -e "${GREEN}  14.${PLAIN}安装Hysteria"
        echo -e "${GREEN}  15.${PLAIN}配置FireWall"
        echo -e "${GREEN}  16.${PLAIN}安装SubStore"
        echo -e "${GREEN}  17.${PLAIN}提取WireGuard"
        echo -e "${GREEN}   0.${PLAIN}离开SteinsGate"
        read -p "$(echo -e "${BLUE}✦ Choice [0-19] ✦ : ${PLAIN}")" choice
        choice=$(echo "$choice" | xargs)
        case "$choice" in
            1)  linux_update ;;
            2)  linux_clean ;;
            3)  install_install ;;
            4)  change_timezone ;;
            5)  dns_config_menu ;;
            6)  ssh_config_menu ;;
            7)  echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps ;;
            8)  set_swap_menu ;;
            9)  install_acme ;;
            10) install_nginx ;;
            11) install_snell ;;
            12) install_mihomo ;;
            13) install_trojan ;;
            14) install_hysteria ;;
            15) configure_firewall ;;
            16) install_substore ;;
            17) install_wireguard ;;
            0)  clear; echo -e "${BLUE}「命运石之扉の选择,El Psy Kongroo」${PLAIN}"; sleep 0.6; clear; break ;;
            *)  clear; echo -e "${RED}[!] 无效选项，请重新选择${PLAIN}"; sleep 0.4 ;;
        esac
    done
}

main_menu
