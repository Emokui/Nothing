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

trim_input() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_numeric_choice() {
    local value
    value=$(trim_input "$1")
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((10#$value))"
    else
        printf '%s' "$value"
    fi
}

read_menu_choice() {
    local prompt="$1"
    local value
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" value
    normalize_numeric_choice "$value"
}

show_invalid_option() {
    local message="${1:-无效选项}"
    local delay="${2:-0.5}"
    local clear_first="${3:-0}"

    (( clear_first )) && clear
    echo -e "${RED}${message}${PLAIN}"
    sleep "$delay"
}

get_default_interface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
    echo "$iface"
}

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

ssh_get_current_port() {
    local current_port
    current_port=$(get_sshd_option "Port" "22")
    [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=22
    echo "$current_port"
}

ssh_read_status() {
    printf '%s\n' \
        "$(ssh_get_current_port)" \
        "$(get_sshd_option "PermitRootLogin" "yes")" \
        "$(get_sshd_option "PasswordAuthentication" "yes")" \
        "$(get_sshd_option "PubkeyAuthentication" "yes")"
}

ssh_status_label() {
    if [[ "$1" == "yes" ]]; then
        echo "${GREEN}开启${PLAIN}"
    else
        echo "${RED}关闭${PLAIN}"
    fi
}

ssh_root_login_label() {
    local permit_root_login="$1"
    case "$permit_root_login" in
        yes)
            echo "${GREEN}开启${PLAIN}"
            ;;
        prohibit-password|without-password)
            echo "${YELLOW}仅密钥${PLAIN}"
            ;;
        forced-commands-only)
            echo "${YELLOW}受限${PLAIN}"
            ;;
        no)
            echo "${RED}关闭${PLAIN}"
            ;;
        *)
            echo "${YELLOW}${permit_root_login:-未知}${PLAIN}"
            ;;
    esac
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

pkg_install() {
    command -v apt >/dev/null 2>&1 || return 1
    apt update && apt install -y "$@"
}

pkg_update() {
    command -v apt >/dev/null 2>&1 || return 1
    apt update && apt upgrade -y
}

pkg_clean() {
    command -v apt >/dev/null 2>&1 || return 1
    apt autoremove -y && apt autoclean -y && apt clean
}

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
        echo -e "${RED}未检测到可用的 apt!${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${GREEN}系统更新完成${PLAIN}"
    press_any_key_to_continue
}

linux_clean() {
    clear
    echo -e "${YELLOW}正在清理系统垃圾...${PLAIN}"

    pkg_clean || echo -e "${RED}未检测到可用的 apt!${PLAIN}"

    echo -e "${YELLOW}正在清理旧内核...${PLAIN}"
    local current_kernel
    current_kernel=$(uname -r)
    echo -e "${BLUE}当前运行内核: ${GREEN}${current_kernel}${PLAIN}"

    local old_kernels=""
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

    if [ -n "$old_kernels" ]; then
        if command -v update-grub &>/dev/null; then
            echo -e "${YELLOW}正在更新GRUB引导...${PLAIN}"
            update-grub > /dev/null 2>&1
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
    local log_pattern
    for log_pattern in "*.log" "*.gz" "*.1"; do
        find /var/log -type f -name "$log_pattern" -mtime +1 -exec rm -f {} \;
    done

    echo -e "${YELLOW}正在清理临时目录...${PLAIN}"
    find /tmp -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null
    find /var/tmp -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null

    echo -e "${YELLOW}正在清理用户缓存...${PLAIN}"
    local cache_dir
    for cache_dir in "$HOME/.cache" /home/*/.cache; do
        [ -d "$cache_dir" ] && rm -rf "$cache_dir"/*
    done

    echo -e "${GREEN}系统清理完成${PLAIN}"
    press_any_key_to_continue
}

swapfile_path="/swapfile"

reinstall_check_sys() {
    reinstall_release=''
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) reinstall_release="$ID" ;;
        esac
    fi
}

reinstall_install_dependencies() {
    apt-get -o Acquire::ForceIPv4=true update
    apt-get -y -o Acquire::ForceIPv4=true install xz-utils openssl gawk file wget cpio gzip iproute2 util-linux
}

reinstall_require_commands() {
    local missing=0 cmd=''
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "[${GREEN}ok${PLAIN}]\t${cmd}"
        else
            echo -e "[${RED}missing${PLAIN}]\t${cmd}"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || {
        echo -e "${RED}缺少依赖，请先修复环境。${PLAIN}"
        exit 1
    }
}

reinstall_cidr_to_netmask() {
    local n="${1:-32}" b='' m='' i='' s=''
    for ((i = 0; i < 32; i++)); do
        if [[ "$i" -lt "$n" ]]; then
            b="${b}1"
        else
            b="${b}0"
        fi
    done
    for ((i = 0; i < 4; i++)); do
        s=$(echo "$b" | cut -c$((i * 8 + 1))-$(((i + 1) * 8)))
        if [[ -z "$m" ]]; then
            m="$((2#${s}))"
        else
            m="${m}.$((2#${s}))"
        fi
    done
    echo "$m"
}

reinstall_get_default_interface() {
    local iface=''
    iface=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
    echo "$iface"
}

reinstall_get_target_disk() {
    local root_source='' root_disk='' disks=''
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
    if [[ "$disks" == /dev/* ]]; then
        echo "$disks"
    elif [[ -n "$disks" ]]; then
        echo "/dev/$disks"
    fi
}

reinstall_get_grub() {
    local boot_dir="${1:-/boot}" folder='' file_name='' ver=''
    folder=$(find "$boot_dir" -type d -name "grub*" 2>/dev/null | head -n1)
    [[ -n "$folder" ]] || return
    file_name=$(ls -1 "$folder" 2>/dev/null | grep '^grub.conf$\|^grub.cfg$')
    if [[ -z "$file_name" ]]; then
        ls -1 "$folder" 2>/dev/null | grep -q '^grubenv$' || return
        folder=$(find "$boot_dir" -type f -name "grubenv" 2>/dev/null | xargs dirname | grep -v "^$folder" | head -n1)
        [[ -n "$folder" ]] || return
        file_name=$(ls -1 "$folder" 2>/dev/null | grep '^grub.conf$\|^grub.cfg$')
    fi
    [[ -n "$file_name" ]] || return
    if [[ "$file_name" == "grub.cfg" ]]; then
        ver='0'
    else
        ver='1'
    fi
    echo "${folder}:${file_name}:${ver}"
}

reinstall_low_mem() {
    local mem=''
    mem=$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | grep -o "[0-9]*")
    [[ -n "$mem" ]] || return 0
    [[ "$mem" -le "524288" ]] && return 1 || return 0
}

reinstall_validate_grub_config() {
    local grub_file="$1" open_count='' close_count=''
    if command -v grub-script-check >/dev/null 2>&1; then
        grub-script-check "$grub_file" >/tmp/grub-script-check.log 2>&1
        return $?
    elif command -v grub2-script-check >/dev/null 2>&1; then
        grub2-script-check "$grub_file" >/tmp/grub-script-check.log 2>&1
        return $?
    fi
    open_count=$(grep -o '{' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
    close_count=$(grep -o '}' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
    if grep -q 'menuentry ' "$grub_file" && [[ "$open_count" == "$close_count" ]]; then
        : >/tmp/grub-script-check.log
        return 0
    fi
    return 1
}

reinstall_detect_current_ssh_port() {
    local port=''
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] && [[ -f /etc/ssh/sshd_config ]]; then
        port=$(awk 'tolower($1) == "port" {print $2}' /etc/ssh/sshd_config 2>/dev/null | tail -n1)
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || port='22'
    echo "$port"
}

reinstall_select_debian_mirror() {
    local dist="$1" current='' url=''
    for current in "https://deb.debian.org/debian" "https://archive.debian.org/debian"; do
        url="${current}/dists/${dist}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz"
        if wget -4 --spider --timeout=3 -o /dev/null "$url"; then
            echo "$current"
            return 0
        fi
    done
    return 1
}

reinstall_pick_ipv6_line() {
    local iface="$1" ip6_line='' ip6_src=''

    ip6_line=$(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '!/ temporary / && !/ deprecated / {print; exit}')
    if [[ -z "$ip6_line" ]]; then
        ip6_src=$(ip -6 route get 2001:4860:4860::8888 oif "$iface" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
        if [[ -n "$ip6_src" ]]; then
            ip6_line=$(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk -v src="$ip6_src" '$4 ~ ("^" src "/") {print; exit}')
        fi
    fi

    echo "$ip6_line"
}

reinstall_gather_network_state() {
    local iaddr='' ip6_line='' ip6_route='' ipv6_iface='' attempt=''

    REINSTALL_NETWORK_INTERFACE=$(reinstall_get_default_interface)
    [[ -n "$REINSTALL_NETWORK_INTERFACE" ]] || {
        echo -e "${RED}未检测到默认网卡。${PLAIN}"
        exit 1
    }

    iaddr=$(ip -4 addr show dev "$REINSTALL_NETWORK_INTERFACE" | awk '/inet / {print $2; exit}')
    REINSTALL_IPV4_ADDR="${iaddr%/*}"
    REINSTALL_IPV4_PREFIX="${iaddr#*/}"
    REINSTALL_IPV4_MASK=$(reinstall_cidr_to_netmask "$REINSTALL_IPV4_PREFIX")
    REINSTALL_IPV4_GATE=$(ip -4 route show default | awk '/^default/ {print $3; exit}')

    [[ -n "$REINSTALL_IPV4_ADDR" && -n "$REINSTALL_IPV4_MASK" && -n "$REINSTALL_IPV4_GATE" ]] || {
        echo -e "${RED}当前 IPv4 信息不完整，无法执行重装。${PLAIN}"
        exit 1
    }

    REINSTALL_IPV6_MODE='none'
    REINSTALL_IPV6_ADDR=''
    REINSTALL_IPV6_PREFIX=''
    REINSTALL_IPV6_GATE=''

    ipv6_iface=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -n "$ipv6_iface" ]] || ipv6_iface="$REINSTALL_NETWORK_INTERFACE"

    for attempt in 1 2 3; do
        ip6_line=$(reinstall_pick_ipv6_line "$ipv6_iface")
        if [[ -z "$ip6_line" && "$ipv6_iface" != "$REINSTALL_NETWORK_INTERFACE" ]]; then
            ip6_line=$(reinstall_pick_ipv6_line "$REINSTALL_NETWORK_INTERFACE")
        fi
        [[ -n "$ip6_line" ]] && break
        [[ "$attempt" == '3' ]] || sleep 1
    done

    if [[ -n "$ip6_line" ]]; then
        REINSTALL_IPV6_ADDR=$(echo "$ip6_line" | awk '{print $4}' | cut -d/ -f1)
        REINSTALL_IPV6_PREFIX=$(echo "$ip6_line" | awk '{print $4}' | cut -d/ -f2)
        ip6_route=$(ip -6 route show default dev "$ipv6_iface" 2>/dev/null | awk '/^default/ {print; exit}')
        REINSTALL_IPV6_GATE=$(echo "$ip6_route" | awk '/^default/ {print $3; exit}')
        if echo "$ip6_line $ip6_route" | grep -Eq 'proto[[:space:]]+ra|(^|[[:space:]])dynamic([[:space:]]|$)|(^|[[:space:]])mngtmpaddr([[:space:]]|$)'; then
            REINSTALL_IPV6_MODE='auto'
        elif [[ -n "$REINSTALL_IPV6_GATE" ]]; then
            REINSTALL_IPV6_MODE='static'
        else
            REINSTALL_IPV6_MODE='auto'
        fi
    fi
}

reinstall_build_ipv6_block() {
    case "$REINSTALL_IPV6_MODE" in
        auto)
            cat <<'EOF'
cat >> /etc/network/interfaces <<EOF_IPV6
iface $iface inet6 dhcp
    accept_ra 2
    autoconf 1
EOF_IPV6
EOF
            ;;
        static)
            cat <<EOF
cat >> /etc/network/interfaces <<EOF_IPV6
iface \$iface inet6 static
    address ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX}
    gateway ${REINSTALL_IPV6_GATE}
EOF_IPV6
EOF
            ;;
        *)
            ;;
    esac
}

reinstall_write_post_install_script() {
    local ipv6_block=''
    ipv6_block=$(reinstall_build_ipv6_block)

    cat > /tmp/boot/post-install.sh <<EOF
#!/bin/sh
set -eu

iface=\$(awk '/^(auto|allow-hotplug)[[:space:]]+/ {for (i = 2; i <= NF; i++) if (\$i != "lo") {print \$i; exit}}' /etc/network/interfaces 2>/dev/null || true)
[ -n "\$iface" ] || iface='${REINSTALL_NETWORK_INTERFACE}'

update_sshd_option() {
    key="\$1"
    value="\$2"
    if grep -Eiq "^[#[:space:]]*\${key}[[:space:]]+" /etc/ssh/sshd_config; then
        sed -ri "s@^[#[:space:]]*\${key}[[:space:]].*@\${key} \${value}@I" /etc/ssh/sshd_config
    else
        echo "\${key} \${value}" >> /etc/ssh/sshd_config
    fi
}

cat > /etc/network/interfaces <<EOF_INTERFACES
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto \$iface
iface \$iface inet static
    address ${REINSTALL_IPV4_ADDR}
    netmask ${REINSTALL_IPV4_MASK}
    gateway ${REINSTALL_IPV4_GATE}
    dns-nameservers ${REINSTALL_DNS_LIST}
EOF_INTERFACES
${ipv6_block}

update_sshd_option Port ${REINSTALL_SSH_PORT}
update_sshd_option PermitRootLogin yes
update_sshd_option PasswordAuthentication yes
update_sshd_option PubkeyAuthentication yes
EOF
    chmod 700 /tmp/boot/post-install.sh
}

reinstall_install_target_system() {
    local debian_version="$1"
    local dist='' grub='' grub_dir='' grub_file='' grub_ver='' grub_backup=''
    local mirror='' mirror_host='' mirror_folder='' target_disk=''
    local read_grub='' load_num='' cfg0='' cfg1='' cfg2='' insert_grub=''
    local type='' linux_kernel='' linux_img='' add_option='' boot_option='' grub_tmp=''
    local root_password_hash='' partman_early_command='' late_command='' apt_non_free_firmware_line=''

    case "$debian_version" in
        11) dist='bullseye' ;;
        12) dist='bookworm' ;;
        13) dist='trixie' ;;
        *)
            echo -e "${RED}不支持的 Debian 版本: ${debian_version}${PLAIN}"
            exit 1
            ;;
    esac

    reinstall_require_commands ip wget awk grep sed cut cat lsblk cpio gzip find dirname basename openssl findmnt xargs
    reinstall_gather_network_state

    target_disk=$(reinstall_get_target_disk)
    [[ -n "$target_disk" ]] || {
        echo -e "${RED}未检测到目标磁盘。${PLAIN}"
        exit 1
    }

    grub=$(reinstall_get_grub "/boot")
    [[ -n "$grub" ]] || {
        echo -e "${RED}未找到 GRUB 配置。${PLAIN}"
        exit 1
    }
    grub_dir=$(echo "$grub" | cut -d: -f1)
    grub_file=$(echo "$grub" | cut -d: -f2)
    grub_ver=$(echo "$grub" | cut -d: -f3)
    [[ "$grub_ver" == "0" ]] || {
        echo -e "${RED}当前仅支持 GRUB2。${PLAIN}"
        exit 1
    }

    mirror=$(reinstall_select_debian_mirror "$dist")
    [[ -n "$mirror" ]] || {
        echo -e "${RED}未找到可用 Debian 镜像。${PLAIN}"
        exit 1
    }

    if [[ "$debian_version" != '11' ]]; then
        apt_non_free_firmware_line='d-i apt-setup/non-free-firmware boolean true'
    fi

    root_password_hash=$(openssl passwd -1 "$REINSTALL_ROOT_PASSWORD")

    clear
    echo -e "\n${BLUE}# Install${PLAIN}\n"
    echo -e "${YELLOW}目标系统: Debian ${debian_version} (${dist})${PLAIN}"
    echo -e "${YELLOW}目标磁盘: ${target_disk}${PLAIN}"
    echo -e "${YELLOW}IPv4: ${REINSTALL_IPV4_ADDR}/${REINSTALL_IPV4_PREFIX} gw ${REINSTALL_IPV4_GATE}${PLAIN}"
    case "$REINSTALL_IPV6_MODE" in
        auto) echo -e "${YELLOW}IPv6: 自动继承 ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX}（当前环境检测为自动下发）${PLAIN}" ;;
        static) echo -e "${YELLOW}IPv6: 静态继承 ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX} gw ${REINSTALL_IPV6_GATE}${PLAIN}" ;;
        none) echo -e "${YELLOW}IPv6: 当前未检测到可继承配置${PLAIN}" ;;
    esac

    mirror_host=$(echo "$mirror" | awk -F'://|/' '{print $2}')
    mirror_folder=$(echo "$mirror" | awk -F"${mirror_host}" '{print $2}')
    [[ -n "$mirror_folder" ]] || mirror_folder='/'

    wget -4 -qO /tmp/initrd.img "${mirror}/dists/${dist}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz" || {
        echo -e "${RED}下载 initrd 失败。${PLAIN}"
        exit 1
    }
    wget -4 -qO /tmp/vmlinuz "${mirror}/dists/${dist}/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux" || {
        echo -e "${RED}下载内核失败。${PLAIN}"
        exit 1
    }

    [[ -f "${grub_dir}/${grub_file}" ]] || {
        echo -e "${RED}找不到 ${grub_file}。${PLAIN}"
        exit 1
    }
    grub_backup="${grub_dir}/${grub_file}.installnet.$(date +%Y%m%d%H%M%S).bak"
    cp -f "${grub_dir}/${grub_file}" "$grub_backup" || {
        echo -e "${RED}备份 GRUB 失败。${PLAIN}"
        exit 1
    }

    read_grub='/tmp/grub.read'
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
    ' "${grub_dir}/${grub_file}" > "$read_grub"

    load_num=$(grep -c 'menuentry ' "$read_grub")
    if [[ "$load_num" -eq '1' ]]; then
        sed '/^$/d' "$read_grub" > /tmp/grub.new
    elif [[ "$load_num" -gt '1' ]]; then
        cfg0=$(awk '/menuentry / {print NR}' "$read_grub" | head -n1)
        cfg2=$(awk '/menuentry / {print NR}' "$read_grub" | head -n2 | tail -n1)
        cfg1=''
        for tmp_cfg in $(awk '/}/ {print NR}' "$read_grub"); do
            [[ "$tmp_cfg" -gt "$cfg0" && "$tmp_cfg" -lt "$cfg2" ]] && cfg1="$tmp_cfg"
        done
        [[ -n "$cfg1" ]] || {
            echo -e "${RED}解析 GRUB 菜单失败。${PLAIN}"
            exit 1
        }
        sed -n "${cfg0},${cfg1}p" "$read_grub" > /tmp/grub.new
    else
        echo -e "${RED}未找到可复用的 GRUB 菜单项。${PLAIN}"
        exit 1
    fi

    sed -i "/menuentry.*/c\\menuentry\\ 'Install OS [${dist} amd64]' --class debian --class gnu-linux --class gnu --class os {" /tmp/grub.new
    sed -i "/echo.*Loading/d" /tmp/grub.new
    insert_grub=$(awk '/menuentry / {print NR}' "${grub_dir}/${grub_file}" | head -n1)
    [[ -n "$insert_grub" && "$insert_grub" -gt 0 ]] || {
        echo -e "${RED}定位 GRUB 插入位置失败。${PLAIN}"
        exit 1
    }

    if grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new | awk '{print $2}' | tail -n1 | grep -q '^/boot/'; then
        type='InBoot'
    else
        type='NoBoot'
    fi
    linux_kernel=$(grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new | awk '{print $1}' | head -n1)
    [[ -n "$linux_kernel" ]] || {
        echo -e "${RED}读取 GRUB 内核项失败。${PLAIN}"
        exit 1
    }
    linux_img=$(grep 'initrd.*/' /tmp/grub.new | awk '{print $1}' | tail -n1)
    if [[ -z "$linux_img" ]]; then
        sed -i "/$linux_kernel.*\//a\\\tinitrd /" /tmp/grub.new
        linux_img='initrd'
    fi

    add_option=''
    reinstall_low_mem || add_option=' lowmem=+0'
    boot_option="auto=true${add_option} hostname=debian domain= quiet"

    if [[ "$type" == 'InBoot' ]]; then
        sed -i "/$linux_kernel.*\//c\\\t$linux_kernel\t/boot/vmlinuz $boot_option" /tmp/grub.new
        sed -i "/$linux_img.*\//c\\\t$linux_img\t/boot/initrd.img" /tmp/grub.new
    else
        sed -i "/$linux_kernel.*\//c\\\t$linux_kernel\t/vmlinuz $boot_option" /tmp/grub.new
        sed -i "/$linux_img.*\//c\\\t$linux_img\t/initrd.img" /tmp/grub.new
    fi
    sed -i '$a\\n' /tmp/grub.new

    grub_tmp=$(mktemp)
    head -n $((insert_grub - 1)) "${grub_dir}/${grub_file}" > "$grub_tmp"
    cat /tmp/grub.new >> "$grub_tmp"
    tail -n +"$insert_grub" "${grub_dir}/${grub_file}" >> "$grub_tmp"
    cp -f "$grub_tmp" "${grub_dir}/${grub_file}"
    rm -f "$grub_tmp"

    if ! reinstall_validate_grub_config "${grub_dir}/${grub_file}"; then
        cp -f "$grub_backup" "${grub_dir}/${grub_file}"
        echo -e "${RED}GRUB 语法校验失败，已回滚。${PLAIN}"
        exit 1
    fi

    if [[ -f "${grub_dir}/grubenv" ]]; then
        sed -i 's/saved_entry/#saved_entry/g' "${grub_dir}/grubenv"
    fi

    rm -rf /tmp/boot
    mkdir -p /tmp/boot
    cd /tmp/boot || exit 1

    mv -f /tmp/initrd.img /tmp/initrd.img.gz
    gzip -d < /tmp/initrd.img.gz | cpio --extract --verbose --make-directories --no-absolute-filenames >/dev/null 2>&1

    reinstall_write_post_install_script

    partman_early_command='debconf-set partman-auto/disk "$(list-devices disk | head -n1)"'
    late_command='cp /post-install.sh /target/root/reinstall-post.sh; chmod 700 /target/root/reinstall-post.sh; in-target /bin/sh /root/reinstall-post.sh; rm -f /target/root/reinstall-post.sh'

    cat > /tmp/boot/preseed.cfg <<EOF
d-i debian-installer/locale string en_US
d-i console-setup/layoutcode string us
d-i keyboard-configuration/xkb-keymap string us

d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string ${REINSTALL_IPV4_ADDR}
d-i netcfg/get_netmask string ${REINSTALL_IPV4_MASK}
d-i netcfg/get_gateway string ${REINSTALL_IPV4_GATE}
d-i netcfg/get_nameservers string ${REINSTALL_DNS_LIST}
d-i netcfg/confirm_static boolean true

d-i hw-detect/load_firmware boolean true

d-i mirror/country string manual
d-i mirror/http/hostname string ${mirror_host}
d-i mirror/http/directory string ${mirror_folder}
d-i mirror/http/proxy string
d-i apt-setup/contrib boolean true
d-i apt-setup/non-free boolean true
${apt_non_free_firmware_line}

d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password ${root_password_hash}

d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean false

d-i partman/early_command string ${partman_early_command}
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/mount_style select uuid
d-i partman/choose_partition select finish
d-i partman-auto/method string regular
d-i partman-auto/init_automatically_partition select Guided - use entire disk
d-i partman-auto/choose_recipe select atomic
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server isc-dhcp-client ifupdown
d-i pkgsel/upgrade select none

popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${target_disk}
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i preseed/late_command string ${late_command}
EOF

    find . | cpio -H newc --create --verbose | gzip -9 > /tmp/initrd.img
    cp -f /tmp/initrd.img /boot/initrd.img
    cp -f /tmp/vmlinuz /boot/vmlinuz
    chown root:root "${grub_dir}/${grub_file}"
    chmod 444 "${grub_dir}/${grub_file}"

    echo -e "${GREEN}[信息]${PLAIN} 安装引导已写入，系统将在 3 秒后自动重启继续安装。"
    sleep 3
    reboot || sudo reboot >/dev/null 2>&1
}

reinstall_debian() {
    local debian_version="$1" pw='' pw2='' confirm='' target_disk=''

    read -r -s -p " 请设置 root 密码: " pw
    echo
    [[ -n "$pw" ]] || {
        echo -e "${RED}密码不能为空。${PLAIN}"
        return
    }

    read -r -s -p " 请再次输入 root 密码: " pw2
    echo
    [[ "$pw" == "$pw2" ]] || {
        echo -e "${RED}两次输入密码不一致。${PLAIN}"
        return
    }

    REINSTALL_SSH_PORT=$(reinstall_detect_current_ssh_port)
    REINSTALL_ROOT_PASSWORD="$pw"
    target_disk=$(reinstall_get_target_disk)

    echo -e "${YELLOW} 将使用 Debian ${debian_version} 执行重装。${PLAIN}"
    echo -e "${YELLOW} 目标磁盘: ${target_disk:-未检测到}${PLAIN}"
    echo -e "${YELLOW} 重装后 SSH 端口将保持为: ${REINSTALL_SSH_PORT}${PLAIN}"
    echo -e "${YELLOW} 默认 DNS: ${REINSTALL_DNS_LIST}${PLAIN}"
    echo -e "${YELLOW} 输入 YES 后将写入安装引导并自动重启。${PLAIN}"
    read -r -p " 输入「YES」确认开始重装，其它键取消: " confirm
    [[ "$confirm" == "YES" ]] || {
        echo -e "${YELLOW} 已取消重装。${PLAIN}"
        return
    }

    reinstall_install_target_system "$debian_version"
}

reinstall_start_menu() {
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

reinstall_main_loop() {
    local num=''
    while true; do
        reinstall_start_menu
        read -r -p " 请输入数字 [0-3]: " num
        num=$(echo "$num" | grep -oE '^[0-9]+$')
        case "$num" in
            1) reinstall_debian 11 ;;
            2) reinstall_debian 12 ;;
            3) reinstall_debian 13 ;;
            0) break ;;
            *)
                echo -e "${RED}请输入正确数字 [0-3]${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

reinstall_menu() {
    PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
    export PATH
    reinstall_check_sys
    [[ "$EUID" -ne '0' ]] && echo -e "${RED}请使用 root 权限运行此脚本${PLAIN}" && return
    [[ -z "${reinstall_release:-}" ]] && echo -e "${RED}暂不支持当前系统${PLAIN}" && press_any_key_to_continue && return
    reinstall_install_dependencies
    reinstall_main_loop
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
        sys_tz=$(trim_input "$(timedatectl show -p Timezone --value 2>/dev/null)")
        echo "${sys_tz:-未知}"
    }

    _timezone_get_zone_tab() {
        local zone_tab="/usr/share/zoneinfo/zone1970.tab"
        [[ -f "$zone_tab" ]] || zone_tab="/usr/share/zoneinfo/zone.tab"
        [[ -f "$zone_tab" ]] || return 1
        echo "$zone_tab"
    }

    _timezone_detect_recommended() {
        local tz=""
        if ! command -v curl >/dev/null; then
            echo -e "${YELLOW}未检测到 curl,正在尝试安装...${PLAIN}" >&2
            pkg_install curl >/dev/null 2>&1 || return 1
        fi

        tz=$(trim_input "$(curl -fsSL --connect-timeout 5 --max-time 8 https://ipapi.co/timezone 2>/dev/null | tr -d '\r')")
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
        local sys_tz pause_after=0
        sys_tz=$(_timezone_get_system_tz)
        clear
        echo -e "${BLUE}======= 时区管理 =====${PLAIN}"
        echo -e "${YELLOW}当前 ${sys_tz}${PLAIN}"
        echo -e "${YELLOW}推荐 ${current_tz_web:-不可用}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}推荐时区  ${GREEN}2.${PLAIN}国家代码"
        echo -e "${GREEN}3.${PLAIN}手动输入  ${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"
        
        choice=$(read_menu_choice "请输入选项 [0-3]: ")
        
        case "$choice" in
            1)
                if [ -n "$current_tz_web" ]; then
                    _timezone_apply "$current_tz_web"
                else
                    echo -e "${YELLOW}当前无法获取推荐时区,请使用国家代码或手动输入${PLAIN}"
                fi
                pause_after=1
                ;;
            2)
                clear
                read -r -p "$(echo -e "${BLUE}请输入国家代码 (如 CN,US,JP): ${PLAIN}")" input_code
                input_code=$(trim_input "$input_code")
                input_code=$(printf '%s' "$input_code" | tr '[:lower:]' '[:upper:]')
                [ -z "$input_code" ] && continue

                zone_tab=$(_timezone_get_zone_tab || true)
                if [ -z "$zone_tab" ]; then
                    echo -e "${RED}系统缺失时区索引文件 (zone1970.tab/zone.tab)，无法自动列表。${PLAIN}"
                    pause_after=1
                else
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

                    read -r -p "$(echo -e "${BLUE}请选择编号: ${PLAIN}")" tz_idx
                    tz_idx=$(trim_input "$tz_idx")
                    if [[ "$tz_idx" =~ ^[0-9]+$ ]] && [ "$tz_idx" -ge 1 ] && [ "$tz_idx" -le "${#lines[@]}" ]; then
                        sel_tz="${lines[$((tz_idx-1))]}"
                        _timezone_apply "$sel_tz"
                    else
                        echo -e "${RED}无效编号${PLAIN}"
                    fi
                    pause_after=1
                fi
                ;;
            3)
                read -r -p "$(echo -e "${BLUE}请输入时区全称 (例: Asia/Shanghai): ${PLAIN}")" manual_tz
                manual_tz=$(trim_input "$manual_tz")
                if [ -n "$manual_tz" ]; then
                    _timezone_apply "$manual_tz"
                fi
                pause_after=1
                ;;
            0)
                return
                ;;
            *)
                show_invalid_option
                ;;
        esac
        (( pause_after == 1 )) && press_any_key_to_continue
    done
}

REINSTALL_DNS_LIST='8.8.8.8 1.1.1.1 2001:4860:4860::8888 2606:4700:4700::1111'

set_ip_priority() {
    local GAI_CONF="/etc/gai.conf"
    local MANAGED_BEGIN="# Zero.sh IP Priority BEGIN"
    local MANAGED_END="# Zero.sh IP Priority END"

    _priority_rule_exists() {
        local precedence_value="$1"
        [[ -f "$GAI_CONF" ]] || return 1

        {
            sed -n "/^${MANAGED_BEGIN}$/,/^${MANAGED_END}$/p" "$GAI_CONF" | grep -qE "^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+${precedence_value}$" ||
            grep -qE "^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+${precedence_value}[[:space:]]*$" "$GAI_CONF"
        }
    }

    _get_current_priority() {
        if _priority_rule_exists 100; then
            echo "IPv4 优先"
        elif _priority_rule_exists 10; then
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

    _apply_priority_mode() {
        local mode="$1"
        local label="$2"
        _cleanup_legacy_priority_rule
        _write_priority_block "$mode"
        echo -e "${GREEN}✔ 已设置为 ${label}${PLAIN}"
        press_any_key_to_continue
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
                _apply_priority_mode "ipv4" "IPv4 优先"
                ;;
            2)
                _apply_priority_mode "ipv6" "IPv6 优先"
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

BBR_SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
BBR_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
BBR_REPO_FILE="/etc/apt/sources.list.d/xanmod-release.list"
BBR_PERSIST_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
BBR_PERSIST_SERVICE_NAME="bbr-optimize-persist.service"
BBR_PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"

bbr_confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    read -r -p "$prompt" answer
    answer=$(trim_input "$answer")
    [[ -z "$answer" ]] && answer="$default"
    [[ "$answer" =~ ^[Yy]$ ]]
}

bbr_fail_and_pause() {
    local message="$1"
    echo -e "${RED}${message}${PLAIN}"
    press_any_key_to_continue
    return 1
}

bbr_prompt_reboot() {
    if bbr_confirm "现在重启服务器使配置生效吗？(Y/N): "; then
        reboot_vps
    else
        echo -e "${YELLOW}已取消,请稍后手动执行 reboot${PLAIN}"
    fi
}

bbr_read_runtime_status() {
    local current_kernel cc qdisc available_cc xanmod_installed="no"

    current_kernel=$(uname -r 2>/dev/null)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

    if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+linux-image-.*xanmod'; then
        xanmod_installed="yes"
    fi

    printf '%s\n' \
        "$current_kernel" \
        "$cc" \
        "$qdisc" \
        "$available_cc" \
        "$xanmod_installed"
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
    bbr_confirm "是否继续？(Y/N): "
}

bbr_check_and_prepare_swap() {
    local total_ram total_swap managed_swap recommend_swap other_swap target_swapfile
    total_ram=$(free -m | awk '/Mem:/ {print $2}')
    total_swap=$(get_current_swap_mb)
    managed_swap=$(get_managed_swap_mb)
    recommend_swap=$(swap_recommended_for_ram_mb "$total_ram")

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

    if bbr_confirm "是否现在配置虚拟内存？(Y/N): "; then
        set_swap "$target_swapfile" 0 || return 1
    else
        echo -e "${YELLOW}已跳过虚拟内存配置${PLAIN}"
    fi
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
    bw_choice=$(read_menu_choice "请输入选项 [0-2]: ")
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
            read -r -p "请输入选择 [6]: " preset_choice
            preset_choice=$(trim_input "$preset_choice")
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
                    read -r -p "请输入带宽值（Mbps）: " manual_bandwidth
                    manual_bandwidth=$(trim_input "$manual_bandwidth")
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
    if bbr_confirm "是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: " "Y"; then
        echo "$buffer_mb"
    else
        [[ "$region" == "overseas" ]] && echo 32 || echo 16
    fi
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
        bbr_fail_and_pause "错误: 当前仅支持 x86_64 系统"
        return 1
    fi

    bbr_check_and_prepare_swap || {
        bbr_fail_and_pause "虚拟内存配置失败，已停止本次优化"
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
    read -r -p "请输入选择 [1]: " region_choice
    region_choice=$(trim_input "$region_choice")
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
    local -a bbr_status
    mapfile -t bbr_status < <(bbr_read_runtime_status)
    current_kernel="${bbr_status[0]}"
    actual_cc="${bbr_status[1]}"
    actual_qdisc="${bbr_status[2]}"
    available_cc="${bbr_status[3]}"

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
    if ! bbr_confirm "确定继续安装吗？(Y/N): "; then
        echo "已取消安装"
        press_any_key_to_continue
        return 1
    fi

    if [[ "$(uname -m)" != "x86_64" ]]; then
        bbr_fail_and_pause "错误: 当前仅支持 x86_64 系统"
        return 1
    fi

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            bbr_fail_and_pause "错误: 仅支持 Debian 和 Ubuntu"
            return 1
        fi
    else
        bbr_fail_and_pause "错误: 无法确定操作系统类型"
        return 1
    fi

    bbr_check_disk_space 3 || {
        press_any_key_to_continue
        return 1
    }
    bbr_check_and_prepare_swap || {
        bbr_fail_and_pause "虚拟内存配置失败，已停止安装"
        return 1
    }
    bbr_ensure_apt_packages curl gnupg ca-certificates || {
        bbr_fail_and_pause "依赖安装失败"
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
        bbr_fail_and_pause "错误: 无法确定系统代号，已停止安装"
        return 1
    fi

    echo "deb [signed-by=${BBR_KEYRING}] http://deb.xanmod.org ${distro_codename} main" > "$BBR_REPO_FILE"

    echo -e "${YELLOW}正在检测 CPU 支持的最优内核版本...${PLAIN}"
    local version package_name package_hint
    version=$(bbr_detect_x86_64_level_local)
    if ! [[ "$version" =~ ^[1-4]$ ]]; then
        bbr_fail_and_pause "错误: 无法可靠检测 CPU 对应的 XanMod x64v 等级"
        return 1
    fi

    apt-get update || {
        bbr_fail_and_pause "apt-get update 失败"
        return 1
    }

    local package_info package_status install_ok=0 verify_package
    local install_packages=()

    package_info=$(bbr_select_xanmod_package "$version") || {
        bbr_fail_and_pause "错误: 当前仓库中未找到适配 x64v${version} 的 XanMod 内核包"
        return 1
    }

    package_name="${package_info%%|*}"
    package_hint="${package_info#*|}"
    mapfile -t install_packages < <(bbr_resolve_xanmod_payload_packages "$package_name" 2>/dev/null || true)

    if [[ "${#install_packages[@]}" -eq 0 ]]; then
        bbr_fail_and_pause "错误: 无法解析 ${package_name} 对应的内核安装包"
        return 1
    fi

    echo -e "${GREEN}目标通道: ${package_name}${PLAIN}"
    echo -e "${YELLOW}说明: ${package_hint}${PLAIN}"
    echo -e "${YELLOW}实际安装: ${install_packages[*]}${PLAIN}"

    if ! apt-get install -y "${install_packages[@]}"; then
        bbr_fail_and_pause "XanMod 内核安装失败"
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
        bbr_fail_and_pause "未检测到 XanMod 内核安装成功"
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

    if bbr_confirm "确定继续吗？(Y/N): "; then
        echo -e "${YELLOW}正在卸载 XanMod 相关包...${PLAIN}"
        if ! apt purge -y 'linux-*xanmod*'; then
            bbr_fail_and_pause "卸载 XanMod 相关包失败"
            return 1
        fi
        update-grub 2>/dev/null || true
        rm -f "$BBR_REPO_FILE" "$BBR_KEYRING" /usr/share/keyrings/xanmod-archive-keyring.gpg
        rm -f "$BBR_SYSCTL_CONF" /etc/sysctl.d/99-zero-bbr.conf /etc/modules-load.d/bbr.conf
        bbr_apply_mss_clamp disable
        bbr_cleanup_persist
        echo -e "${GREEN}XanMod 内核已卸载${PLAIN}"
        bbr_prompt_reboot
    else
        echo "已取消"
    fi
    press_any_key_to_continue
}

bbr_menu_status_line() {
    local current_kernel cc qdisc xanmod_state xanmod_installed
    local -a bbr_status

    mapfile -t bbr_status < <(bbr_read_runtime_status)
    current_kernel="${bbr_status[0]}"
    cc="${bbr_status[1]}"
    qdisc="${bbr_status[2]}"
    xanmod_installed="${bbr_status[4]}"

    if [[ "$xanmod_installed" == "yes" ]]; then
        xanmod_state="${GREEN}已安装${PLAIN}"
    else
        xanmod_state="${YELLOW}未安装${PLAIN}"
    fi

    echo -e "${BLUE}内核 ${YELLOW}${current_kernel:-unknown}${PLAIN}"
    echo -e "${BLUE}XanMod ${xanmod_state} | BBR ${GREEN}${cc:-unknown}${PLAIN} | Qdisc ${GREEN}${qdisc:-unknown}${PLAIN}"
}

bbr_show_manage_menu() {
    clear
    echo -e "${BLUE}============ BBR管理 ============${PLAIN}"
    bbr_menu_status_line
    echo -e "${BLUE}==================================${PLAIN}"
    echo -e "${GREEN}1.安装XanMod${PLAIN}   ${RED}2.卸载XanMod${PLAIN}"
    echo -e "${BLUE}3.BBR调优${PLAIN}      ${YELLOW}0.返回菜单${PLAIN}"
    echo -e "${BLUE}==================================${PLAIN}"
}

handle_bbr_manage_choice() {
    case "$1" in
        1) clear; bbr_install_xanmod_kernel ;;
        2) clear; bbr_uninstall_xanmod_kernel ;;
        3) clear; bbr_configure_direct ;;
        0) return 1 ;;
        *) show_invalid_option ;;
    esac

    return 0
}

bbr_manage_menu() {
    local opt
    while true; do
        bbr_show_manage_menu
        opt=$(read_menu_choice "请输入选项 [0-3]: ")
        handle_bbr_manage_choice "$opt" || return
    done
}

DNS_RESOLV_CONF="/etc/resolv.conf"
DNS_RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
DNS_RESOLVED_DROPIN_FILE="$DNS_RESOLVED_DROPIN_DIR/99-custom-dns.conf"

dns_read_runtime_status() {
    local active="0" iface="" dns_list=""

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        active="1"
        iface="$(get_default_interface)"
        if [[ -n "$iface" ]] && command -v resolvectl >/dev/null 2>&1; then
            dns_list="$(resolvectl status "$iface" 2>/dev/null | awk '/DNS Servers:/ {for (i=3; i<=NF; i++) print $i}')"
        fi
    fi

    printf '%s\n' "$active" "$iface"
    [[ -n "$dns_list" ]] && printf '%s\n' "$dns_list"
}

dns_show_current() {
    local iface dns_list resolved_active dns
    local -a dns_status

    echo -e "${YELLOW}当前DNS配置:${PLAIN}\n"

    echo -e "${BLUE}resolv.conf:${PLAIN}"
    if [[ -f "$DNS_RESOLV_CONF" ]]; then
        while read -r dns; do
            [[ "$dns" =~ ^nameserver ]] || continue
            echo -e "  ${GREEN}${dns}${PLAIN}"
        done < "$DNS_RESOLV_CONF"
    else
        echo -e "  (不存在)"
    fi
    echo

    echo -e "${BLUE}systemd-resolved:${PLAIN}"
    mapfile -t dns_status < <(dns_read_runtime_status)
    resolved_active="${dns_status[0]}"
    iface="${dns_status[1]}"
    dns_list=$(printf '%s\n' "${dns_status[@]:2}")

    if [[ "$resolved_active" == "1" ]]; then
        if [[ -n "$iface" ]]; then
            echo -e "  默认网卡: ${GREEN}${iface}${PLAIN}"
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

dns_is_valid_ipv4() {
    local ip="$1" IFS=.
    local o1 o2 o3 o4 o

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" -ge 0 && "$o" -le 255 ]] 2>/dev/null || return 1
    done
    return 0
}

dns_is_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9A-Fa-f:%.]+$ ]] || return 1
    [[ "$ip" == *:* ]] || return 1
    [[ ${#ip} -le 80 ]] || return 1
    return 0
}

dns_is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ [[:space:]] ]] && return 1
    [[ "$ip" == *\"* || "$ip" == *\'* || "$ip" == *\\* ]] && return 1
    dns_is_valid_ipv4 "$ip" && return 0
    dns_is_valid_ipv6 "$ip" && return 0
    return 1
}

dns_systemd_resolved_active() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1
}

dns_unlock_resolv() {
    if command -v chattr >/dev/null 2>&1 && [[ -f "$DNS_RESOLV_CONF" ]]; then
        chattr -i "$DNS_RESOLV_CONF" 2>/dev/null || true
    fi
}

dns_write_resolv_conf() {
    local dns
    {
        for dns in "$@"; do
            echo "nameserver $dns"
        done
    } > "$DNS_RESOLV_CONF" 2>/dev/null || true
}

dns_restart_local_resolvers() {
    local svc
    if command -v systemctl >/dev/null 2>&1; then
        for svc in nscd dnsmasq named; do
            systemctl is-active "$svc" >/dev/null 2>&1 && systemctl restart "$svc" >/dev/null 2>&1
        done
    fi
}

dns_apply() {
    local dns_list=("$@")
    local ok=() bad=()
    local dns iface

    for dns in "${dns_list[@]}"; do
        if dns_is_valid_ip "$dns"; then
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

    if dns_systemd_resolved_active; then
        mkdir -p "$DNS_RESOLVED_DROPIN_DIR"
        {
            echo "[Resolve]"
            echo "DNS=${dns_list[*]}"
            echo "Domains=~."
        } > "$DNS_RESOLVED_DROPIN_FILE"

        systemctl restart systemd-resolved 2>/dev/null || true

        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl flush-caches 2>/dev/null || true
            iface="$(get_default_interface)"
            if [[ -n "$iface" ]]; then
                resolvectl dns "$iface" "${dns_list[@]}" 2>/dev/null || true
                resolvectl domain "$iface" "~." 2>/dev/null || true
                resolvectl flush-caches 2>/dev/null || true
            fi
        fi

        if [[ ! -L "$DNS_RESOLV_CONF" ]]; then
            dns_unlock_resolv
            dns_write_resolv_conf "${dns_list[@]}"
        fi
    else
        if [[ -L "$DNS_RESOLV_CONF" ]]; then
            rm -f "$DNS_RESOLV_CONF" 2>/dev/null || true
        fi
        dns_unlock_resolv
        dns_write_resolv_conf "${dns_list[@]}"
    fi

    dns_restart_local_resolvers
    return 0
}

dns_apply_with_feedback() {
    if dns_apply "$@"; then
        echo -e "${GREEN}DNS已修改并立即生效${PLAIN}"
    else
        echo -e "${RED}DNS修改失败${PLAIN}"
    fi
    press_any_key_to_continue
}

dns_show_menu() {
    clear
    echo -e "${BLUE}======== DNS 配置工具 ========${PLAIN}\n"
    dns_show_current
    echo -e "${GREEN}1.${PLAIN}修改DNS为 ${GREEN}8.8.8.8${PLAIN} 和 ${GREEN}1.1.1.1${PLAIN}"
    echo -e "${GREEN}2.${PLAIN}自定义修改DNS"
    echo -e "${YELLOW}0.${PLAIN}返回主菜单"
    echo -e "${BLUE}==============================${PLAIN}"
}

dns_read_custom_servers() {
    local dns=""

    echo -e "\n${YELLOW}请输入DNS(每行一个,空行结束):${PLAIN}"
    while true; do
        read -r -p "> " dns
        dns=$(trim_input "$dns")
        [[ -z "$dns" ]] && break
        printf '%s\n' "$dns"
    done
}

handle_dns_choice() {
    local choice="$1"
    local -a custom_dns=()

    case "$choice" in
        1)
            dns_apply_with_feedback "8.8.8.8" "1.1.1.1"
            ;;
        2)
            clear
            mapfile -t custom_dns < <(dns_read_custom_servers)
            if [[ ${#custom_dns[@]} -eq 0 ]]; then
                echo -e "${YELLOW}未输入DNS${PLAIN}"
                press_any_key_to_continue
            else
                dns_apply_with_feedback "${custom_dns[@]}"
            fi
            ;;
        0)
            return 1
            ;;
        *)
            show_invalid_option
            ;;
    esac

    return 0
}

dns_fix() {
    local choice

    while true; do
        dns_show_menu
        choice=$(read_menu_choice "请输入选项 [0-2]: ")
        handle_dns_choice "$choice" || return
    done
}

ssh_show_config_menu() {
    local current_port="$1"
    local root_login_text="$2"
    local password_login_text="$3"
    local pubkey_login_text="$4"

    clear
    echo -e "${BLUE}======== SSH ========${PLAIN}"
    echo -e "${BLUE}端口 ${YELLOW}${current_port}${PLAIN} | Root ${root_login_text}"
    echo -e "${BLUE}密码 ${password_login_text} | 密钥 ${pubkey_login_text}"
    echo -e "${BLUE}======================${PLAIN}"
    echo -e "${GREEN}1.设置密码${PLAIN}  ${GREEN}2.设置密钥${PLAIN}"
    echo -e "${BLUE}3.修改端口${PLAIN}  ${RED}4.修改登录${PLAIN}"
    echo -e "${YELLOW}0.返回菜单${PLAIN}"
    echo -e "${BLUE}======================${PLAIN}"
}

handle_ssh_config_choice() {
    case "$1" in
        1) enable_or_change_root_password ;;
        2) enable_root_key_login ;;
        3) change_ssh_port ;;
        4) disable_ssh_login_menu ;;
        0) return 1 ;;
        *) show_invalid_option "无效选项，请重试" "0.3" ;;
    esac

    return 0
}

ssh_config_menu() {
    local current_port permit_root_login pass_auth pubkey_auth
    local root_login_text password_login_text pubkey_login_text
    local ssh_choice
    local -a ssh_status

    while true; do
        mapfile -t ssh_status < <(ssh_read_status)
        current_port="${ssh_status[0]}"
        permit_root_login="${ssh_status[1]}"
        pass_auth="${ssh_status[2]}"
        pubkey_auth="${ssh_status[3]}"

        root_login_text=$(ssh_root_login_label "$permit_root_login")
        password_login_text=$(ssh_status_label "$pass_auth")
        pubkey_login_text=$(ssh_status_label "$pubkey_auth")

        ssh_show_config_menu "$current_port" "$root_login_text" "$password_login_text" "$pubkey_login_text"
        ssh_choice=$(read_menu_choice "请输入选项 [0-4]: ")
        handle_ssh_config_choice "$ssh_choice" || return
    done
}

change_ssh_port() {
    while true; do
        clear
        local current_port old_port
        current_port=$(ssh_get_current_port)
        old_port="$current_port"
        echo -e "${YELLOW}当前SSH端口: ${GREEN}${current_port:-22}${PLAIN}\n"
        read -r -p "$(echo -e "${BLUE}请输入新的SSH端口(输入0返回): ${PLAIN}")" new_port
        new_port=$(trim_input "$new_port")
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
    read -r -p "$(echo -e "${BLUE}按回车继续,输入0返回:${PLAIN}")" input
    input=$(trim_input "$input")
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
    local key_passphrase=""

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    echo -e "${BLUE}是否需要为私钥设置密码？${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}是"
    echo -e "${GREEN}2.${PLAIN}否"
    read -r -p "$(echo -e "${BLUE}choice [1/2]: ${PLAIN}")" set_passwd

    if [[ "$set_passwd" != "1" && "$set_passwd" != "2" ]]; then
        echo -e "${RED}输入无效,已返回主菜单${PLAIN}"
        sleep 0.3
        return
    fi

    if [ "$set_passwd" = "1" ]; then
        clear
        echo -e "${BLUE}请输入私钥密码(不显示):${PLAIN}"
        read -r -s key_passphrase
        echo
    fi

    rm -f "$TMP_KEY" "$TMP_PUB"
    if ! ssh-keygen -t ed25519 -N "$key_passphrase" -f "$TMP_KEY"; then
        echo -e "${RED}密钥生成失败${PLAIN}"
        press_any_key_to_continue
        return 1
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
    local -a ssh_status

    mapfile -t ssh_status < <(ssh_read_status)
    pass_auth="${ssh_status[2]}"
    pubkey_auth="${ssh_status[3]}"

    [[ "$pass_auth" == "yes" ]] && has_password=1
    [[ "$pubkey_auth" == "yes" ]] && has_pubkey=1

    password_login_text=$(ssh_status_label "$pass_auth")
    pubkey_login_text=$(ssh_status_label "$pubkey_auth")

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
    disable_choice=$(read_menu_choice "请输入选项 [0-2]: ")
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

reboot_vps() {
    echo "即将重启系统..."
    reboot
}

swap_pause_if_needed() {
    local show_pause="${1:-1}"
    (( show_pause )) && press_any_key_to_continue
}

swap_is_valid_size_mb() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 128 ))
}

swap_is_valid_swappiness() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= 100 ))
}

swap_has_managed_state() {
    local temp_swap_path="${swapfile_path}.zero.tmp"
    local backup_swap_path="${swapfile_path}.zero.bak"

    grep -q "$swapfile_path" /proc/swaps 2>/dev/null \
        || grep -q "$temp_swap_path" /proc/swaps 2>/dev/null \
        || [[ -f "$swapfile_path" ]] \
        || [[ -f "$temp_swap_path" ]] \
        || [[ -f "$backup_swap_path" ]]
}

swap_get_total_ram_mb() {
    free -m | awk '/Mem:/ {print $2}'
}

swap_recommended_for_ram_mb() {
    local total_ram="${1:-0}"
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

swap_get_current_swappiness() {
    cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知"
}

swap_read_menu_status() {
    local total_ram current_swap managed_swap recommend_swap current_swappiness

    total_ram=$(swap_get_total_ram_mb)
    current_swap=$(get_current_swap_mb)
    managed_swap=$(get_managed_swap_mb)
    recommend_swap=$(swap_recommended_for_ram_mb "$total_ram")
    current_swappiness=$(swap_get_current_swappiness)

    printf '%s\n' \
        "$current_swap" \
        "$managed_swap" \
        "$total_ram" \
        "$recommend_swap" \
        "$current_swappiness"
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

swap_show_menu() {
    local current_swap="$1"
    local managed_swap="$2"
    local total_ram="$3"
    local current_swappiness="$4"

    clear
    echo -e "${BLUE}========= SWAP =========${PLAIN}"
    echo -e "${YELLOW}内存 ${total_ram}MB | 总Swap ${current_swap}MB${PLAIN}"
    echo -e "${YELLOW}文件Swap ${managed_swap}MB | Swappiness ${current_swappiness}${PLAIN}"
    echo -e "${BLUE}========================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}推荐大小    ${GREEN}2.${PLAIN}自定义"
    echo -e "${GREEN}3.${PLAIN}Swappiness  ${RED}4.${PLAIN}关闭Swap"
    echo -e "${YELLOW}0.${PLAIN}返回菜单"
    echo -e "${BLUE}========================${PLAIN}"
}

handle_swap_menu_choice() {
    local opt="$1"
    local recommend_swap="$2"
    local custom=""

    case "$opt" in
        1)
            set_swap "$recommend_swap"
            ;;
        2)
            read -rp "请输入 Swap 大小 (单位 MB,建议 >=128): " custom
            custom=$(trim_input "$custom")
            if swap_is_valid_size_mb "$custom"; then
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
            return 1
            ;;
        *)
            show_invalid_option "无效选项" "1"
            ;;
    esac

    return 0
}

set_swap_menu() {
    local current_swap managed_swap total_ram recommend_swap
    local current_swappiness opt
    local -a swap_status

    while true; do
        mapfile -t swap_status < <(swap_read_menu_status)
        current_swap="${swap_status[0]}"
        managed_swap="${swap_status[1]}"
        total_ram="${swap_status[2]}"
        recommend_swap="${swap_status[3]}"
        current_swappiness="${swap_status[4]}"

        swap_show_menu "$current_swap" "$managed_swap" "$total_ram" "$current_swappiness"
        opt=$(read_menu_choice "请输入选项 [0-4]: ")
        handle_swap_menu_choice "$opt" "$recommend_swap" || return
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
    if ! swap_is_valid_size_mb "$size_mb"; then
        echo -e "${RED}无效的 Swap 大小${PLAIN}"
        swap_pause_if_needed "$show_pause"
        return 1
    fi

    existing_swap_mb=$(get_swap_file_size_mb "$swapfile_path")
    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024 + existing_swap_mb))
    
    if (( avail_mb < size_mb + 500 )); then
        echo -e "${RED}磁盘空间不足!当前可用: ${avail_mb}MB, 需要: ${size_mb}MB (+预留500MB)${PLAIN}"
        swap_pause_if_needed "$show_pause"
        return 1
    fi

    root_fstype=$(trim_input "$(df --output=fstype / | tail -1)")
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
        swap_pause_if_needed "$show_pause"
        return 1
    fi

    if (( old_active )); then
        echo -e "${YELLOW}正在切换旧 Swap...${PLAIN}"
        if ! swapoff "$swapfile_path"; then
            echo -e "${RED}旧 Swap 卸载失败,已保留原配置${PLAIN}"
            rm -f "$temp_swap_path"
            swap_pause_if_needed "$show_pause"
            return 1
        fi
    fi

    if (( had_existing )); then
        if ! mv "$swapfile_path" "$backup_swap_path"; then
            echo -e "${RED}旧 Swap 备份失败,已保留原配置${PLAIN}"
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
            rm -f "$temp_swap_path"
            swap_pause_if_needed "$show_pause"
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
        swap_pause_if_needed "$show_pause"
        return 1
    fi

    if ! swapon "$swapfile_path"; then
        echo -e "${RED}新 Swap 启用失败,已尝试恢复旧配置${PLAIN}"
        rm -f "$swapfile_path"
        if (( had_existing )); then
            mv "$backup_swap_path" "$swapfile_path" 2>/dev/null || true
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
        fi
        swap_pause_if_needed "$show_pause"
        return 1
    fi

    remove_swap_fstab_entries "$swapfile_path" "$temp_swap_path" "$backup_swap_path"
    if ! echo "$swapfile_path none swap sw 0 0" >> /etc/fstab; then
        echo -e "${YELLOW}Swap 已启用,但写入 /etc/fstab 失败,重启后不会自动挂载${PLAIN}"
    fi

    rm -f "$backup_swap_path"

    echo -e "${GREEN}✓ Swap 设置成功!${PLAIN}"
    free -h
    swap_pause_if_needed "$show_pause"
    return 0
}

delete_swap() {
    local temp_swap_path="${swapfile_path}.zero.tmp"
    local backup_swap_path="${swapfile_path}.zero.bak"

    if ! swap_has_managed_state; then
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
    current_val=$(swap_get_current_swappiness)
    echo -e "当前 Swappiness: ${GREEN}${current_val}${PLAIN}"
    echo -e "数值范围 0-100.数值越低,越倾向于使用物理内存;数值越高,越倾向于使用 Swap。"
  
    read -rp "请输入新的 Swappiness 值 (0-100): " new_val
    new_val=$(trim_input "$new_val")
    if swap_is_valid_swappiness "$new_val"; then
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

ACME_HOME="$ROOT_HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
ACME_CERT_PATH="/etc/cert"
ACME_PORT80_OPEN_HOOK="/usr/local/bin/zero-acme-port80-open"
ACME_PORT80_CLOSE_HOOK="/usr/local/bin/zero-acme-port80-close"

ACME_PORT80_FIREWALL_BACKUP=""
ACME_PORT80_FIREWALL_CHANGED=0

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

acme_install_dependencies() {
    local packages=(
        curl
        wget
        socat
        openssl
        dnsutils
        cron
        tar
        ca-certificates
    )

    echo -e "${YELLOW}正在安装 ACME 依赖...${PLAIN}"
    pkg_install "${packages[@]}"
}

acme_install_port80_hook_scripts() {
    install -d -m 700 /usr/local/bin /run/zero-acme-port80 || return 1

    cat > "$ACME_PORT80_OPEN_HOOK" <<'EOF'
#!/bin/sh
set -eu

STATE_DIR="/run/zero-acme-port80"
STATE_FILE="$STATE_DIR/state"
ZERO_FW_CHAIN="ZERO_INPUT"

run_cmd() {
    cmd="$1"
    shift
    if "$cmd" -w 3 "$@" >/dev/null 2>&1; then
        return 0
    fi
    "$cmd" "$@" >/dev/null 2>&1
}

supports_table() {
    cmd="$1"
    table="$2"
    run_cmd "$cmd" -t "$table" -S
}

rule_exists() {
    cmd="$1"
    table="$2"
    chain="$3"
    shift 3
    if "$cmd" -w 3 -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
        return 0
    fi
    "$cmd" -t "$table" -C "$chain" "$@" >/dev/null 2>&1
}

ensure_rule_present() {
    cmd="$1"
    table="$2"
    chain="$3"
    shift 3
    rule_exists "$cmd" "$table" "$chain" "$@" && return 0
    run_cmd "$cmd" -t "$table" -I "$chain" 1 "$@"
}

cleanup_state() {
    rm -f "$STATE_FILE" "$STATE_DIR/rules.v4" "$STATE_DIR/rules.v6"
}

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
cleanup_state

changed=0

for cmd in iptables ip6tables; do
    case "$cmd" in
        iptables|ip6tables) ;;
        *) continue ;;
    esac

    command -v "$cmd" >/dev/null 2>&1 || continue
    supports_table "$cmd" filter || continue
    rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || continue

    if ! rule_exists "$cmd" filter "$ZERO_FW_CHAIN" -p tcp --dport 80 -j ACCEPT; then
        if [ "$changed" -eq 0 ]; then
            command -v iptables-save >/dev/null 2>&1 && iptables-save > "$STATE_DIR/rules.v4" || true
            command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$STATE_DIR/rules.v6" || true
        fi
        ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -p tcp --dport 80 -j ACCEPT
        changed=1
    fi
done

if [ "$changed" -eq 1 ]; then
    printf 'CHANGED=1\n' > "$STATE_FILE"
else
    cleanup_state
fi
EOF

    cat > "$ACME_PORT80_CLOSE_HOOK" <<'EOF'
#!/bin/sh
set -eu

STATE_DIR="/run/zero-acme-port80"
STATE_FILE="$STATE_DIR/state"

cleanup_state() {
    rm -f "$STATE_FILE" "$STATE_DIR/rules.v4" "$STATE_DIR/rules.v6"
}

[ -f "$STATE_FILE" ] || exit 0
. "$STATE_FILE"

if [ "${CHANGED:-0}" != "1" ]; then
    cleanup_state
    exit 0
fi

if [ -s "$STATE_DIR/rules.v4" ] && command -v iptables-restore >/dev/null 2>&1; then
    iptables-restore < "$STATE_DIR/rules.v4" || true
fi
if [ -s "$STATE_DIR/rules.v6" ] && command -v ip6tables-restore >/dev/null 2>&1; then
    ip6tables-restore < "$STATE_DIR/rules.v6" || true
fi

cleanup_state
EOF

    chmod 700 "$ACME_PORT80_OPEN_HOOK" "$ACME_PORT80_CLOSE_HOOK" || return 1
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
    acme_tar_url="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
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

acme_require_installed() {
    acme_ensure_installed || {
        press_any_key_to_continue
        return 1
    }
    acme_install_port80_hook_scripts && return 0
    echo -e "${RED}ACME 80 端口钩子脚本安装失败${PLAIN}"
    press_any_key_to_continue
    return 1
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

acme_prompt_validated_domain() {
    local prompt="$1"
    local restore_port80="${2:-0}"
    local domain
    ACME_PROMPT_DOMAIN=""

    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" domain
    domain=$(trim_input "$domain")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}未输入域名${PLAIN}"
        (( restore_port80 == 1 )) && acme_restore_port_80_firewall_if_needed
        press_any_key_to_continue
        return 1
    fi
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        (( restore_port80 == 1 )) && acme_restore_port_80_firewall_if_needed
        press_any_key_to_continue
        return 1
    fi
    ACME_PROMPT_DOMAIN="$domain"
    return 0
}

acme_get_cf_credentials() {
    local cfgak cfemail

    read -r -p "$(echo -e "${BLUE}请输入 CloudFlare Global API Key: ${PLAIN}")" cfgak
    cfgak=$(trim_input "$cfgak")
    if [[ -z "$cfgak" ]]; then
        echo -e "${RED}未输入 CloudFlare Global API Key${PLAIN}"
        return 1
    fi
    export CF_Key="$cfgak"

    read -r -p "$(echo -e "${BLUE}请输入 CloudFlare 登录邮箱: ${PLAIN}")" cfemail
    cfemail=$(trim_input "$cfemail")
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

acme_issue_failed_cleanup() {
    local restore_port80="${1:-0}"
    acme_print_issue_failed
    (( restore_port80 == 1 )) && acme_restore_port_80_firewall_if_needed
    press_any_key_to_continue
}

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

acme_finalize_issue() {
    local issue_domain="$1"
    local save_name="$2"
    local restore_port80="${3:-0}"

    if (( restore_port80 == 1 )); then
        acme_restore_port_80_firewall_if_needed
    fi
    acme_install_issued_cert "$issue_domain" "$save_name" || echo -e "${RED}证书安装失败${PLAIN}"
    press_any_key_to_continue
}

acme_check_port_80() {
    local firewall_opened=0
    local zero_fw_managed=0
    local cmd backup=""

    acme_reset_port_80_firewall_state

    if ! command -v lsof >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 lsof，正在安装...${PLAIN}"
        pkg_install lsof >/dev/null 2>&1 || {
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

    acme_require_installed || return

    acme_check_port_80 || {
        press_any_key_to_continue
        return
    }

    acme_prompt_validated_domain "请输入解析完成的域名: " 1 || return
    domain="$ACME_PROMPT_DOMAIN"

    acme_ensure_cert_path
    if ! acme_has_ipv4; then
        if ! acme_exec --issue -d "$domain" --standalone -k ec-256 --listen-v6 --insecure --pre-hook "$ACME_PORT80_OPEN_HOOK" --post-hook "$ACME_PORT80_CLOSE_HOOK"; then
            acme_issue_failed_cleanup 1
            return
        fi
    else
        if ! acme_exec --issue -d "$domain" --standalone -k ec-256 --insecure --pre-hook "$ACME_PORT80_OPEN_HOOK" --post-hook "$ACME_PORT80_CLOSE_HOOK"; then
            acme_issue_failed_cleanup 1
            return
        fi
    fi

    acme_finalize_issue "$domain" "$domain" 1
}

acme_issue_cf_single() {
    local domain

    acme_require_installed || return

    acme_prompt_validated_domain "请输入需要申请证书的域名: " || return
    domain="$ACME_PROMPT_DOMAIN"
    if ! acme_get_cf_credentials; then
        press_any_key_to_continue
        return
    fi

    acme_ensure_cert_path
    if ! acme_exec --issue --dns dns_cf -d "$domain" -k ec-256 --insecure; then
        acme_issue_failed_cleanup
        return
    fi
    acme_finalize_issue "$domain" "$domain"
}

acme_issue_cf_wildcard() {
    local domain

    acme_require_installed || return

    acme_prompt_validated_domain "请输入需要申请证书的泛域名根域名: " || return
    domain="$ACME_PROMPT_DOMAIN"
    if ! acme_get_cf_credentials; then
        press_any_key_to_continue
        return
    fi

    acme_ensure_cert_path
    if ! acme_exec --issue --dns dns_cf -d "*.${domain}" -d "$domain" -k ec-256 --insecure; then
        acme_issue_failed_cleanup
        return
    fi
    acme_finalize_issue "*.${domain}" "$domain"
}

acme_revoke_cert() {
    local cert_list choice confirm selected_domain base_domain
    local -a domains=()

    acme_require_installed || return

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

    read -r -p "$(echo -e "${BLUE}请输入要撤销的证书序号(0返回): ${PLAIN}")" choice
    choice=$(trim_input "$choice")
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
    read -r -p "$(echo -e "${BLUE}确认撤销? [y/N]: ${PLAIN}")" confirm
    confirm=$(trim_input "$confirm")
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
    acme_require_installed || return

    if acme_exec --cron; then
        echo -e "${GREEN}证书续期任务已执行${PLAIN}"
    else
        echo -e "${RED}证书续期执行失败${PLAIN}"
    fi
    press_any_key_to_continue
}

acme_switch_provider() {
    local provider

    acme_require_installed || return

    clear
    echo -e "${BLUE}======== 证书CA ========${PLAIN}"
    echo -e "${GREEN}1.LetsEncrypt${PLAIN}  ${GREEN}2.BuyPass${PLAIN}"
    echo -e "${GREEN}3.ZeroSSL${PLAIN}     ${YELLOW}0.返回菜单${PLAIN}"
    echo -e "${BLUE}========================${PLAIN}"
    provider=$(read_menu_choice "请输入选项 [0-3]: ")

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
    read -r -p "$(echo -e "${BLUE}请输入证书域名(默认: ${default_domain}): ${PLAIN}")" domain
    domain=$(trim_input "$domain")
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

acme_show_menu() {
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
}

handle_acme_choice() {
    case "$1" in
        1) acme_install_core; press_any_key_to_continue ;;
        2) acme_uninstall ;;
        3) acme_issue_standalone ;;
        4) acme_issue_cf_single ;;
        5) acme_issue_cf_wildcard ;;
        6) acme_revoke_cert ;;
        7) acme_renew_cert ;;
        8) acme_switch_provider ;;
        9) acme_generate_self_signed_cert ;;
        0) return 1 ;;
        *) show_invalid_option ;;
    esac

    return 0
}

acme_menu() {
    local acme_choice

    while true; do
        acme_show_menu
        acme_choice=$(read_menu_choice "请输入选项 [0-9]: ")
        handle_acme_choice "$acme_choice" || return
    done
}

readonly SNELL_BIN="/usr/local/bin/snell-server"
readonly SNELL_ETC="/etc/snell"
readonly SNELL_CONFIGS="${SNELL_ETC}/configs"

readonly SNELL_DEFAULT_PORT=8443
readonly SNELL_DEFAULT_DNS="1.1.1.1"
readonly SNELL_DEFAULT_OBFS_HOST="icloud.com.cn"
readonly SNELL_RELEASE_PAGE="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
readonly SNELL_DOWNLOAD_BASE="https://dl.nssurge.com/snell"
readonly SNELL_CDN_BASE="https://snell-cdn.pages.dev/snell"

snell_pause_and_clear() {
  press_any_key_to_continue "按任意键继续..."
  clear
}

snell_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

snell_install_tool_if_missing() {
  local tool="$1"
  shift

  snell_command_exists "$tool" && return 0

  echo -e "${YELLOW}未检测到 ${tool}，正在自动安装...${PLAIN}"
  pkg_install "$@" || {
    echo -e "${RED}未检测到可用的 apt，${tool} 安装失败,请手动安装！${PLAIN}"
    return 1
  }
  snell_command_exists "$tool" || {
    echo -e "${RED}${tool} 安装失败,请手动安装！${PLAIN}"
    return 1
  }
  echo -e "${GREEN}${tool} 安装完成${PLAIN}"
}

snell_get_arch() {
  local uname_arch
  uname_arch=$(uname -m)
  case "$uname_arch" in
    i686|i386)
      echo "i386" ;;
    armv7*|armv6l)
      echo "armv7l" ;;
    armv8*|aarch64|arm64)
      echo "aarch64" ;;
    *)
      echo "amd64" ;;
  esac
}

snell_has_ipv4() {
  curl -4 -s --connect-timeout 3 --max-time 5 https://ipv4.icanhazip.com >/dev/null 2>&1 && return 0
  ip -4 addr show scope global 2>/dev/null | grep -q inet && return 0
  return 1
}

snell_cleanup_tmp() {
  rm -f /tmp/snell-server /tmp/snell-server-*.zip 2>/dev/null
}

snell_normalize_dns_list() {
  local dns="$1"
  printf '%s' "$dns" | sed 's/, */, /g'
}

snell_validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535))
}

snell_validate_config_name() {
  local n="$1"
  [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]]
}

snell_is_installed() {
  [[ -f "$SNELL_BIN" ]] && [[ -x "$SNELL_BIN" ]]
}

snell_collect_config_files() {
  shopt -s nullglob
  SNELL_CONFIG_FILES=("$SNELL_CONFIGS"/*.conf)
  shopt -u nullglob
}

snell_config_exists() {
  snell_collect_config_files
  [[ -d "$SNELL_CONFIGS" && ${#SNELL_CONFIG_FILES[@]} -gt 0 ]]
}

snell_get_current_version() {
  snell_is_installed || return 1

  local output version
  output=$("$SNELL_BIN" --version 2>&1 || true)
  version=$(printf '%s\n' "$output" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*' | head -n1)
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

snell_service_name() {
  printf 'snell@%s.service' "$1"
}

snell_service_file() {
  printf '/etc/systemd/system/%s' "$(snell_service_name "$1")"
}

snell_get_config_value() {
  local config_file="$1"
  local key="$2"
  grep "^${key}[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | sed 's/^ *//;s/ *$//'
}

snell_require_configs() {
  local message="${1:-当前没有任何配置文件}"
  snell_collect_config_files
  if [[ ${#SNELL_CONFIG_FILES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}${message}${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  return 0
}

snell_fetch_url() {
  local url="$1"

  if snell_command_exists curl; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  elif snell_command_exists wget; then
    wget -qO- --timeout=30 "$url"
  else
    snell_install_tool_if_missing curl curl || return 1
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  fi
}

snell_download_file() {
  local url="$1"
  local output_file="$2"

  if snell_command_exists curl; then
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$output_file" "$url"
  elif snell_command_exists wget; then
    wget -qO "$output_file" --timeout=120 "$url"
  else
    snell_install_tool_if_missing curl curl || return 1
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$output_file" "$url"
  fi
}

snell_get_latest_version() {
    local arch
    arch=$(snell_get_arch)

    local page
    page=$(snell_fetch_url "$SNELL_RELEASE_PAGE")
    
    if [[ -z "$page" ]]; then
        echo -e "${RED}无法获取版本信息，请检查网络连接${PLAIN}"
        return 1
    fi

    local all_links
    all_links=$(echo "$page" | grep -oE "https://dl.nssurge.com/snell/snell-server-v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*-linux-${arch}\.zip")
    
    if [[ -z "$all_links" ]]; then
        echo -e "${RED}未找到适用于 ${arch} 架构的版本${PLAIN}"
        return 1
    fi

    local latest_stable latest_beta
    latest_stable=$(echo "$all_links" | grep -vE 'b[0-9]+|beta' | sort -V | tail -n 1)
    latest_beta=$(echo "$all_links" | grep -E 'b[0-9]+|beta' | sort -V | tail -n 1)

    if ! snell_has_ipv4; then
      latest_stable=$(echo "$latest_stable" | sed "s|dl.nssurge.com|snell-cdn.pages.dev|")
      latest_beta=$(echo "$latest_beta" | sed "s|dl.nssurge.com|snell-cdn.pages.dev|")
    fi

    if [[ -n "$latest_stable" ]]; then
        SNELL_VERSION=$(echo "$latest_stable" | sed -E "s/.*snell-server-(v[0-9]+\.[0-9]+\.[0-9]+)-linux-${arch}\.zip/\1/")
        SNELL_URL="$latest_stable"
    else
        SNELL_VERSION=""
        SNELL_URL=""
    fi

    if [[ -n "$latest_beta" ]]; then
        SNELL_BETA_VERSION=$(echo "$latest_beta" | sed -E "s/.*snell-server-(v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*)-linux-${arch}\.zip/\1/")
        SNELL_BETA_URL="$latest_beta"
    else
        SNELL_BETA_VERSION=""
        SNELL_BETA_URL=""
    fi
}

snell_get_latest_beta_version() {
    snell_get_latest_version || return 1
    SNELL_VERSION="$SNELL_BETA_VERSION"
    SNELL_URL="$SNELL_BETA_URL"
}

snell_download_and_install() {
  local url="$1"
  local version="$2"
  local zip_file
  zip_file=$(basename "$url")
  
  cd /tmp || { echo -e "${RED}无法进入 /tmp 目录${PLAIN}"; return 1; }
  snell_cleanup_tmp
  
  echo -e "${YELLOW}下载 Snell（$(snell_get_arch)，${version}）...${PLAIN}"
  if ! snell_download_file "$url" "$zip_file"; then
    echo -e "${RED}下载失败，请检查网络连接${PLAIN}"
    snell_cleanup_tmp
    return 1
  fi
  
  snell_install_tool_if_missing unzip unzip || return 1
  
  if ! unzip -o "$zip_file"; then
    echo -e "${RED}解压失败${PLAIN}"
    snell_cleanup_tmp
    return 1
  fi
  
  if [[ ! -e "snell-server" ]]; then
    echo -e "${RED}未找到 snell-server 可执行文件${PLAIN}"
    snell_cleanup_tmp
    return 1
  fi
  
  chmod +x snell-server
  mv -f snell-server "${SNELL_BIN}"
  mkdir -p "$SNELL_ETC"
  snell_cleanup_tmp
  
  echo -e "${GREEN}Snell ${version} 安装成功${PLAIN}"
  return 0
}

snell_restart_all_services() {
  systemctl daemon-reload
  shopt -s nullglob
  local services=(/etc/systemd/system/snell@*.service)
  shopt -u nullglob
  
  if [[ ${#services[@]} -eq 0 ]]; then
    return 0
  fi
  
  echo -e "${YELLOW}正在重启所有 Snell 服务...${PLAIN}"
  for svc in "${services[@]}"; do
    local svc_name
    svc_name=$(basename "$svc")
    systemctl restart "$svc_name"
    echo -e "${GREEN}已重启服务: $svc_name${PLAIN}"
  done
  echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
}

snell_install() {
  clear
  if snell_is_installed; then
    echo -e "${YELLOW}Snell 已安装,如需更新请选择【4.更新 Snell】${PLAIN}"
    snell_pause_and_clear
    return
  fi
  echo -e "${BLUE}开始安装 Snell...${PLAIN}"

  if ! snell_get_latest_version; then
    snell_pause_and_clear
    return 1
  fi

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
      echo -e "${RED}未获取到 Snell 最新正式版信息,请检查网络或稍后再试！${PLAIN}"
      snell_pause_and_clear
      return 1
  fi

  mkdir -p "$SNELL_ETC"
  mkdir -p "$SNELL_CONFIGS"

  if snell_download_and_install "$SNELL_URL" "$SNELL_VERSION"; then
    echo -e "${BLUE}请选择【2.配置 Snell】生成并管理配置文件${PLAIN}"
  fi
  
  snell_pause_and_clear
}

snell_update_stable() {
  clear
  if ! snell_is_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    snell_pause_and_clear
    return 1
  fi

  echo -e "${BLUE}开始检查并更新 Snell 正式版 ...${PLAIN}"

  if ! snell_get_latest_version; then
    snell_pause_and_clear
    return 1
  fi

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
      echo -e "${RED}未获取到 Snell 最新正式版信息,请检查网络或稍后再试！${PLAIN}"
      snell_pause_and_clear
      return 1
  fi

  local current_ver=""
  current_ver=$(snell_get_current_version || true)

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是正式版最新版:${SNELL_VERSION}${PLAIN}"
    snell_pause_and_clear
    return 0
  fi

  if snell_download_and_install "$SNELL_URL" "$SNELL_VERSION"; then
    snell_restart_all_services
  fi
  
  snell_pause_and_clear
}

snell_update_beta() {
  clear
  if ! snell_is_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  echo -e "${BLUE}开始检查并更新 Snell 测试版 ...${PLAIN}"

  if ! snell_get_latest_beta_version; then
    snell_pause_and_clear
    return 1
  fi

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
    echo -e "${RED}未检测到任何 Snell 测试版!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi

  local current_ver=""
  current_ver=$(snell_get_current_version || true)

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是测试版最新版：${SNELL_VERSION}${PLAIN}"
    snell_pause_and_clear
    return 0
  fi

  if snell_download_and_install "$SNELL_URL" "$SNELL_VERSION"; then
    snell_restart_all_services
  fi
  
  snell_pause_and_clear
}

snell_rollback_v4() {
  clear
  local target_version="v4.1.1"
  local arch
  arch=$(snell_get_arch)
  
  local current_ver=""
  current_ver=$(snell_get_current_version || true)
  if [[ "$current_ver" == "$target_version" ]] && [[ -f "$SNELL_BIN" ]]; then
      echo -e "${GREEN}Snell 当前已是 ${target_version} 版本 ${PLAIN}"
      snell_pause_and_clear
      return 0
  fi

  local url
  if snell_has_ipv4; then
    url="${SNELL_DOWNLOAD_BASE}/snell-server-${target_version}-linux-${arch}.zip"
  else
    url="${SNELL_CDN_BASE}/snell-server-${target_version}-linux-${arch}.zip"
  fi

  echo -e "${YELLOW}回退到 Snell ${target_version}...${PLAIN}"
  if snell_download_and_install "$url" "$target_version"; then
    snell_restart_all_services
  fi
  
  snell_pause_and_clear
}

snell_generate_config_file() {
  local config_file="$1"
  local port="$2"
  local psk="$3"
  local obfs="$4"
  local obfs_host="$5"
  local ipv6="$6"
  local tfo="$7"
  local dns="$8"
  
  {
    echo "[snell-server]"
    echo "listen = ::0:${port}"
    echo "psk = ${psk}"
    echo "obfs = ${obfs}"
    [[ "$obfs" == "http" && -n "$obfs_host" ]] && echo "obfs-host = ${obfs_host}"
    echo "ipv6 = ${ipv6}"
    echo "tfo = ${tfo}"
    echo "dns = ${dns}"
  } > "$config_file"
}

snell_create_systemd_service() {
  local config_name="$1"
  local config_file="$2"
  local service_name
  service_name=$(snell_service_name "$config_name")
  
  cat > "$(snell_service_file "$config_name")" << EOF
[Unit]
Description=Snell Instance (${config_name})
After=network.target

[Service]
ExecStart=${SNELL_BIN} -c ${config_file}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable --now "$service_name"
}

snell_generate_and_enable_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  mkdir -p "$config_dir"
  
  echo -e "${BLUE}请输入配置名称:${PLAIN}"
  read -r -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  config_name=$(trim_input "$config_name")
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  if ! snell_validate_config_name "$config_name"; then
    echo -e "${RED}配置名称只能包含字母、数字、下划线和连字符${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  if [[ -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 已存在!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  read -r -p "$(echo -e "${BLUE}请输入监听端口 ${YELLOW}(默认${SNELL_DEFAULT_PORT})${BLUE}: ${PLAIN}")" port
  port=$(trim_input "$port")
  port=${port:-$SNELL_DEFAULT_PORT}
  if ! snell_validate_port "$port"; then
    echo -e "${RED}端口必须是 1-65535 之间的数字${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  read -r -p "$(echo -e "${BLUE}请输入PSK密钥 ${YELLOW}(回车随机生成)${BLUE}: ${PLAIN}")" psk
  psk=$(trim_input "$psk")
  [[ -z "$psk" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  
  local obfs="off"
  local obfs_host=""
  read -r -p "$(echo -e "${BLUE}是否开启 obfs ${YELLOW}(默认不开启 Y/N)${BLUE}: ${PLAIN}")" enable_obfs
  enable_obfs=$(trim_input "$enable_obfs")
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -r -p "$(echo -e "${BLUE}请输入 obfs 域名 ${YELLOW}(默认 ${SNELL_DEFAULT_OBFS_HOST})${BLUE}: ${PLAIN}")" obfs_host
    obfs_host=$(trim_input "$obfs_host")
    obfs_host=${obfs_host:-$SNELL_DEFAULT_OBFS_HOST}
  fi

  local ipv6="false"
  read -r -p "$(echo -e "${BLUE}是否开启 IPv6 ${YELLOW}(默认不开启 Y/N)${BLUE}: ${PLAIN}")" enable_ipv6
  enable_ipv6=$(trim_input "$enable_ipv6")
  if [[ "$enable_ipv6" =~ ^[yY]$ ]]; then
    ipv6="true"
  fi

  local tfo="true"
  read -r -p "$(echo -e "${BLUE}是否开启 TFO ${YELLOW}(默认开启 Y/N)${BLUE}: ${PLAIN}")" enable_tfo
  enable_tfo=$(trim_input "$enable_tfo")
  if [[ "$enable_tfo" =~ ^[nN]$ ]]; then
    tfo="false"
  fi

  local dns="$SNELL_DEFAULT_DNS"
  read -r -p "$(echo -e "${BLUE}是否自定义DNS ${YELLOW}(默认${SNELL_DEFAULT_DNS} Y/N)${BLUE}: ${PLAIN}")" custom_dns
  custom_dns=$(trim_input "$custom_dns")
  if [[ "$custom_dns" =~ ^[yY]$ ]]; then
    read -r -p "$(echo -e "${BLUE}请输入 DNS ${YELLOW}(用英文逗号分隔)${BLUE}: ${PLAIN}")" dns
    dns=$(trim_input "$dns")
    dns=${dns:-$SNELL_DEFAULT_DNS}
  fi
  dns=$(snell_normalize_dns_list "$dns")

  snell_generate_config_file "$config_file" "$port" "$psk" "$obfs" "$obfs_host" "$ipv6" "$tfo" "$dns"
  echo -e "${GREEN}配置文件已生成: $config_file${PLAIN}"

  if snell_create_systemd_service "$config_name" "$config_file"; then
    echo -e "${GREEN}配置 $config_name 已启动并设置为开机自启${PLAIN}"
  else
    echo -e "${RED}配置 $config_name 创建成功，但服务启动失败，请检查 systemd 日志${PLAIN}"
  fi
  snell_pause_and_clear
}

snell_modify_config() {
  clear
  local config_dir="$SNELL_CONFIGS"

  snell_require_configs "当前没有任何配置文件,请先生成配置" || return
  
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  snell_list_configs
  echo -e "${BLUE}请选择要修改的配置名称:${PLAIN}"
  read -r -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  config_name=$(trim_input "$config_name")
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  local service_name
  service_name=$(snell_service_name "$config_name")
  
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi

  local current_port current_psk current_obfs current_obfs_host current_ipv6 current_tfo current_dns
  current_port=$(snell_get_config_value "$config_file" "listen" | awk -F: '{print $NF}' | tr -d ' ')
  current_psk=$(snell_get_config_value "$config_file" "psk" | tr -d ' ')
  current_obfs=$(snell_get_config_value "$config_file" "obfs" | tr -d ' ')
  current_obfs_host=$(snell_get_config_value "$config_file" "obfs-host" | tr -d ' ')
  current_ipv6=$(snell_get_config_value "$config_file" "ipv6" | tr -d ' ')
  current_tfo=$(snell_get_config_value "$config_file" "tfo" | tr -d ' ')
  current_dns=$(snell_get_config_value "$config_file" "dns")

  clear
  echo -e "${BLUE}当前配置内容:${PLAIN}"
  echo -e "端口: ${GREEN}${current_port}${PLAIN}"
  echo -e "PSK: ${GREEN}${current_psk}${PLAIN}"
  echo -e "OBFS: ${GREEN}${current_obfs}${PLAIN}"
  [[ "$current_obfs" == "http" ]] && echo -e "OBFS域名: ${GREEN}${current_obfs_host}${PLAIN}"
  echo -e "IPv6: ${GREEN}${current_ipv6:-false}${PLAIN}"
  echo -e "TFO: ${GREEN}${current_tfo:-true}${PLAIN}"
  echo -e "DNS: ${GREEN}${current_dns:-$SNELL_DEFAULT_DNS}${PLAIN}"

  local status
  status=$(systemctl is-active "$service_name" 2>/dev/null)
  case "$status" in
    active)   echo -e "服务状态: ${GREEN}已启动(active)${PLAIN}" ;;
    inactive) echo -e "服务状态: ${YELLOW}已停止(inactive)${PLAIN}" ;;
    failed)   echo -e "服务状态: ${RED}启动失败(failed)${PLAIN}" ;;
    *)        echo -e "服务状态: ${BLUE}未知或未安装${PLAIN}" ;;
  esac

  read -r -p "$(echo -e "${YELLOW}是否修改此配置? (Y/N): ${PLAIN}")" confirm_modify
  confirm_modify=$(trim_input "$confirm_modify")
  if [[ ! "$confirm_modify" =~ ^[yY]$ ]]; then
    return
  fi

  echo -e "${YELLOW}开始修改配置(回车保持原值)...${PLAIN}"
  
  read -r -p "$(echo -e "${BLUE}请输入新端口 ${YELLOW}(当前${current_port})${BLUE}: ${PLAIN}")" port
  port=$(trim_input "$port")
  port=${port:-$current_port}
  if ! snell_validate_port "$port"; then
    echo -e "${RED}端口必须是 1-65535 之间的数字${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  read -r -p "$(echo -e "${BLUE}请输入新PSK密钥 ${YELLOW}(当前${current_psk} R随机生成)${BLUE}: ${PLAIN}")" psk
  psk=$(trim_input "$psk")
  if [[ "$psk" =~ ^[rR]$ ]]; then
    psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  elif [[ -z "$psk" ]]; then
    psk=$current_psk
  fi
  
  local obfs obfs_host
  read -r -p "$(echo -e "${BLUE}是否开启 obfs ${YELLOW}(当前${current_obfs} Y/N)${BLUE}: ${PLAIN}")" enable_obfs
  enable_obfs=$(trim_input "$enable_obfs")
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -r -p "$(echo -e "${BLUE}请输入 obfs 域名 ${YELLOW}(当前${current_obfs_host:-$SNELL_DEFAULT_OBFS_HOST})${BLUE}: ${PLAIN}")" obfs_host
    obfs_host=$(trim_input "$obfs_host")
    obfs_host=${obfs_host:-${current_obfs_host:-$SNELL_DEFAULT_OBFS_HOST}}
  elif [[ "$enable_obfs" =~ ^[nN]$ ]]; then
    obfs="off"
    obfs_host=""
  else
    obfs=${current_obfs:-off}
    obfs_host=${current_obfs_host:-}
  fi

  local ipv6
  read -r -p "$(echo -e "${BLUE}是否开启 IPv6 ${YELLOW}(当前${current_ipv6:-false} Y/N)${BLUE}: ${PLAIN}")" enable_ipv6
  enable_ipv6=$(trim_input "$enable_ipv6")
  if [[ "$enable_ipv6" =~ ^[yY]$ ]]; then
    ipv6="true"
  elif [[ "$enable_ipv6" =~ ^[nN]$ ]]; then
    ipv6="false"
  else
    ipv6=${current_ipv6:-false}
  fi

  local tfo
  read -r -p "$(echo -e "${BLUE}是否开启 TFO ${YELLOW}(当前${current_tfo:-true} Y/N)${BLUE}: ${PLAIN}")" enable_tfo
  enable_tfo=$(trim_input "$enable_tfo")
  if [[ "$enable_tfo" =~ ^[yY]$ ]]; then
    tfo="true"
  elif [[ "$enable_tfo" =~ ^[nN]$ ]]; then
    tfo="false"
  else
    tfo=${current_tfo:-true}
  fi

  local dns
  read -r -p "$(echo -e "${BLUE}是否自定义DNS ${YELLOW}(当前${current_dns:-$SNELL_DEFAULT_DNS}, Y/N)${BLUE}: ${PLAIN}")" custom_dns
  custom_dns=$(trim_input "$custom_dns")
  if [[ "$custom_dns" =~ ^[yY]$ ]]; then
    read -r -p "$(echo -e "${BLUE}请输入 DNS ${YELLOW}(用英文逗号分隔)${BLUE}: ${PLAIN}")" dns
    dns=$(trim_input "$dns")
    dns=${dns:-$SNELL_DEFAULT_DNS}
  else
    dns=${current_dns:-$SNELL_DEFAULT_DNS}
  fi
  dns=$(snell_normalize_dns_list "$dns")

  snell_generate_config_file "$config_file" "$port" "$psk" "$obfs" "$obfs_host" "$ipv6" "$tfo" "$dns"

  echo -e "${YELLOW}配置已更新,正在重启服务...${PLAIN}"
  if systemctl restart "$service_name"; then
    echo -e "${GREEN}服务已重启,新配置已生效${PLAIN}"
  else
    echo -e "${RED}服务重启失败,请检查当前配置或 systemd 日志${PLAIN}"
  fi
  echo -e "${BLUE}------ 当前服务状态 ------${PLAIN}"
  systemctl status "$service_name" --no-pager
  snell_pause_and_clear
}

snell_delete_config() {
  clear
  local config_dir="$SNELL_CONFIGS"

  snell_require_configs || return
  
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  snell_list_configs
  echo -e "${BLUE}请输入要删除的配置名称,输入99删除全部配置:${PLAIN}"
  read -r -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  config_name=$(trim_input "$config_name")
  
  if [[ "$config_name" == "99" ]]; then
    snell_delete_all_configs
    return
  fi
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  local service_name
  service_name=$(snell_service_name "$config_name")
  
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  systemctl disable --now "$service_name" &>/dev/null || true
  rm -f "$(snell_service_file "$config_name")"
  rm -f "$config_file"
  systemctl daemon-reload
  echo -e "${GREEN}配置 $config_name 及其服务已删除${PLAIN}"
  snell_pause_and_clear
}

snell_delete_all_configs() {
  clear
  local config_dir="$SNELL_CONFIGS"

  snell_require_configs || return
  
  echo -e "${RED}警告:即将删除所有配置及服务!${PLAIN}"
  read -r -p "$(echo -e "${YELLOW}确定继续?[y/N]: ${PLAIN}")" choice
  choice=$(trim_input "$choice")
  [[ ! "$choice" =~ ^[yY]$ ]] && snell_pause_and_clear && return
  
  for config_file in "${SNELL_CONFIG_FILES[@]}"; do
    local config_name
    config_name=$(basename "$config_file" .conf)
    local service_name
    service_name=$(snell_service_name "$config_name")
    systemctl disable --now "$service_name" &>/dev/null || true
    rm -f "$(snell_service_file "$config_name")"
  done
  
  rm -rf "$config_dir"
  systemctl daemon-reload
  echo -e "${GREEN}所有配置及服务已删除${PLAIN}"
  snell_pause_and_clear
}

snell_delete_all() {
  clear
  if ! snell_is_installed && ! snell_config_exists; then
    echo -e "${YELLOW}未安装及配置 Snell,请先安装并配置 Snell。${PLAIN}"
    snell_pause_and_clear
    return
  fi

  echo -e "${RED}警告!此操作将彻底删除snell-server及其相关内容、服务${PLAIN}"
  read -r -p "$(echo -e "${YELLOW}确定继续? [y/N]: ${PLAIN}")" confirm
  confirm=$(trim_input "$confirm")
  [[ ! "$confirm" =~ ^[yY]$ ]] && echo -e "${YELLOW}操作已取消${PLAIN}" && snell_pause_and_clear && return

  shopt -s nullglob
  local services=(/etc/systemd/system/snell@*.service)
  shopt -u nullglob
  
  for svc in "${services[@]}"; do
    local svc_name
    svc_name=$(basename "$svc")
    systemctl disable --now "$svc_name" &>/dev/null || true
    rm -f "$svc"
  done

  systemctl daemon-reload

  [[ -d "$SNELL_ETC" ]] && rm -rf "$SNELL_ETC"
  [[ -f "$SNELL_BIN" ]] && rm -f "$SNELL_BIN"

  echo -e "${GREEN}已彻底删除snell服务${PLAIN}"
  snell_pause_and_clear
}

snell_stop_or_restart() {
  clear
  local config_dir="$SNELL_CONFIGS"

  snell_require_configs || return
  
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  snell_list_configs
  echo -e "${BLUE}请输入要停止的配置名称,输入0重启全部配置:${PLAIN}"
  read -r -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  config_name=$(trim_input "$config_name")
  
  if [[ "$config_name" == "0" ]]; then
    snell_restart_all_services
    snell_pause_and_clear
    return
  fi
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  local service_name
  service_name=$(snell_service_name "$config_name")
  
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    snell_pause_and_clear
    return 1
  fi
  
  systemctl stop "$service_name"
  echo -e "${YELLOW}已停止服务: $service_name${PLAIN}"
  snell_pause_and_clear
}

snell_list_configs() {
  snell_collect_config_files
  if [[ ${#SNELL_CONFIG_FILES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}没有找到任何配置文件${PLAIN}"
    return 0
  fi
  
  for f in "${SNELL_CONFIG_FILES[@]}"; do
    local name
    name=$(basename "$f" .conf)
    echo -e "  ${YELLOW}${name}${PLAIN}"
  done
}

snell_show_sub_menu() {
  clear
  echo -e "${BLUE}✦ Config_Menu ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}生成配置"
  echo -e "${GREEN}  2.${PLAIN}停止服务"
  echo -e "${GREEN}  3.${PLAIN}修改配置"
  echo -e "${GREEN}  4.${PLAIN}删除配置"
  echo -e "${GREEN}  0.${PLAIN}返回主页"
}

snell_config_menu() {
  while true; do
    snell_show_sub_menu
    sub_choice=$(read_menu_choice "✦ Steins Gate ✦ : ")
    case $sub_choice in
      1) snell_generate_and_enable_config ;;
      2) snell_stop_or_restart ;;
      3) snell_modify_config ;;
      4) snell_delete_config ;;
      0) break ;;
      *) show_invalid_option "无效选项,请重新选择" ;;
    esac
  done
}

snell_update_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Update ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}正式版"
  echo -e "${GREEN}  2.${PLAIN}测试版"
  echo -e "${GREEN}  3.${PLAIN}回退v4版"
  echo -e "${GREEN}  0.${PLAIN}返回主页"
  update_choice=$(read_menu_choice "✦ Steins Gate ✦ : ")
  case $update_choice in
    1) snell_update_stable ;;
    2) snell_update_beta ;;
    3) snell_rollback_v4 ;;
    0) return ;;
    *) show_invalid_option "无效选项,请重新选择" ;;
  esac
}

snell_show_main_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Ver.1.3 ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}安装Snell"
  echo -e "${GREEN}  2.${PLAIN}配置Snell"
  echo -e "${GREEN}  3.${PLAIN}删除Snell"
  echo -e "${GREEN}  4.${PLAIN}更新Snell"
  echo -e "${GREEN}  0.${PLAIN}离开Snell"
}

snell_menu() {
  while true; do
    snell_show_main_menu
    main_choice=$(read_menu_choice "✦ Steins Gate ✦ : ")
    case $main_choice in
      1) snell_install ;;
      2) snell_config_menu ;;
      3) snell_delete_all ;;
      4) snell_update_menu ;;
      0) return ;;
      *) show_invalid_option "无效选项,请重新选择" ;;
    esac
  done
}


get_app_installer_url() {
    case "$1" in
        shoes)     echo "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/shoes.sh" ;;
        mihomo)    echo "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/mihomo.sh" ;;
        wireproxy) echo "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/wireproxy.sh" ;;
        warp)      echo "https://raw.githubusercontent.com/Emokui/Steins/Gate/Bash/warp.sh" ;;
        *)         return 1 ;;
    esac
}

run_app_installer() {
    local app="$1"
    local url=""
    local tmp_script=""
    local rc=0

    if ! url=$(get_app_installer_url "$app"); then
        echo -e "${RED}未知安装项: ${app}${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 curl/wget，正在尝试安装...${PLAIN}"
        pkg_install curl wget >/dev/null 2>&1 || true
    fi

    tmp_script=$(mktemp /tmp/zero-installer.XXXXXX) || {
        echo -e "${RED}无法创建临时脚本文件${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$url" -o "$tmp_script"; then
            rm -f "$tmp_script"
            echo -e "${RED}下载远程安装脚本失败${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -qO "$tmp_script" "$url"; then
            rm -f "$tmp_script"
            echo -e "${RED}下载远程安装脚本失败${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
    else
        rm -f "$tmp_script"
        echo -e "${RED}未找到可用的下载工具（curl/wget）${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    bash "$tmp_script"
    rc=$?
    rm -f "$tmp_script"
    return "$rc"
}

reinstall_system_menu() { reinstall_menu; }
reboot_system()         { echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps; }
configure_shoes()       { run_app_installer "shoes"; }
configure_mihomo()      { run_app_installer "mihomo"; }
configure_wireproxy()   { run_app_installer "wireproxy"; }
configure_warpstack()   { run_app_installer "warp"; }

FIREWALL_RULE_DIR="/etc/iptables"
FIREWALL_RULES_V4="$FIREWALL_RULE_DIR/zero.rules.v4"
FIREWALL_RULES_V6="$FIREWALL_RULE_DIR/zero.rules.v6"
ZERO_FIREWALL_SERVICE="/etc/systemd/system/zero-firewall-persistent.service"
ZERO_FIREWALL_SERVICE_NAME="zero-firewall-persistent.service"
ZERO_FW_CHAIN="ZERO_INPUT"
ZERO_PORT_JUMP_CHAIN="ZERO_PORT_JUMP"

FIREWALL_LAST_BACKUP=""

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

firewall_install_tools() {
    command -v apt >/dev/null 2>&1 || return 1
    apt update && apt install -y iptables iproute2
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

firewall_require_backup() {
    local cancel_label="${1:-本次修改}"
    FIREWALL_LAST_BACKUP=""
    FIREWALL_LAST_BACKUP=$(firewall_create_backup) || {
        echo -e "${RED}创建防火墙备份失败,已取消${cancel_label}${PLAIN}"
        return 1
    }
}

firewall_restore_with_notice() {
    local backup="$1"
    local restored_msg="$2"
    local failed_msg="$3"

    if firewall_restore_backup "$backup"; then
        firewall_save_rules >/dev/null 2>&1 || true
        [[ -n "$restored_msg" ]] && echo -e "${YELLOW}${restored_msg}${PLAIN}"
    else
        echo -e "${RED}${failed_msg}${PLAIN}"
    fi
}

firewall_dispose_backup() {
    local backup="${1:-}"
    [[ -n "$backup" ]] && firewall_remove_backup "$backup"
}

firewall_read_runtime_status() {
    local has_iptables=false
    local has_ip6tables=false

    firewall_supports_table "iptables" filter && has_iptables=true
    firewall_supports_table "ip6tables" filter && has_ip6tables=true

    printf '%s\n' \
        "$(ssh_get_current_port)" \
        "$has_iptables" \
        "$has_ip6tables"
}

firewall_read_view_status() {
    local input_scope jump_scope="不支持"

    input_scope=$(firewall_hook_scope filter INPUT "$ZERO_FW_CHAIN")
    if firewall_supports_table "iptables" nat || firewall_supports_table "ip6tables" nat; then
        jump_scope=$(firewall_hook_scope nat PREROUTING "$ZERO_PORT_JUMP_CHAIN")
    fi

    printf '%s\n' "$input_scope" "$jump_scope"
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
    local input_scope jump_summary
    local -a firewall_view_status

    clear
    echo -e "${BLUE}=================== 防火墙规则详情 ===================${PLAIN}"
    mapfile -t firewall_view_status < <(firewall_read_view_status)
    input_scope="${firewall_view_status[0]}"
    jump_summary="${firewall_view_status[1]}"

    echo -e "${YELLOW}状态:${PLAIN} 入站管理=${input_scope}  |  端口跳跃=${jump_summary}"
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
    local jump_summary
    local -a firewall_view_status

    clear
    mapfile -t firewall_view_status < <(firewall_read_view_status)
    jump_summary="${firewall_view_status[1]}"
    echo -e "${BLUE}=================== 端口跳跃状态 ===================${PLAIN}\n"
    echo -e "${YELLOW}状态:${PLAIN} 端口跳跃=${jump_summary}"
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
    interface=$(get_default_interface)
    if [[ -z "$interface" ]]; then
        echo -e "${RED}未检测到有效网卡,请检查网络配置${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local user_interface
    read -r -p "$(echo -e "${YELLOW}请输入网卡名称(默认:${interface}): ${PLAIN}")" user_interface
    user_interface=$(trim_input "$user_interface")
    user_interface=${user_interface:-$interface}
    if ! ip link show "$user_interface" >/dev/null 2>&1; then
        echo -e "${RED}网卡 ${user_interface} 不存在${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local port_range start_port end_port
    read -r -p "$(echo -e "${YELLOW}请输入 UDP 端口范围(默认18443:28444): ${PLAIN}")" port_range
    port_range=$(trim_input "$port_range")
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
    read -r -p "$(echo -e "${YELLOW}请输入目标 UDP 端口: ${PLAIN}")" target_port
    target_port=$(trim_input "$target_port")
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

    firewall_require_backup "本次修改" || {
        press_any_key_to_continue
        return 1
    }
    backup="$FIREWALL_LAST_BACKUP"

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
        firewall_restore_with_notice "$backup" "已恢复到修改前的端口跳跃状态" "回滚失败,请手动检查当前 NAT 规则"
        firewall_dispose_backup "$backup"
        press_any_key_to_continue
        return 1
    fi

    firewall_save_rules || true
    firewall_dispose_backup "$backup"
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

    firewall_require_backup "删除" || {
        press_any_key_to_continue
        return 1
    }
    backup="$FIREWALL_LAST_BACKUP"

    echo -e "${BLUE}正在删除端口跳跃规则...${PLAIN}"
    if ! port_jump_clear_managed_rules; then
        echo -e "${RED}删除端口跳跃规则失败${PLAIN}"
        firewall_restore_with_notice "$backup" "已恢复删除前的端口跳跃状态" "回滚失败,请手动检查 NAT 规则"
        firewall_dispose_backup "$backup"
        press_any_key_to_continue
        return 1
    fi

    firewall_save_rules || true
    firewall_dispose_backup "$backup"
    echo -e "${GREEN}端口跳跃配置已删除${PLAIN}"
    press_any_key_to_continue
}

port_jump_show_menu() {
    clear
    echo -e "${BLUE}✦ Ports Jump ✦${PLAIN}"
    echo -e "${GREEN}  1.${PLAIN}设置跳跃"
    echo -e "${GREEN}  2.${PLAIN}修改跳跃"
    echo -e "${GREEN}  3.${PLAIN}查看跳跃"
    echo -e "${GREEN}  4.${PLAIN}删除跳跃"
    echo -e "${GREEN}  0.${PLAIN}返回上级"
}

handle_port_jump_choice() {
    case "$1" in
        1) port_jump_set ;;
        2) port_jump_modify ;;
        3) port_jump_view ;;
        4) port_jump_delete ;;
        0) return 1 ;;
        *) show_invalid_option "无效选项,请重新输入" ;;
    esac

    return 0
}

port_jump_menu() {
    local pjopt

    while true; do
        port_jump_show_menu
        pjopt=$(read_menu_choice "✦ Steins Gate ✦ : ")
        handle_port_jump_choice "$pjopt" || return
    done
}

firewall_show_menu() {
    local current_ssh_port="$1"
    local has_iptables="$2"
    local has_ip6tables="$3"

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
}

handle_firewall_action_choice() {
    local action_choice="$1"
    local current_ssh_port="$2"

    case "$action_choice" in
        0)
            return 1
            ;;
        1|2)
            local input_ports protocol_label action_failed port_range start_port end_port port_spec backup
            protocol_label="TCP+UDP"

            read -r -p "请输入端口（如 443 或 1000-2000，可空格分隔多个）: " input_ports
            input_ports=$(trim_input "$input_ports")
            action_failed=0
            firewall_require_backup "本次操作" || {
                press_any_key_to_continue
                return 0
            }
            backup="$FIREWALL_LAST_BACKUP"

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
                firewall_restore_with_notice "$backup" "[!] 本次操作存在失败项,已回滚到修改前状态" "[!] 本次操作存在失败项,且回滚失败,请立即检查规则"
            fi
            firewall_dispose_backup "$backup"
            press_any_key_to_continue
            ;;
        3)
            local backup
            firewall_require_backup "清空" || {
                press_any_key_to_continue
                return 0
            }
            backup="$FIREWALL_LAST_BACKUP"
            if firewall_clear_managed_rules; then
                firewall_save_rules || true
                echo -e "${GREEN}[✓] 已清空本脚本管理的规则,不再改动系统原有 INPUT/FORWARD/OUTPUT 策略${PLAIN}"
            else
                echo -e "${RED}[!] 清空规则失败${PLAIN}"
                firewall_restore_with_notice "$backup" "已恢复到清空前的状态" "回滚失败,请手动检查当前规则"
            fi
            firewall_dispose_backup "$backup"
            press_any_key_to_continue
            ;;
        4)
            local backup
            firewall_require_backup "本次操作" || {
                press_any_key_to_continue
                return 0
            }
            backup="$FIREWALL_LAST_BACKUP"
            echo -e "${YELLOW}[*] 正在配置仅保留 SSH 的入站策略(SSH: ${current_ssh_port})...${PLAIN}"
            if firewall_lockdown_all "$current_ssh_port"; then
                firewall_save_rules || true
                echo -e "${GREEN}[✓] 已应用仅留 SSH 的入站规则${PLAIN}"
            else
                echo -e "${RED}[!] 写入仅保留 SSH 规则失败${PLAIN}"
                firewall_restore_with_notice "$backup" "已恢复到修改前的状态" "回滚失败,请手动检查当前规则"
            fi
            firewall_dispose_backup "$backup"
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
            show_invalid_option "[!] 无效选项" "1"
            ;;
    esac

    return 0
}

configure_firewall() {
    local action_choice current_ssh_port has_iptables has_ip6tables
    local -a firewall_runtime_status

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
        mapfile -t firewall_runtime_status < <(firewall_read_runtime_status)
        current_ssh_port="${firewall_runtime_status[0]}"
        has_iptables="${firewall_runtime_status[1]}"
        has_ip6tables="${firewall_runtime_status[2]}"
        firewall_show_menu "$current_ssh_port" "$has_iptables" "$has_ip6tables"
        action_choice=$(read_menu_choice "请输入选项 [0-6]: ")
        handle_firewall_action_choice "$action_choice" "$current_ssh_port" || return
    done
}

show_main_menu() {
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
}

handle_main_menu_choice() {
    case "$1" in
        1)  linux_update ;;
        2)  linux_clean ;;
        3)  reinstall_system_menu ;;
        4)  change_timezone ;;
        5)  set_ip_priority ;;
        6)  bbr_manage_menu ;;
        7)  dns_fix ;;
        8)  ssh_config_menu ;;
        9)  reboot_system ;;
        10) set_swap_menu ;;
        11) acme_menu ;;
        12) snell_menu ;;
        13) configure_shoes ;;
        14) configure_mihomo ;;
        15) configure_firewall ;;
        16) configure_wireproxy ;;
        17) configure_warpstack ;;
        0)
            clear
            echo -e "${BLUE}「命运石之扉の选择,El Psy Kongroo」${PLAIN}"
            sleep 0.6
            clear
            return 1
            ;;
        *)
            show_invalid_option "[!] 无效选项，请重新选择" "0.4" "1"
            ;;
    esac

    return 0
}

main_menu() {
    local choice

    while true; do
        show_main_menu
        choice=$(read_menu_choice "✦ Choice [0-17] ✦ : ")
        handle_main_menu_choice "$choice" || break
    done
}

main_menu
