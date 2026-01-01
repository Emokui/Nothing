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

get_recommended_swap() {
    local total_ram
    total_ram=$(free -m | awk '/Mem:/ {print $2}')
    if (( total_ram <= 2048 )); then
        echo $((total_ram * 2))
    elif (( total_ram <= 8192 )); then
        echo $((total_ram))
    else
        echo 4096
    fi
}

set_swap_menu() {
    while true; do
        clear
        local current_swap total_ram recommend_swap
        current_swap=$(free -m | awk '/Swap:/ {print $2}')
        total_ram=$(free -m | awk '/Mem:/ {print $2}')
        recommend_swap=$(get_recommended_swap)
        
        local current_swappiness
        current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知")

        echo -e "${BLUE}===== 虚拟内存(Swap) =====${PLAIN}"
        echo -e "${YELLOW}物理内存: ${total_ram} MB${PLAIN}"
        echo -e "${YELLOW}当前Swap: ${current_swap} MB${PLAIN} (推荐: ${recommend_swap} MB)"
        echo -e "${YELLOW}当前Swappiness: ${current_swappiness}${PLAIN} (数值越小越不倾向使用Swap,VPS建议 10-60)"
        echo -e "${BLUE}====================================${PLAIN}"
        echo -e "${GREEN}1. 设置 Swap (智能推荐: ${recommend_swap} MB)${PLAIN}"
        echo -e "${GREEN}2. 自定义 Swap 大小${PLAIN}"
        echo -e "${GREEN}3. 调整 Swappiness 策略${PLAIN}"
        echo -e "${RED}4. 删除/关闭 Swap${PLAIN}"
        echo -e "${YELLOW}0. 返回主菜单${PLAIN}"
        echo -e "${BLUE}====================================${PLAIN}"
        
        read -p "$(echo -e "${BLUE}请输入选项 [0-4]: ${PLAIN}")" opt
        case "$opt" in
            1)
                set_swap "$recommend_swap"
                ;;
            2)
                read -rp "请输入 Swap 大小 (单位 MB,,建议 >=128): " custom
                if [[ "$custom" =~ ^[0-9]+$ ]] && (( custom >= 128 )); then
                    set_swap "$custom"
                else
                    echo -e "${RED}输入无效！${PLAIN}"
                    sleep 2
                fi
                ;;
            3)
                set_swappiness
                ;;
            4)
                delete_swap
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

set_swap() {
    local size_mb="$1"
    local avail_kb avail_mb

    echo -e "${YELLOW}正在检查环境...${PLAIN}"
    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024))
    
    if (( avail_mb < size_mb + 500 )); then
        echo -e "${RED}磁盘空间不足！当前可用: ${avail_mb}MB, 需要: ${size_mb}MB (+预留500MB)${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    if grep -q "$swapfile_path" /proc/swaps; then
        echo -e "${YELLOW}发现已存在的 Swap，正在卸载...${PLAIN}"
        sudo swapoff "$swapfile_path" 2>/dev/null || true
    fi
    sudo rm -f "$swapfile_path"
    
    sudo sed -i "\|${swapfile_path}|d" /etc/fstab

    echo -e "${BLUE}正在创建 ${size_mb}MB 的 Swap 文件...${PLAIN}"
    
    if command -v fallocate >/dev/null 2>&1; then
        if ! sudo fallocate -l "${size_mb}M" "$swapfile_path" 2>/dev/null; then
             echo -e "${YELLOW}fallocate 创建失败,尝试使用 dd 写零 (速度较慢,请耐心等待)...${PLAIN}"
             sudo dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress
        fi
    else
        sudo dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress
    fi

    sudo chmod 600 "$swapfile_path"
    sudo mkswap "$swapfile_path"
    sudo swapon "$swapfile_path"

    echo "$swapfile_path none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null

    echo -e "${GREEN}✓ Swap 设置成功!${PLAIN}"
    free -h
    press_any_key_to_continue
}

delete_swap() {
    echo -e "${YELLOW}正在删除 Swap...${PLAIN}"
    sudo swapoff "$swapfile_path" 2>/dev/null || true
    sudo rm -f "$swapfile_path"
    sudo sed -i "\|${swapfile_path}|d" /etc/fstab
    echo -e "${GREEN}✓ Swap 已删除并关闭${PLAIN}"
    free -h
    press_any_key_to_continue
}

set_swappiness() {
    local current_val
    current_val=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    echo -e "当前 Swappiness: ${GREEN}${current_val}${PLAIN}"
    echo -e "数值范围 0-100.数值越低,系统越倾向于使用物理内存(高性能);数值越高,越倾向于使用 Swap。"
    echo -e "建议值:VPS/服务器: ${GREEN}10${PLAIN}, 桌面: ${GREEN}60${PLAIN}"
    
    read -rp "请输入新的 Swappiness 值 (0-100): " new_val
    if [[ "$new_val" =~ ^[0-9]+$ ]] && (( new_val >= 0 && new_val <= 100 )); then
        sudo sysctl vm.swappiness="$new_val"
        
        if grep -q "^vm.swappiness" /etc/sysctl.conf; then
            sudo sed -i "s/^vm.swappiness.*/vm.swappiness = $new_val/" /etc/sysctl.conf
        else
            echo "vm.swappiness = $new_val" | sudo tee -a /etc/sysctl.conf >/dev/null
        fi
        
        echo -e "${GREEN}✓ 设置成功！${PLAIN}"
    else
        echo -e "${RED}输入无效${PLAIN}"
    fi
    press_any_key_to_continue
}
# ====== SSH管理 ======
ssh_config_menu() {
    while true; do
        clear
        echo -e "${BLUE}====== SSH配置 ======${PLAIN}"
        echo -e "${GREEN} 1.设置Root密码${PLAIN}"
        echo -e "${GREEN} 2.设置Root密钥${PLAIN}"
        echo -e "${BLUE} 3.修改登录端口${PLAIN}"
        echo -e "${RED} 4.关闭登录方式${PLAIN}"
        echo -e "${YELLOW} 0.返回主菜单${PLAIN}"
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
dns_fix()           { run_install_script "https://raw.githubusercontent.com/Emokui/Nothing/Zero/Shell/dns.sh"; }

# ====== VPS重启 ======
reboot_vps() {
    echo "即将重启系统..."
    reboot
}

# ====== 防火墙配置 ======
configure_firewall() {
    get_ssh_port() {
        local port
        if [ -f /etc/ssh/sshd_config ]; then
            port=$(grep "^Port" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}')
        fi
        
        if [[ -z "$port" ]]; then
            port=22
        fi
        echo "$port"
    }
    apply_firewall_cmd() {
        iptables "$@" 2>/dev/null || true
        
        if command -v ip6tables &>/dev/null; then
            ip6tables "$@" 2>/dev/null || true
        fi
    }
    save_rules() {
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        elif command -v service &>/dev/null; then
             service iptables save 2>/dev/null
             service ip6tables save 2>/dev/null
        fi
    }
    local current_ssh_port
    current_ssh_port=$(get_ssh_port)
    echo -e "${BLUE}[*] 检查 iptables 工具...${PLAIN}"
    
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}[!] 未检测到 iptables,尝试安装...${PLAIN}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y iptables iptables-persistent
        elif command -v dnf &>/dev/null; then
            dnf install -y iptables-services
        elif command -v yum &>/dev/null; then
            yum install -y iptables-services
        else
            echo -e "${RED}[!] 请手动安装 iptables!${PLAIN}"
            return 1
        fi
    fi
    while true; do
        clear
        echo -e "${BLUE}========= iptables 防火墙管理 =========${PLAIN}"
        echo -e "${BLUE}SSH端口:  ${YELLOW}${current_ssh_port}${PLAIN}"
        echo -e "${BLUE}IPv6支持: $(command -v ip6tables &>/dev/null && echo -e "${GREEN}开启${PLAIN}" || echo -e "${RED}未关闭${PLAIN}")${PLAIN}"
        echo -e "${BLUE}=======================================${PLAIN}"
        echo -e "${GREEN}1.开启端口${PLAIN}"
        echo -e "${RED}2.关闭端口${PLAIN}"
        echo -e "${GREEN}3.开启全部端口${PLAIN}"
        echo -e "${RED}4.关闭全部端口(保留SSH)${PLAIN}"
        echo -e "${BLUE}5.显示当前规则${PLAIN}"
        echo -e "${YELLOW}0.返回主菜单${PLAIN}"
        echo -e "${BLUE}=======================================${PLAIN}"
        read -p "$(echo -e "${BLUE}请输入选项 [0-5]: ${PLAIN}")" action_choice
        action_choice=$(echo "$action_choice" | xargs)
        
        [[ "$action_choice" == "0" ]] && return
        case "$action_choice" in
            1|2)
                read -rp "请输入端口（如 443 或 1000-2000）: " input_ports
                for port_range in $input_ports; do
                    local start_port end_port
                    if [[ "$port_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start_port=${BASH_REMATCH[1]}
                        end_port=${BASH_REMATCH[2]}
                    elif [[ "$port_range" =~ ^([0-9]+)$ ]]; then
                        start_port=$port_range
                        end_port=$port_range
                    else
                        echo -e "${RED}[!] 无效端口格式: $port_range${PLAIN}"
                        continue
                    fi
                    if [[ "$action_choice" == "1" ]]; then
                        apply_firewall_cmd -D INPUT -p tcp --dport "$start_port:$end_port" -j DROP
                        apply_firewall_cmd -D INPUT -p udp --dport "$start_port:$end_port" -j DROP
                        apply_firewall_cmd -D INPUT -p tcp --dport "$start_port:$end_port" -j ACCEPT
                        apply_firewall_cmd -D INPUT -p udp --dport "$start_port:$end_port" -j ACCEPT
                        
                        apply_firewall_cmd -I INPUT -p tcp --dport "$start_port:$end_port" -j ACCEPT
                        apply_firewall_cmd -I INPUT -p udp --dport "$start_port:$end_port" -j ACCEPT
                        echo -e "${GREEN}[✓] 端口 $port_range 已开启${PLAIN}"
                    else
                        if [[ "$start_port" -le "$current_ssh_port" && "$end_port" -ge "$current_ssh_port" ]]; then
                            echo -e "${YELLOW}[!] 警告: 即使选择关闭,SSH 端口 ($current_ssh_port) 也不会被阻断。${PLAIN}"
                        else
                            apply_firewall_cmd -D INPUT -p tcp --dport "$start_port:$end_port" -j ACCEPT
                            apply_firewall_cmd -D INPUT -p udp --dport "$start_port:$end_port" -j ACCEPT
                            apply_firewall_cmd -D INPUT -p tcp --dport "$start_port:$end_port" -j DROP
                            apply_firewall_cmd -D INPUT -p udp --dport "$start_port:$end_port" -j DROP
                            apply_firewall_cmd -I INPUT -p tcp --dport "$start_port:$end_port" -j DROP
                            apply_firewall_cmd -I INPUT -p udp --dport "$start_port:$end_port" -j DROP
                            echo -e "${RED}[✓] 端口 $port_range 已关闭${PLAIN}"
                        fi
                    fi
                done
                save_rules
                press_any_key_to_continue
                ;;
            3)  
                apply_firewall_cmd -F
                apply_firewall_cmd -P INPUT ACCEPT
                apply_firewall_cmd -P FORWARD ACCEPT
                apply_firewall_cmd -P OUTPUT ACCEPT
                save_rules
                echo -e "${GREEN}[✓] 防火墙规则已清空,所有端口开放${PLAIN}"
                press_any_key_to_continue
                ;;
            4)  
                echo -e "${YELLOW}[*] 正在配置全关闭策略(保留SSH: $current_ssh_port）...${PLAIN}"
                
                apply_firewall_cmd -F
                
                apply_firewall_cmd -P INPUT DROP
                apply_firewall_cmd -P FORWARD DROP
                apply_firewall_cmd -P OUTPUT ACCEPT
                apply_firewall_cmd -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                 
                apply_firewall_cmd -A INPUT -i lo -j ACCEPT
                
                apply_firewall_cmd -A INPUT -p tcp --dport "$current_ssh_port" -j ACCEPT
                if command -v ip6tables &>/dev/null; then
                   ip6tables -A INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || true
                fi
                save_rules
                echo -e "${RED}[✓] 已阻止所有入站连接(SSH 端口 $current_ssh_port 已放行)${PLAIN}"
                press_any_key_to_continue
                ;;
            5)
                list_rules() {
                    clear
                    echo -e "\n${BLUE}=================== 防火墙规则详情 (IPv4/IPv6) ===================${PLAIN}"
                    
                    local policy
                    policy=$(iptables -L INPUT -n | grep "Chain INPUT" | awk '{print $4}' | tr -d ')')
                    echo -e "默认策略: $([[ "$policy" == "DROP" ]] && echo -e "${RED}拒绝 (DROP)${PLAIN}" || echo -e "${GREEN}接受 (ACCEPT)${PLAIN}")"
                    
                    echo -e "${BLUE}----------------------------------------------------------------------${PLAIN}"
                    # Header: ID(14v), Action(14v=16b), Prot(14v=16b), Port
                    printf "%-14s %-16s %-16s %-s\n" "ID" "行为" "协议" "端口"
                    echo -e "${BLUE}----------------------------------------------------------------------${PLAIN}"
                    parse_table() {
                        local ver=$1
                        local cmd=$2
                        if ! command -v $cmd &>/dev/null; then return; fi
                        
                        $cmd -L INPUT -n -v --line-numbers | grep -v "Chain" | grep -v "target" | while read -r line; do
                             echo "$ver $line"
                        done
                    }
                    {
                        parse_table "v4" "iptables"
                        parse_table "v6" "ip6tables"
                    } | awk '
                    BEGIN {
                        GREEN="\033[0;32m"
                        RED="\033[0;31m"
                        YELLOW="\033[0;33m"
                        PLAIN="\033[0m"
                    }
                    {
                        ver=$1
                        num=$2
                        # target=$5, prot=$6, in_iface=$8, extra=$12...
                        target=$5
                        raw_prot=$6
                        in_iface=$8
                        
                        extra=""
                        for(i=12; i<=NF; i++) extra = extra $i " "
                        
                        
                        if (raw_prot == "6") prot="tcp"
                        else if (raw_prot == "17") prot="udp"
                        else if (raw_prot == "1") prot="icmp"
                        else if (raw_prot == "58") prot="icmpv6"
                        else if (raw_prot == "0" || raw_prot == "all") prot="all"
                        else prot=raw_prot
                        if (prot == "icmpv6") next
                        
                        gsub(/0.0.0.0\/0/, "", extra)
                        gsub(/::\/0/, "", extra)
                        gsub(/^[ \t]+|[ \t]+$/, "", extra) # trim
                        if (extra ~ "^" prot " ") {
                            sub("^" prot " ", "", extra)
                        }
                        
                        if (in_iface != "*") {
                            extra = "[网卡:" in_iface "] " extra
                        }
                        
                        if (extra ~ /\[网卡:lo\]/) next
                        if (extra ~ /state RELATED,ESTABLISHED/) next
                        signature = target "|" prot "|" extra
                        
                        if (!seen[signature]++) {
                            order[count++] = signature
                        }
                        
                        if (ver == "v4") id_v4[signature] = num
                        else id_v6[signature] = num
                        
                        meta_target[signature] = target
                        meta_prot[signature] = prot
                        meta_extra[signature] = extra
                    }
                    END {
                        for(i=0; i<count; i++) {
                            sig = order[i]
                            
                            v4 = id_v4[sig]
                            v6 = id_v6[sig]
                            if (v4 && v6 && v4 == v6) disp_id = v4;
                            else if (v4 && v6) disp_id = v4 "(v4)/" v6 "(v6)";
                            else if (v4) disp_id = v4 "(v4)";
                            else disp_id = v6 "(v6)";
                            
                            t = meta_target[sig]
                            if (t == "ACCEPT") color = GREEN
                            else if (t == "DROP") color = RED
                            else color = YELLOW
                            
                            len_t = length(t)
                            pad_len = 14 - len_t
                            if (pad_len < 0) pad_len = 0
                            pad = sprintf("%" pad_len "s", "")
                            
                            final_target = color t pad PLAIN
                            
                            printf "%-14s %s %-14s %s\n", disp_id, final_target, meta_prot[sig], meta_extra[sig]
                        }
                    }
                    '
                    echo -e "${BLUE}----------------------------------------------------------------------${PLAIN}"
                }
                list_rules
                press_any_key_to_continue
                ;;
            *)
                echo -e "${RED}[!] 无效选项${PLAIN}"
                sleep 1
                ;;
        esac
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
            5)  dns_fix ;;
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
