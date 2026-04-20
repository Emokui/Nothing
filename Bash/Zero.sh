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
ACME_HOME="$ROOT_HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
ACME_CERT_PATH="/etc/cert"

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

ssh_socket_units_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local unit
    for unit in ssh.socket sshd.socket; do
        systemctl cat "$unit" >/dev/null 2>&1 || continue
        if systemctl is-active "$unit" >/dev/null 2>&1 || systemctl is-enabled "$unit" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

ssh_apply_socket_port() {
    local port="$1"
    local unit dropin_dir dropin_file applied=0

    command -v systemctl >/dev/null 2>&1 || return 0

    for unit in ssh.socket sshd.socket; do
        systemctl cat "$unit" >/dev/null 2>&1 || continue
        if systemctl is-active "$unit" >/dev/null 2>&1 || systemctl is-enabled "$unit" >/dev/null 2>&1; then
            dropin_dir="/etc/systemd/system/${unit}.d"
            dropin_file="${dropin_dir}/zero-port.conf"
            mkdir -p "$dropin_dir" || return 1
            {
                echo "[Socket]"
                echo "ListenStream="
                echo "ListenStream=${port}"
            } > "$dropin_file" || return 1
            applied=1
        fi
    done

    if (( applied )); then
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        for unit in ssh.socket sshd.socket; do
            systemctl cat "$unit" >/dev/null 2>&1 || continue
            if systemctl is-active "$unit" >/dev/null 2>&1 || systemctl is-enabled "$unit" >/dev/null 2>&1; then
                systemctl restart "$unit" >/dev/null 2>&1 || return 1
            fi
        done
    fi

    return 0
}

ssh_port_is_listening() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -H -lnt 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" || $4 ~ "\\]:" port "$" {found=1} END {exit !found}'
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" || $4 ~ "\\]:" port "$" {found=1} END {exit !found}'
        return $?
    fi

    return 1
}

restart_sshd_safe() {
    local expected_port="${1:-}"

    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}sshd 配置有误,未重启sshd请检查${SSHD_CONFIG}${PLAIN}"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if [[ -n "$expected_port" ]] && ! ssh_apply_socket_port "$expected_port"; then
            echo -e "${RED}ssh.socket 端口更新失败,请手动检查 systemd socket 配置${PLAIN}"
            return 1
        fi

        if ! systemctl restart sshd 2>/dev/null && ! systemctl restart ssh 2>/dev/null && ! ssh_socket_units_available; then
            echo -e "${RED}sshd 服务重启失败,请手动检查服务状态${PLAIN}"
            return 1
        fi
    elif command -v service >/dev/null 2>&1; then
        if ! service sshd restart >/dev/null 2>&1 && ! service ssh restart >/dev/null 2>&1; then
            echo -e "${RED}sshd 服务重启失败,请手动检查服务状态${PLAIN}"
            return 1
        fi
    else
        echo -e "${RED}未找到 systemctl/service,无法自动重启 sshd${PLAIN}"
        return 1
    fi

    if [[ -n "$expected_port" ]]; then
        sleep 1
        if ! ssh_port_is_listening "$expected_port"; then
            echo -e "${RED}sshd 未监听新的端口 ${expected_port},已停止本次修改${PLAIN}"
            return 1
        fi
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
            local installed_kernels
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

get_swap_file_size_mb() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local size_bytes
        size_bytes=$(stat -c %s "$path" 2>/dev/null || echo 0)
        echo $(((size_bytes + 1048575) / 1048576))
    else
        echo 0
    fi
}

get_current_swap_mb() {
    if [[ -r /proc/swaps ]]; then
        awk 'NR>1 {sum+=$3} END {print int((sum + 512) / 1024)}' /proc/swaps
    else
        free -m | awk '/Swap:/ {print $2}'
    fi
}

get_managed_swap_mb() {
    if [[ -r /proc/swaps ]]; then
        awk -v path="$swapfile_path" 'NR>1 && $1 == path {sum+=$3} END {print int((sum + 512) / 1024)}' /proc/swaps
    elif [[ -f "$swapfile_path" ]]; then
        get_swap_file_size_mb "$swapfile_path"
    else
        echo 0
    fi
}

remove_swap_fstab_entries() {
    local path
    for path in "$@"; do
        sed -i "\|${path}|d" /etc/fstab 2>/dev/null || true
    done
}

create_swap_file() {
    local path="$1"
    local size_mb="$2"
    local root_fstype="$3"

    rm -f "$path"

    if [[ "$root_fstype" == "btrfs" ]]; then
        echo -e "${YELLOW}检测到 btrfs,正在按 swapfile 要求创建文件...${PLAIN}"
        : > "$path" || return 1
        if ! command -v chattr >/dev/null 2>&1 || ! chattr +C "$path" >/dev/null 2>&1; then
            rm -f "$path"
            echo -e "${RED}btrfs Swap 文件创建失败: 无法为文件设置 NoCOW${PLAIN}"
            return 1
        fi
        if command -v btrfs >/dev/null 2>&1; then
            btrfs property set "$path" compression none >/dev/null 2>&1 || true
        fi
        if ! dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress; then
            rm -f "$path"
            return 1
        fi
    elif command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${size_mb}M" "$path" 2>/dev/null; then
            echo -e "${YELLOW}fallocate 创建失败,改用 dd 写零...${PLAIN}"
            if ! dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress; then
                rm -f "$path"
                return 1
            fi
        fi
    else
        if ! dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress; then
            rm -f "$path"
            return 1
        fi
    fi

    chmod 600 "$path" || return 1
    mkswap "$path" >/dev/null || return 1
}

set_swap_menu() {
    while true; do
        clear
        local current_swap managed_swap total_ram recommend_swap
        current_swap=$(get_current_swap_mb)
        managed_swap=$(get_managed_swap_mb)
        total_ram=$(free -m | awk '/Mem:/ {print $2}')
        recommend_swap=$(get_recommended_swap)
        
        local current_swappiness
        current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知")

        echo -e "${BLUE}========= SWAP =========${PLAIN}"
        echo -e "${YELLOW}内存 ${total_ram}MB | 总Swap ${current_swap}MB${PLAIN}"
        echo -e "${YELLOW}文件Swap ${managed_swap}MB | Swappiness ${current_swappiness}${PLAIN}"
        echo -e "${BLUE}========================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}推荐大小    ${GREEN}2.${PLAIN}自定义"
        echo -e "${GREEN}3.${PLAIN}Swappiness  ${RED}4.${PLAIN}关闭Swap"
        echo -e "${YELLOW}0.${PLAIN}返回菜单"
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
    local show_pause="${2:-1}"
    local avail_kb avail_mb existing_swap_mb root_fstype
    local temp_swap_path="${swapfile_path}.zero.tmp"
    local backup_swap_path="${swapfile_path}.zero.bak"
    local had_existing=0 old_active=0

    echo -e "${YELLOW}正在检查环境...${PLAIN}"
    if ! [[ "$size_mb" =~ ^[0-9]+$ ]] || (( size_mb < 128 )); then
        echo -e "${RED}无效的 Swap 大小${PLAIN}"
        (( show_pause )) && press_any_key_to_continue
        return 1
    fi

    existing_swap_mb=$(get_swap_file_size_mb "$swapfile_path")
    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024 + existing_swap_mb))
    
    if (( avail_mb < size_mb + 500 )); then
        echo -e "${RED}磁盘空间不足!当前可用: ${avail_mb}MB, 需要: ${size_mb}MB (+预留500MB)${PLAIN}"
        (( show_pause )) && press_any_key_to_continue
        return 1
    fi

    root_fstype=$(df --output=fstype / | tail -1 | xargs)
    [[ -f "$swapfile_path" ]] && had_existing=1
    grep -q "$swapfile_path" /proc/swaps 2>/dev/null && old_active=1

    if grep -q "$temp_swap_path" /proc/swaps 2>/dev/null; then
        swapoff "$temp_swap_path" 2>/dev/null || true
    fi
    rm -f "$temp_swap_path"
    rm -f "$backup_swap_path"

    echo -e "${BLUE}正在创建 ${size_mb}MB 的 Swap 文件...${PLAIN}"
    if ! create_swap_file "$temp_swap_path" "$size_mb" "$root_fstype"; then
        echo -e "${RED}Swap 文件创建失败${PLAIN}"
        rm -f "$temp_swap_path"
        (( show_pause )) && press_any_key_to_continue
        return 1
    fi

    if (( old_active )); then
        echo -e "${YELLOW}正在切换旧 Swap...${PLAIN}"
        if ! swapoff "$swapfile_path"; then
            echo -e "${RED}旧 Swap 卸载失败,已保留原配置${PLAIN}"
            rm -f "$temp_swap_path"
            (( show_pause )) && press_any_key_to_continue
            return 1
        fi
    fi

    if (( had_existing )); then
        if ! mv "$swapfile_path" "$backup_swap_path"; then
            echo -e "${RED}旧 Swap 备份失败,已保留原配置${PLAIN}"
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
            rm -f "$temp_swap_path"
            (( show_pause )) && press_any_key_to_continue
            return 1
        fi
    fi

    if ! mv "$temp_swap_path" "$swapfile_path"; then
        echo -e "${RED}新 Swap 文件替换失败,已尝试恢复旧配置${PLAIN}"
        rm -f "$temp_swap_path"
        if (( had_existing )); then
            mv "$backup_swap_path" "$swapfile_path" 2>/dev/null || true
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
        fi
        (( show_pause )) && press_any_key_to_continue
        return 1
    fi

    if ! swapon "$swapfile_path"; then
        echo -e "${RED}新 Swap 启用失败,已尝试恢复旧配置${PLAIN}"
        rm -f "$swapfile_path"
        if (( had_existing )); then
            mv "$backup_swap_path" "$swapfile_path" 2>/dev/null || true
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
        fi
        (( show_pause )) && press_any_key_to_continue
        return 1
    fi

    remove_swap_fstab_entries "$swapfile_path" "$temp_swap_path" "$backup_swap_path"
    if ! echo "$swapfile_path none swap sw 0 0" >> /etc/fstab; then
        echo -e "${YELLOW}Swap 已启用,但写入 /etc/fstab 失败,重启后不会自动挂载${PLAIN}"
    fi

    rm -f "$backup_swap_path"

    echo -e "${GREEN}✓ Swap 设置成功!${PLAIN}"
    free -h
    (( show_pause )) && press_any_key_to_continue
    return 0
}

delete_swap() {
    local temp_swap_path="${swapfile_path}.zero.tmp"
    local backup_swap_path="${swapfile_path}.zero.bak"

    if ! grep -q "$swapfile_path" /proc/swaps 2>/dev/null \
        && ! grep -q "$temp_swap_path" /proc/swaps 2>/dev/null \
        && [ ! -f "$swapfile_path" ] \
        && [ ! -f "$temp_swap_path" ] \
        && [ ! -f "$backup_swap_path" ]; then
        echo -e "${YELLOW}当前没有 Swap 文件,无需操作${PLAIN}"
        press_any_key_to_continue
        return 0
    fi

    echo -e "${YELLOW}正在删除 Swap...${PLAIN}"
    swapoff "$swapfile_path" 2>/dev/null || true
    swapoff "$temp_swap_path" 2>/dev/null || true
    rm -f "$swapfile_path" "$temp_swap_path" "$backup_swap_path"
    remove_swap_fstab_entries "$swapfile_path" "$temp_swap_path" "$backup_swap_path"
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

BBR_SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
BBR_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
BBR_REPO_FILE="/etc/apt/sources.list.d/xanmod-release.list"
BBR_PERSIST_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
BBR_PERSIST_SERVICE_NAME="bbr-optimize-persist.service"
BBR_PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"

bbr_prompt_reboot() {
    read -rp "现在重启服务器使配置生效吗？(Y/N): " answer
    case "$answer" in
        [Yy]) reboot_vps ;;
        *) echo -e "${YELLOW}已取消,请稍后手动执行 reboot${PLAIN}" ;;
    esac
}

bbr_cpu_has_flags() {
    local flags needle
    flags=$(awk -F': ' '/^flags[[:space:]]*:/ {print tolower($2); exit}' /proc/cpuinfo 2>/dev/null)
    [[ -n "$flags" ]] || return 1

    for needle in "$@"; do
        case " $flags " in
            *" ${needle} "*) ;;
            *) return 1 ;;
        esac
    done
}

bbr_detect_x86_64_level_local() {
    if ! bbr_cpu_has_flags cx16 lahf_lm popcnt sse3 ssse3 sse4_1 sse4_2; then
        echo 1
        return 0
    fi

    if ! bbr_cpu_has_flags avx avx2 bmi1 bmi2 f16c fma movbe xsave; then
        echo 2
        return 0
    fi

    if ! bbr_cpu_has_flags abm && ! bbr_cpu_has_flags lzcnt; then
        echo 2
        return 0
    fi

    if ! bbr_cpu_has_flags avx512f avx512bw avx512cd avx512dq avx512vl; then
        echo 3
        return 0
    fi

    echo 4
}

bbr_ensure_apt_packages() {
    local missing_packages=()
    local package check_cmd

    for package in "$@"; do
        check_cmd="$package"
        case "$package" in
            gnupg) check_cmd="gpg" ;;
            ca-certificates) check_cmd="update-ca-certificates" ;;
        esac

        if ! command -v "$check_cmd" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    [[ "${#missing_packages[@]}" -eq 0 ]] && return 0

    echo -e "${YELLOW}正在更新软件仓库...${PLAIN}"
    apt-get update || return 1

    echo -e "${YELLOW}正在安装依赖: ${missing_packages[*]}${PLAIN}"
    apt-get install -y "${missing_packages[@]}" || return 1
}

bbr_select_xanmod_package() {
    local version="$1" package_name package_hint candidate_version
    local packages=()

    case "$version" in
        1)
            packages=("linux-xanmod-lts-x64v1")
            ;;
        2)
            packages=("linux-xanmod-x64v2" "linux-xanmod-lts-x64v2")
            ;;
        3|4)
            packages=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3")
            ;;
        *)
            return 1
            ;;
    esac

    for package_name in "${packages[@]}"; do
        candidate_version=$(apt-cache policy "$package_name" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
        [[ -z "$candidate_version" || "$candidate_version" == "(none)" ]] && continue

        case "$package_name" in
            linux-xanmod-lts-x64v1)
                package_hint="x64v1 仅提供 LTS 包，已自动切换到 LTS"
                ;;
            linux-xanmod-lts-x64v2)
                package_hint="当前仓库仅提供 LTS 分支，已自动切换到 x64v2 LTS"
                ;;
            linux-xanmod-lts-x64v3)
                package_hint="当前仓库仅提供 LTS 分支，已自动切换到 x64v3 LTS"
                ;;
            linux-xanmod-x64v2)
                package_hint="x64v2"
                ;;
            linux-xanmod-x64v3)
                package_hint="x64v${version} 检测结果，按官方建议安装 x64v3"
                ;;
        esac

        echo "${package_name}|${package_hint}"
        return 0
    done

    return 1
}

bbr_resolve_xanmod_payload_packages() {
    local package_name="$1"
    apt-cache depends --important "$package_name" 2>/dev/null \
        | awk '/Depends:/ {print $2}' \
        | grep -E '^linux-(image|headers)-.*xanmod' \
        | awk '!seen[$0]++'
}

bbr_fetch_xanmod_key() {
    local output_file="$1" log_file="$2"
    curl -fsSL "https://gitlab.com/afrd.gpg" -o "$output_file" >"$log_file" 2>&1 && [[ -s "$output_file" ]]
}

bbr_check_disk_space() {
    local required_gb="$1"
    local required_space_mb=$((required_gb * 1024))
    local available_space_mb
    available_space_mb=$(df -m / | awk 'NR==2 {print $4}')

    if (( available_space_mb >= required_space_mb )); then
        return 0
    fi

    echo -e "${YELLOW}警告: 磁盘空间不足${PLAIN}"
    echo -e "当前可用: ${GREEN}$((available_space_mb / 1024))G${PLAIN} | 最低需求: ${GREEN}${required_gb}G${PLAIN}"
    read -rp "是否继续？(Y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

bbr_check_and_prepare_swap() {
    local total_ram total_swap managed_swap recommend_swap other_swap target_swapfile
    total_ram=$(free -m | awk '/Mem:/ {print $2}')
    total_swap=$(get_current_swap_mb)
    managed_swap=$(get_managed_swap_mb)
    recommend_swap=$(get_recommended_swap)

    if (( total_swap >= recommend_swap )); then
        return 0
    fi

    other_swap=$((total_swap - managed_swap))
    target_swapfile=$((recommend_swap - other_swap))
    if (( target_swapfile < 128 )); then
        target_swapfile=128
    fi

    echo -e "${YELLOW}检测到虚拟内存（SWAP）需要优化${PLAIN}"
    echo -e "物理内存: ${GREEN}${total_ram}MB${PLAIN} | 总Swap: ${GREEN}${total_swap}MB${PLAIN} | 推荐: ${GREEN}${recommend_swap}MB${PLAIN}"
    echo -e "文件Swap: ${GREEN}${managed_swap}MB${PLAIN} -> ${GREEN}${target_swapfile}MB${PLAIN}（仅管理 ${swapfile_path}）"

    read -rp "是否现在配置虚拟内存？(Y/N): " answer
    case "$answer" in
        [Yy])
            set_swap "$target_swapfile" 0 || return 1
            ;;
        *)
            echo -e "${YELLOW}已跳过虚拟内存配置${PLAIN}"
            ;;
    esac
}

bbr_fetch_text_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        return 1
    fi
}

bbr_download_url_to_file() {
    local url="$1" output_file="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$output_file"
    else
        return 1
    fi
}

bbr_extract_speedtest_version() {
    local input="$1"
    printf '%s\n' "$input" | sed -nE 's#.*ookla-speedtest-([0-9.]+)-linux-x86_64\.tgz.*#\1#p'
}

bbr_get_speedtest_download_url() {
    local page_content download_url
    page_content=$(bbr_fetch_text_url "https://speedtest-static-dev.speedtest.dev/apps/cli") || return 1
    download_url=$(printf '%s\n' "$page_content" | grep -Eo 'https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-linux-x86_64\.tgz' | head -n 1)
    [[ -n "$download_url" ]] || return 1
    echo "$download_url"
}

bbr_get_installed_speedtest_version() {
    speedtest --version 2>/dev/null | sed -nE 's/^Speedtest by Ookla ([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?.*/\1/p'
}

bbr_install_speedtest_from_url() {
    local download_url="$1" speedtest_tmp
    speedtest_tmp=$(mktemp -d) || return 1

    bbr_download_url_to_file "$download_url" "${speedtest_tmp}/speedtest.tgz" || {
        rm -rf "$speedtest_tmp"
        return 1
    }

    tar -xzf "${speedtest_tmp}/speedtest.tgz" -C "$speedtest_tmp" || {
        rm -rf "$speedtest_tmp"
        return 1
    }

    install -m 0755 "${speedtest_tmp}/speedtest" /usr/local/bin/speedtest || {
        rm -rf "$speedtest_tmp"
        return 1
    }

    rm -rf "$speedtest_tmp"
}

bbr_ensure_speedtest() {
    local cpu_arch download_url latest_version installed_version
    cpu_arch=$(uname -m)

    case "$cpu_arch" in
        x86_64) ;;
        *)
            echo -e "${RED}错误: 不支持的架构 ${cpu_arch}${PLAIN}" >&2
            return 1
            ;;
    esac

    download_url=$(bbr_get_speedtest_download_url 2>/dev/null || true)
    if [[ -z "$download_url" ]]; then
        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
    fi
    latest_version=$(bbr_extract_speedtest_version "$download_url")

    if command -v speedtest >/dev/null 2>&1; then
        installed_version=$(bbr_get_installed_speedtest_version)
        if [[ -n "$installed_version" && -n "$latest_version" && "$installed_version" == "$latest_version" ]]; then
            return 0
        fi

        if [[ -n "$installed_version" && -n "$latest_version" ]]; then
            echo -e "${YELLOW}检测到 speedtest 新版本 ${latest_version}，正在更新...${PLAIN}" >&2
        else
            return 0
        fi
    else
        echo -e "${YELLOW}speedtest 未安装，正在安装...${PLAIN}" >&2
    fi

    bbr_install_speedtest_from_url "$download_url" || return 1
}

bbr_detect_bandwidth() {
    echo -e "${BLUE}======== 带宽检测 ========${PLAIN}" >&2
    echo -e "${GREEN}1.${PLAIN}自动检测    ${GREEN}2.${PLAIN}预设档位" >&2
    echo -e "${YELLOW}0.${PLAIN}返回菜单" >&2
    echo -e "${BLUE}==========================${PLAIN}" >&2
    read -rp "$(echo -e "${BLUE}请输入选项 [0-2]: ${PLAIN}")" bw_choice
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        0)
            return 2
            ;;
        1)
            echo -e "${YELLOW}正在运行 speedtest 自动测速...${PLAIN}" >&2
            bbr_ensure_speedtest >/dev/null 2>&1 || {
                echo -e "${YELLOW}测速工具安装失败，使用默认值 1000 Mbps${PLAIN}" >&2
                echo "1000"
                return 1
            }

            local servers_list server_count
            servers_list=$(speedtest --accept-license --accept-gdpr --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            if [[ -n "$servers_list" ]]; then
                server_count=$(echo "$servers_list" | wc -l | tr -d ' ')
                echo -e "${GREEN}已找到 ${server_count} 个附近节点${PLAIN}" >&2
            else
                servers_list="auto"
                echo -e "${YELLOW}未获取到节点列表，将自动选择最近服务器${PLAIN}" >&2
            fi

            local speedtest_output="" upload_speed="" upload_mbps="" success_server="" failed_server="" attempt=0 server_id
            for server_id in $servers_list; do
                attempt=$((attempt + 1))

                if [[ "$server_id" == "auto" ]]; then
                    echo -e "${YELLOW}[尝试 ${attempt}] 自动选择最近服务器...${PLAIN}" >&2
                    speedtest_output=$(speedtest --accept-license --accept-gdpr 2>&1)
                else
                    echo -e "${YELLOW}[尝试 ${attempt}] 测试服务器 #${server_id}...${PLAIN}" >&2
                    speedtest_output=$(speedtest --accept-license --accept-gdpr --server-id="$server_id" 2>&1)
                fi

                echo "$speedtest_output" >&2
                echo >&2

                upload_speed=""
                if echo "$speedtest_output" | grep -q "Upload:"; then
                    upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n 1)
                fi
                if [[ -z "$upload_speed" ]]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi

                if [[ -n "$upload_speed" ]] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                    success_server=$(echo "$speedtest_output" | grep "Server:" | head -n 1 | sed 's/.*Server: //')
                    echo -e "${GREEN}测速成功${PLAIN}" >&2
                    [[ -n "$success_server" ]] && echo -e "使用服务器: ${GREEN}${success_server}${PLAIN}" >&2
                    break
                fi

                failed_server=$(echo "$speedtest_output" | grep "Server:" | head -n 1 | sed 's/.*Server: //' | sed 's/[[:space:]]*$//')
                if [[ -n "$failed_server" ]]; then
                    echo -e "${YELLOW}节点失败: ${failed_server}${PLAIN}" >&2
                else
                    echo -e "${YELLOW}节点失败,继续尝试下一个${PLAIN}" >&2
                fi
                echo >&2
            done

            if [[ -z "$upload_speed" ]] || echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                echo -e "${YELLOW}测速失败，使用默认值 1000 Mbps${PLAIN}" >&2
                echo "1000"
                return 1
            fi

            upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || (( upload_mbps <= 0 )); then
                echo -e "${YELLOW}检测值异常 (${upload_speed})，使用默认值 1000 Mbps${PLAIN}" >&2
                echo "1000"
                return 1
            fi

            echo -e "${GREEN}检测到上传带宽: ${upload_mbps} Mbps${PLAIN}" >&2
            echo "$upload_mbps"
            ;;
        2)
            echo "1. 100 Mbps" >&2
            echo "2. 200 Mbps" >&2
            echo "3. 300 Mbps" >&2
            echo "4. 500 Mbps" >&2
            echo "5. 700 Mbps" >&2
            echo "6. 1000 Mbps" >&2
            echo "7. 1500 Mbps" >&2
            echo "8. 2000 Mbps" >&2
            echo "9. 2500 Mbps" >&2
            echo "10. 自定义输入" >&2
            read -rp "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}
            case "$preset_choice" in
                1) echo 100 ;;
                2) echo 200 ;;
                3) echo 300 ;;
                4) echo 500 ;;
                5) echo 700 ;;
                6) echo 1000 ;;
                7) echo 1500 ;;
                8) echo 2000 ;;
                9) echo 2500 ;;
                10)
                    read -rp "请输入带宽值（Mbps）: " manual_bandwidth
                    if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && (( manual_bandwidth > 0 )); then
                        echo "$manual_bandwidth"
                    else
                        echo 1000
                        return 1
                    fi
                    ;;
                *) echo 1000; return 1 ;;
            esac
            ;;
        *)
            echo 1000
            return 1
            ;;
    esac
}

bbr_calculate_buffer_size() {
    local bandwidth="$1"
    local region="${2:-asia}"
    local buffer_mb

    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || (( bandwidth <= 0 )); then
        [[ "$region" == "overseas" ]] && echo 32 || echo 16
        return 0
    fi

    if [[ "$region" == "overseas" ]]; then
        if (( bandwidth <= 100 )); then
            buffer_mb=8
        elif (( bandwidth <= 200 )); then
            buffer_mb=16
        elif (( bandwidth <= 300 )); then
            buffer_mb=20
        elif (( bandwidth <= 500 )); then
            buffer_mb=32
        elif (( bandwidth <= 700 )); then
            buffer_mb=48
        else
            buffer_mb=64
        fi
    else
        if (( bandwidth <= 100 )); then
            buffer_mb=6
        elif (( bandwidth <= 200 )); then
            buffer_mb=8
        elif (( bandwidth <= 300 )); then
            buffer_mb=10
        elif (( bandwidth <= 500 )); then
            buffer_mb=12
        elif (( bandwidth <= 700 )); then
            buffer_mb=14
        elif (( bandwidth <= 1000 )); then
            buffer_mb=16
        elif (( bandwidth <= 1500 )); then
            buffer_mb=20
        elif (( bandwidth <= 2000 )); then
            buffer_mb=24
        elif (( bandwidth <= 2500 )); then
            buffer_mb=28
        else
            buffer_mb=32
        fi
    fi

    echo -e "${YELLOW}推荐缓冲区: ${GREEN}${buffer_mb}MB${PLAIN}" >&2
    read -rp "是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: " confirm
    confirm=${confirm:-Y}
    case "$confirm" in
        [Yy]) echo "$buffer_mb" ;;
        *) [[ "$region" == "overseas" ]] && echo 32 || echo 16 ;;
    esac
}

bbr_check_and_clean_conflicts() {
    echo -e "${BLUE}=== 检查 sysctl 配置冲突 ===${PLAIN}"
    local conflicts=()
    local conf base num
    local tune_key_regex='(^|\s)net\.(core\.(rmem_max|wmem_max|default_qdisc)|ipv4\.tcp_(rmem|wmem|congestion_control))'

    for conf in /etc/sysctl.d/*.conf; do
        [[ -f "$conf" ]] || continue
        [[ "$conf" == "$BBR_SYSCTL_CONF" ]] && continue
        if grep -qE "$tune_key_regex" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            if [[ -z "$num" || "$num" -ge 99 ]]; then
                conflicts+=("$conf")
            fi
        fi
    done

    local has_sysctl_conflict=0
    if [[ -f /etc/sysctl.conf ]] && grep -qE "$tune_key_regex" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [[ "${#conflicts[@]}" -eq 0 && "$has_sysctl_conflict" -eq 0 ]]; then
        echo -e "${GREEN}✓ 未发现可能的覆盖配置${PLAIN}"
        return 0
    fi

    echo -e "${YELLOW}发现可能的覆盖配置${PLAIN}"
    if [[ "${#conflicts[@]}" -gt 0 ]]; then
        printf '  - %s\n' "${conflicts[@]}"
    fi
    [[ "$has_sysctl_conflict" -eq 1 ]] && echo "  - /etc/sysctl.conf"

    read -rp "是否自动禁用/注释这些覆盖配置？(Y/N): " answer
    case "$answer" in
        [Yy])
            if [[ "$has_sysctl_conflict" -eq 1 ]]; then
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null || true
                local key
                for key in \
                    'net\.ipv4\.tcp_wmem' \
                    'net\.ipv4\.tcp_rmem' \
                    'net\.core\.rmem_max' \
                    'net\.core\.wmem_max' \
                    'net\.core\.default_qdisc' \
                    'net\.ipv4\.tcp_congestion_control'
                do
                    sed -i "/^[[:space:]]*${key}/s/^[[:space:]]*/# /" /etc/sysctl.conf 2>/dev/null
                done
            fi
            for conf in "${conflicts[@]}"; do
                mv "$conf" "${conf}.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            done
            ;;
        *)
            echo -e "${YELLOW}已跳过自动清理，可能导致新配置未完全生效${PLAIN}"
            ;;
    esac
}

bbr_eligible_ifaces() {
    local path dev
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        dev=$(basename "$path")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        echo "$dev"
    done
}

bbr_apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${YELLOW}警告: 未检测到 tc（iproute2），跳过 fq 应用${PLAIN}"
        return 0
    fi

    local applied=0 dev
    for dev in $(bbr_eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied + 1))
    done

    if (( applied > 0 )); then
        echo -e "${GREEN}已对 ${applied} 个网卡应用 fq${PLAIN}"
    else
        echo -e "${YELLOW}未发现可应用 fq 的网卡${PLAIN}"
    fi
}

bbr_apply_mss_clamp() {
    local action="$1"
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${YELLOW}警告: 未检测到 iptables，跳过 MSS clamp${PLAIN}"
        return 0
    fi

    if [[ "$action" == "enable" ]]; then
        while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; do
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || break
        done
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; do
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || break
        done
    fi
}

bbr_cleanup_persist() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$BBR_PERSIST_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$BBR_PERSIST_SERVICE" "$BBR_PERSIST_SCRIPT"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

bbr_configure_direct() {
    if [[ "$(uname -m)" != "x86_64" ]]; then
        echo -e "${RED}错误: 当前仅支持 x86_64 系统${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    bbr_check_and_prepare_swap || {
        echo -e "${RED}虚拟内存配置失败，已停止本次优化${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    echo -e "${YELLOW}[步骤 1/5] 带宽检测与缓冲区...${PLAIN}"
    local detected_bandwidth
    detected_bandwidth=$(bbr_detect_bandwidth)
    local bandwidth_status=$?
    if [[ "$bandwidth_status" -eq 2 ]]; then
        return 0
    fi

    local region="asia" region_choice
    echo "1. 亚太地区（港/日/新/韩等）"
    echo "2. 美国/欧洲（跨太平洋/大西洋）"
    read -rp "请输入选择 [1]: " region_choice
    [[ "${region_choice:-1}" == "2" ]] && region="overseas"

    local buffer_mb buffer_bytes
    buffer_mb=$(bbr_calculate_buffer_size "$detected_bandwidth" "$region")
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    echo -e "${YELLOW}[步骤 2/5] 清理配置冲突...${PLAIN}"
    [[ -L /etc/sysctl.d/99-sysctl.conf ]] && rm -f /etc/sysctl.d/99-sysctl.conf
    bbr_check_and_clean_conflicts

    echo -e "${YELLOW}[步骤 3/5] 创建配置文件...${PLAIN}"
    local mem_total vm_swappiness=5 vm_dirty_ratio=15 vm_min_free_kbytes=65536
    mem_total=$(free -m | awk '/Mem:/ {print $2}')
    if (( mem_total < 2048 )); then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi

    cat > "$BBR_SYSCTL_CONF" <<EOF
# BBR Direct/Endpoint Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_syncookies=1
vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    echo -e "${YELLOW}[步骤 4/5] 应用所有优化参数...${PLAIN}"
    local sysctl_output sysctl_rc
    sysctl_output=$(sysctl -p "$BBR_SYSCTL_CONF" 2>&1)
    sysctl_rc=$?
    if [[ "$sysctl_rc" -ne 0 ]]; then
        echo -e "${YELLOW}部分 sysctl 参数应用失败（不支持的参数会被跳过）${PLAIN}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -n 5
    fi

    bbr_apply_tc_fq_now
    bbr_apply_mss_clamp enable
    bbr_cleanup_persist

    cat > "$BBR_PERSIST_SERVICE" <<'EOF'
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
EOF

    cat > "$BBR_PERSIST_SCRIPT" <<'EOF'
#!/bin/bash
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null
done
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
EOF

    chmod +x "$BBR_PERSIST_SCRIPT"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable "$BBR_PERSIST_SERVICE_NAME" >/dev/null 2>&1
    else
        echo -e "${YELLOW}未检测到 systemctl，已跳过持久化服务启用${PLAIN}"
    fi

    echo -e "${YELLOW}[步骤 5/5] 验证配置...${PLAIN}"
    local actual_qdisc actual_cc available_cc current_kernel
    actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    current_kernel=$(uname -r)

    if [[ "$actual_qdisc" == "fq" && "$actual_cc" == "bbr" ]] && echo "$available_cc" | grep -qw bbr; then
        if echo "$current_kernel" | grep -qi 'xanmod'; then
            echo -e "${GREEN}✓ fq + bbr 已启用，当前运行内核为 XanMod${PLAIN}"
            echo -e "配置说明: ${GREEN}${buffer_mb}MB${PLAIN} 缓冲区（${GREEN}${detected_bandwidth} Mbps${PLAIN} 带宽）"
        else
            echo -e "${YELLOW}fq + bbr 已启用，但当前运行内核不是 XanMod${PLAIN}"
            echo -e "${YELLOW}如需确认 BBR v3，请先重启进入 XanMod 内核后再验证${PLAIN}"
        fi
    else
        echo -e "${YELLOW}配置已保存，但部分参数未立即生效${PLAIN}"
    fi

    press_any_key_to_continue
}

bbr_install_xanmod_kernel() {
    echo -e "${BLUE}=== 安装 XanMod 内核与 BBR v3 ===${PLAIN}"
    echo "支持系统: Debian/Ubuntu (x86_64)"
    echo -e "${YELLOW}警告: 将升级 Linux 内核，请提前备份重要数据${PLAIN}"
    read -rp "确定继续安装吗？(Y/N): " choice
    case "$choice" in
        [Yy]) ;;
        *) echo "已取消安装"; press_any_key_to_continue; return 1 ;;
    esac

    if [[ "$(uname -m)" != "x86_64" ]]; then
        echo -e "${RED}错误: 当前仅支持 x86_64 系统${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            echo -e "${RED}错误: 仅支持 Debian 和 Ubuntu${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    else
        echo -e "${RED}错误: 无法确定操作系统类型${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    bbr_check_disk_space 3 || {
        press_any_key_to_continue
        return 1
    }
    bbr_check_and_prepare_swap || {
        echo -e "${RED}虚拟内存配置失败，已停止安装${PLAIN}"
        press_any_key_to_continue
        return 1
    }
    bbr_ensure_apt_packages curl gnupg ca-certificates || {
        echo -e "${RED}依赖安装失败${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    echo -e "${YELLOW}正在添加 XanMod 仓库密钥...${PLAIN}"
    mkdir -p /etc/apt/keyrings
    local key_tmp key_log
    key_tmp=$(mktemp) || {
        press_any_key_to_continue
        return 1
    }
    key_log="${key_tmp}.log"

    if ! bbr_fetch_xanmod_key "$key_tmp" "$key_log" || ! gpg --dearmor -o "$BBR_KEYRING" --yes < "$key_tmp" 2>>"$key_log"; then
        echo -e "${RED}错误: XanMod 仓库密钥下载或导入失败${PLAIN}"
        [[ -s "$key_log" ]] && tail -n 12 "$key_log"
        rm -f "$key_tmp" "$key_log"
        press_any_key_to_continue
        return 1
    fi
    rm -f "$key_tmp" "$key_log"

    local distro_codename
    if [[ -n "${VERSION_CODENAME:-}" ]]; then
        distro_codename="$VERSION_CODENAME"
    elif [[ -n "${UBUNTU_CODENAME:-}" ]]; then
        distro_codename="$UBUNTU_CODENAME"
    elif command -v lsb_release >/dev/null 2>&1; then
        distro_codename=$(lsb_release -sc 2>/dev/null)
    else
        distro_codename=""
    fi

    if [[ -z "$distro_codename" ]]; then
        echo -e "${RED}错误: 无法确定系统代号，已停止安装${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo "deb [signed-by=${BBR_KEYRING}] http://deb.xanmod.org ${distro_codename} main" > "$BBR_REPO_FILE"

    echo -e "${YELLOW}正在检测 CPU 支持的最优内核版本...${PLAIN}"
    local version package_name package_hint
    version=$(bbr_detect_x86_64_level_local)
    if ! [[ "$version" =~ ^[1-4]$ ]]; then
        echo -e "${RED}错误: 无法可靠检测 CPU 对应的 XanMod x64v 等级${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    apt-get update || {
        echo -e "${RED}apt-get update 失败${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    local package_info package_status install_ok=0 verify_package
    local install_packages=()

    package_info=$(bbr_select_xanmod_package "$version") || {
        echo -e "${RED}错误: 当前仓库中未找到适配 x64v${version} 的 XanMod 内核包${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    package_name="${package_info%%|*}"
    package_hint="${package_info#*|}"
    mapfile -t install_packages < <(bbr_resolve_xanmod_payload_packages "$package_name" 2>/dev/null || true)

    if [[ "${#install_packages[@]}" -eq 0 ]]; then
        echo -e "${RED}错误: 无法解析 ${package_name} 对应的内核安装包${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${GREEN}目标通道: ${package_name}${PLAIN}"
    echo -e "${YELLOW}说明: ${package_hint}${PLAIN}"
    echo -e "${YELLOW}实际安装: ${install_packages[*]}${PLAIN}"

    if ! apt-get install -y "${install_packages[@]}"; then
        echo -e "${RED}XanMod 内核安装失败${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    install_ok=1
    for verify_package in "${install_packages[@]}"; do
        package_status=$(dpkg-query -W -f='${Status}' "$verify_package" 2>/dev/null || true)
        if [[ "$package_status" != "install ok installed" ]]; then
            install_ok=0
            break
        fi
    done

    if (( install_ok == 0 )); then
        echo -e "${RED}未检测到 XanMod 内核安装成功${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${GREEN}XanMod 内核安装成功${PLAIN}"
    echo -e "${YELLOW}提示: 请先重启系统加载新内核，然后再进行 BBR 调优${PLAIN}"
    press_any_key_to_continue
}

bbr_uninstall_xanmod_kernel() {
    echo -e "${YELLOW}警告: 即将卸载 XanMod 内核${PLAIN}"
    local non_xanmod_kernels
    non_xanmod_kernels=$(dpkg -l 2>/dev/null | grep '^ii' | grep 'linux-image-' | grep -v 'xanmod' | grep -v 'dbg' | wc -l)
    if [[ "$non_xanmod_kernels" -eq 0 ]]; then
        echo -e "${RED}安全检查未通过：未检测到非 XanMod 的回退内核${PLAIN}"
        echo "建议先安装默认内核:"
        echo "  apt install -y linux-image-amd64   # Debian"
        echo "  apt install -y linux-image-generic # Ubuntu"
        press_any_key_to_continue
        return 1
    fi

    read -rp "确定继续吗？(Y/N): " confirm
    case "$confirm" in
        [Yy])
            echo -e "${YELLOW}正在卸载 XanMod 相关包...${PLAIN}"
            if ! apt purge -y 'linux-*xanmod*'; then
                press_any_key_to_continue
                return 1
            fi
            update-grub 2>/dev/null || true
            rm -f "$BBR_REPO_FILE" "$BBR_KEYRING" /usr/share/keyrings/xanmod-archive-keyring.gpg
            rm -f "$BBR_SYSCTL_CONF" /etc/sysctl.d/99-zero-bbr.conf /etc/modules-load.d/bbr.conf
            bbr_apply_mss_clamp disable
            bbr_cleanup_persist
            echo -e "${GREEN}XanMod 内核已卸载${PLAIN}"
            bbr_prompt_reboot
            ;;
        *)
            echo "已取消"
            ;;
    esac
    press_any_key_to_continue
}

bbr_menu_status_line() {
    local current_kernel cc qdisc xanmod_state
    current_kernel=$(uname -r 2>/dev/null)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+linux-image-.*xanmod'; then
        xanmod_state="${GREEN}已安装${PLAIN}"
    else
        xanmod_state="${YELLOW}未安装${PLAIN}"
    fi

    echo -e "${BLUE}内核 ${YELLOW}${current_kernel:-unknown}${PLAIN}"
    echo -e "${BLUE}XanMod ${xanmod_state} | BBR ${GREEN}${cc:-unknown}${PLAIN} | Qdisc ${GREEN}${qdisc:-unknown}${PLAIN}"
}

bbr_manage_menu() {
    local opt
    while true; do
        clear
        echo -e "${BLUE}============ BBR管理 ============${PLAIN}"
        bbr_menu_status_line
        echo -e "${BLUE}==================================${PLAIN}"
        echo -e "${GREEN}1.安装XanMod${PLAIN}   ${RED}2.卸载XanMod${PLAIN}"
        echo -e "${BLUE}3.BBR调优${PLAIN}      ${YELLOW}0.返回菜单${PLAIN}"
        echo -e "${BLUE}==================================${PLAIN}"
        read -rp "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" opt

        case "$opt" in
            1) clear; bbr_install_xanmod_kernel ;;
            2) clear; bbr_uninstall_xanmod_kernel ;;
            3) clear; bbr_configure_direct ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

ssh_config_menu() {
    while true; do
        clear
        local current_port permit_root_login pass_auth pubkey_auth
        local root_login_text password_login_text pubkey_login_text

        current_port=$(get_sshd_option "Port" "22")
        [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=22
        permit_root_login=$(get_sshd_option "PermitRootLogin" "yes")
        pass_auth=$(get_sshd_option "PasswordAuthentication" "yes")
        pubkey_auth=$(get_sshd_option "PubkeyAuthentication" "yes")

        case "$permit_root_login" in
            yes)
                root_login_text="${GREEN}开启${PLAIN}"
                ;;
            prohibit-password|without-password)
                root_login_text="${YELLOW}仅密钥${PLAIN}"
                ;;
            forced-commands-only)
                root_login_text="${YELLOW}受限${PLAIN}"
                ;;
            no)
                root_login_text="${RED}关闭${PLAIN}"
                ;;
            *)
                root_login_text="${YELLOW}${permit_root_login:-未知}${PLAIN}"
                ;;
        esac

        if [[ "$pass_auth" == "yes" ]]; then
            password_login_text="${GREEN}开启${PLAIN}"
        else
            password_login_text="${RED}关闭${PLAIN}"
        fi

        if [[ "$pubkey_auth" == "yes" ]]; then
            pubkey_login_text="${GREEN}开启${PLAIN}"
        else
            pubkey_login_text="${RED}关闭${PLAIN}"
        fi

        echo -e "${BLUE}======== SSH ========${PLAIN}"
        echo -e "${BLUE}端口 ${YELLOW}${current_port}${PLAIN} | Root ${root_login_text}"
        echo -e "${BLUE}密码 ${password_login_text} | 密钥 ${pubkey_login_text}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.设置密码${PLAIN}  ${GREEN}2.设置密钥${PLAIN}"
        echo -e "${BLUE}3.修改端口${PLAIN}  ${RED}4.修改登录${PLAIN}"
        echo -e "${YELLOW}0.返回菜单${PLAIN}"
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
        local current_port old_port
        current_port=$(get_sshd_option "Port" "22")
        [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=22
        old_port="$current_port"
        echo -e "${YELLOW}当前SSH端口: ${GREEN}${current_port:-22}${PLAIN}\n"
        read -rp "$(echo -e "${BLUE}请输入新的SSH端口(输入0返回): ${PLAIN}")" new_port
        new_port=$(echo "$new_port" | xargs)
        if [[ "$new_port" == "0" ]]; then
            return
        fi
        if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )); then
            if [[ "$new_port" == "$old_port" ]]; then
                echo -e "${YELLOW}SSH 端口已是 ${old_port},无需修改${PLAIN}"
                press_any_key_to_continue
                return
            fi

            if ! firewall_can_change_ssh_port "$new_port"; then
                echo -e "${RED}当前防火墙未放行 TCP ${new_port},请先到 FireWall -> 放行端口 中放行后再修改 SSH 端口${PLAIN}"
                press_any_key_to_continue
                continue
            fi

            if ! update_sshd_option "Port" "$new_port"; then
                echo -e "${RED}写入 SSH 端口配置失败,请检查 ${SSHD_CONFIG}${PLAIN}"
                press_any_key_to_continue
                continue
            fi

            if restart_sshd_safe "$new_port"; then
                echo -e "${YELLOW}[✓]SSH端口已修改为 $new_port${PLAIN}"
                press_any_key_to_continue
                return
            fi

            if update_sshd_option "Port" "$old_port" && restart_sshd_safe "$old_port" >/dev/null 2>&1; then
                echo -e "${YELLOW}已自动回滚到原 SSH 端口 ${old_port}${PLAIN}"
            else
                echo -e "${RED}回滚到原 SSH 端口 ${old_port} 失败,请立即通过控制台检查 SSH 配置${PLAIN}"
            fi
            press_any_key_to_continue
            continue
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
    local password_login_text pubkey_login_text

    pass_auth=$(get_sshd_option "PasswordAuthentication" "yes")
    pubkey_auth=$(get_sshd_option "PubkeyAuthentication" "yes")

    [[ "$pass_auth" == "yes" ]] && has_password=1
    [[ "$pubkey_auth" == "yes" ]] && has_pubkey=1

    if [[ "$pass_auth" == "yes" ]]; then
        password_login_text="${GREEN}开启${PLAIN}"
    else
        password_login_text="${RED}关闭${PLAIN}"
    fi

    if [[ "$pubkey_auth" == "yes" ]]; then
        pubkey_login_text="${GREEN}开启${PLAIN}"
    else
        pubkey_login_text="${RED}关闭${PLAIN}"
    fi

    local enabled_count=$((has_password + has_pubkey))

    echo -e "${BLUE}==== 登录方式 ====${PLAIN}"
    echo -e "${BLUE}密码 ${password_login_text} | 密钥 ${pubkey_login_text}"
    echo

    if [[ $enabled_count -le 1 ]]; then
        echo -e "${RED}当前仅剩一种登录方式,禁止关闭全部登录方式${PLAIN}"
        press_any_key_to_continue
        return
    fi

    echo -e "${GREEN}1.关闭密码登录${PLAIN}"
    echo -e "${GREEN}2.关闭密钥登录${PLAIN}"
    echo -e "${YELLOW}0.返回上级${PLAIN}"
    read -p "$(echo -e "${BLUE}请输入选项 [0-2]: ${PLAIN}")" disable_choice
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
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            press_any_key_to_continue
            ;;
    esac
}

change_timezone() {
    if ! command -v timedatectl >/dev/null; then
        echo -e "${RED}未安装 timedatectl,无法自动设置时区${PLAIN}"
        press_any_key_to_continue
        return
    fi

    _timezone_is_valid() {
        local tz="$1"
        [[ "$tz" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || return 1
        [[ -f "/usr/share/zoneinfo/$tz" ]] || return 1
        return 0
    }

    _timezone_get_system_tz() {
        local sys_tz
        sys_tz=$(timedatectl show -p Timezone --value 2>/dev/null | xargs)
        echo "${sys_tz:-未知}"
    }

    _timezone_detect_recommended() {
        local tz=""
        if ! command -v curl >/dev/null; then
            echo -e "${YELLOW}未检测到 curl,正在尝试安装...${PLAIN}" >&2
            pkg_install curl >/dev/null 2>&1 || return 1
        fi

        tz=$(curl -fsSL --connect-timeout 5 --max-time 8 https://ipapi.co/timezone 2>/dev/null | tr -d '\r' | xargs)
        _timezone_is_valid "$tz" || return 1
        echo "$tz"
    }

    _timezone_apply() {
        local tz="$1"
        if ! _timezone_is_valid "$tz"; then
            echo -e "${RED}无效的时区名称: ${tz}${PLAIN}"
            return 1
        fi

        echo -e "${YELLOW}正在设置时区为 ${tz} ...${PLAIN}"
        if timedatectl set-timezone "$tz"; then
            echo -e "${GREEN}✔ 设置成功! 当前时间: $(date)${PLAIN}"
            return 0
        fi

        echo -e "${RED}✘ 设置失败${PLAIN}"
        return 1
    }

    echo -e "${YELLOW}正在检测推荐时区...${PLAIN}"
    local current_tz_web
    current_tz_web=$(_timezone_detect_recommended || true)

    while true; do
        local sys_tz
        sys_tz=$(_timezone_get_system_tz)
        clear
        echo -e "${BLUE}======= 时区管理 =====${PLAIN}"
        echo -e "${YELLOW}当前 ${sys_tz}${PLAIN}"
        echo -e "${YELLOW}推荐 ${current_tz_web:-不可用}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}推荐时区  ${GREEN}2.${PLAIN}国家代码"
        echo -e "${GREEN}3.${PLAIN}手动输入  ${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"
        
        read -p "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" choice
        choice=$(echo "$choice" | xargs)
        
        case "$choice" in
            1)
                if [ -n "$current_tz_web" ]; then
                    _timezone_apply "$current_tz_web"
                else
                    echo -e "${YELLOW}当前无法获取推荐时区,请使用国家代码或手动输入${PLAIN}"
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

                mapfile -t lines < <(awk -v code="$input_code" '$1 ~ ("(^|,)" code "(,|$)") {print $3}' "$zone_tab" | sort -u)
                
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
                    _timezone_apply "$sel_tz"
                else
                    echo -e "${RED}无效编号${PLAIN}"
                fi
                press_any_key_to_continue
                ;;
            3)
                read -rp "$(echo -e "${BLUE}请输入时区全称 (例: Asia/Shanghai): ${PLAIN}")" manual_tz
                manual_tz=$(echo "$manual_tz" | xargs)
                if [ -n "$manual_tz" ]; then
                    _timezone_apply "$manual_tz"
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

check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -qi "debian" /etc/issue; then
        release="debian"
    elif grep -qi "ubuntu" /etc/issue; then
        release="ubuntu"
    elif grep -qiE "centos|red hat|redhat" /etc/issue; then
        release="centos"
    elif grep -qi "debian" /proc/version; then
        release="debian"
    elif grep -qi "ubuntu" /proc/version; then
        release="ubuntu"
    elif grep -qiE "centos|red hat|redhat" /proc/version; then
        release="centos"
    fi
}

first_job() {
    if [[ "${release}" == "centos" ]]; then
        yum install -y xz openssl gawk file wget cpio gzip iproute util-linux
    elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
        apt-get update
        apt-get install -y xz-utils openssl gawk file wget cpio gzip iproute2 util-linux
    fi
}

dependence() {
    Full='0'
    for BIN_DEP in $(echo "$1" | sed 's/,/\n/g'); do
        if [[ -n "$BIN_DEP" ]]; then
            Found='0'
            for BIN_PATH in $(echo "$PATH" | sed 's/:/\n/g'); do
                ls "$BIN_PATH/$BIN_DEP" >/dev/null 2>&1
                if [ $? == '0' ]; then
                    Found='1'
                    break
                fi
            done
            if [ "$Found" == '1' ]; then
                echo -en "[\033[32mok\033[0m]\t"
            else
                Full='1'
                echo -en "[\033[31mNot Install\033[0m]"
            fi
            echo -en "\t$BIN_DEP\n"
        fi
    done
    if [ "$Full" == '1' ]; then
        echo -ne "\n\033[31mError! \033[0mPlease use '\033[33mapt-get\033[0m' or '\033[33myum\033[0m' install it.\n\n\n"
        exit 1
    fi
}

selectMirror() {
    local dist="$1"
    local ver="${2:-amd64}"
    local temp mirror_url current
    local -a mirrors

    [[ -n "$dist" && -n "$ver" ]] || return 1
    temp="SUB_MIRROR/dists/${dist}/main/installer-${ver}/current/images/netboot/debian-installer/${ver}/initrd.gz"

    mirrors+=("https://deb.debian.org/debian" "https://archive.debian.org/debian")

    for current in "${mirrors[@]}"; do
        mirror_url="${temp/SUB_MIRROR/$current}"
        if wget --spider --timeout=3 -o /dev/null "$mirror_url"; then
            echo "$current"
            return 0
        fi
    done

    return 1
}

netmask() {
    n="${1:-32}"
    b=""
    m=""
    for ((i=0;i<32;i++)); do
        [ $i -lt $n ] && b="${b}1" || b="${b}0"
    done
    for ((i=0;i<4;i++)); do
        s=$(echo "$b" | cut -c$[$[$i*8]+1]-$[$[$i+1]*8])
        [ "$m" == "" ] && m="$((2#${s}))" || m="${m}.$((2#${s}))"
    done
    echo "$m"
}

getInterface() {
    interface=""
    Interfaces=$(cat /proc/net/dev | grep ':' | cut -d':' -f1 | sed 's/\s//g' | grep -iv '^lo\|^sit\|^stf\|^gif\|^dummy\|^vmnet\|^vir\|^gre\|^ipip\|^ppp\|^bond\|^tun\|^tap\|^ip6gre\|^ip6tnl\|^teql\|^ocserv\|^vpn')
    defaultRoute=$(ip route show default | grep "^default")
    for item in $Interfaces; do
        [ -n "$item" ] || continue
        echo "$defaultRoute" | grep -q "$item"
        [ $? -eq 0 ] && interface="$item" && break
    done
    echo "$interface"
}

getDisk() {
    local root_source root_disk disks
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null | head -n1)
    if [[ -n "$root_source" ]]; then
        root_disk=$(lsblk -ndo PKNAME "$root_source" 2>/dev/null | tail -n1)
        if [[ "$root_disk" =~ ^dm- ]]; then
            root_disk=$(lsblk -ndo PKNAME "/dev/$root_disk" 2>/dev/null | tail -n1)
        fi
        if [[ -n "$root_disk" ]]; then
            echo "/dev/$root_disk"
            return
        fi
    fi
    disks=$(lsblk | sed 's/[[:space:]]*$//g' | grep "disk$" | cut -d' ' -f1 | grep -v "fd[0-9]*\|sr[0-9]*" | head -n1)
    [ -n "$disks" ] || echo ""
    echo "$disks" | grep -q "/dev"
    [ $? -eq 0 ] && echo "$disks" || echo "/dev/$disks"
}

getGrub() {
    Boot="${1:-/boot}"
    folder=$(find "$Boot" -type d -name "grub*" 2>/dev/null | head -n1)
    [ -n "$folder" ] || return
    fileName=$(ls -1 "$folder" 2>/dev/null | grep '^grub.conf$\|^grub.cfg$')
    if [ -z "$fileName" ]; then
        ls -1 "$folder" 2>/dev/null | grep -q '^grubenv$'
        [ $? -eq 0 ] || return
        folder=$(find "$Boot" -type f -name "grubenv" 2>/dev/null | xargs dirname | grep -v "^$folder" | head -n1)
        [ -n "$folder" ] || return
        fileName=$(ls -1 "$folder" 2>/dev/null | grep '^grub.conf$\|^grub.cfg$')
    fi
    [ -n "$fileName" ] || return
    [ "$fileName" == "grub.cfg" ] && ver="0" || ver="1"
    echo "${folder}:${fileName}:${ver}"
}

lowMem() {
    mem=$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | grep -o "[0-9]*")
    [ -n "$mem" ] || return 0
    [ "$mem" -le "524288" ] && return 1 || return 0
}

validate_grub_config() {
    local grub_file="$1"
    if command -v grub-script-check >/dev/null 2>&1; then
        grub-script-check "$grub_file" >/tmp/grub-script-check.log 2>&1
        return $?
    elif command -v grub2-script-check >/dev/null 2>&1; then
        grub2-script-check "$grub_file" >/tmp/grub-script-check.log 2>&1
        return $?
    fi
    local open_count close_count
    open_count=$(grep -o '{' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
    close_count=$(grep -o '}' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
    if grep -q 'menuentry ' "$grub_file" && [[ "$open_count" == "$close_count" ]]; then
        echo "Warning: grub-script-check/grub2-script-check not found, fallback to basic GRUB sanity check."
        : >/tmp/grub-script-check.log
        return 0
    fi
    echo "Error! grub-script-check/grub2-script-check not found and fallback GRUB check failed."
    return 1
}

detect_current_ssh_port() {
    local port=''
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] && [[ -f /etc/ssh/sshd_config ]]; then
        port=$(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | tail -n1)
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || port='22'
    echo "$port"
}

installnet_main() {
    local debian_version="$1"
    local root_password="$2"
    local ssh_port="${3:-22}"
    local ipAddr='' ipMask='' ipGate='' ipDNS='' interface='' iAddr=''
    local IncDisk='' DIST='' LinuxMirror='' MirrorHost='' MirrorFolder=''
    local Grub='' GRUBDIR='' GRUBFILE='' GRUBVER='' GRUB_BACKUP=''
    local myPASSWORD='' READGRUB='' LoadNum='' CFG0='' CFG1='' CFG2='' INSERTGRUB=''
    local Type='' LinuxKernel='' LinuxIMG='' Add_OPTION='' BOOT_OPTION='' GRUB_TMP=''
    local partman_early_command='' late_command=''

    [[ "$EUID" -ne '0' ]] && echo "Error: This script must be run as root!" && return 1

    case "$debian_version" in
        11) DIST='bullseye' ;;
        12) DIST='bookworm' ;;
        13) DIST='trixie' ;;
        *) echo "Error! Unsupported Debian version: ${debian_version}"; return 1 ;;
    esac

    Grub=$(getGrub "/boot")
    [[ -n "$Grub" ]] || { echo "Error! Not Found grub."; return 1; }
    GRUBDIR=$(echo "$Grub" | cut -d':' -f1)
    GRUBFILE=$(echo "$Grub" | cut -d':' -f2)
    GRUBVER=$(echo "$Grub" | cut -d':' -f3)
    [[ "$GRUBVER" == "0" ]] || { echo "Error! Only GRUB2 is supported in safe mode."; return 1; }

    clear && echo -e "\n${BLUE}# Check Dependence${PLAIN}\n"
    dependence ip,wget,awk,grep,sed,cut,cat,lsblk,cpio,gzip,find,dirname,basename,openssl

    interface=$(getInterface)
    [[ -n "$interface" ]] || { echo "Error! Network interface not found."; return 1; }
    iAddr=$(ip -4 addr show dev "$interface" | awk '/inet /{print $2; exit}')
    ipAddr="${iAddr%/*}"
    ipMask=$(netmask "${iAddr#*/}")
    ipGate=$(ip route show default | awk '/^default/{print $3; exit}')
    ipDNS=$(awk '/^nameserver /{print $2; exit}' /etc/resolv.conf 2>/dev/null)
    [[ -n "$ipDNS" ]] || ipDNS='8.8.8.8'
    [[ -n "$ipAddr" && -n "$ipMask" && -n "$ipGate" ]] || { echo "Error! Invalid network config."; return 1; }

    IncDisk=$(getDisk)
    [[ -n "$IncDisk" ]] || { echo "Error! Target disk not found."; return 1; }

    myPASSWORD="$(openssl passwd -1 "$root_password")"
    LinuxMirror=$(selectMirror "$DIST" "amd64")
    [[ -n "$LinuxMirror" ]] || { echo "Error! Invalid Debian mirror."; return 1; }
    clear && echo -e "\n${BLUE}# Install${PLAIN}\n"
    echo -e "\n${YELLOW}[Debian] [${DIST}] [amd64] Downloading...${PLAIN}"

    MirrorHost="$(echo "$LinuxMirror" | awk -F'://|/' '{print $2}')"
    MirrorFolder="$(echo "$LinuxMirror" | awk -F"${MirrorHost}" '{print $2}')"
    [[ -n "$MirrorFolder" ]] || MirrorFolder="/"

    wget -qO '/tmp/initrd.img' "${LinuxMirror}/dists/${DIST}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz" || {
        echo "Error! Download 'initrd.img' failed."
        return 1
    }
    wget -qO '/tmp/vmlinuz' "${LinuxMirror}/dists/${DIST}/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux" || {
        echo "Error! Download 'vmlinuz' failed."
        return 1
    }

    [[ -f "${GRUBDIR}/${GRUBFILE}" ]] || { echo "Error! Not Found ${GRUBFILE}."; return 1; }
    GRUB_BACKUP="${GRUBDIR}/${GRUBFILE}.installnet.$(date +%Y%m%d%H%M%S).bak"
    cp -f "${GRUBDIR}/${GRUBFILE}" "$GRUB_BACKUP" || { echo "Error! Backup grub file failed."; return 1; }

    READGRUB='/tmp/grub.read'
    awk '
    /^[[:space:]]*menuentry[[:space:]]/ {
      if (found) exit
      found = 1
      depth = 0
    }
    found {
      print
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      if (depth == 0) exit
    }
    ' "$GRUBDIR/$GRUBFILE" > "$READGRUB"
    LoadNum="$(grep -c 'menuentry ' "$READGRUB")"
    if [[ "$LoadNum" -eq '1' ]]; then
        sed '/^$/d' "$READGRUB" >/tmp/grub.new
    elif [[ "$LoadNum" -gt '1' ]]; then
        CFG0="$(awk '/menuentry /{print NR}' "$READGRUB" | head -n 1)"
        CFG2="$(awk '/menuentry /{print NR}' "$READGRUB" | head -n 2 | tail -n 1)"
        CFG1=""
        for tmpCFG in $(awk '/}/{print NR}' "$READGRUB"); do
            [ "$tmpCFG" -gt "$CFG0" -a "$tmpCFG" -lt "$CFG2" ] && CFG1="$tmpCFG"
        done
        [[ -z "$CFG1" ]] && { echo "Error! read $GRUBFILE. "; return 1; }
        sed -n "$CFG0,$CFG1"p "$READGRUB" >/tmp/grub.new
        [[ -f /tmp/grub.new ]] && [[ "$(grep -c '{' /tmp/grub.new)" -eq "$(grep -c '}' /tmp/grub.new)" ]] || {
            echo -ne "\033[31mError! \033[0mNot configure $GRUBFILE. \n"; return 1
        }
    fi
    [ ! -f /tmp/grub.new ] && echo "Error! $GRUBFILE. " && return 1
    sed -i "/menuentry.*/c\menuentry\ \'Install OS \[$DIST\ amd64\]\'\ --class debian\ --class\ gnu-linux\ --class\ gnu\ --class\ os\ \{" /tmp/grub.new
    sed -i "/echo.*Loading/d" /tmp/grub.new
    INSERTGRUB="$(awk '/menuentry /{print NR}' "$GRUBDIR/$GRUBFILE" | head -n 1)"
    [[ -z "$INSERTGRUB" || "$INSERTGRUB" -le 0 ]] && echo "Error! read grub insert position failed." && return 1

    [[ -n "$(grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new | awk '{print $2}' | tail -n 1 | grep '^/boot/')" ]] && Type='InBoot' || Type='NoBoot'
    LinuxKernel="$(grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new | awk '{print $1}' | head -n 1)"
    [[ -z "$LinuxKernel" ]] && echo "Error! read grub config! " && return 1
    LinuxIMG="$(grep 'initrd.*/' /tmp/grub.new | awk '{print $1}' | tail -n 1)"
    [ -z "$LinuxIMG" ] && sed -i "/$LinuxKernel.*\//a\\\tinitrd\ \/" /tmp/grub.new && LinuxIMG='initrd'
    Add_OPTION=""
    lowMem || Add_OPTION=" lowmem=+0"
    BOOT_OPTION="auto=true${Add_OPTION} hostname=debian domain= quiet"
    [[ "$Type" == 'InBoot' ]] && {
        sed -i "/$LinuxKernel.*\//c\\\t$LinuxKernel\\t\/boot\/vmlinuz $BOOT_OPTION" /tmp/grub.new
        sed -i "/$LinuxIMG.*\//c\\\t$LinuxIMG\\t\/boot\/initrd.img" /tmp/grub.new
    }
    [[ "$Type" == 'NoBoot' ]] && {
        sed -i "/$LinuxKernel.*\//c\\\t$LinuxKernel\\t\/vmlinuz $BOOT_OPTION" /tmp/grub.new
        sed -i "/$LinuxIMG.*\//c\\\t$LinuxIMG\\t\/initrd.img" /tmp/grub.new
    }
    sed -i '$a\\n' /tmp/grub.new
    GRUB_TMP="$(mktemp)"
    head -n $((INSERTGRUB-1)) "$GRUBDIR/$GRUBFILE" >"$GRUB_TMP"
    cat /tmp/grub.new >>"$GRUB_TMP"
    tail -n +"$INSERTGRUB" "$GRUBDIR/$GRUBFILE" >>"$GRUB_TMP"
    cp -f "$GRUB_TMP" "$GRUBDIR/$GRUBFILE"
    rm -f "$GRUB_TMP"

    if ! validate_grub_config "$GRUBDIR/$GRUBFILE"; then
        cp -f "$GRUB_BACKUP" "$GRUBDIR/$GRUBFILE"
        echo "Error! GRUB syntax check failed, rollback done. log: /tmp/grub-script-check.log"
        return 1
    fi
    [[ -f "$GRUBDIR/grubenv" ]] && sed -i 's/saved_entry/#saved_entry/g' "$GRUBDIR/grubenv"

    rm -rf /tmp/boot
    mkdir -p /tmp/boot
    cd /tmp/boot || return 1

    mv -f /tmp/initrd.img /tmp/initrd.img.gz
    gzip -d < /tmp/initrd.img.gz | cpio --extract --verbose --make-directories --no-absolute-filenames >>/dev/null 2>&1

    partman_early_command="debconf-set partman-auto/disk ${IncDisk}"
    late_command="sed -ri 's/^#?Port.*/Port ${ssh_port}/g' /target/etc/ssh/sshd_config; sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' /target/etc/ssh/sshd_config; sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/g' /target/etc/ssh/sshd_config"
cat >/tmp/boot/preseed.cfg<<EOF
d-i debian-installer/locale string en_US
d-i console-setup/layoutcode string us
d-i keyboard-configuration/xkb-keymap string us
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string $ipAddr
d-i netcfg/get_netmask string $ipMask
d-i netcfg/get_gateway string $ipGate
d-i netcfg/get_nameservers string $ipDNS
d-i netcfg/confirm_static boolean true
d-i hw-detect/load_firmware boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string $MirrorHost
d-i mirror/http/directory string $MirrorFolder
d-i mirror/http/proxy string
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password $myPASSWORD
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean false
d-i partman/early_command string $partman_early_command
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/mount_style select uuid
d-i partman/choose_partition select finish
d-i partman-auto/method string regular
d-i partman-auto/init_automatically_partition select Guided - use entire disk
d-i partman-auto/choose_recipe select All files in one partition (recommended for new users)
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string $IncDisk
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i preseed/late_command string $late_command
EOF

    find . | cpio -H newc --create --verbose | gzip -9 > /tmp/initrd.img
    cp -f /tmp/initrd.img /boot/initrd.img
    cp -f /tmp/vmlinuz /boot/vmlinuz
    chown root:root "$GRUBDIR/$GRUBFILE"
    chmod 444 "$GRUBDIR/$GRUBFILE"
    echo -e "${YELLOW}安装引导已写入，系统将在 3 秒后自动重启继续安装。${PLAIN}"
    sleep 3 && reboot || sudo reboot >/dev/null 2>&1
}

reinstall_debian() {
    local debian_version="$1"
    local ssh_port target_disk confirm pw pw2
    read -r -s -p " 请设置 root 密码: " pw
    echo
    if [[ -z "$pw" ]]; then
        echo -e "${RED}密码不能为空。${PLAIN}"
        return
    fi
    read -r -s -p " 请再次输入 root 密码: " pw2
    echo
    if [[ "$pw" != "$pw2" ]]; then
        echo -e "${RED}两次输入密码不一致。${PLAIN}"
        return
    fi

    ssh_port="$(detect_current_ssh_port)"
    target_disk="$(getDisk)"
    if [[ -z "$target_disk" ]]; then
        echo -e "${RED}未检测到目标磁盘。${PLAIN}"
        return
    fi

    echo -e "${YELLOW} 将使用 Debian ${debian_version} 执行重装${PLAIN}"
    echo -e "${YELLOW} 目标磁盘: ${target_disk}${PLAIN}"
    echo -e "${YELLOW} 重装后「SSH」端口将保持为: ${ssh_port}${PLAIN}"
    echo -e "${YELLOW} 确认后会写入安装引导并在完成后自动重启${PLAIN}"
    read -r -p " 输入「YES」确认开始重装,其它键取消: " confirm
    [[ "$confirm" == "YES" ]] || { echo -e "${YELLOW} 已取消重装 ${PLAIN}"; return; }

    installnet_main "${debian_version}" "${pw}" "${ssh_port}"
}

reinstall_debian11() {
    reinstall_debian 11
}

reinstall_debian12() {
    reinstall_debian 12
}

reinstall_debian13() {
    reinstall_debian 13
}

start_menu() {
    clear
    echo -e "${BLUE}一键网络重装管理脚本${PLAIN}"
    echo
    echo -e "${BLUE}————————————重装系统————————————${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 重装 Debian 11"
    echo -e " ${GREEN}2.${PLAIN} 重装 Debian 12"
    echo -e " ${GREEN}3.${PLAIN} 重装 Debian 13"
    echo -e " ${YELLOW}0.${PLAIN} 返回菜单"
    echo
}

main_loop() {
    while true; do
        start_menu
        read -p " 请输入数字 [0-3]: " num
        num=$(echo "$num" | grep -oE '^[0-9]+$')
        case "$num" in
            1) reinstall_debian11 ;;
            2) reinstall_debian12 ;;
            3) reinstall_debian13 ;;
            0) break ;;
            *)
                clear
                echo -e "${RED}请输入正确数字 [0-3]${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

reinstall_menu() {
    PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
    export PATH
    check_sys
    [[ "$EUID" -ne '0' ]] && echo -e "${RED}请使用 root 权限运行此脚本${PLAIN}" && return
    [[ -z "${release:-}" ]] && echo -e "${RED}暂不支持当前系统${PLAIN}" && press_any_key_to_continue && return
    first_job
    main_loop
}

acme_exec() {
    [[ -f "$ACME_BIN" ]] || return 1
    bash "$ACME_BIN" "$@"
}

acme_is_installed() {
    acme_exec -v >/dev/null 2>&1
}

acme_ensure_cert_path() {
    mkdir -p "$ACME_CERT_PATH"
}

acme_has_ipv4() {
    ip -4 addr show scope global 2>/dev/null | grep -q inet
}

acme_get_download_url() {
    echo "https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
}

acme_pkg_install() {
    local pm
    pm=$(detect_pkg_manager)

    case "$pm" in
        apt)    apt update && apt install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        apk)    apk add "$@" ;;
        pacman) pacman -Sy --noconfirm "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        *)      return 1 ;;
    esac
}

acme_install_dependencies() {
    local pm packages=()
    pm=$(detect_pkg_manager)

    case "$pm" in
        apt)    packages=(curl wget socat openssl dnsutils cron tar ca-certificates) ;;
        dnf)    packages=(curl wget socat openssl bind-utils cronie tar ca-certificates) ;;
        yum)    packages=(curl wget socat openssl bind-utils cronie tar ca-certificates) ;;
        apk)    packages=(curl wget socat openssl bind-tools dcron tar ca-certificates) ;;
        pacman) packages=(curl wget socat openssl bind cronie tar ca-certificates) ;;
        zypper) packages=(curl wget socat openssl bind-utils cron tar ca-certificates) ;;
        *)
            echo -e "${RED}当前系统暂不支持自动安装 ACME 依赖${PLAIN}"
            return 1
            ;;
    esac

    echo -e "${YELLOW}正在安装 ACME 依赖...${PLAIN}"
    acme_pkg_install "${packages[@]}"
}

acme_enable_cron() {
    systemctl start cron 2>/dev/null || systemctl start cronie 2>/dev/null || true
    systemctl enable cron 2>/dev/null || systemctl enable cronie 2>/dev/null || true
}

acme_install_core() {
    local tempdir tarball acme_tar_url automail email current_version

    acme_ensure_cert_path

    if acme_is_installed; then
        current_version=$(acme_exec -v 2>/dev/null | head -n1)
        echo -e "${YELLOW}检测到 acme.sh 已安装${PLAIN}${current_version:+: ${GREEN}${current_version}${PLAIN}}"
        echo -e "${YELLOW}正在更新 acme.sh...${PLAIN}"
        acme_exec --upgrade --auto-upgrade >/dev/null 2>&1 || {
            echo -e "${RED}acme.sh 更新失败${PLAIN}"
            return 1
        }
        acme_exec --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
        echo -e "${GREEN}acme.sh 已更新完成${PLAIN}"
        return 0
    fi

    acme_install_dependencies || return 1
    acme_enable_cron

    automail=$(date +%s%N | md5sum | cut -c 1-16)
    email="${automail}@gmail.com"
    acme_tar_url=$(acme_get_download_url)
    tempdir=$(mktemp -d /tmp/zero-acme.XXXXXX) || {
        echo -e "${RED}无法创建临时目录${PLAIN}"
        return 1
    }
    tarball="$tempdir/master.tar.gz"

    if ! wget -O "$tarball" "$acme_tar_url" 2>/dev/null; then
        if ! curl -fsSL "$acme_tar_url" -o "$tarball" 2>/dev/null; then
            echo -e "${RED}acme.sh 下载失败${PLAIN}"
            rm -rf "$tempdir"
            return 1
        fi
    fi

    if ! tar zxf "$tarball" -C "$tempdir"; then
        echo -e "${RED}acme.sh 解压失败${PLAIN}"
        rm -rf "$tempdir"
        return 1
    fi

    if ! (cd "$tempdir/acme.sh-master" && ./acme.sh --install --accountemail "$email"); then
        echo -e "${RED}acme.sh 安装失败${PLAIN}"
        rm -rf "$tempdir"
        return 1
    fi

    rm -rf "$tempdir"
    acme_exec --upgrade --auto-upgrade >/dev/null 2>&1 || true
    acme_exec --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    if acme_is_installed; then
        echo -e "${GREEN}acme.sh 安装成功${PLAIN}"
        return 0
    fi

    echo -e "${RED}acme.sh 安装失败${PLAIN}"
    return 1
}

acme_uninstall() {
    if ! acme_is_installed; then
        echo -e "${YELLOW}当前未安装 acme.sh${PLAIN}"
        press_any_key_to_continue
        return
    fi

    if acme_exec --uninstall; then
        rm -rf "$ACME_HOME"
        echo -e "${GREEN}acme.sh 已卸载${PLAIN}"
    else
        echo -e "${RED}acme.sh 卸载失败，请手动检查${PLAIN}"
    fi
    press_any_key_to_continue
}

acme_ensure_installed() {
    if acme_is_installed; then
        return 0
    fi

    echo -e "${YELLOW}检测到尚未安装 acme.sh，正在自动安装...${PLAIN}"
    acme_install_core || return 1
    acme_is_installed || {
        echo -e "${RED}acme.sh 安装失败，无法继续操作${PLAIN}"
        return 1
    }
}

acme_get_cert_list() {
    acme_exec --list 2>/dev/null | tail -n +2
}

acme_display_cert_list() {
    local cert_list
    cert_list=$(acme_get_cert_list)

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

acme_validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

acme_get_cf_credentials() {
    local cfgak cfemail

    read -rp "$(echo -e "${BLUE}请输入 CloudFlare Global API Key: ${PLAIN}")" cfgak
    if [[ -z "$cfgak" ]]; then
        echo -e "${RED}未输入 CloudFlare Global API Key${PLAIN}"
        return 1
    fi
    export CF_Key="$cfgak"

    read -rp "$(echo -e "${BLUE}请输入 CloudFlare 登录邮箱: ${PLAIN}")" cfemail
    if [[ -z "$cfemail" ]]; then
        echo -e "${RED}未输入 CloudFlare 登录邮箱${PLAIN}"
        return 1
    fi
    export CF_Email="$cfemail"
    return 0
}

acme_check_cert_result() {
    local domain="$1"

    acme_ensure_cert_path
    if [[ -s "$ACME_CERT_PATH/$domain.crt" && -s "$ACME_CERT_PATH/$domain.key" ]]; then
        echo -e "${GREEN}证书申请成功${PLAIN}"
        echo -e "${YELLOW}证书: $ACME_CERT_PATH/$domain.crt${PLAIN}"
        echo -e "${YELLOW}私钥: $ACME_CERT_PATH/$domain.key${PLAIN}"
        return 0
    fi

    echo -e "${RED}证书申请失败${PLAIN}"
    return 1
}

acme_install_issued_cert() {
    local issue_domain="$1"
    local save_name="$2"

    acme_exec --install-cert -d "$issue_domain" --key-file "$ACME_CERT_PATH/$save_name.key" --fullchain-file "$ACME_CERT_PATH/$save_name.crt" --ecc || return 1
    acme_check_cert_result "$save_name"
}

acme_print_issue_failed() {
    echo -e "${RED}证书签发失败，已跳过证书安装${PLAIN}"
    echo -e "${YELLOW}如上方提示 rateLimited，请等待限制时间结束后重试${PLAIN}"
}

ACME_PORT80_FIREWALL_BACKUP=""
ACME_PORT80_FIREWALL_CHANGED=0

acme_reset_port_80_firewall_state() {
    if [[ -n "$ACME_PORT80_FIREWALL_BACKUP" ]]; then
        firewall_remove_backup "$ACME_PORT80_FIREWALL_BACKUP"
    fi
    ACME_PORT80_FIREWALL_BACKUP=""
    ACME_PORT80_FIREWALL_CHANGED=0
}

acme_restore_port_80_firewall_if_needed() {
    if (( ACME_PORT80_FIREWALL_CHANGED == 1 )) && [[ -n "$ACME_PORT80_FIREWALL_BACKUP" ]]; then
        if firewall_restore_backup "$ACME_PORT80_FIREWALL_BACKUP"; then
            firewall_save_rules >/dev/null 2>&1 || true
        else
            echo -e "${RED}80 端口防火墙回滚失败,请手动检查当前规则${PLAIN}"
        fi
    fi
    acme_reset_port_80_firewall_state
}

acme_check_port_80() {
    local firewall_opened=0
    local zero_fw_managed=0
    local cmd backup=""

    acme_reset_port_80_firewall_state

    if ! command -v lsof >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 lsof，正在安装...${PLAIN}"
        acme_pkg_install lsof >/dev/null 2>&1 || {
            echo -e "${RED}lsof 安装失败，无法检测 80 端口${PLAIN}"
            return 1
        }
    fi

    echo -e "${YELLOW}正在检测 80 端口状态...${PLAIN}"

    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        firewall_rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || continue
        zero_fw_managed=1
        if ! firewall_rule_exists "$cmd" filter "$ZERO_FW_CHAIN" -p tcp --dport 80 -j ACCEPT; then
            if [[ -z "$backup" ]]; then
                backup=$(firewall_create_backup) || {
                    echo -e "${RED}创建防火墙备份失败,已取消本次申请${PLAIN}"
                    return 1
                }
            fi
            if ! firewall_apply_port_rule "$cmd" open tcp 80; then
                [[ -n "$backup" ]] && firewall_restore_backup "$backup" >/dev/null 2>&1 || true
                [[ -n "$backup" ]] && firewall_remove_backup "$backup"
                echo -e "${RED}临时放行 80 端口失败,已恢复修改前规则${PLAIN}"
                return 1
            fi
            firewall_opened=1
        fi
    done
    if (( zero_fw_managed == 1 && firewall_opened == 1 )); then
        ACME_PORT80_FIREWALL_BACKUP="$backup"
        ACME_PORT80_FIREWALL_CHANGED=1
        echo -e "${GREEN}✓ 已临时放行 80 端口 (Zero FireWall)${PLAIN}"
    elif (( zero_fw_managed == 1 )); then
        echo -e "${GREEN}Zero FireWall 已放行 80 端口${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 Zero FireWall 正在接管入站规则，本步骤不会自动修改其他防火墙${PLAIN}"
        echo -e "${YELLOW}如需放行 80 端口，请先到 FireWall 菜单中处理${PLAIN}"
    fi

    local listen_pids
    listen_pids=$(lsof -t -iTCP:80 -sTCP:LISTEN 2>/dev/null | sort -u)
    if [[ -z "$listen_pids" ]]; then
        echo -e "${GREEN}检测到当前 80 端口未被占用${PLAIN}"
        return 0
    fi

    echo -e "${RED}检测到 80 端口被其他程序占用${PLAIN}"
    lsof -iTCP:80 -sTCP:LISTEN 2>/dev/null
    read -rp "$(echo -e "${BLUE}如需结束占用进程请输入 Y，其他键返回菜单 [Y/N]: ${PLAIN}")" yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        printf '%s\n' "$listen_pids" | xargs -r kill -9
        sleep 1
        return 0
    fi
    acme_restore_port_80_firewall_if_needed
    return 1
}

acme_issue_standalone() {
    local domain

    acme_ensure_installed || {
        press_any_key_to_continue
        return
    }

    acme_check_port_80 || {
        press_any_key_to_continue
        return
    }

    read -rp "$(echo -e "${BLUE}请输入解析完成的域名: ${PLAIN}")" domain
    domain=$(echo "$domain" | xargs)
    if [[ -z "$domain" ]]; then
        echo -e "${RED}未输入域名${PLAIN}"
        acme_restore_port_80_firewall_if_needed
        press_any_key_to_continue
        return
    fi
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        acme_restore_port_80_firewall_if_needed
        press_any_key_to_continue
        return
    fi

    acme_ensure_cert_path
    if ! acme_has_ipv4; then
        if ! acme_exec --issue -d "$domain" --standalone -k ec-256 --listen-v6 --insecure; then
            acme_print_issue_failed
            acme_restore_port_80_firewall_if_needed
            press_any_key_to_continue
            return
        fi
    else
        if ! acme_exec --issue -d "$domain" --standalone -k ec-256 --insecure; then
            acme_print_issue_failed
            acme_restore_port_80_firewall_if_needed
            press_any_key_to_continue
            return
        fi
    fi

    if (( ACME_PORT80_FIREWALL_CHANGED == 1 )); then
        firewall_save_rules >/dev/null 2>&1 || true
        acme_reset_port_80_firewall_state
    fi
    acme_install_issued_cert "$domain" "$domain" || echo -e "${RED}证书安装失败${PLAIN}"
    press_any_key_to_continue
}

acme_issue_cf_single() {
    local domain

    acme_ensure_installed || {
        press_any_key_to_continue
        return
    }

    read -rp "$(echo -e "${BLUE}请输入需要申请证书的域名: ${PLAIN}")" domain
    domain=$(echo "$domain" | xargs)
    if [[ -z "$domain" ]]; then
        echo -e "${RED}未输入域名${PLAIN}"
        press_any_key_to_continue
        return
    fi
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        press_any_key_to_continue
        return
    fi
    if ! acme_get_cf_credentials; then
        press_any_key_to_continue
        return
    fi

    acme_ensure_cert_path
    if ! acme_exec --issue --dns dns_cf -d "$domain" -k ec-256 --insecure; then
        acme_print_issue_failed
        press_any_key_to_continue
        return
    fi
    acme_install_issued_cert "$domain" "$domain" || echo -e "${RED}证书安装失败${PLAIN}"
    press_any_key_to_continue
}

acme_issue_cf_wildcard() {
    local domain

    acme_ensure_installed || {
        press_any_key_to_continue
        return
    }

    read -rp "$(echo -e "${BLUE}请输入需要申请证书的泛域名根域名: ${PLAIN}")" domain
    domain=$(echo "$domain" | xargs)
    if [[ -z "$domain" ]]; then
        echo -e "${RED}未输入域名${PLAIN}"
        press_any_key_to_continue
        return
    fi
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        press_any_key_to_continue
        return
    fi
    if ! acme_get_cf_credentials; then
        press_any_key_to_continue
        return
    fi

    acme_ensure_cert_path
    if ! acme_exec --issue --dns dns_cf -d "*.${domain}" -d "$domain" -k ec-256 --insecure; then
        acme_print_issue_failed
        press_any_key_to_continue
        return
    fi
    acme_install_issued_cert "*.${domain}" "$domain" || echo -e "${RED}证书安装失败${PLAIN}"
    press_any_key_to_continue
}

acme_revoke_cert() {
    local cert_list choice confirm selected_domain base_domain
    local -a domains=()

    acme_ensure_installed || {
        press_any_key_to_continue
        return
    }

    clear
    echo -e "${BLUE}================ 证书列表 ================${PLAIN}"
    if ! acme_display_cert_list; then
        press_any_key_to_continue
        return
    fi

    cert_list=$(acme_get_cert_list)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        domains+=("$(echo "$line" | awk '{print $1}')")
    done <<< "$cert_list"
    echo

    read -rp "$(echo -e "${BLUE}请输入要撤销的证书序号(0返回): ${PLAIN}")" choice
    choice=$(echo "$choice" | xargs)
    if [[ "$choice" == "0" ]]; then
        return
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#domains[@]} )); then
        echo -e "${RED}无效序号${PLAIN}"
        press_any_key_to_continue
        return
    fi

    selected_domain="${domains[$((choice-1))]}"
    echo -e "${YELLOW}即将撤销证书: ${selected_domain}${PLAIN}"
    read -rp "$(echo -e "${BLUE}确认撤销? [y/N]: ${PLAIN}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消操作${PLAIN}"
        press_any_key_to_continue
        return
    fi

    if ! acme_exec --revoke -d "$selected_domain" --ecc; then
        echo -e "${RED}证书撤销失败,本地文件未删除${PLAIN}"
        press_any_key_to_continue
        return
    fi
    if ! acme_exec --remove -d "$selected_domain" --ecc; then
        echo -e "${RED}证书移除失败,请手动检查 acme.sh 状态${PLAIN}"
        press_any_key_to_continue
        return
    fi
    rm -rf "$ACME_HOME/${selected_domain}_ecc"

    base_domain="${selected_domain#\*.}"
    rm -f "$ACME_CERT_PATH/$base_domain.crt" "$ACME_CERT_PATH/$base_domain.key"
    rm -f "$ACME_CERT_PATH/$selected_domain.crt" "$ACME_CERT_PATH/$selected_domain.key" 2>/dev/null || true

    echo -e "${GREEN}证书 ${selected_domain} 已撤销${PLAIN}"
    press_any_key_to_continue
}

acme_renew_cert() {
    acme_ensure_installed || {
        press_any_key_to_continue
        return
    }

    if acme_exec --cron; then
        echo -e "${GREEN}证书续期任务已执行${PLAIN}"
    else
        echo -e "${RED}证书续期执行失败${PLAIN}"
    fi
    press_any_key_to_continue
}

acme_switch_provider() {
    local provider

    acme_ensure_installed || {
        press_any_key_to_continue
        return
    }

    clear
    echo -e "${BLUE}======== 证书CA ========${PLAIN}"
    echo -e "${GREEN}1.LetsEncrypt${PLAIN}  ${GREEN}2.BuyPass${PLAIN}"
    echo -e "${GREEN}3.ZeroSSL${PLAIN}     ${YELLOW}0.返回菜单${PLAIN}"
    echo -e "${BLUE}========================${PLAIN}"
    read -rp "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" provider
    provider=$(echo "$provider" | xargs)

    case "$provider" in
        1)
            acme_exec --set-default-ca --server letsencrypt && echo -e "${GREEN}已切换到 LetsEncrypt${PLAIN}" || echo -e "${RED}切换失败${PLAIN}"
            ;;
        2)
            acme_exec --set-default-ca --server buypass && echo -e "${GREEN}已切换到 BuyPass${PLAIN}" || echo -e "${RED}切换失败${PLAIN}"
            ;;
        3)
            acme_exec --set-default-ca --server zerossl && echo -e "${GREEN}已切换到 ZeroSSL${PLAIN}" || echo -e "${RED}切换失败${PLAIN}"
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            ;;
    esac
    press_any_key_to_continue
}

acme_generate_self_signed_cert() {
    local default_domain="icloud.com.cn"
    local days=3650
    local domain key_file crt_file

    clear
    acme_ensure_cert_path
    read -rp "$(echo -e "${BLUE}请输入证书域名(默认: ${default_domain}): ${PLAIN}")" domain
    domain=$(echo "$domain" | xargs)
    domain="${domain:-$default_domain}"

    key_file="$ACME_CERT_PATH/${domain}.key"
    crt_file="$ACME_CERT_PATH/${domain}.crt"

    openssl ecparam -name prime256v1 -genkey -noout -out "$key_file" || {
        echo -e "${RED}私钥生成失败${PLAIN}"
        press_any_key_to_continue
        return
    }

    openssl req -new -x509 -key "$key_file" -out "$crt_file" -days "$days" -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" || {
        echo -e "${RED}证书生成失败${PLAIN}"
        press_any_key_to_continue
        return
    }

    chmod 644 "$crt_file"
    chmod 600 "$key_file"
    echo -e "${GREEN}自签证书生成完成${PLAIN}"
    echo -e "${YELLOW}证书: $crt_file${PLAIN}"
    echo -e "${YELLOW}私钥: $key_file${PLAIN}"
    press_any_key_to_continue
}

acme_menu() {
    while true; do
        clear
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e "         ${RED}证书申请${PLAIN}"
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN}安装Acme"
        echo -e " ${GREEN}2.${PLAIN}卸载Acme"
        echo -e "${BLUE}-------------${PLAIN}"
        echo -e " ${GREEN}3.${PLAIN}申请单域名证书 ${YELLOW}(80 端口申请)${PLAIN}"
        echo -e " ${GREEN}4.${PLAIN}申请单域名证书 ${YELLOW}(CF API 申请)${PLAIN}"
        echo -e " ${GREEN}5.${PLAIN}申请泛域名证书 ${YELLOW}(CF API 申请)${PLAIN}"
        echo -e "${BLUE}-------------${PLAIN}"
        echo -e " ${GREEN}6.${PLAIN}撤销已申请的证书"
        echo -e " ${GREEN}7.${PLAIN}续期已申请的证书"
        echo -e " ${GREEN}8.${PLAIN}切换证书颁发机构"
        echo -e " ${GREEN}9.${PLAIN}生成自签证书"
        echo -e "${BLUE}-------------${PLAIN}"
        echo -e " ${YELLOW}0.${PLAIN}返回菜单"
        echo
        read -rp "$(echo -e "${BLUE}请输入选项 [0-9]: ${PLAIN}")" acme_choice
        acme_choice=$(echo "$acme_choice" | xargs)

        case "$acme_choice" in
            1) acme_install_core; press_any_key_to_continue ;;
            2) acme_uninstall ;;
            3) acme_issue_standalone ;;
            4) acme_issue_cf_single ;;
            5) acme_issue_cf_wildcard ;;
            6) acme_revoke_cert ;;
            7) acme_renew_cert ;;
            8) acme_switch_provider ;;
            9) acme_generate_self_signed_cert ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

run_install_script() {
    bash <(curl -sL "$1")
}

install_snell()     { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/snell.sh"; }
install_mihomo()    { run_install_script "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/mihomo.sh"; }
install_system()    { reinstall_menu; }
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
    if (command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1) && command -v ip >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}[!] 未检测到完整的防火墙工具(iptables/ip6tables/ip),正在尝试安装...${PLAIN}"
    if ! firewall_install_tools; then
        echo -e "${RED}[!] 无法自动安装防火墙工具,请手动安装 iptables/ip6tables 和 iproute2${PLAIN}"
        return 1
    fi

    if (! command -v iptables >/dev/null 2>&1 && ! command -v ip6tables >/dev/null 2>&1) || ! command -v ip >/dev/null 2>&1; then
        echo -e "${RED}[!] 安装完成后仍缺少可用的防火墙工具或 ip 命令${PLAIN}"
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

firewall_port_spec_contains() {
    local port="$1"
    local spec="$2"

    if [[ "$spec" =~ ^[0-9]+$ ]]; then
        (( port == spec ))
        return
    fi

    if [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        (( port >= ${BASH_REMATCH[1]} && port <= ${BASH_REMATCH[2]} ))
        return
    fi

    return 1
}

firewall_chain_allows_tcp_port_for_ssh_change() {
    local cmd="$1"
    local port="$2"
    local line proto dport target

    firewall_supports_table "$cmd" filter || return 0
    firewall_rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || return 0
    firewall_chain_exists "$cmd" filter "$ZERO_FW_CHAIN" || return 0

    while IFS= read -r line; do
        [[ "$line" == "-A $ZERO_FW_CHAIN "* ]] || continue
        [[ "$line" == *"-m conntrack --ctstate ESTABLISHED,RELATED"* ]] && continue
        [[ "$line" == *"-m conntrack --ctstate RELATED,ESTABLISHED"* ]] && continue
        [[ "$line" == *"-i lo"* ]] && continue

        proto=""
        dport=""
        target=""

        [[ "$line" =~ -p[[:space:]]+([^[:space:]]+) ]] && proto="${BASH_REMATCH[1]}"
        [[ "$line" =~ --dport[[:space:]]+([^[:space:]]+) ]] && dport="${BASH_REMATCH[1]}"
        [[ "$line" =~ -j[[:space:]]+([^[:space:]]+) ]] && target="${BASH_REMATCH[1]}"

        [[ -n "$proto" && "$proto" != "tcp" ]] && continue
        [[ -n "$dport" ]] && ! firewall_port_spec_contains "$port" "$dport" && continue

        case "$target" in
            ACCEPT) return 0 ;;
            DROP)   return 1 ;;
        esac
    done < <("$cmd" -t filter -S "$ZERO_FW_CHAIN" 2>/dev/null)

    return 0
}

firewall_can_change_ssh_port() {
    local port="$1"
    local cmd
    local checked=0

    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        firewall_rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || continue
        checked=1
        firewall_chain_allows_tcp_port_for_ssh_change "$cmd" "$port" || return 1
    done

    (( checked == 0 )) && return 0
    return 0
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
        firewall_supports_table "$cmd" nat || continue
        firewall_chain_exists "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" && return 0
        firewall_rule_exists "$cmd" nat PREROUTING -j "$ZERO_PORT_JUMP_CHAIN" && return 0
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
    local MANAGED_BEGIN="# Zero.sh IP Priority BEGIN"
    local MANAGED_END="# Zero.sh IP Priority END"

    _get_current_priority() {
        if [[ -f "$GAI_CONF" ]] && {
            sed -n "/^${MANAGED_BEGIN}$/,/^${MANAGED_END}$/p" "$GAI_CONF" | grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100$' ||
            grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100[[:space:]]*$' "$GAI_CONF"
        }; then
            echo "IPv4 优先"
        elif [[ -f "$GAI_CONF" ]] && {
            sed -n "/^${MANAGED_BEGIN}$/,/^${MANAGED_END}$/p" "$GAI_CONF" | grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+10$' ||
            grep -qE '^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+10[[:space:]]*$' "$GAI_CONF"
        }; then
            echo "IPv6 优先"
        else
            echo "系统默认"
        fi
    }

    _remove_managed_priority() {
        if [[ -f "$GAI_CONF" ]]; then
            sed -i "/^${MANAGED_BEGIN}$/,/^${MANAGED_END}$/d" "$GAI_CONF"
        fi
    }

    _write_priority_block() {
        local mode="$1"
        local ipv4_mapped_precedence="10"

        [[ "$mode" == "ipv4" ]] && ipv4_mapped_precedence="100"

        _remove_managed_priority
        touch "$GAI_CONF"
        {
            echo
            echo "$MANAGED_BEGIN"
            echo "precedence ::1/128 50"
            echo "precedence ::/0 40"
            echo "precedence 2002::/16 30"
            echo "precedence ::/96 20"
            echo "precedence ::ffff:0:0/96 $ipv4_mapped_precedence"
            echo "$MANAGED_END"
        } >> "$GAI_CONF"
    }

    _cleanup_legacy_priority_rule() {
        if [[ -f "$GAI_CONF" ]]; then
            sed -i '/^precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]\+[0-9]\+[[:space:]]*$/d' "$GAI_CONF"
        fi
    }

    while true; do
        clear
        local current_priority
        current_priority=$(_get_current_priority)
        echo -e "${BLUE}====== IP优先级 ======${PLAIN}"
        echo -e "${YELLOW}当前优先级: ${GREEN}${current_priority}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}IPv4优先  ${GREEN}2.${PLAIN}IPv6优先"
        echo -e "${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"
        read -rp "$(echo -e "${BLUE}请输入选项 [0-2]: ${PLAIN}")" choice

        case "$choice" in
            1)
                _cleanup_legacy_priority_rule
                _write_priority_block "ipv4"
                echo -e "${GREEN}✔ 已设置为 IPv4 优先${PLAIN}"
                press_any_key_to_continue
                ;;
            2)
                _cleanup_legacy_priority_rule
                _write_priority_block "ipv6"
                echo -e "${GREEN}✔ 已设置为 IPv6 优先${PLAIN}"
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
        echo -e "${GREEN}  06.${PLAIN}配置BBR"
        echo -e "${GREEN}  07.${PLAIN}配置DNS"
        echo -e "${GREEN}  08.${PLAIN}配置SSH"
        echo -e "${GREEN}  09.${PLAIN}重启VPS"
        echo -e "${GREEN}  10.${PLAIN}配置SWAP"
        echo -e "${GREEN}  11.${PLAIN}配置ACME"
        echo -e "${GREEN}  12.${PLAIN}配置Snell"
        echo -e "${GREEN}  13.${PLAIN}配置Shoes"
        echo -e "${GREEN}  14.${PLAIN}配置Mihomo"
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
            6)  bbr_manage_menu ;;
            7)  dns_fix ;;
            8)  ssh_config_menu ;;
            9)  echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps ;;
            10) set_swap_menu ;;
            11) acme_menu ;;
            12) install_snell ;;
            13) install_shoes ;;
            14) install_mihomo ;;
            15) configure_firewall ;;
            16) install_wireproxy ;;
            17) install_warp ;;
            0)  clear; echo -e "${BLUE}「命运石之扉の选择,El Psy Kongroo」${PLAIN}"; sleep 0.6; clear; break ;;
            *)  clear; echo -e "${RED}[!] 无效选项，请重新选择${PLAIN}"; sleep 0.4 ;;
        esac
    done
}

main_menu
