#!/bin/bash

set -u

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
PLAIN="\033[0m"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请用 root 用户运行本脚本${PLAIN}"
  exit 1
fi

get_root_home() {
    getent passwd root | cut -d: -f6
}

ROOT_HOME="$(get_root_home)"
SSHD_CONFIG="/etc/ssh/sshd_config"
FIREWALL_RULE_DIR="/etc/iptables"
FIREWALL_RULES_V4="$FIREWALL_RULE_DIR/zero.rules.v4"
FIREWALL_RULES_V6="$FIREWALL_RULE_DIR/zero.rules.v6"
ZERO_FIREWALL_SERVICE="/etc/systemd/system/zero-firewall-persistent.service"
ZERO_FIREWALL_SERVICE_NAME="zero-firewall-persistent.service"
ZERO_FW_CHAIN="ZERO_INPUT"
ZERO_PORT_JUMP_CHAIN="ZERO_PORT_JUMP"

get_sshd_effective_option() {
    local option="$1"
    local key value
    key=$(printf '%s' "$option" | tr '[:upper:]' '[:lower:]')

    if ! command -v sshd >/dev/null 2>&1; then
        return 1
    fi

    value=$(sshd -T -f "$SSHD_CONFIG" 2>/dev/null | awk -v key="$key" '$1 == key {print $2; exit}')
    [[ -n "$value" ]] || return 1
    echo "$value"
}

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

update_sshd_option() {
    local option="$1"
    local value="$2"
    local config_file="${3:-$SSHD_CONFIG}"
    local dropin_dir="/etc/ssh/sshd_config.d"
    if [[ -d "$dropin_dir" ]]; then
        for f in "$dropin_dir"/*.conf; do
            [[ -f "$f" ]] && sed -i "/^[#[:space:]]*${option}[[:space:]]/Id" "$f"
        done
    fi
    
    sed -i "/^[#[:space:]]*${option}[[:space:]]/Id" "$config_file"
    echo "${option} ${value}" >> "$config_file"
}

get_sshd_option() {
    local option="$1"
    local default="${2:-}"
    local config_file="${3:-$SSHD_CONFIG}"
    local line value effective

    if effective=$(get_sshd_effective_option "$option"); then
        echo "$effective"
        return
    fi

    line=$(grep -Ei "^[[:space:]]*${option}[[:space:]]+" "$config_file" 2>/dev/null | tail -1 || true)
    if [[ -n "$line" ]]; then
        value=$(echo "$line" | awk '{print tolower($2)}')
        echo "$value"
    else
        echo "$default"
    fi
}

restart_sshd_safe() {
    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}sshd 配置有误,未重启sshd请检查${SSHD_CONFIG}${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl restart sshd 2>/dev/null && ! systemctl restart ssh 2>/dev/null; then
            echo -e "${RED}sshd 服务重启失败,请手动检查服务状态${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    elif command -v service >/dev/null 2>&1; then
        if ! service sshd restart >/dev/null 2>&1 && ! service ssh restart >/dev/null 2>&1; then
            echo -e "${RED}sshd 服务重启失败,请手动检查服务状态${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    else
        echo -e "${RED}未找到 systemctl/service,无法自动重启 sshd${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    return 0
}

detect_pkg_manager() {
    if command -v apt &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v apk &>/dev/null; then echo "apk"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v zypper &>/dev/null; then echo "zypper"
    elif command -v emerge &>/dev/null; then echo "emerge"
    else echo ""
    fi
}

pkg_install() {
    local pkg="$1"
    local pm
    pm=$(detect_pkg_manager)
    
    case "$pm" in
        apt)    apt update && apt install -y "$pkg" ;;
        dnf)    dnf install -y "$pkg" ;;
        yum)    yum install -y "$pkg" ;;
        apk)    apk add "$pkg" ;;
        pacman) pacman -Sy --noconfirm "$pkg" ;;
        zypper) zypper --non-interactive install "$pkg" ;;
        emerge) emerge --ask=n "$pkg" ;;
        *)      return 1 ;;
    esac
}

pkg_update() {
    local pm
    pm=$(detect_pkg_manager)
    
    case "$pm" in
        apt)    apt update && apt upgrade -y ;;
        dnf)    dnf upgrade --refresh -y ;;
        yum)    yum update -y ;;
        apk)    apk update && apk upgrade ;;
        pacman) pacman -Syu --noconfirm ;;
        zypper) zypper refresh && zypper update -y ;;
        emerge) emerge --sync && emerge --ask=n --update --deep --newuse @world ;;
        *)      return 1 ;;
    esac
}

pkg_clean() {
    local pm
    pm=$(detect_pkg_manager)
    
    case "$pm" in
        apt)    apt autoremove -y && apt autoclean -y && apt clean ;;
        dnf)    dnf autoremove -y && dnf clean all ;;
        yum)    yum autoremove -y && yum clean all ;;
        apk)    apk cache clean ;;
        pacman)
            local orphans
            orphans=$(pacman -Qtdq 2>/dev/null)
            if [[ -n "$orphans" ]]; then
                pacman -Rns $orphans --noconfirm
            fi
            pacman -Scc --noconfirm
            ;;
        zypper) zypper clean --all ;;
        emerge) emerge --depclean && eclean-dist --deep ;;
        *)      return 1 ;;
    esac
}

# ====== 安装wget ======
install_wget_if_missing() {
    if ! command -v wget &>/dev/null; then
        echo -e "${YELLOW}未检测到 wget，正在自动安装...${PLAIN}"
        if ! pkg_install wget; then
            echo -e "${RED}无法识别的包管理器，wget 安装失败，请手动安装！${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}wget 安装完成${PLAIN}"
    fi
}

install_wget_if_missing

enable_bbr_if_needed() {
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        return 0
    fi

    echo -e "${YELLOW}正在开启 BBR 拥塞控制...${PLAIN}"
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1

    grep -qxF 'net.core.default_qdisc=fq' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}✓ BBR 已开启${PLAIN}"
}

enable_bbr_if_needed

fix_gcp_debian_sources() {(
    local product_name
    product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    [[ "$product_name" != *"Google"* ]] && return 0

    [ ! -f /etc/os-release ] && return 0
    . /etc/os-release
    [[ "$ID" != "debian" ]] && return 0

    local codename="$VERSION_CODENAME"
    [[ -z "$codename" ]] && return 0

    local components
    case "$codename" in
        bullseye)
            components="main contrib non-free"
            ;;
        bookworm|trixie)
            components="main contrib non-free non-free-firmware"
            ;;
        *)
            return 0
            ;;
    esac

    local source_file="/etc/apt/sources.list"
    [ -f /etc/apt/sources.list.d/debian.sources ] && source_file="/etc/apt/sources.list.d/debian.sources"
    if grep -q "mirrors.mit.edu" "$source_file" 2>/dev/null; then
        return 0
    fi

    echo -e "${YELLOW}检测到 GCP Debian ${VERSION_ID} (${codename}),正在配置教育网源...${PLAIN}"

    local format
    if [ -f /etc/apt/sources.list.d/debian.sources ] || [ "$codename" = "trixie" ]; then
        format="deb822"
        source_file="/etc/apt/sources.list.d/debian.sources"
        rm -f /etc/apt/sources.list
    else
        format="legacy"
        source_file="/etc/apt/sources.list"
        rm -f /etc/apt/sources.list.d/debian.sources
    fi

    if [ "$format" = "deb822" ]; then
        cat > "$source_file" <<GCPEOF
Types: deb
URIs: http://mirrors.mit.edu/debian
Suites: $codename ${codename}-updates ${codename}-backports
Components: $components
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://mirrors.ocf.berkeley.edu/debian-security
Suites: ${codename}-security
Components: $components
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
GCPEOF
    else
        cat > "$source_file" <<GCPEOF
deb http://mirrors.mit.edu/debian $codename $components
deb http://mirrors.mit.edu/debian ${codename}-updates $components
deb http://mirrors.mit.edu/debian ${codename}-backports $components
deb http://mirrors.ocf.berkeley.edu/debian-security ${codename}-security $components
GCPEOF
    fi

    rm -rf /var/lib/apt/lists/*
    apt clean 2>/dev/null
    echo -e "${GREEN}GCP 源配置完成 (MIT + Berkeley)${PLAIN}"
)}

linux_update() {
    clear
    echo -e "${YELLOW}正在更新系统...${PLAIN}"

    fix_gcp_debian_sources

    if ! pkg_update; then
        echo -e "${RED}未知的包管理器!${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${GREEN}系统更新完成${PLAIN}"
    press_any_key_to_continue
}

linux_clean() {
    clear
    echo -e "${YELLOW}正在清理系统垃圾...${PLAIN}"

    pkg_clean || echo -e "${RED}未知的包管理器!${PLAIN}"

    echo -e "${YELLOW}正在清理旧内核...${PLAIN}"
    local current_kernel
    current_kernel=$(uname -r)
    echo -e "${BLUE}当前运行内核: ${GREEN}${current_kernel}${PLAIN}"

    local pm old_kernels=""
    pm=$(detect_pkg_manager)

    case "$pm" in
        apt)
            old_kernels=$(dpkg -l | \
                grep -E '^ii|^rc' | \
                grep -E 'linux-(image|headers|modules)' | \
                awk '{print $2}' | \
                grep -E 'linux-(image|headers|modules)(-extra)?-[0-9]' | \
                grep -v "$current_kernel" \
                || true)
            if [ -n "$old_kernels" ]; then
                echo -e "${YELLOW}发现以下旧内核包:${PLAIN}"
                echo "$old_kernels"
                for pkg in $old_kernels; do
                    echo -e "  清理: $pkg"
                    if ! apt-get purge -y "$pkg" > /dev/null 2>&1; then
                        echo -e "  ${RED}警告: $pkg 清理失败${PLAIN}"
                    fi
                done
            else
                echo -e "${GREEN}无旧内核需要清理${PLAIN}"
            fi
            ;;
        dnf|yum)
            local installed_kernels keep_count=1
            installed_kernels=$(rpm -q kernel kernel-core kernel-modules 2>/dev/null | grep -v "not installed" | grep -v "$current_kernel" || true)
            if [ -n "$installed_kernels" ]; then
                echo -e "${YELLOW}发现以下旧内核包:${PLAIN}"
                echo "$installed_kernels"
                for pkg in $installed_kernels; do
                    echo -e "  清理: $pkg"
                    if ! $pm remove -y "$pkg" > /dev/null 2>&1; then
                        echo -e "  ${RED}警告: $pkg 清理失败${PLAIN}"
                    fi
                done
            else
                echo -e "${GREEN}无旧内核需要清理${PLAIN}"
            fi
            ;;
        pacman)
            local cached_kernels
            cached_kernels=$(ls /var/cache/pacman/pkg/linux-[0-9]* 2>/dev/null | grep -v "$(pacman -Q linux 2>/dev/null | awk '{print $2}')" || true)
            if [ -n "$cached_kernels" ]; then
                echo -e "${YELLOW}清理旧内核缓存...${PLAIN}"
                paccache -rk1 2>/dev/null
            else
                echo -e "${GREEN}无旧内核缓存需要清理${PLAIN}"
            fi
            ;;
        *)
            echo -e "${YELLOW}当前包管理器不支持自动清理旧内核,跳过${PLAIN}"
            ;;
    esac

    if [ -n "$old_kernels" ] || [ -n "${installed_kernels:-}" ]; then
        if command -v update-grub &>/dev/null; then
            echo -e "${YELLOW}正在更新GRUB引导...${PLAIN}"
            update-grub > /dev/null 2>&1
        elif command -v grub2-mkconfig &>/dev/null; then
            echo -e "${YELLOW}正在更新GRUB引导...${PLAIN}"
            grub2-mkconfig -o /boot/grub2/grub.cfg > /dev/null 2>&1
        fi
    fi

    if command -v docker &>/dev/null; then
        echo -e "${YELLOW}清理Docker垃圾...${PLAIN}"
        docker system prune -af
        docker volume prune -f
    fi

    echo -e "${YELLOW}正在清理系统日志...${PLAIN}"
    if command -v journalctl &>/dev/null; then
        journalctl --vacuum-time=1d --vacuum-size=10M
    fi
    find /var/log -type f -name "*.log" -mtime +1 -exec rm -f {} \;
    find /var/log -type f -name "*.gz" -mtime +1 -exec rm -f {} \;
    find /var/log -type f -name "*.1" -mtime +1 -exec rm -f {} \;

    echo -e "${YELLOW}正在清理临时目录...${PLAIN}"
    find /tmp -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null
    find /var/tmp -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null

    echo -e "${YELLOW}正在清理用户缓存...${PLAIN}"
    if [ -d "$HOME/.cache" ]; then
        rm -rf "$HOME/.cache/"*
    fi
    
    for uhome in /home/*/; do
        [ -d "$uhome/.cache" ] && rm -rf "$uhome/.cache/"*
    done

    echo -e "${GREEN}系统清理完成${PLAIN}"
    press_any_key_to_continue
}

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

        echo -e "${BLUE}==== 虚拟内存(Swap) ====${PLAIN}"
        echo -e "${YELLOW}物理内存: ${total_ram} MB${PLAIN}"
        echo -e "${YELLOW}当前Swap: ${current_swap} MB${PLAIN}"
        echo -e "${YELLOW}当前Swappiness: ${current_swappiness}${PLAIN}"
        echo -e "${BLUE}========================${PLAIN}"
        echo -e "${GREEN}1.设置Swap(推荐:${recommend_swap}MB)${PLAIN}"
        echo -e "${GREEN}2.设置Swap(自定义)${PLAIN}"
        echo -e "${GREEN}3.调整Swappiness策略${PLAIN}"
        echo -e "${RED}4.关闭Swap${PLAIN}"
        echo -e "${YELLOW}0.返回主菜单${PLAIN}"
        echo -e "${BLUE}========================${PLAIN}"
        
        read -p "$(echo -e "${BLUE}请输入选项 [0-4]: ${PLAIN}")" opt
        case "$opt" in
            1)
                set_swap "$recommend_swap"
                ;;
            2)
                read -rp "请输入 Swap 大小 (单位 MB,建议 >=128): " custom
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
    local avail_kb avail_mb root_fstype

    echo -e "${YELLOW}正在检查环境...${PLAIN}"
    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024))
    
    if (( avail_mb < size_mb + 500 )); then
        echo -e "${RED}磁盘空间不足!当前可用: ${avail_mb}MB, 需要: ${size_mb}MB (+预留500MB)${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    if grep -q "$swapfile_path" /proc/swaps 2>/dev/null; then
        echo -e "${YELLOW}发现已存在的 Swap,正在卸载...${PLAIN}"
        swapoff "$swapfile_path" 2>/dev/null || true
    fi
    rm -f "$swapfile_path"

    if ! sed -i "\|${swapfile_path}|d" /etc/fstab; then
        echo -e "${RED}清理 /etc/fstab 旧 Swap 条目失败${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${BLUE}正在创建 ${size_mb}MB 的 Swap 文件...${PLAIN}"

    root_fstype=$(df --output=fstype / | tail -1 | xargs)

    if [[ "$root_fstype" == "btrfs" || "$root_fstype" == "xfs" ]]; then
        echo -e "${YELLOW}检测到 ${root_fstype} 文件系统,使用 dd 创建 (请耐心等待)...${PLAIN}"
        if ! dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress; then
            echo -e "${RED}Swap 文件创建失败${PLAIN}"
            rm -f "$swapfile_path"
            press_any_key_to_continue
            return 1
        fi
    elif command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${size_mb}M" "$swapfile_path" 2>/dev/null; then
             echo -e "${YELLOW}fallocate 创建失败,尝试使用 dd 写零 (速度较慢,请耐心等待)...${PLAIN}"
             if ! dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress; then
                 echo -e "${RED}Swap 文件创建失败${PLAIN}"
                 rm -f "$swapfile_path"
                 press_any_key_to_continue
                 return 1
             fi
        fi
    else
        if ! dd if=/dev/zero of="$swapfile_path" bs=1M count="$size_mb" status=progress; then
            echo -e "${RED}Swap 文件创建失败${PLAIN}"
            rm -f "$swapfile_path"
            press_any_key_to_continue
            return 1
        fi
    fi

    if ! chmod 600 "$swapfile_path"; then
        echo -e "${RED}设置 Swap 文件权限失败${PLAIN}"
        rm -f "$swapfile_path"
        press_any_key_to_continue
        return 1
    fi

    if ! mkswap "$swapfile_path" >/dev/null; then
        echo -e "${RED}mkswap 失败,未启用 Swap${PLAIN}"
        rm -f "$swapfile_path"
        press_any_key_to_continue
        return 1
    fi

    if ! swapon "$swapfile_path"; then
        echo -e "${RED}swapon 失败,未启用 Swap${PLAIN}"
        rm -f "$swapfile_path"
        press_any_key_to_continue
        return 1
    fi

    if ! echo "$swapfile_path none swap sw 0 0" >> /etc/fstab; then
        echo -e "${YELLOW}Swap 已启用,但写入 /etc/fstab 失败,重启后不会自动挂载${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${GREEN}✓ Swap 设置成功!${PLAIN}"
    free -h
    press_any_key_to_continue
}

delete_swap() {
    if ! grep -q "$swapfile_path" /proc/swaps 2>/dev/null && [ ! -f "$swapfile_path" ]; then
        echo -e "${YELLOW}当前没有 Swap 文件,无需操作${PLAIN}"
        press_any_key_to_continue
        return 0
    fi
    echo -e "${YELLOW}正在删除 Swap...${PLAIN}"
    swapoff "$swapfile_path" 2>/dev/null || true
    rm -f "$swapfile_path"
    sed -i "\|${swapfile_path}|d" /etc/fstab
    echo -e "${GREEN}✓ Swap 已删除并关闭${PLAIN}"
    free -h
    press_any_key_to_continue
}

set_swappiness() {
    local current_val
    current_val=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    echo -e "当前 Swappiness: ${GREEN}${current_val}${PLAIN}"
    echo -e "数值范围 0-100.数值越低,越倾向于使用物理内存;数值越高,越倾向于使用 Swap。"
  
    read -rp "请输入新的 Swappiness 值 (0-100): " new_val
    if [[ "$new_val" =~ ^[0-9]+$ ]] && (( new_val >= 0 && new_val <= 100 )); then
        sysctl vm.swappiness="$new_val"
        
        if grep -q "^vm.swappiness" /etc/sysctl.conf; then
            sed -i "s/^vm.swappiness.*/vm.swappiness = $new_val/" /etc/sysctl.conf
        else
            echo "vm.swappiness = $new_val" | tee -a /etc/sysctl.conf >/dev/null
        fi
        
        echo -e "${GREEN}✓ 设置成功！${PLAIN}"
    else
        echo -e "${RED}输入无效${PLAIN}"
    fi
    press_any_key_to_continue
}

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
        local current_port
        current_port=$(get_sshd_option "Port" "22")
        [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=22
        echo -e "${YELLOW}当前SSH端口: ${GREEN}${current_port:-22}${PLAIN}\n"
        read -rp "$(echo -e "${BLUE}请输入新的SSH端口(输入0返回): ${PLAIN}")" new_port
        new_port=$(echo "$new_port" | xargs)
        if [[ "$new_port" == "0" ]]; then
            return
        fi
        if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )); then
            update_sshd_option "Port" "$new_port"
            
            if restart_sshd_safe; then
                echo -e "${YELLOW}[✓]SSH端口已修改为 $new_port${PLAIN}"
                press_any_key_to_continue
                return
            fi
        else
            echo "[!] 无效的端口格式"
            press_any_key_to_continue
        fi
    done
}

enable_or_change_root_password() {
    clear
    echo -e "${YELLOW}设置 Root 密码并启用密码登录${PLAIN}"
    echo
    read -rp "$(echo -e "${BLUE}按回车继续,输入0返回:${PLAIN}")" input
    input=$(echo "$input" | xargs)
    if [[ "$input" == "0" ]]; then
        return
    fi

    passwd root || { echo -e "${RED}密码设置失败${PLAIN}"; press_any_key_to_continue; return; }
    
    update_sshd_option "PermitRootLogin" "yes"
    update_sshd_option "PasswordAuthentication" "yes"
    
    if restart_sshd_safe; then
        echo -e "${GREEN}[✓]Root密码已设置,密码登录已启用${PLAIN}"
    fi
    press_any_key_to_continue
}

enable_root_key_login() {
    clear
    local SSH_DIR="$ROOT_HOME/.ssh"
    local AUTH_KEYS="$SSH_DIR/authorized_keys"
    local TMP_KEY="$SSH_DIR/id_ed25519"
    local TMP_PUB="$SSH_DIR/id_ed25519.pub"

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
        if ! ssh-keygen -t ed25519 -N "$key_passphrase" -f "$TMP_KEY"; then
            echo -e "${RED}密钥生成失败${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    else
        rm -f "$TMP_KEY" "$TMP_PUB"
        if ! ssh-keygen -t ed25519 -N "" -f "$TMP_KEY"; then
            echo -e "${RED}密钥生成失败${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    fi

    local PUB_CONTENT
    PUB_CONTENT=$(cat "$TMP_PUB")
    if ! grep -qxF "$PUB_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
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
        press_any_key_to_continue
        return 1
    fi

    echo -e "${YELLOW}私钥内容已显示并删除。请务必妥善保存！${PLAIN}"

    update_sshd_option "PermitRootLogin" "yes"
    update_sshd_option "PubkeyAuthentication" "yes"

    if restart_sshd_safe; then
        echo -e "${GREEN}root ed25519 密钥登录已配置完成。${PLAIN}"
    fi
    press_any_key_to_continue
}

disable_ssh_login_menu() {
    clear
    local has_password=0
    local has_pubkey=0
    local pass_auth pubkey_auth

    pass_auth=$(get_sshd_option "PasswordAuthentication" "yes")
    pubkey_auth=$(get_sshd_option "PubkeyAuthentication" "yes")

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
                update_sshd_option "PasswordAuthentication" "no"
                if restart_sshd_safe; then
                    echo -e "${GREEN}[✓]密码登录已关闭${PLAIN}"
                fi
            else
                echo -e "${YELLOW}密码登录本就已关闭,无需操作${PLAIN}"
            fi
            press_any_key_to_continue
            ;;
        2)
            if [[ $has_pubkey -eq 1 ]]; then
                update_sshd_option "PubkeyAuthentication" "no"
                if restart_sshd_safe; then
                    echo -e "${GREEN}[✓]密钥登录已关闭${PLAIN}"
                fi
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

change_timezone() {
    if ! command -v timedatectl >/dev/null; then
        echo -e "${RED}未安装 timedatectl,无法自动设置时区${PLAIN}"
        press_any_key_to_continue
        return
    fi
    
    if ! command -v curl >/dev/null; then
        echo -e "${YELLOW}未检测到 curl,正在自动安装...${PLAIN}"
        pkg_install curl
    fi

    echo -e "${YELLOW}正在检测当前网络推荐时区...${PLAIN}"
    local current_tz_web
    current_tz_web=$(curl -s --connect-timeout 5 https://ipapi.co/timezone)

    while true; do
        local sys_tz
        sys_tz=$(timedatectl 2>/dev/null | grep -i 'time zone' | awk '{print $3}')
        clear
        echo -e "${BLUE}========= 更改时区管理 ========${PLAIN}"
        echo -e "${YELLOW} 当前系统时区: ${GREEN}${sys_tz}${PLAIN}"
        echo -e "${YELLOW} 网络推荐时区: ${GREEN}${current_tz_web:-未知}${PLAIN}"
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e "${GREEN} 1.使用推荐时区 (${current_tz_web})${PLAIN}"
        echo -e "${GREEN} 2.按国家代码选择${PLAIN}"
        echo -e "${GREEN} 3.手动输入时区名称${PLAIN}"
        echo -e "${YELLOW} 0.返回主菜单${PLAIN}"
        echo -e "${BLUE}===============================${PLAIN}"
        
        read -p "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" choice
        choice=$(echo "$choice" | xargs)
        
        case "$choice" in
            1)
                if [ -n "$current_tz_web" ]; then
                    echo -e "${YELLOW}正在设置时区为 $current_tz_web ...${PLAIN}"
                    if timedatectl set-timezone "$current_tz_web"; then
                        echo -e "${GREEN}✔ 设置成功!当前时间: $(date)${PLAIN}"
                    else
                        echo -e "${RED}✘ 设置失败,请检查时区名称是否正确。${PLAIN}"
                    fi
                else
                    echo -e "${RED}如果是离线环境或API超时,无法获取推荐时区。${PLAIN}"
                fi
                press_any_key_to_continue
                ;;
            2)
                clear
                read -rp "$(echo -e "${BLUE}请输入国家代码 (如 CN,US,JP): ${PLAIN}")" input_code
                input_code=$(echo "$input_code" | tr a-z A-Z | xargs)
                [ -z "$input_code" ] && continue

                zone_tab="/usr/share/zoneinfo/zone1970.tab"
                [ ! -f "$zone_tab" ] && zone_tab="/usr/share/zoneinfo/zone.tab"

                if [ ! -f "$zone_tab" ]; then
                    echo -e "${RED}系统缺失时区索引文件 (zone1970.tab/zone.tab)，无法自动列表。${PLAIN}"
                    press_any_key_to_continue
                    continue
                fi

                mapfile -t lines < <(awk -v code="$input_code" '$1 == code {print $3}' "$zone_tab" | sort -u)
                
                if [ "${#lines[@]}" -eq 0 ]; then
                    echo -e "${RED}未找到代码 [$input_code] 对应的时区信息。${PLAIN}"
                    sleep 1
                    continue
                fi

                echo -e "${BLUE}=== [$input_code] 可选时区 ===${PLAIN}"
                for i in "${!lines[@]}"; do
                    echo -e "  ${GREEN}$((i+1)).${PLAIN} ${lines[$i]}"
                done
                echo -e "${BLUE}==========================${PLAIN}"
                
                read -rp "$(echo -e "${BLUE}请选择编号: ${PLAIN}")" tz_idx
                if [[ "$tz_idx" =~ ^[0-9]+$ ]] && [ "$tz_idx" -ge 1 ] && [ "$tz_idx" -le "${#lines[@]}" ]; then
                    sel_tz="${lines[$((tz_idx-1))]}"
                    echo -e "${YELLOW}正在设置时区为 $sel_tz ...${PLAIN}"
                    if timedatectl set-timezone "$sel_tz"; then
                        echo -e "${GREEN}✔ 设置成功！当前时间: $(date)${PLAIN}"
                    else
                        echo -e "${RED}设置失败。${PLAIN}"
                    fi
                else
                    echo -e "${RED}无效编号${PLAIN}"
                fi
                press_any_key_to_continue
                ;;
            3)
                read -rp "$(echo -e "${BLUE}请输入时区全称 (例: Asia/Shanghai): ${PLAIN}")" manual_tz
                if [ -n "$manual_tz" ]; then
                    if timedatectl set-timezone "$manual_tz" 2>/dev/null; then
                        echo -e "${GREEN}✔ 设置成功!当前时间: $(date)${PLAIN}"
                    else
                        echo -e "${RED}设置失败:${PLAIN}无效的时区名称"
                    fi
                fi
                press_any_key_to_continue
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                sleep 0.5
                ;;
        esac
    done
}

run_install_script() {
    bash <(curl -sL "$1")
}

install_acme()      { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/acme.sh"; }
install_snell()     { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/snell.sh"; }
install_mihomo()    { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/mihomo.sh"; }
install_hysteria()  { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/hysteria.sh"; }
install_system()    { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/Install.sh"; }
install_shoes()     { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/shoes.sh"; }
install_warp()      { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/warp.sh"; }
install_wireproxy() { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/wireproxy.sh"; }


dns_fix() {
    local RESOLV_CONF="/etc/resolv.conf"
    local RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
    local RESOLVED_DROPIN_FILE="$RESOLVED_DROPIN_DIR/99-custom-dns.conf"

    _dns_get_default_iface() {
        local iface
        iface="$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)"
        if [[ -z "$iface" ]]; then
            iface="$(ip -6 route show default 2>/dev/null | awk '{print $5}' | head -n1)"
        fi
        echo "$iface"
    }

    _dns_show_current() {
        echo -e "${YELLOW}当前DNS配置:${PLAIN}\n"

        echo -e "${BLUE}resolv.conf:${PLAIN}"
        if [[ -f "$RESOLV_CONF" ]]; then
            while read -r line; do
                [[ "$line" =~ ^nameserver ]] || continue
                echo -e "  ${GREEN}${line}${PLAIN}"
            done < "$RESOLV_CONF"
        else
            echo -e "  (不存在)"
        fi
        echo

        echo -e "${BLUE}systemd-resolved:${PLAIN}"
        if systemctl is-active systemd-resolved >/dev/null 2>&1; then
            local iface dns_list
            iface="$(_dns_get_default_iface)"
            if [[ -n "$iface" ]]; then
                echo -e "  默认网卡: ${GREEN}${iface}${PLAIN}"
                dns_list="$(resolvectl status "$iface" 2>/dev/null \
                    | awk '/DNS Servers:/ {for (i=3; i<=NF; i++) print $i}')"
                if [[ -n "$dns_list" ]]; then
                    echo -e "  DNS Servers:"
                    while read -r dns; do
                        echo -e "    ${GREEN}- ${dns}${PLAIN}"
                    done <<< "$dns_list"
                else
                    echo -e "  (systemd-resolved 未接管 DNS)"
                fi
            else
                echo -e "  (未检测到默认网卡)"
            fi
        else
            echo -e "  (systemd-resolved 未运行)"
        fi
        echo
    }

    _dns_is_valid_ipv4() {
        local ip="$1" IFS=.
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        read -r o1 o2 o3 o4 <<<"$ip"
        for o in "$o1" "$o2" "$o3" "$o4"; do
            [[ "$o" -ge 0 && "$o" -le 255 ]] 2>/dev/null || return 1
        done
        return 0
    }

    _dns_is_valid_ipv6() {
        local ip="$1"
        [[ "$ip" =~ ^[0-9A-Fa-f:%.]+$ ]] || return 1
        [[ "$ip" == *:* ]] || return 1
        [[ ${#ip} -le 80 ]] || return 1
        return 0
    }

    _dns_is_valid_ip() {
        local ip="$1"
        [[ "$ip" =~ [[:space:]] ]] && return 1
        [[ "$ip" == *\"* || "$ip" == *\'* || "$ip" == *\\* ]] && return 1
        _dns_is_valid_ipv4 "$ip" && return 0
        _dns_is_valid_ipv6 "$ip" && return 0
        return 1
    }

    _dns_unlock_resolv() {
        if command -v chattr >/dev/null 2>&1 && [[ -f "$RESOLV_CONF" ]]; then
            chattr -i "$RESOLV_CONF" 2>/dev/null || true
        fi
    }

    _dns_apply() {
        local dns_list=("$@")
        local ok=() bad=()

        for dns in "${dns_list[@]}"; do
            if _dns_is_valid_ip "$dns"; then
                ok+=("$dns")
            else
                bad+=("$dns")
            fi
        done
        dns_list=("${ok[@]}")

        if [[ ${#dns_list[@]} -eq 0 ]]; then
            echo -e "${RED}未检测到有效的DNS IP（请输入IPv4/IPv6地址）${PLAIN}"
            return 1
        fi
        if [[ ${#bad[@]} -gt 0 ]]; then
            echo -e "${YELLOW}已忽略无效DNS：${bad[*]}${PLAIN}"
        fi

        if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
            mkdir -p "$RESOLVED_DROPIN_DIR"
            {
                echo "[Resolve]"
                echo "DNS=${dns_list[*]}"
                echo "Domains=~."
            } > "$RESOLVED_DROPIN_FILE"

            systemctl restart systemd-resolved 2>/dev/null || true

            if command -v resolvectl >/dev/null 2>&1; then
                resolvectl flush-caches 2>/dev/null || true
                local iface
                iface="$(_dns_get_default_iface)"
                if [[ -n "$iface" ]]; then
                    resolvectl dns "$iface" "${dns_list[@]}" 2>/dev/null || true
                    resolvectl domain "$iface" "~." 2>/dev/null || true
                    resolvectl flush-caches 2>/dev/null || true
                fi
            fi

            if [[ ! -L "$RESOLV_CONF" ]]; then
                _dns_unlock_resolv
                {
                    for dns in "${dns_list[@]}"; do
                        echo "nameserver $dns"
                    done
                } > "$RESOLV_CONF" 2>/dev/null || true
            fi
        else
            if [[ -L "$RESOLV_CONF" ]]; then
                rm -f "$RESOLV_CONF" 2>/dev/null || true
            fi
            _dns_unlock_resolv
            {
                for dns in "${dns_list[@]}"; do
                    echo "nameserver $dns"
                done
            } > "$RESOLV_CONF" 2>/dev/null || true
        fi

        if command -v systemctl >/dev/null 2>&1; then
            for svc in nscd dnsmasq named; do
                systemctl is-active "$svc" >/dev/null 2>&1 && systemctl restart "$svc" >/dev/null 2>&1
            done
        fi
        return 0
    }

    while true; do
        clear
        echo -e "${BLUE}======== DNS 配置工具 ========${PLAIN}\n"
        _dns_show_current
        echo -e "${GREEN}1.${PLAIN}修改DNS为 ${GREEN}8.8.8.8${PLAIN} 和 ${GREEN}1.1.1.1${PLAIN}"
        echo -e "${GREEN}2.${PLAIN}自定义修改DNS"
        echo -e "${YELLOW}0.${PLAIN}返回主菜单"
        echo -e "${BLUE}==============================${PLAIN}"
        read -rp "$(echo -e "${BLUE}请输入选项 [0-2]: ${PLAIN}")" choice

        case "$choice" in
            1)
                if _dns_apply "8.8.8.8" "1.1.1.1"; then
                    echo -e "${GREEN}DNS已修改并立即生效${PLAIN}"
                else
                    echo -e "${RED}DNS修改失败${PLAIN}"
                fi
                press_any_key_to_continue
                ;;
            2)
                clear
                echo -e "\n${YELLOW}请输入DNS(每行一个,空行结束):${PLAIN}"
                local custom_dns=()
                while true; do
                    read -rp "> " dns
                    [[ -z "$dns" ]] && break
                    custom_dns+=("$dns")
                done

                if [[ ${#custom_dns[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}未输入DNS${PLAIN}"
                else
                    if _dns_apply "${custom_dns[@]}"; then
                        echo -e "${GREEN}DNS已修改并立即生效${PLAIN}"
                    else
                        echo -e "${RED}DNS修改失败${PLAIN}"
                    fi
                fi
                press_any_key_to_continue
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                sleep 0.5
                ;;
        esac
    done
}

reboot_vps() {
    echo "即将重启系统..."
    reboot
}

firewall_exec_quiet() {
    local cmd="$1"
    shift
    "$cmd" -w 3 "$@" >/dev/null 2>&1 && return 0
    "$cmd" "$@" >/dev/null 2>&1
}

firewall_exec() {
    local cmd="$1"
    shift
    local output

    if output=$("$cmd" -w 3 "$@" 2>&1); then
        return 0
    fi
    if output=$("$cmd" "$@" 2>&1); then
        return 0
    fi

    [[ -n "$output" ]] && echo -e "${RED}[!] ${cmd} $* 失败: ${output}${PLAIN}"
    return 1
}

firewall_supports_table() {
    local cmd="$1"
    local table="$2"
    command -v "$cmd" >/dev/null 2>&1 || return 1
    firewall_exec_quiet "$cmd" -t "$table" -S
}

firewall_chain_exists() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    firewall_exec_quiet "$cmd" -t "$table" -S "$chain"
}

firewall_ensure_chain() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    firewall_chain_exists "$cmd" "$table" "$chain" && return 0
    firewall_exec "$cmd" -t "$table" -N "$chain"
}

firewall_flush_chain() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    firewall_chain_exists "$cmd" "$table" "$chain" || return 0
    firewall_exec "$cmd" -t "$table" -F "$chain"
}

firewall_delete_chain() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    firewall_chain_exists "$cmd" "$table" "$chain" || return 0
    firewall_flush_chain "$cmd" "$table" "$chain" || return 1
    firewall_exec "$cmd" -t "$table" -X "$chain"
}

firewall_rule_exists() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    shift 3
    firewall_exec_quiet "$cmd" -t "$table" -C "$chain" "$@"
}

firewall_ensure_rule_absent() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    shift 3
    while firewall_rule_exists "$cmd" "$table" "$chain" "$@"; do
        firewall_exec "$cmd" -t "$table" -D "$chain" "$@" || return 1
    done
}

firewall_ensure_rule_present() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    shift 3
    firewall_rule_exists "$cmd" "$table" "$chain" "$@" && return 0
    firewall_exec "$cmd" -t "$table" -A "$chain" "$@"
}

firewall_ensure_rule_first() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    shift 3
    firewall_ensure_rule_absent "$cmd" "$table" "$chain" "$@" || return 1
    firewall_exec "$cmd" -t "$table" -I "$chain" 1 "$@"
}

firewall_has_rules() {
    local cmd="$1"
    local table="$2"
    local chain="$3"
    firewall_chain_exists "$cmd" "$table" "$chain" || return 1
    "$cmd" -t "$table" -S "$chain" 2>/dev/null | grep -q '^-A '
}

firewall_get_default_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$iface" ]] && iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
    echo "$iface"
}

firewall_install_tools() {
    local pm
    pm=$(detect_pkg_manager)

    case "$pm" in
        apt)    apt update && apt install -y iptables iproute2 ;;
        dnf)    dnf install -y iptables-services iproute ;;
        yum)    yum install -y iptables-services iproute ;;
        apk)    apk add iptables ip6tables iproute2 ;;
        pacman) pacman -Sy --noconfirm iptables iproute2 ;;
        zypper) zypper --non-interactive install iptables iproute2 ;;
        emerge) emerge --ask=n net-firewall/iptables sys-apps/iproute2 ;;
        *)      return 1 ;;
    esac
}

firewall_prepare_tools() {
    if command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}[!] 未检测到 iptables/ip6tables,正在尝试安装...${PLAIN}"
    if ! firewall_install_tools; then
        echo -e "${RED}[!] 无法自动安装防火墙工具,请手动安装 iptables/ip6tables${PLAIN}"
        return 1
    fi

    if ! command -v iptables >/dev/null 2>&1 && ! command -v ip6tables >/dev/null 2>&1; then
        echo -e "${RED}[!] 安装完成后仍未找到可用的防火墙工具${PLAIN}"
        return 1
    fi
}

firewall_write_restore_service() {
    mkdir -p "$FIREWALL_RULE_DIR" || return 1
    cat > "$ZERO_FIREWALL_SERVICE" <<EOF
[Unit]
Description=Restore Zero firewall rules
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -s "$FIREWALL_RULES_V4" ] && iptables-restore < "$FIREWALL_RULES_V4" || true; [ -s "$FIREWALL_RULES_V6" ] && ip6tables-restore < "$FIREWALL_RULES_V6" || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

firewall_setup_persistence() {
    mkdir -p "$FIREWALL_RULE_DIR" || return 1

    if command -v systemctl >/dev/null 2>&1; then
        firewall_write_restore_service || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable "$ZERO_FIREWALL_SERVICE_NAME" >/dev/null 2>&1 || return 1
        return 0
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        return 0
    fi

    if command -v service >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

firewall_save_rules() {
    local persistence_ok=0
    local legacy_saved=0

    mkdir -p "$FIREWALL_RULE_DIR" || {
        echo -e "${RED}[!] 无法创建规则保存目录: $FIREWALL_RULE_DIR${PLAIN}"
        return 1
    }

    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$FIREWALL_RULES_V4" 2>/dev/null || {
            echo -e "${RED}[!] 保存 IPv4 规则失败${PLAIN}"
            return 1
        }
    fi

    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$FIREWALL_RULES_V6" 2>/dev/null || {
            echo -e "${RED}[!] 保存 IPv6 规则失败${PLAIN}"
            return 1
        }
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if firewall_setup_persistence; then
            persistence_ok=1
        else
            echo -e "${RED}[!] 无法启用 systemd 防火墙自恢复服务${PLAIN}"
        fi
    elif command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            persistence_ok=1
        else
            echo -e "${RED}[!] netfilter-persistent 保存失败${PLAIN}"
        fi
    elif command -v service >/dev/null 2>&1; then
        service iptables save >/dev/null 2>&1 && legacy_saved=1
        service ip6tables save >/dev/null 2>&1 && legacy_saved=1
        (( legacy_saved == 1 )) && persistence_ok=1
        if (( legacy_saved == 0 )); then
            echo -e "${YELLOW}[!] 已写入规则文件,但当前系统未检测到可用的 service 持久化入口${PLAIN}"
        fi
    fi

    if (( persistence_ok == 0 )); then
        echo -e "${YELLOW}[!] 规则当前已生效,并已保存到 ${FIREWALL_RULE_DIR},但重启后的自动恢复未完全确认${PLAIN}"
        return 1
    fi

    return 0
}

firewall_create_backup() {
    local v4_backup=""
    local v6_backup=""
    local created=0

    if command -v iptables >/dev/null 2>&1 && ! command -v iptables-save >/dev/null 2>&1; then
        return 1
    fi

    if command -v ip6tables >/dev/null 2>&1 && ! command -v ip6tables-save >/dev/null 2>&1; then
        return 1
    fi

    if command -v iptables-save >/dev/null 2>&1; then
        v4_backup=$(mktemp /tmp/zero-fw-v4.XXXXXX) || return 1
        iptables-save > "$v4_backup" 2>/dev/null || {
            rm -f "$v4_backup"
            return 1
        }
        created=1
    fi

    if command -v ip6tables-save >/dev/null 2>&1; then
        v6_backup=$(mktemp /tmp/zero-fw-v6.XXXXXX) || {
            rm -f "$v4_backup"
            return 1
        }
        ip6tables-save > "$v6_backup" 2>/dev/null || {
            rm -f "$v4_backup" "$v6_backup"
            return 1
        }
        created=1
    fi

    (( created == 1 )) || return 1
    echo "${v4_backup}|${v6_backup}"
}

firewall_restore_backup() {
    local backup="$1"
    local v4_backup=""
    local v6_backup=""
    local restored=0

    IFS='|' read -r v4_backup v6_backup <<< "$backup"

    if [[ -n "$v4_backup" && -f "$v4_backup" ]]; then
        command -v iptables-restore >/dev/null 2>&1 || return 1
        iptables-restore < "$v4_backup" >/dev/null 2>&1 || return 1
        restored=1
    fi

    if [[ -n "$v6_backup" && -f "$v6_backup" ]]; then
        command -v ip6tables-restore >/dev/null 2>&1 || return 1
        ip6tables-restore < "$v6_backup" >/dev/null 2>&1 || return 1
        restored=1
    fi

    (( restored == 1 ))
}

firewall_remove_backup() {
    local backup="$1"
    local v4_backup=""
    local v6_backup=""

    IFS='|' read -r v4_backup v6_backup <<< "$backup"
    rm -f "$v4_backup" "$v6_backup"
}

firewall_get_ssh_port() {
    local port
    port=$(get_sshd_option "Port" "22")
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    echo "$port"
}

firewall_prepare_input_chain_for_cmd() {
    local cmd="$1"
    firewall_supports_table "$cmd" filter || return 1
    firewall_ensure_chain "$cmd" filter "$ZERO_FW_CHAIN" || return 1
    firewall_ensure_rule_absent "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || return 1
    firewall_exec "$cmd" -t filter -I INPUT 1 -j "$ZERO_FW_CHAIN"
}

firewall_prepare_nat_chain_for_cmd() {
    local cmd="$1"
    firewall_supports_table "$cmd" nat || return 1
    firewall_ensure_chain "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" || return 1
    firewall_ensure_rule_absent "$cmd" nat PREROUTING -j "$ZERO_PORT_JUMP_CHAIN" || return 1
    firewall_exec "$cmd" -t nat -I PREROUTING 1 -j "$ZERO_PORT_JUMP_CHAIN"
}

firewall_protocol_label() {
    case "$1" in
        tcp)  echo "TCP" ;;
        udp)  echo "UDP" ;;
        *)    echo "$1" ;;
    esac
}

firewall_scope_suffix() {
    case "$1" in
        v4) echo " [仅IPv4]" ;;
        v6) echo " [仅IPv6]" ;;
        *)  echo "" ;;
    esac
}

firewall_should_hide_rule_in_view() {
    local chain="$1"
    local rule="$2"

    case "$chain" in
        "$ZERO_FW_CHAIN")
            [[ "$rule" == *"-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"* ]] && return 0
            [[ "$rule" == *"-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"* ]] && return 0
            [[ "$rule" == *"-i lo -j ACCEPT"* ]] && return 0
            [[ "$rule" == *"-p ipv6-icmp -j ACCEPT"* ]] && return 0
            ;;
    esac

    return 1
}

firewall_hook_scope() {
    local table="$1"
    local parent_chain="$2"
    local target_chain="$3"
    local has_v4=0
    local has_v6=0

    firewall_rule_exists "iptables" "$table" "$parent_chain" -j "$target_chain" && has_v4=1
    firewall_rule_exists "ip6tables" "$table" "$parent_chain" -j "$target_chain" && has_v6=1

    if (( has_v4 == 1 && has_v6 == 1 )); then
        echo "v4/v6"
    elif (( has_v4 == 1 )); then
        echo "仅IPv4"
    elif (( has_v6 == 1 )); then
        echo "仅IPv6"
    else
        echo "未挂载"
    fi
}

firewall_humanize_rule() {
    local chain="$1"
    local rule="$2"
    local target=""
    local proto=""
    local dport=""
    local iface=""
    local to_ports=""

    [[ "$rule" =~ -j[[:space:]]+([^[:space:]]+) ]] && target="${BASH_REMATCH[1]}"
    [[ "$rule" =~ -p[[:space:]]+([^[:space:]]+) ]] && proto="${BASH_REMATCH[1]}"
    [[ "$rule" =~ --dport[[:space:]]+([^[:space:]]+) ]] && dport="${BASH_REMATCH[1]}"
    [[ "$rule" =~ -i[[:space:]]+([^[:space:]]+) ]] && iface="${BASH_REMATCH[1]}"
    [[ "$rule" =~ --to-ports[[:space:]]+([^[:space:]]+) ]] && to_ports="${BASH_REMATCH[1]}"

    case "$chain" in
        "$ZERO_FW_CHAIN")
            if [[ "$rule" == *"-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"* ]] || [[ "$rule" == *"-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"* ]]; then
                echo "放行 已建立连接"
                return
            fi
            if [[ "$rule" == *"-i lo -j ACCEPT"* ]]; then
                echo "放行 本地回环"
                return
            fi
            if [[ "$rule" == *"-p ipv6-icmp -j ACCEPT"* ]]; then
                echo "放行 IPv6 ICMP"
                return
            fi
            if [[ "$rule" == "-j DROP" ]]; then
                echo "阻断 其他流量"
                return
            fi
            if [[ -n "$target" && -n "$proto" && -n "$dport" ]]; then
                case "$target" in
                    ACCEPT) echo "放行 $(firewall_protocol_label "$proto") ${dport}" ;;
                    DROP)   echo "阻断 $(firewall_protocol_label "$proto") ${dport}" ;;
                    *)      echo "${target} $(firewall_protocol_label "$proto") ${dport}" ;;
                esac
                return
            fi
            ;;
        "$ZERO_PORT_JUMP_CHAIN")
            if [[ "$target" == "REDIRECT" && -n "$proto" && -n "$dport" && -n "$to_ports" ]]; then
                if [[ -n "$iface" ]]; then
                    echo "跳跃 $(firewall_protocol_label "$proto") ${dport} -> ${to_ports} (${iface})"
                else
                    echo "跳跃 $(firewall_protocol_label "$proto") ${dport} -> ${to_ports}"
                fi
                return
            fi
            ;;
    esac

    echo "$rule"
}

firewall_compact_rendered_lines() {
    local chain="$1"
    local scope rule proto port target action
    local -a order_types order_values raw_lines group_scopes group_actions group_ports group_tcp group_udp
    local order_count=0
    local raw_count=0
    local group_count=0
    local found_index
    local i

    if [[ "$chain" != "$ZERO_FW_CHAIN" ]]; then
        cat
        return 0
    fi

    while IFS=$'\t' read -r scope rule; do
        [[ -z "$scope" ]] && continue

        proto=""
        port=""
        target=""
        action=""

        if [[ "$rule" =~ -p[[:space:]]+(tcp|udp) ]]; then
            proto="${BASH_REMATCH[1]}"
        fi
        if [[ "$rule" =~ --dport[[:space:]]+([^[:space:]]+) ]]; then
            port="${BASH_REMATCH[1]}"
        fi
        if [[ "$rule" =~ -j[[:space:]]+(ACCEPT|DROP) ]]; then
            target="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$proto" && -n "$port" && -n "$target" ]]; then
            proto=$(firewall_protocol_label "$proto")
            if [[ "$target" == "ACCEPT" ]]; then
                action="放行"
            else
                action="阻断"
            fi

            found_index=-1
            for (( i=0; i<group_count; i++ )); do
                if [[ "${group_scopes[i]}" == "$scope" && "${group_actions[i]}" == "$action" && "${group_ports[i]}" == "$port" ]]; then
                    found_index=$i
                    break
                fi
            done

            if (( found_index < 0 )); then
                found_index=$group_count
                group_scopes[group_count]="$scope"
                group_actions[group_count]="$action"
                group_ports[group_count]="$port"
                group_tcp[group_count]=0
                group_udp[group_count]=0
                order_types[order_count]="group"
                order_values[order_count]="$group_count"
                ((order_count++))
                ((group_count++))
            fi

            if [[ "$proto" == "TCP" ]]; then
                group_tcp[found_index]=1
            elif [[ "$proto" == "UDP" ]]; then
                group_udp[found_index]=1
            fi

            continue
        fi

        raw_lines[raw_count]="${scope}"$'\t'"${rule}"
        order_types[order_count]="line"
        order_values[order_count]="$raw_count"
        ((order_count++))
        ((raw_count++))
    done

    for (( i=0; i<order_count; i++ )); do
        if [[ "${order_types[i]}" == "line" ]]; then
            printf '%s\n' "${raw_lines[${order_values[i]}]}"
            continue
        fi

        local group_index="${order_values[i]}"
        local proto_label="UDP"

        if (( ${group_tcp[group_index]:-0} == 1 && ${group_udp[group_index]:-0} == 1 )); then
            proto_label="TCP+UDP"
        elif (( ${group_tcp[group_index]:-0} == 1 )); then
            proto_label="TCP"
        fi

        printf '%s\tDISPLAY:%s %s %s\n' \
            "${group_scopes[group_index]}" \
            "${group_actions[group_index]}" \
            "$proto_label" \
            "${group_ports[group_index]}"
    done
}

firewall_render_merged_chain() {
    local table="$1"
    local chain="$2"
    local title="$3"
    local rendered=""
    local displayed=0

    rendered=$(
        {
            if firewall_has_rules "iptables" "$table" "$chain"; then
                iptables -t "$table" -S "$chain" 2>/dev/null | sed -n "s/^-A ${chain} /v4 /p"
            fi
            if firewall_has_rules "ip6tables" "$table" "$chain"; then
                ip6tables -t "$table" -S "$chain" 2>/dev/null | sed -n "s/^-A ${chain} /v6 /p"
            fi
        } | awk '
            function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
            {
                ver=$1
                $1=""
                rule=trim($0)
                if (!(rule in idx)) {
                    idx[rule]=++count
                    order[count]=rule
                }
                if (ver=="v4") seen4[rule]=1
                if (ver=="v6") seen6[rule]=1
            }
            END {
                for (i=1; i<=count; i++) {
                    rule=order[i]
                    if (seen4[rule] && seen6[rule]) scope="both"
                    else if (seen4[rule]) scope="v4"
                    else scope="v6"
                    printf "%s\t%s\n", scope, rule
                }
            }
        '
    )
    rendered=$(printf '%s\n' "$rendered" | firewall_compact_rendered_lines "$chain")

    echo -e "${YELLOW}${title}:${PLAIN}"
    if [[ -z "$rendered" ]]; then
        if firewall_chain_exists "iptables" "$table" "$chain" || firewall_chain_exists "ip6tables" "$table" "$chain"; then
            echo "  (空)"
        else
            echo "  (未创建)"
        fi
        return
    fi

    while IFS=$'\t' read -r scope rule; do
        [[ -z "$scope" ]] && continue
        firewall_should_hide_rule_in_view "$chain" "$rule" && continue
        displayed=1
        if [[ "$rule" == DISPLAY:* ]]; then
            echo "  - ${rule#DISPLAY:}$(firewall_scope_suffix "$scope")"
        else
            echo "  - $(firewall_humanize_rule "$chain" "$rule")$(firewall_scope_suffix "$scope")"
        fi
    done <<< "$rendered"

    if (( displayed == 0 )); then
        echo "  (无自定义规则)"
    fi
}

port_jump_legacy_rules() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || return 0
    firewall_supports_table "$cmd" nat || return 0
    "$cmd" -t nat -S PREROUTING 2>/dev/null | grep -E '^-A PREROUTING .* -j REDIRECT --to-ports '
}

port_jump_has_legacy_rules() {
    local cmd="$1"
    [[ -n "$(port_jump_legacy_rules "$cmd")" ]]
}

list_firewall_rules() {
    local jump_summary="不支持"

    clear
    echo -e "${BLUE}=================== 防火墙规则详情 ===================${PLAIN}"
    if firewall_supports_table "iptables" nat || firewall_supports_table "ip6tables" nat; then
        jump_summary=$(firewall_hook_scope nat PREROUTING "$ZERO_PORT_JUMP_CHAIN")
    fi

    echo -e "${YELLOW}状态:${PLAIN} 入站管理=$(firewall_hook_scope filter INPUT "$ZERO_FW_CHAIN")  |  端口跳跃=${jump_summary}"
    firewall_render_merged_chain filter "$ZERO_FW_CHAIN" "端口规则"

    if firewall_supports_table "iptables" nat || firewall_supports_table "ip6tables" nat; then
        firewall_render_merged_chain nat "$ZERO_PORT_JUMP_CHAIN" "端口跳跃"

        if port_jump_has_legacy_rules "iptables" || port_jump_has_legacy_rules "ip6tables"; then
            echo -e "${YELLOW}旧版直连 REDIRECT 规则:${PLAIN}"
            port_jump_legacy_rules "iptables"
            port_jump_legacy_rules "ip6tables"
        fi
    fi

    echo -e "${BLUE}======================================================${PLAIN}"
}

firewall_apply_port_rule() {
    local cmd="$1"
    local action="$2"
    local proto="$3"
    local port_spec="$4"

    firewall_prepare_input_chain_for_cmd "$cmd" || return 1

    if [[ "$action" == "open" ]]; then
        firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -p "$proto" --dport "$port_spec" -j DROP || return 1
        firewall_ensure_rule_first "$cmd" filter "$ZERO_FW_CHAIN" -p "$proto" --dport "$port_spec" -j ACCEPT
    else
        firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -p "$proto" --dport "$port_spec" -j ACCEPT || return 1
        firewall_ensure_rule_first "$cmd" filter "$ZERO_FW_CHAIN" -p "$proto" --dport "$port_spec" -j DROP
    fi
}

firewall_clear_managed_rules() {
    local cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        firewall_prepare_input_chain_for_cmd "$cmd" || return 1
        firewall_flush_chain "$cmd" filter "$ZERO_FW_CHAIN" || return 1
    done
}

firewall_lockdown_all() {
    local current_ssh_port="$1"
    local cmd
    local active=0

    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        active=1
        firewall_prepare_input_chain_for_cmd "$cmd" || return 1
        firewall_flush_chain "$cmd" filter "$ZERO_FW_CHAIN" || return 1
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -i lo -j ACCEPT || return 1
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -p tcp --dport "$current_ssh_port" -j ACCEPT || return 1
        if [[ "$cmd" == "ip6tables" ]]; then
            firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -p ipv6-icmp -j ACCEPT || return 1
        fi
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -j DROP || return 1
    done

    (( active == 1 ))
}

port_jump_has_managed_config() {
    local cmd
    for cmd in iptables ip6tables; do
        firewall_has_rules "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" && return 0
    done
    return 1
}

port_jump_clear_managed_rules() {
    local cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" nat || continue
        firewall_ensure_rule_absent "$cmd" nat PREROUTING -j "$ZERO_PORT_JUMP_CHAIN" || return 1
        firewall_delete_chain "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" || return 1
    done
}

port_jump_view() {
    clear
    echo -e "${BLUE}=================== 端口跳跃状态 ===================${PLAIN}\n"
    echo -e "${YELLOW}状态:${PLAIN} 端口跳跃=$(firewall_hook_scope nat PREROUTING "$ZERO_PORT_JUMP_CHAIN")"
    firewall_render_merged_chain nat "$ZERO_PORT_JUMP_CHAIN" "端口跳跃"
    if port_jump_has_legacy_rules "iptables" || port_jump_has_legacy_rules "ip6tables"; then
        echo -e "${YELLOW}旧版直连 REDIRECT 规则:${PLAIN}"
        port_jump_legacy_rules "iptables"
        port_jump_legacy_rules "ip6tables"
    fi
    echo -e "${BLUE}====================================================${PLAIN}"
    press_any_key_to_continue
}

port_jump_set() {
    local mode="${1:-create}"
    local backup=""

    clear
    echo -e "${BLUE}检查 iptables/ip6tables 是否已安装...${PLAIN}"
    firewall_prepare_tools || {
        press_any_key_to_continue
        return 1
    }

    if [[ "$mode" != "overwrite" ]] && port_jump_has_managed_config; then
        echo -e "${YELLOW}已检测到当前脚本管理的端口跳跃规则,请先使用“修改跳跃”或“删除跳跃”${PLAIN}"
        press_any_key_to_continue
        return 0
    fi

    if port_jump_has_legacy_rules "iptables" || port_jump_has_legacy_rules "ip6tables"; then
        echo -e "${YELLOW}检测到旧版直连 PREROUTING REDIRECT 规则。${PLAIN}"
        echo -e "${YELLOW}为避免误删其他 NAT 规则,当前版本只管理本脚本创建的端口跳跃链,请先手动清理旧规则。${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local interface
    interface=$(firewall_get_default_iface)
    if [[ -z "$interface" ]]; then
        echo -e "${RED}未检测到有效网卡,请检查网络配置${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local user_interface
    read -rp "$(echo -e "${YELLOW}请输入网卡名称(默认:${interface}): ${PLAIN}")" user_interface
    user_interface=${user_interface:-$interface}
    if ! ip link show "$user_interface" >/dev/null 2>&1; then
        echo -e "${RED}网卡 ${user_interface} 不存在${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local port_range start_port end_port
    read -rp "$(echo -e "${YELLOW}请输入 UDP 端口范围(默认18443:28444): ${PLAIN}")" port_range
    port_range=${port_range:-18443:28444}
    if [[ "$port_range" =~ ^([0-9]+):([0-9]+)$ ]]; then
        start_port=${BASH_REMATCH[1]}
        end_port=${BASH_REMATCH[2]}
    else
        echo -e "${RED}端口范围格式错误,请使用 start:end${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    if (( start_port < 1 || end_port > 65535 || start_port > end_port )); then
        echo -e "${RED}无效端口范围,必须在 1-65535 且起始不大于结束${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local target_port
    read -rp "$(echo -e "${YELLOW}请输入目标 UDP 端口: ${PLAIN}")" target_port
    if ! [[ "$target_port" =~ ^[0-9]+$ ]] || (( target_port < 1 || target_port > 65535 )); then
        echo -e "${RED}无效的目标端口,请输入 1-65535${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local need_v4=0 need_v6=0 ok_v4=0 ok_v6=0
    firewall_supports_table "iptables" nat && need_v4=1
    firewall_supports_table "ip6tables" nat && need_v6=1
    if (( need_v4 == 0 && need_v6 == 0 )); then
        echo -e "${RED}当前系统未检测到可用的 NAT 表,无法设置端口跳跃${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    backup=$(firewall_create_backup) || {
        echo -e "${RED}创建防火墙备份失败,已取消本次修改${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    if (( need_v4 == 1 )); then
        firewall_prepare_nat_chain_for_cmd "iptables" &&
        firewall_flush_chain "iptables" nat "$ZERO_PORT_JUMP_CHAIN" &&
        firewall_ensure_rule_present "iptables" nat "$ZERO_PORT_JUMP_CHAIN" -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" &&
        ok_v4=1
    fi

    if (( need_v6 == 1 )); then
        firewall_prepare_nat_chain_for_cmd "ip6tables" &&
        firewall_flush_chain "ip6tables" nat "$ZERO_PORT_JUMP_CHAIN" &&
        firewall_ensure_rule_present "ip6tables" nat "$ZERO_PORT_JUMP_CHAIN" -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" &&
        ok_v6=1
    fi

    if (( (need_v4 == 1 && ok_v4 == 0) || (need_v6 == 1 && ok_v6 == 0) )); then
        echo -e "${RED}端口跳跃规则未能完整写入,正在回滚本次修改...${PLAIN}"
        if firewall_restore_backup "$backup"; then
            firewall_save_rules >/dev/null 2>&1 || true
            echo -e "${YELLOW}已恢复到修改前的端口跳跃状态${PLAIN}"
        else
            echo -e "${RED}回滚失败,请手动检查当前 NAT 规则${PLAIN}"
        fi
        firewall_remove_backup "$backup"
        press_any_key_to_continue
        return 1
    fi

    firewall_save_rules || true
    firewall_remove_backup "$backup"
    echo -e "${GREEN}端口跳跃规则已写入: ${user_interface} ${port_range} -> ${target_port}/udp${PLAIN}"
    port_jump_view
}

port_jump_modify() {
    clear
    if ! port_jump_has_managed_config; then
        echo -e "${YELLOW}当前没有由本脚本管理的端口跳跃规则${PLAIN}"
        press_any_key_to_continue
        return 0
    fi

    port_jump_set overwrite
}

port_jump_delete() {
    local backup=""

    clear
    if ! port_jump_has_managed_config; then
        echo -e "${YELLOW}当前没有由本脚本管理的端口跳跃规则${PLAIN}"
        if port_jump_has_legacy_rules "iptables" || port_jump_has_legacy_rules "ip6tables"; then
            echo -e "${YELLOW}检测到旧版直连 REDIRECT 规则,请手动清理 PREROUTING 中的对应条目${PLAIN}"
        fi
        press_any_key_to_continue
        return 0
    fi

    backup=$(firewall_create_backup) || {
        echo -e "${RED}创建防火墙备份失败,已取消删除${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    echo -e "${BLUE}正在删除端口跳跃规则...${PLAIN}"
    if ! port_jump_clear_managed_rules; then
        echo -e "${RED}删除端口跳跃规则失败${PLAIN}"
        if firewall_restore_backup "$backup"; then
            firewall_save_rules >/dev/null 2>&1 || true
            echo -e "${YELLOW}已恢复删除前的端口跳跃状态${PLAIN}"
        else
            echo -e "${RED}回滚失败,请手动检查 NAT 规则${PLAIN}"
        fi
        firewall_remove_backup "$backup"
        press_any_key_to_continue
        return 1
    fi

    firewall_save_rules || true
    firewall_remove_backup "$backup"
    echo -e "${GREEN}端口跳跃配置已删除${PLAIN}"
    press_any_key_to_continue
}

port_jump_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Ports Jump ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}设置跳跃"
        echo -e "${GREEN}  2.${PLAIN}修改跳跃"
        echo -e "${GREEN}  3.${PLAIN}查看跳跃"
        echo -e "${GREEN}  4.${PLAIN}删除跳跃"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        read -rp "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" pjopt

        case "$pjopt" in
            1) port_jump_set ;;
            2) port_jump_modify ;;
            3) port_jump_view ;;
            4) port_jump_delete ;;
            0) break ;;
            *) echo -e "${RED}无效选项,请重新输入${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

configure_firewall() {
    if ! firewall_prepare_tools; then
        press_any_key_to_continue
        return 1
    fi

    if ! firewall_prepare_input_chain_for_cmd "iptables" 2>/dev/null && ! firewall_prepare_input_chain_for_cmd "ip6tables" 2>/dev/null; then
        echo -e "${RED}[!] 无法初始化防火墙管理链${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    firewall_setup_persistence || true

    while true; do
        local current_ssh_port
        local has_iptables=false
        local has_ip6tables=false

        firewall_supports_table "iptables" filter && has_iptables=true
        firewall_supports_table "ip6tables" filter && has_ip6tables=true
        current_ssh_port=$(firewall_get_ssh_port)

        clear
        echo -e "${BLUE}===== iptables 防火墙管理 =====${PLAIN}"
        echo -e "${BLUE}SSH端口:  ${YELLOW}${current_ssh_port}${PLAIN}"
        if [[ "$has_iptables" != "true" || "$has_ip6tables" != "true" ]]; then
            if [[ "$has_iptables" == "true" && "$has_ip6tables" != "true" ]]; then
                echo -e "${YELLOW}当前仅支持 IPv4，规则将只写入 IPv4${PLAIN}"
            elif [[ "$has_iptables" != "true" && "$has_ip6tables" == "true" ]]; then
                echo -e "${YELLOW}当前仅支持 IPv6，规则将只写入 IPv6${PLAIN}"
            else
                echo -e "${RED}未检测到可用的 iptables/ip6tables，部分功能可能不可用${PLAIN}"
            fi
        fi
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e "${GREEN}1.放行端口${PLAIN}"
        echo -e "${RED}2.阻断端口${PLAIN}"
        echo -e "${GREEN}3.清空规则${PLAIN}"
        echo -e "${RED}4.仅放行SSH${PLAIN}"
        echo -e "${BLUE}5.查看当前规则${PLAIN}"
        echo -e "${GREEN}6.配置端口跳跃${PLAIN}"
        echo -e "${YELLOW}0.返回主菜单${PLAIN}"
        echo -e "${BLUE}===============================${PLAIN}"
        read -rp "$(echo -e "${BLUE}请输入选项 [0-6]: ${PLAIN}")" action_choice
        action_choice=$(echo "$action_choice" | xargs)

        [[ "$action_choice" == "0" ]] && return
        case "$action_choice" in
            1|2)
                local input_ports protocol_label action_failed port_range start_port end_port port_spec backup
                protocol_label="TCP+UDP"

                read -rp "请输入端口（如 443 或 1000-2000，可空格分隔多个）: " input_ports
                action_failed=0
                backup=$(firewall_create_backup) || {
                    echo -e "${RED}创建防火墙备份失败,已取消本次操作${PLAIN}"
                    press_any_key_to_continue
                    continue
                }

                for port_range in $input_ports; do
                    local port_failed=0
                    if [[ "$port_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start_port=${BASH_REMATCH[1]}
                        end_port=${BASH_REMATCH[2]}
                    elif [[ "$port_range" =~ ^([0-9]+)$ ]]; then
                        start_port=$port_range
                        end_port=$port_range
                    else
                        echo -e "${RED}[!] 无效端口格式: $port_range${PLAIN}"
                        action_failed=1
                        continue
                    fi

                    if (( start_port < 1 || end_port > 65535 || start_port > end_port )); then
                        echo -e "${RED}[!] 端口范围无效: $port_range (必须 1-65535 且起始≤结束)${PLAIN}"
                        action_failed=1
                        continue
                    fi

                    if (( start_port == end_port )); then
                        port_spec="$start_port"
                    else
                        port_spec="$start_port:$end_port"
                    fi

                    local proto cmd
                    for proto in tcp udp; do
                        if [[ "$action_choice" == "2" && "$proto" == "tcp" && "$start_port" -le "$current_ssh_port" && "$end_port" -ge "$current_ssh_port" ]]; then
                            echo -e "${YELLOW}[!] 跳过 TCP ${port_range}: 不能阻断当前 SSH 端口 ${current_ssh_port}${PLAIN}"
                            continue
                        fi

                        for cmd in iptables ip6tables; do
                            firewall_supports_table "$cmd" filter || continue
                            if [[ "$action_choice" == "1" ]]; then
                                firewall_apply_port_rule "$cmd" "open" "$proto" "$port_spec" || {
                                    action_failed=1
                                    port_failed=1
                                }
                            else
                                firewall_apply_port_rule "$cmd" "close" "$proto" "$port_spec" || {
                                    action_failed=1
                                    port_failed=1
                                }
                            fi
                        done
                    done

                    if (( port_failed == 0 )); then
                        if [[ "$action_choice" == "1" ]]; then
                            echo -e "${GREEN}[✓] 端口 $port_range 已按 ${protocol_label} 规则放行${PLAIN}"
                        else
                            echo -e "${RED}[✓] 端口 $port_range 已按 ${protocol_label} 规则阻断${PLAIN}"
                        fi
                    else
                        echo -e "${YELLOW}[!] 端口 $port_range 的部分规则写入失败,请查看当前规则${PLAIN}"
                    fi
                done

                if (( action_failed == 0 )); then
                    firewall_save_rules || true
                else
                    if firewall_restore_backup "$backup"; then
                        firewall_save_rules >/dev/null 2>&1 || true
                        echo -e "${YELLOW}[!] 本次操作存在失败项,已回滚到修改前状态${PLAIN}"
                    else
                        echo -e "${RED}[!] 本次操作存在失败项,且回滚失败,请立即检查规则${PLAIN}"
                    fi
                fi
                firewall_remove_backup "$backup"
                press_any_key_to_continue
                ;;
            3)
                local backup
                backup=$(firewall_create_backup) || {
                    echo -e "${RED}创建防火墙备份失败,已取消清空${PLAIN}"
                    press_any_key_to_continue
                    continue
                }
                if firewall_clear_managed_rules; then
                    firewall_save_rules || true
                    echo -e "${GREEN}[✓] 已清空本脚本管理的规则,不再改动系统原有 INPUT/FORWARD/OUTPUT 策略${PLAIN}"
                else
                    echo -e "${RED}[!] 清空规则失败${PLAIN}"
                    if firewall_restore_backup "$backup"; then
                        firewall_save_rules >/dev/null 2>&1 || true
                        echo -e "${YELLOW}已恢复到清空前的状态${PLAIN}"
                    else
                        echo -e "${RED}回滚失败,请手动检查当前规则${PLAIN}"
                    fi
                fi
                firewall_remove_backup "$backup"
                press_any_key_to_continue
                ;;
            4)
                local backup
                backup=$(firewall_create_backup) || {
                    echo -e "${RED}创建防火墙备份失败,已取消本次操作${PLAIN}"
                    press_any_key_to_continue
                    continue
                }
                echo -e "${YELLOW}[*] 正在配置仅保留 SSH 的入站策略(SSH: ${current_ssh_port})...${PLAIN}"
                if firewall_lockdown_all "$current_ssh_port"; then
                    firewall_save_rules || true
                    echo -e "${GREEN}[✓] 已应用仅留 SSH 的入站规则${PLAIN}"
                else
                    echo -e "${RED}[!] 写入仅保留 SSH 规则失败${PLAIN}"
                    if firewall_restore_backup "$backup"; then
                        firewall_save_rules >/dev/null 2>&1 || true
                        echo -e "${YELLOW}已恢复到修改前的状态${PLAIN}"
                    else
                        echo -e "${RED}回滚失败,请手动检查当前规则${PLAIN}"
                    fi
                fi
                firewall_remove_backup "$backup"
                press_any_key_to_continue
                ;;
            5)
                list_firewall_rules
                press_any_key_to_continue
                ;;
            6)
                port_jump_menu
                ;;
            *)
                echo -e "${RED}[!] 无效选项${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

set_ip_priority() {
    local GAI_CONF="/etc/gai.conf"
    local IPV4_RULE="precedence ::ffff:0:0/96  100"

    _get_current_priority() {
        if [[ ! -f "$GAI_CONF" ]]; then
            echo "IPv6 (系统默认)"
            return
        fi
        if grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$GAI_CONF" 2>/dev/null; then
            echo "IPv4 优先"
        else
            echo "IPv6 优先 (默认)"
        fi
    }

    while true; do
        clear
        local current_priority
        current_priority=$(_get_current_priority)
        echo -e "${BLUE}======== IP优先级设置 ========${PLAIN}"
        echo -e "${YELLOW}当前优先级: ${GREEN}${current_priority}${PLAIN}"
        echo -e "${BLUE}==============================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}设置IPv4优先"
        echo -e "${GREEN}2.${PLAIN}设置IPv6优先"
        echo -e "${GREEN}3.${PLAIN}恢复系统默认"
        echo -e "${YELLOW}0.${PLAIN}返回主菜单"
        echo -e "${BLUE}==============================${PLAIN}"
        read -rp "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" choice

        case "$choice" in
            1)
                if [[ ! -f "$GAI_CONF" ]]; then
                    echo "$IPV4_RULE" > "$GAI_CONF"
                elif grep -qE '^precedence[[:space:]]+::ffff:0:0/96' "$GAI_CONF" 2>/dev/null; then
                    sed -i 's/^precedence[[:space:]]\+::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "$GAI_CONF"
                elif grep -qE '^#.*precedence[[:space:]]+::ffff:0:0/96' "$GAI_CONF" 2>/dev/null; then
                    sed -i 's/^#.*\(precedence[[:space:]]\+::ffff:0:0\/96\).*/precedence ::ffff:0:0\/96  100/' "$GAI_CONF"
                else
                    echo "$IPV4_RULE" >> "$GAI_CONF"
                fi
                echo -e "${GREEN}✔ 已设置为 IPv4 优先${PLAIN}"
                press_any_key_to_continue
                ;;
            2)
                if [[ -f "$GAI_CONF" ]]; then
                    sed -i '/^precedence[[:space:]]\+::ffff:0:0\/96/d' "$GAI_CONF"
                fi
                echo -e "${GREEN}✔ 已设置为 IPv6 优先${PLAIN}"
                press_any_key_to_continue
                ;;
            3)
                if [[ -f "$GAI_CONF" ]]; then
                    sed -i '/^precedence[[:space:]]\+::ffff:0:0\/96/d' "$GAI_CONF"
                fi
                echo -e "${GREEN}✔ 已恢复系统默认 (IPv6 优先)${PLAIN}"
                press_any_key_to_continue
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                sleep 0.5
                ;;
        esac
    done
}

# ====== 主菜单 ======
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Steins Gate_Ver.2.3 ✦${PLAIN}"
        echo -e "${GREEN}  01.${PLAIN}系统更新"
        echo -e "${GREEN}  02.${PLAIN}系统清理"
        echo -e "${GREEN}  03.${PLAIN}重装系统"
        echo -e "${GREEN}  04.${PLAIN}设置时区"
        echo -e "${GREEN}  05.${PLAIN}配置IP栈"
        echo -e "${GREEN}  06.${PLAIN}配置DNS"
        echo -e "${GREEN}  07.${PLAIN}配置SSH"
        echo -e "${GREEN}  08.${PLAIN}重启VPS"
        echo -e "${GREEN}  09.${PLAIN}配置SWAP"
        echo -e "${GREEN}  10.${PLAIN}配置ACME"
        echo -e "${GREEN}  11.${PLAIN}配置Snell"
        echo -e "${GREEN}  12.${PLAIN}配置Shoes"
        echo -e "${GREEN}  13.${PLAIN}配置Mihomo"
        echo -e "${GREEN}  14.${PLAIN}配置Hysteria"
        echo -e "${GREEN}  15.${PLAIN}配置FireWall"
        echo -e "${GREEN}  16.${PLAIN}配置WireProxy"
        echo -e "${GREEN}  17.${PLAIN}配置WarpStack"
        echo -e "${GREEN}   0.${PLAIN}退出ByeBye"
        read -p "$(echo -e "${BLUE}✦ Choice [0-17] ✦ : ${PLAIN}")" choice
        choice=$(echo "$choice" | xargs)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            choice=$((10#$choice))
        fi
        case "$choice" in
            1)  linux_update ;;
            2)  linux_clean ;;
            3)  install_system ;;
            4)  change_timezone ;;
            5)  set_ip_priority ;;
            6)  dns_fix ;;
            7)  ssh_config_menu ;;
            8)  echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps ;;
            9)  set_swap_menu ;;
            10) install_acme ;;
            11) install_snell ;;
            12) install_shoes ;;
            13) install_mihomo ;;
            14) install_hysteria ;;
            15) configure_firewall ;;
            16) install_wireproxy ;;
            17) install_warp ;;
            0)  clear; echo -e "${BLUE}「命运石之扉の选择,El Psy Kongroo」${PLAIN}"; sleep 0.6; clear; break ;;
            *)  clear; echo -e "${RED}[!] 无效选项，请重新选择${PLAIN}"; sleep 0.4 ;;
        esac
    done
}

main_menu
