#!/bin/bash

set -u

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
PLAIN="\033[0m"

check_supported_system() {
    local os_id arch

    if [[ ! -r /etc/os-release ]]; then
        echo -e "${RED}不支持${PLAIN}"
        return 1
    fi

    source /etc/os-release
    os_id="${ID:-}"
    case "$os_id" in
        debian|ubuntu) ;;
        *)
            echo -e "${RED}不支持${PLAIN}"
            return 1
            ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) return 0 ;;
        *)
            echo -e "${RED}不支持${PLAIN}"
            return 1
            ;;
    esac
}

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请用 root 用户运行本脚本${PLAIN}"
  exit 1
fi

check_supported_system || exit 1

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

pause_any_key() {
    local msg="${1:-按任意键继续...}"
    press_any_key_to_continue "$msg"
}

pause_any_key_and_clear() {
    pause_any_key "${1:-按任意键继续...}"
    clear
}

pause_enter() {
    local msg="${1:-按回车继续...}"
    if [ -t 0 ]; then
        read -r -p "$(echo -e "${BLUE}${msg}${PLAIN}")" _
    else
        echo
    fi
}

pause_enter_and_clear() {
    pause_enter "${1:-按回车返回...}"
    clear
}

trim_input() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

log_info() {
    echo -e "${BLUE}$*${PLAIN}"
}

log_ok() {
    echo -e "${GREEN}$*${PLAIN}"
}

log_warn() {
    echo -e "${YELLOW}$*${PLAIN}"
}

log_err() {
    echo -e "${RED}$*${PLAIN}"
}

log_prefixed() {
    local color="$1"
    local prefix="$2"
    shift 2
    echo -e "${color}${prefix}${PLAIN} $*"
}

service_failure_hint() {
    local service_name="$1"
    [[ -n "$service_name" ]] && echo -e "${YELLOW}需要排查时: systemctl status --no-pager ${service_name}${PLAIN}"
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
    get_default_interface
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
    if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "amd64" ]]; then
        echo -e "${RED}当前重装模块仅支持 amd64/x86_64${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    if ! reinstall_install_dependencies; then
        echo -e "${RED}重装依赖安装失败,已停止本次操作${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
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
BBR_SPEEDTEST_BIN="/usr/local/bin/speedtest"
BBR_SPEEDTEST_MARKER="/usr/local/bin/.zero-bbr-speedtest.sha256"

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

bbr_xanmod_installed() {
    dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+linux-image-.*xanmod'
}

bbr_read_runtime_status() {
    local current_kernel cc qdisc available_cc xanmod_installed="no"

    current_kernel=$(uname -r 2>/dev/null)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

    if bbr_xanmod_installed; then
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
    if ! bbr_cpu_has_flags cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2; then
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

bbr_get_speedtest_download_url() {
    local page_content download_url
    page_content=$(bbr_fetch_text_url "https://speedtest-static-dev.speedtest.dev/apps/cli") || return 1
    download_url=$(printf '%s\n' "$page_content" | grep -Eo 'https://install\.speedtest\.net/app/cli/ookla-speedtest-[0-9.]+-linux-x86_64\.tgz' | head -n 1)
    [[ -n "$download_url" ]] || return 1
    echo "$download_url"
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

    install -m 0755 "${speedtest_tmp}/speedtest" "$BBR_SPEEDTEST_BIN" || {
        rm -rf "$speedtest_tmp"
        return 1
    }

    bbr_mark_managed_speedtest
    hash -r 2>/dev/null || true
    rm -rf "$speedtest_tmp"
}

bbr_mark_managed_speedtest() {
    [[ -x "$BBR_SPEEDTEST_BIN" ]] || return 0
    command -v sha256sum >/dev/null 2>&1 || return 0
    sha256sum "$BBR_SPEEDTEST_BIN" 2>/dev/null | awk '{print $1}' > "$BBR_SPEEDTEST_MARKER" 2>/dev/null || true
}

bbr_cleanup_managed_speedtest() {
    [[ -f "$BBR_SPEEDTEST_MARKER" ]] || return 0

    if [[ ! -e "$BBR_SPEEDTEST_BIN" ]]; then
        rm -f "$BBR_SPEEDTEST_MARKER"
        return 0
    fi

    command -v sha256sum >/dev/null 2>&1 || {
        rm -f "$BBR_SPEEDTEST_MARKER"
        return 0
    }

    local expected current
    expected=$(head -n 1 "$BBR_SPEEDTEST_MARKER" 2>/dev/null)
    current=$(sha256sum "$BBR_SPEEDTEST_BIN" 2>/dev/null | awk '{print $1}')
    if [[ -n "$expected" && "$expected" == "$current" ]]; then
        rm -f "$BBR_SPEEDTEST_BIN"
        hash -r 2>/dev/null || true
    fi
    rm -f "$BBR_SPEEDTEST_MARKER"
}

bbr_ensure_speedtest() {
    local cpu_arch download_url
    cpu_arch=$(uname -m)

    case "$cpu_arch" in
        x86_64) ;;
        *)
            echo -e "${RED}错误: 不支持的架构 ${cpu_arch}${PLAIN}" >&2
            return 1
            ;;
    esac

    if command -v speedtest >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}speedtest 未安装，正在临时安装...${PLAIN}" >&2
    download_url=$(bbr_get_speedtest_download_url 2>/dev/null || true)
    if [[ -z "$download_url" ]]; then
        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
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
                bbr_cleanup_managed_speedtest
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
                bbr_cleanup_managed_speedtest
                echo "1000"
                return 1
            fi

            upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || (( upload_mbps <= 0 )); then
                echo -e "${YELLOW}检测值异常 (${upload_speed})，使用默认值 1000 Mbps${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                echo "1000"
                return 1
            fi

            echo -e "${GREEN}检测到上传带宽: ${upload_mbps} Mbps${PLAIN}" >&2
            bbr_cleanup_managed_speedtest
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

bbr_profile_label() {
    case "$1" in
        download) echo "下载增强" ;;
        *) echo "代理均衡" ;;
    esac
}

bbr_buffer_memory_cap_mb() {
    local mem_total="$1"
    local profile="${2:-balanced}"

    if ! [[ "$mem_total" =~ ^[0-9]+$ ]] || (( mem_total <= 0 )); then
        [[ "$profile" == "download" ]] && echo 96 || echo 64
        return 0
    fi

    if (( mem_total < 512 )); then
        [[ "$profile" == "download" ]] && echo 16 || echo 12
    elif (( mem_total < 768 )); then
        [[ "$profile" == "download" ]] && echo 32 || echo 24
    elif (( mem_total < 1024 )); then
        [[ "$profile" == "download" ]] && echo 64 || echo 48
    elif (( mem_total < 2048 )); then
        [[ "$profile" == "download" ]] && echo 80 || echo 64
    elif (( mem_total < 4096 )); then
        [[ "$profile" == "download" ]] && echo 96 || echo 80
    elif [[ "$profile" == "download" ]]; then
        echo 128
    else
        echo 96
    fi
}

bbr_calculate_buffer_size() {
    local bandwidth="$1"
    local region="${2:-asia}"
    local profile="${3:-balanced}"
    local mem_total="${4:-0}"
    local buffer_mb

    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || (( bandwidth <= 0 )); then
        case "$profile:$region" in
            download:overseas) buffer_mb=48 ;;
            download:*) buffer_mb=24 ;;
            *:overseas) buffer_mb=32 ;;
            *) buffer_mb=16 ;;
        esac
    elif [[ "$profile" == "download" ]]; then
        if [[ "$region" == "overseas" ]]; then
            if (( bandwidth <= 100 )); then
                buffer_mb=8
            elif (( bandwidth <= 200 )); then
                buffer_mb=16
            elif (( bandwidth <= 300 )); then
                buffer_mb=24
            elif (( bandwidth <= 500 )); then
                buffer_mb=32
            elif (( bandwidth <= 700 )); then
                buffer_mb=40
            elif (( bandwidth <= 1000 )); then
                buffer_mb=48
            elif (( bandwidth <= 1500 )); then
                buffer_mb=64
            elif (( bandwidth <= 2500 )); then
                buffer_mb=80
            else
                buffer_mb=96
            fi
        else
            if (( bandwidth <= 100 )); then
                buffer_mb=6
            elif (( bandwidth <= 200 )); then
                buffer_mb=8
            elif (( bandwidth <= 300 )); then
                buffer_mb=12
            elif (( bandwidth <= 500 )); then
                buffer_mb=16
            elif (( bandwidth <= 700 )); then
                buffer_mb=20
            elif (( bandwidth <= 1000 )); then
                buffer_mb=24
            elif (( bandwidth <= 1500 )); then
                buffer_mb=32
            elif (( bandwidth <= 2000 )); then
                buffer_mb=40
            elif (( bandwidth <= 2500 )); then
                buffer_mb=48
            else
                buffer_mb=64
            fi
        fi
    else
        if [[ "$region" == "overseas" ]]; then
            if (( bandwidth <= 100 )); then
                buffer_mb=8
            elif (( bandwidth <= 200 )); then
                buffer_mb=12
            elif (( bandwidth <= 300 )); then
                buffer_mb=16
            elif (( bandwidth <= 500 )); then
                buffer_mb=20
            elif (( bandwidth <= 700 )); then
                buffer_mb=28
            elif (( bandwidth <= 1000 )); then
                buffer_mb=32
            elif (( bandwidth <= 1500 )); then
                buffer_mb=40
            else
                buffer_mb=48
            fi
        else
            if (( bandwidth <= 100 )); then
                buffer_mb=4
            elif (( bandwidth <= 200 )); then
                buffer_mb=6
            elif (( bandwidth <= 300 )); then
                buffer_mb=8
            elif (( bandwidth <= 500 )); then
                buffer_mb=10
            elif (( bandwidth <= 700 )); then
                buffer_mb=12
            elif (( bandwidth <= 1000 )); then
                buffer_mb=16
            elif (( bandwidth <= 1500 )); then
                buffer_mb=20
            elif (( bandwidth <= 2000 )); then
                buffer_mb=24
            else
                buffer_mb=32
            fi
        fi
    fi

    local raw_buffer_mb mem_cap profile_label
    raw_buffer_mb="$buffer_mb"
    mem_cap=$(bbr_buffer_memory_cap_mb "$mem_total" "$profile")
    if [[ "$mem_cap" =~ ^[0-9]+$ ]] && (( buffer_mb > mem_cap )); then
        echo -e "${YELLOW}内存保护: 按带宽/地区计算 ${raw_buffer_mb}MB，物理内存 ${mem_total}MB，上限 ${mem_cap}MB${PLAIN}" >&2
        buffer_mb="$mem_cap"
    fi

    profile_label=$(bbr_profile_label "$profile")
    echo -e "${YELLOW}推荐缓冲区(${profile_label}): ${GREEN}${buffer_mb}MB${PLAIN}${YELLOW}（带宽/地区: ${raw_buffer_mb}MB，内存上限: ${mem_cap}MB）${PLAIN}" >&2
    if bbr_confirm "是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: " "Y"; then
        echo "$buffer_mb"
    else
        local custom_buffer
        read -r -p "请输入自定义缓冲区大小（MB）[${buffer_mb}]: " custom_buffer
        custom_buffer=$(trim_input "$custom_buffer")
        if [[ "$custom_buffer" =~ ^[0-9]+$ ]] && (( custom_buffer > 0 && custom_buffer <= 512 )); then
            if [[ "$mem_cap" =~ ^[0-9]+$ ]] && (( custom_buffer > mem_cap )); then
                echo -e "${YELLOW}内存保护: 自定义值超过 ${mem_cap}MB，已使用 ${mem_cap}MB${PLAIN}" >&2
                echo "$mem_cap"
                return 0
            fi
            echo "$custom_buffer"
        else
            echo "$buffer_mb"
        fi
    fi
}

bbr_clean_sysctl_conf_conflicts() {
    [[ -f /etc/sysctl.conf ]] || return 0

    cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null || true

    local key
    for key in \
        'net\.ipv4\.tcp_wmem' \
        'net\.ipv4\.tcp_rmem' \
        'net\.ipv4\.tcp_tw_reuse' \
        'net\.ipv4\.ip_local_port_range' \
        'net\.ipv4\.tcp_max_syn_backlog' \
        'net\.ipv4\.tcp_slow_start_after_idle' \
        'net\.ipv4\.tcp_mtu_probing' \
        'net\.ipv4\.tcp_notsent_lowat' \
        'net\.ipv4\.tcp_fin_timeout' \
        'net\.ipv4\.tcp_max_tw_buckets' \
        'net\.ipv4\.tcp_fastopen' \
        'net\.ipv4\.tcp_keepalive_time' \
        'net\.ipv4\.tcp_keepalive_intvl' \
        'net\.ipv4\.tcp_keepalive_probes' \
        'net\.ipv4\.udp_rmem_min' \
        'net\.ipv4\.udp_wmem_min' \
        'net\.ipv4\.tcp_syncookies' \
        'net\.core\.rmem_max' \
        'net\.core\.wmem_max' \
        'net\.core\.default_qdisc' \
        'net\.core\.somaxconn' \
        'net\.core\.netdev_max_backlog' \
        'net\.ipv4\.tcp_congestion_control'
    do
        sed -i -E "/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    done
}

bbr_check_and_clean_conflicts() {
    echo -e "${BLUE}=== 检查 sysctl 配置冲突 ===${PLAIN}"
    local conflicts=()
    local conf base num
    local tune_key_regex='net\.(core\.(rmem_max|wmem_max|default_qdisc|somaxconn|netdev_max_backlog)|ipv4\.(ip_local_port_range|udp_(rmem_min|wmem_min)|tcp_(rmem|wmem|congestion_control|tw_reuse|max_syn_backlog|slow_start_after_idle|mtu_probing|notsent_lowat|fin_timeout|max_tw_buckets|fastopen|keepalive_time|keepalive_intvl|keepalive_probes|syncookies)))'
    local active_tune_regex="^[[:space:]]*${tune_key_regex}[[:space:]]*="
    local sysctl_conf_tune_regex="^[[:space:]]*#?[[:space:]]*${tune_key_regex}[[:space:]]*="

    for conf in /etc/sysctl.d/*.conf; do
        [[ -f "$conf" ]] || continue
        [[ "$conf" == "$BBR_SYSCTL_CONF" ]] && continue
        if grep -qE "$active_tune_regex" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            if [[ -z "$num" || "$num" -ge 99 ]]; then
                conflicts+=("$conf")
            fi
        fi
    done

    local has_sysctl_conflict=0
    if [[ -f /etc/sysctl.conf ]] && grep -qE "$sysctl_conf_tune_regex" /etc/sysctl.conf 2>/dev/null; then
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

    read -rp "是否自动禁用/清理这些覆盖配置？(Y/N): " answer
    case "$answer" in
        [Yy])
            if [[ "$has_sysctl_conflict" -eq 1 ]]; then
                bbr_clean_sysctl_conf_conflicts
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

    while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; do
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || break
    done

    if [[ "$action" == "enable" ]]; then
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
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

    local profile="balanced" profile_choice profile_label="代理均衡"
    echo "1. 代理均衡（网页响应 + 下载速度）"
    echo "2. 下载增强（大文件/高带宽，仍兼顾网页响应）"
    read -r -p "请输入优化目标 [1]: " profile_choice
    profile_choice=$(trim_input "$profile_choice")
    if [[ "${profile_choice:-1}" == "2" ]]; then
        profile="download"
        profile_label="下载增强"
    fi

    local mem_total
    mem_total=$(free -m | awk '/Mem:/ {print $2}')
    [[ "$mem_total" =~ ^[0-9]+$ ]] || mem_total=0

    local buffer_mb buffer_bytes
    buffer_mb=$(bbr_calculate_buffer_size "$detected_bandwidth" "$region" "$profile" "$mem_total")
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    echo -e "${YELLOW}[步骤 2/5] 清理配置冲突...${PLAIN}"
    [[ -L /etc/sysctl.d/99-sysctl.conf ]] && rm -f /etc/sysctl.d/99-sysctl.conf
    bbr_check_and_clean_conflicts

    echo -e "${YELLOW}[步骤 3/5] 创建配置文件...${PLAIN}"
    local somaxconn=8192 tcp_max_syn_backlog=8192 netdev_max_backlog=5000 tcp_notsent_lowat=32768 tcp_max_tw_buckets=200000
    if [[ "$profile" == "download" ]]; then
        tcp_max_syn_backlog=16384
        netdev_max_backlog=10000
        tcp_notsent_lowat=131072
        tcp_max_tw_buckets=300000
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
net.core.somaxconn=${somaxconn}
net.ipv4.tcp_max_syn_backlog=${tcp_max_syn_backlog}
net.core.netdev_max_backlog=${netdev_max_backlog}
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=${tcp_notsent_lowat}
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=${tcp_max_tw_buckets}
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_syncookies=1
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
if command -v tc >/dev/null 2>&1; then
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue ;;
        esac
        tc qdisc replace dev "$dev" root fq 2>/dev/null
    done
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
EOF

    chmod +x "$BBR_PERSIST_SCRIPT"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || echo -e "${YELLOW}systemd 重新加载失败,BBR 持久化服务可能未生效${PLAIN}"
        systemctl enable "$BBR_PERSIST_SERVICE_NAME" >/dev/null 2>&1 || echo -e "${YELLOW}BBR 持久化服务启用失败,重启后可能需要重新应用调优${PLAIN}"
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
            echo -e "配置说明: ${GREEN}${profile_label}${PLAIN} / ${GREEN}${buffer_mb}MB${PLAIN} 缓冲区（${GREEN}${detected_bandwidth} Mbps${PLAIN} 带宽）"
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
    local action_label="安装"
    bbr_xanmod_installed && action_label="更新"

    echo -e "${BLUE}=== ${action_label} XanMod 内核与 BBR v3 ===${PLAIN}"
    echo "支持系统: Debian/Ubuntu (x86_64)"
    echo -e "${YELLOW}警告: 将升级 Linux 内核，请提前备份重要数据${PLAIN}"
    if ! bbr_confirm "确定继续${action_label}吗？(Y/N): "; then
        echo "已取消${action_label}"
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

    echo -e "${GREEN}XanMod 内核${action_label}成功${PLAIN}"
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
        bbr_cleanup_managed_speedtest
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
    echo -e "${GREEN}1.安装/更新XanMod${PLAIN}   ${RED}2.卸载XanMod${PLAIN}"
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
    } > "$DNS_RESOLV_CONF" 2>/dev/null
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
        mkdir -p "$DNS_RESOLVED_DROPIN_DIR" || return 1
        {
            echo "[Resolve]"
            echo "DNS=${dns_list[*]}"
            echo "Domains=~."
        } > "$DNS_RESOLVED_DROPIN_FILE" || return 1

        if ! systemctl restart systemd-resolved 2>/dev/null; then
            echo -e "${RED}systemd-resolved 重启失败${PLAIN}"
            return 1
        fi

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
            dns_write_resolv_conf "${dns_list[@]}" || return 1
        fi
    else
        if [[ -L "$DNS_RESOLV_CONF" ]]; then
            rm -f "$DNS_RESOLV_CONF" 2>/dev/null || return 1
        fi
        dns_unlock_resolv
        dns_write_resolv_conf "${dns_list[@]}" || return 1
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
    local pass_auth pubkey_auth permit_root_login
    local password_login_text pubkey_login_text
    local -a ssh_status

    mapfile -t ssh_status < <(ssh_read_status)
    permit_root_login="${ssh_status[1]}"
    pass_auth="${ssh_status[2]}"
    pubkey_auth="${ssh_status[3]}"

    [[ "$permit_root_login" == "yes" && "$pass_auth" == "yes" ]] && has_password=1
    [[ "$permit_root_login" =~ ^(yes|prohibit-password|without-password)$ && "$pubkey_auth" == "yes" ]] && has_pubkey=1

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
            if [[ "$pass_auth" == "yes" ]]; then
                if [[ $has_pubkey -ne 1 ]]; then
                    echo -e "${RED}关闭密码登录后将没有可确认的 root 登录方式,已取消${PLAIN}"
                    press_any_key_to_continue
                    return
                fi
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
            if [[ "$pubkey_auth" == "yes" ]]; then
                if [[ $has_password -ne 1 ]]; then
                    echo -e "${RED}关闭密钥登录后将没有可确认的 root 登录方式,已取消${PLAIN}"
                    press_any_key_to_continue
                    return
                fi
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
        if ! sysctl vm.swappiness="$new_val"; then
            echo -e "${RED}Swappiness 应用失败${PLAIN}"
            press_any_key_to_continue
            return 1
        fi
        
        if grep -q "^vm.swappiness" /etc/sysctl.conf; then
            sed -i "s/^vm.swappiness.*/vm.swappiness = $new_val/" /etc/sysctl.conf || echo -e "${YELLOW}写入 /etc/sysctl.conf 失败,重启后可能失效${PLAIN}"
        else
            echo "vm.swappiness = $new_val" | tee -a /etc/sysctl.conf >/dev/null || echo -e "${YELLOW}写入 /etc/sysctl.conf 失败,重启后可能失效${PLAIN}"
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
    mkdir -p /usr/local/bin || return 1
    install -d -m 700 /run/zero-acme-port80 || return 1

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
}

acme_require_port80_hook_scripts() {
    acme_install_port80_hook_scripts && return 0
    echo -e "${RED}ACME 80 端口钩子脚本安装失败${PLAIN}"
    press_any_key_to_continue
    return 1
}

acme_port80_hooks_referenced() {
    grep -Rqs -e "$ACME_PORT80_OPEN_HOOK" -e "$ACME_PORT80_CLOSE_HOOK" "$ACME_HOME" 2>/dev/null
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
    acme_require_port80_hook_scripts || return

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
    if acme_port80_hooks_referenced; then
        acme_require_port80_hook_scripts || return
    fi

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
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        press_any_key_to_continue
        return
    fi

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
  pause_any_key_and_clear "按任意键继续..."
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
    x86_64|amd64)
      echo "amd64" ;;
    *)
      echo -e "${RED}不支持${PLAIN}" >&2
      return 1 ;;
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
  
  if ! mkdir -p "$(dirname "$SNELL_BIN")" "$SNELL_ETC"; then
    echo -e "${RED}创建 Snell 目录失败${PLAIN}"
    snell_cleanup_tmp
    return 1
  fi

  if ! install -m 755 snell-server "${SNELL_BIN}"; then
    echo -e "${RED}安装 snell-server 可执行文件失败${PLAIN}"
    snell_cleanup_tmp
    return 1
  fi
  snell_cleanup_tmp
  
  echo -e "${GREEN}Snell ${version} 安装成功${PLAIN}"
  return 0
}

snell_restart_all_services() {
  local failed=0
  command -v systemctl >/dev/null 2>&1 || {
    echo -e "${RED}未检测到 systemctl,无法重启 Snell 服务${PLAIN}"
    return 1
  }

  systemctl daemon-reload || {
    echo -e "${RED}systemd 重新加载失败${PLAIN}"
    return 1
  }
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
    if systemctl restart "$svc_name" >/dev/null 2>&1; then
      echo -e "${GREEN}已重启服务: $svc_name${PLAIN}"
    else
      failed=1
      echo -e "${RED}服务重启失败: $svc_name${PLAIN}"
      service_failure_hint "$svc_name"
    fi
  done
  if (( failed == 0 )); then
    echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
  fi
  return "$failed"
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
  
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  systemctl enable --now "$service_name" >/dev/null 2>&1
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
    echo -e "${RED}配置 $config_name 已生成,但服务启动失败${PLAIN}"
    service_failure_hint "$(snell_service_name "$config_name")"
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

  local backup_config
  backup_config="$(mktemp)" || {
    echo -e "${RED}创建配置备份失败${PLAIN}"
    snell_pause_and_clear
    return 1
  }
  cp "$config_file" "$backup_config" || {
    rm -f "$backup_config"
    echo -e "${RED}备份配置失败${PLAIN}"
    snell_pause_and_clear
    return 1
  }

  snell_generate_config_file "$config_file" "$port" "$psk" "$obfs" "$obfs_host" "$ipv6" "$tfo" "$dns"

  if systemctl restart "$service_name" >/dev/null 2>&1; then
    rm -f "$backup_config"
    echo -e "${GREEN}配置已更新,服务已重启${PLAIN}"
  else
    if cp "$backup_config" "$config_file" && systemctl restart "$service_name" >/dev/null 2>&1; then
      echo -e "${YELLOW}新配置启动失败,已回滚到上一份可用配置${PLAIN}"
    else
      echo -e "${RED}新配置启动失败,回滚后服务仍未启动${PLAIN}"
      service_failure_hint "$service_name"
    fi
    rm -f "$backup_config"
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
  
  if systemctl stop "$service_name" >/dev/null 2>&1; then
    echo -e "${YELLOW}已停止服务: $service_name${PLAIN}"
  else
    echo -e "${RED}停止服务失败: $service_name${PLAIN}"
    service_failure_hint "$service_name"
  fi
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


SHOES_EXEC_PATH="/usr/local/bin/shoes"
SHOES_CONFIG_DIR="/etc/shoes"
SHOES_CONFIG_PATH="${SHOES_CONFIG_DIR}/config.yaml"
SHOES_SERVICE_NAME="shoes"
SHOES_SERVICE_FILE="/etc/systemd/system/shoes.service"
SHOES_RELEASE_REPO="sukurain/shoes"
SHOES_LATEST_API_URL="https://api.github.com/repos/${SHOES_RELEASE_REPO}/releases/latest"
SHOES_RELEASE_ASSET_NAME="shoes-musl.tar.gz"
SHOES_SS_DEFAULT_CIPHER="2022-blake3-aes-128-gcm"

shoes_check_supported_os() {
    local os_id

    if [[ ! -r /etc/os-release ]]; then
        shoes_print_err "不支持"
        return 1
    fi

    source /etc/os-release
    os_id="${ID:-}"

    case "$os_id" in
        debian|ubuntu)
            return 0
            ;;
        *)
            shoes_print_err "不支持"
            return 1
            ;;
    esac
}

shoes_pause_and_return() {
    pause_enter_and_clear "按回车返回..."
}

shoes_pause_here() {
    pause_enter "按回车继续..."
}

shoes_random_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

shoes_shadowsocks_cipher_key_len() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf '16' ;;
        2022-blake3-aes-256-gcm) printf '32' ;;
        *) return 1 ;;
    esac
}

shoes_shadowsocks_cipher_label() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf '2022-128' ;;
        2022-blake3-aes-256-gcm) printf '2022-256' ;;
        *) printf '%s' "$1" ;;
    esac
}

shoes_normalize_shadowsocks_cipher() {
    case "$1" in
        2022-128)
            printf '2022-blake3-aes-128-gcm'
            ;;
        2022-256)
            printf '2022-blake3-aes-256-gcm'
            ;;
        *)
            return 1
            ;;
    esac
}

shoes_generate_shadowsocks_2022_password() {
    local cipher="$1"
    local key_len output password

    if [[ -x "$SHOES_EXEC_PATH" ]]; then
        output="$("$SHOES_EXEC_PATH" generate-shadowsocks-2022-password "$cipher" 2>/dev/null || true)"
        password="$(printf '%s\n' "$output" | awk -F': ' '/^Password:/ {print $2; exit}')"
        if [[ -n "$password" ]]; then
            printf '%s' "$password"
            return 0
        fi
    fi

    key_len="$(shoes_shadowsocks_cipher_key_len "$cipher")" || return 1
    head -c "$key_len" /dev/urandom | base64 | tr -d '\n'
}

shoes_validate_shadowsocks_2022_password() {
    local cipher="$1"
    local password="$2"
    local key_len decoded_len

    key_len="$(shoes_shadowsocks_cipher_key_len "$cipher")" || return 0
    decoded_len="$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')"
    [[ "$decoded_len" == "$key_len" ]]
}

shoes_random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

shoes_yaml_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

shoes_print_info() {
    log_info "$*"
}

shoes_print_ok() {
    log_ok "$*"
}

shoes_print_warn() {
    log_warn "$*"
}

shoes_print_err() {
    log_err "$*"
}

shoes_require_commands() {
    local missing=()
    local cmd
    for cmd in curl tar systemctl base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        shoes_print_err "缺少命令: ${missing[*]}"
        return 1
    fi
}

shoes_load_defaults() {
    local protocol_key reset_fn
    while IFS= read -r protocol_key; do
        reset_fn="$(shoes_protocol_meta_value "$protocol_key" "reset_fn")"
        "$reset_fn"
    done < <(shoes_protocol_keys)
}

shoes_protocol_marker() {
    printf '# shoes-managed: protocol=%s' "$1"
}

shoes_extract_protocol_block() {
    local protocol_type="$1"
    local marker block
    [[ -f "$SHOES_CONFIG_PATH" ]] || return 0

    marker="$(shoes_protocol_marker "$protocol_type")"
    block="$(awk -v RS='' -v marker="$marker" '
        index($0, marker) > 0 { print; exit }
    ' "$SHOES_CONFIG_PATH")"

    if [[ -n "$block" ]]; then
        printf '%s\n' "$block"
        return 0
    fi

    awk -v RS='' -v protocol_type="$protocol_type" '
        $0 ~ ("type:[[:space:]]*" protocol_type "([[:space:]]|$)") { print; exit }
    ' "$SHOES_CONFIG_PATH"
}

shoes_extract_scalar_from_block() {
    local block="$1"
    local field="$2"
    printf '%s\n' "$block" | sed -nE "s/^[[:space:]-]*${field}:[[:space:]]*\"?([^\"]*)\"?$/\1/p" | head -n1
}

shoes_extract_last_scalar_from_block() {
    local block="$1"
    local field="$2"
    printf '%s\n' "$block" | sed -nE "s/^[[:space:]-]*${field}:[[:space:]]*\"?([^\"]*)\"?$/\1/p" | tail -n1
}

shoes_load_current_config() {
    shoes_load_defaults
    local protocol_key load_fn
    while IFS= read -r protocol_key; do
        load_fn="$(shoes_protocol_meta_value "$protocol_key" "load_fn")"
        "$load_fn"
    done < <(shoes_protocol_keys)
}

shoes_read_value() {
    local __var="$1"
    local prompt="$2"
    local default_value="$3"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    input="${input:-$default_value}"
    printf -v "$__var" '%s' "$input"
}

shoes_trim_whitespace() {
    trim_input "$1"
}

shoes_normalize_bind_address() {
    local raw
    raw="$(shoes_trim_whitespace "$1")"

    if [[ -z "$raw" ]]; then
        printf '%s' "$raw"
        return 0
    fi

    if [[ "$raw" == *:* ]]; then
        printf '%s' "$raw"
        return 0
    fi

    if [[ "$raw" =~ ^[0-9,-]+$ ]]; then
        printf '[::]:%s' "$raw"
        return 0
    fi

    printf '%s' "$raw"
}

shoes_read_address_value() {
    local __var="$1"
    local prompt="$2"
    local default_value="$3"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    input="${input:-$default_value}"
    input="$(shoes_normalize_bind_address "$input")"
    printf -v "$__var" '%s' "$input"
}

shoes_bind_port_display() {
    local value="$1"

    if [[ "$value" =~ ^\[.*\]:([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    if [[ "$value" =~ :([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    printf '%s' "$value"
}

shoes_read_port_value() {
    local var_name="$1"
    local current_value="${!var_name}"
    shoes_read_address_value "$var_name" "端口(默认:$(shoes_bind_port_display "$current_value")): " "$current_value"
}

shoes_read_password_or_random() {
    local __var="$1"
    local prompt="$2"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    if [[ -z "$input" ]]; then
        input="$(shoes_random_pass)"
        shoes_print_ok "密码: ${input}"
    fi
    printf -v "$__var" '%s' "$input"
}

shoes_read_shadowsocks_password_or_random() {
    local __var="$1"
    local prompt="$2"
    local cipher="$3"
    local input=""

    while true; do
        read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
        if [[ -z "$input" ]]; then
            input="$(shoes_generate_shadowsocks_2022_password "$cipher")" || input="$(shoes_random_pass)"
            shoes_print_ok "密码: ${input}"
            break
        fi

        if shoes_validate_shadowsocks_2022_password "$cipher" "$input"; then
            break
        fi

        shoes_print_warn "2022 密码格式不正确，请重新输入，或直接回车随机生成"
    done

    printf -v "$__var" '%s' "$input"
}

shoes_read_shadowsocks_cipher_value() {
    local __var="$1"
    local current_value="${!__var}"
    local input=""

    while true; do
        read -r -p "$(echo -e "${BLUE}加密(默认:$(shoes_shadowsocks_cipher_label "$current_value")): ${PLAIN}")" input
        if [[ -z "$input" ]]; then
            input="$current_value"
        elif ! input="$(shoes_normalize_shadowsocks_cipher "$input")"; then
            shoes_print_warn "只支持 2022-128 或 2022-256"
            continue
        fi
        if shoes_shadowsocks_cipher_key_len "$input" >/dev/null; then
            printf -v "$__var" '%s' "$input"
            return 0
        fi
        shoes_print_warn "只支持 2022-128 或 2022-256"
    done
}

shoes_read_uuid_or_random() {
    local __var="$1"
    local prompt="$2"
    local input=""
    read -r -p "$(echo -e "${BLUE}${prompt}${PLAIN}")" input
    if [[ -z "$input" ]]; then
        input="$(shoes_random_uuid)"
        shoes_print_ok "UUID: ${input}"
    fi
    printf -v "$__var" '%s' "$input"
}

shoes_ask_yes_no() {
    local prompt="$1"
    local default_choice="$2"
    local suffix=""
    local answer=""

    if [[ "$default_choice" == "y" || "$default_choice" == "Y" ]]; then
        suffix="[Y/n]"
        default_choice="y"
    else
        suffix="[y/N]"
        default_choice="n"
    fi

    while true; do
        read -r -p "$(echo -e "${BLUE}${prompt} ${suffix}: ${PLAIN}")" answer
        answer="${answer:-$default_choice}"
        case "$answer" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) shoes_print_warn "请输入 y 或 n" ;;
        esac
    done
}

shoes_bool_label() {
    if [[ "$1" == "true" ]]; then
        echo "${GREEN}开启${PLAIN}"
    else
        echo "${RED}关闭${PLAIN}"
    fi
}

shoes_select_cert() {
    local current_cert="${1:-}"
    local current_key="${2:-}"
    local cert_files=()
    local opt=""
    local index=1

    while true; do
        echo -e "${BLUE}证书配置${PLAIN}"
        if [[ -n "$current_cert" && -n "$current_key" && -f "$current_cert" && -f "$current_key" ]]; then
            echo -e "${GREEN}回车.${PLAIN}保留当前证书: ${current_cert}"
        fi

        cert_files=()
        if compgen -G "/etc/cert/*.crt" > /dev/null 2>&1; then
            mapfile -t cert_files < <(ls /etc/cert/*.crt 2>/dev/null | sort)
        fi

        index=1
        while (( index <= ${#cert_files[@]} )); do
            echo -e "${GREEN}${index}.${PLAIN}$(basename "${cert_files[$((index-1))]}")"
            ((index++))
        done
        echo -e "${GREEN}0.${PLAIN}自定义路径"

        read -r -p "$(echo -e "${BLUE}输入选项: ${PLAIN}")" opt

        if [[ -z "$opt" && -n "$current_cert" && -n "$current_key" && -f "$current_cert" && -f "$current_key" ]]; then
            cert_path="$current_cert"
            key_path="$current_key"
            return 0
        fi

        if [[ "$opt" == "0" ]]; then
            read -r -p "$(echo -e "${BLUE}证书路径: ${PLAIN}")" cert_path
            read -r -p "$(echo -e "${BLUE}私钥路径: ${PLAIN}")" key_path
            if [[ -f "$cert_path" && -f "$key_path" ]]; then
                return 0
            fi
            shoes_print_err "路径无效"
            sleep 1
            continue
        fi

        if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#cert_files[@]} )); then
            cert_path="${cert_files[$((opt-1))]}"
            key_path="${cert_path%.crt}.key"
            if [[ -f "$key_path" ]]; then
                return 0
            fi
            shoes_print_err "未找到对应私钥: $key_path"
            sleep 1
            continue
        fi

        shoes_print_warn "无效选项"
        sleep 1
    done
}

shoes_derive_name_from_cert_path() {
    local cert_file base_name
    cert_file="$1"
    base_name="$(basename "$cert_file")"
    base_name="${base_name%.crt}"
    base_name="${base_name%.pem}"
    printf '%s' "$base_name"
}

shoes_protocol_metadata() {
    cat <<'EOF'
anytls|ENABLE_ANYTLS|shoes_reset_anytls_state|shoes_load_anytls_config|shoes_configure_anytls|shoes_append_anytls|shoes_modify_anytls|AnyTLS|Anytls
trojan|ENABLE_TROJAN|shoes_reset_trojan_state|shoes_load_trojan_config|shoes_configure_trojan|shoes_append_trojan|shoes_modify_trojan|Trojan|Trojan
tuic|ENABLE_TUIC|shoes_reset_tuic_state|shoes_load_tuic_config|shoes_configure_tuic|shoes_append_tuic|shoes_modify_tuic|Tuicv5|Tuicv5
hy2|ENABLE_HY2|shoes_reset_hysteria2_state|shoes_load_hysteria2_config|shoes_configure_hysteria2|shoes_append_hysteria2|shoes_modify_hysteria|Hysteria|Hysteria
shadowsocks|ENABLE_SS|shoes_reset_shadowsocks_state|shoes_load_shadowsocks_config|shoes_configure_shadowsocks|shoes_append_shadowsocks|shoes_modify_shadowsocks|Shadowsocks|Shadowsocks
EOF
}

shoes_protocol_keys() {
    shoes_protocol_metadata | awk -F'|' '{print $1}'
}

shoes_protocol_meta_value() {
    local protocol_key="$1"
    local field="$2"
    local field_index

    case "$field" in
        enable_var) field_index=2 ;;
        reset_fn) field_index=3 ;;
        load_fn) field_index=4 ;;
        configure_fn) field_index=5 ;;
        append_fn) field_index=6 ;;
        modify_fn) field_index=7 ;;
        prompt_label) field_index=8 ;;
        menu_label) field_index=9 ;;
        *) return 1 ;;
    esac

    shoes_protocol_metadata | awk -F'|' -v key="$protocol_key" -v field_index="$field_index" '
        $1 == key { print $field_index; exit }
    '
}

shoes_protocol_enabled() {
    local var_name
    var_name="$(shoes_protocol_meta_value "$1" "enable_var")"
    [[ -n "$var_name" && "${!var_name}" == "y" ]]
}

shoes_set_protocol_enabled() {
    local protocol_key="$1"
    local value="$2"
    local var_name
    var_name="$(shoes_protocol_meta_value "$protocol_key" "enable_var")"
    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" '%s' "$value"
    fi
}

shoes_reset_shadowsocks_state() {
    ENABLE_SS="n"
    SS_ADDRESS="[::]:8388"
    SS_CIPHER="$SHOES_SS_DEFAULT_CIPHER"
    SS_PASSWORD=""
    SS_SHADOWTLS_ENABLED="false"
    SS_CERT=""
    SS_KEY=""
}

shoes_load_shadowsocks_config() {
    local block
    block="$(shoes_extract_protocol_block "shadowsocks")"
    if [[ -n "$block" ]]; then
        ENABLE_SS="y"
        SS_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        SS_CIPHER="$(shoes_extract_scalar_from_block "$block" "cipher")"
        SS_PASSWORD="$(shoes_extract_last_scalar_from_block "$block" "password")"
        if printf '%s\n' "$block" | grep -q 'shadowtls_targets:'; then
            SS_SHADOWTLS_ENABLED="true"
            SS_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
            SS_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
        else
            SS_SHADOWTLS_ENABLED="false"
        fi
    fi
}

shoes_configure_shadowsocks() {
    clear
    echo -e "${BLUE}===== Shadowsocks =====${PLAIN}"
    shoes_read_port_value "SS_ADDRESS"
    shoes_read_shadowsocks_cipher_value "SS_CIPHER"
    shoes_read_shadowsocks_password_or_random "SS_PASSWORD" "密码(回车随机): " "$SS_CIPHER"
    if shoes_ask_yes_no "STLS:" "$([[ "$SS_SHADOWTLS_ENABLED" == "true" ]] && echo y || echo n)"; then
        SS_SHADOWTLS_ENABLED="true"
        shoes_select_cert "$SS_CERT" "$SS_KEY"
        SS_CERT="$cert_path"
        SS_KEY="$key_path"
    else
        SS_SHADOWTLS_ENABLED="false"
    fi
}

shoes_append_shadowsocks() {
    local out="$1"
    local ss_sni
    if [[ "$SS_SHADOWTLS_ENABLED" == "true" ]]; then
        ss_sni="$(shoes_derive_name_from_cert_path "$SS_CERT")"
        cat >> "$out" <<EOF
# shoes-managed: protocol=shadowsocks
- address: $(shoes_yaml_quote "$SS_ADDRESS")
  protocol:
    type: tls
    shadowtls_targets:
      $(shoes_yaml_quote "$ss_sni"):
        password: $(shoes_yaml_quote "$SS_PASSWORD")
        handshake:
          cert: $(shoes_yaml_quote "$SS_CERT")
          key: $(shoes_yaml_quote "$SS_KEY")
        protocol:
          type: shadowsocks
          cipher: $(shoes_yaml_quote "$SS_CIPHER")
          password: $(shoes_yaml_quote "$SS_PASSWORD")
          udp_enabled: true

EOF
        return
    fi

    cat >> "$out" <<EOF
# shoes-managed: protocol=shadowsocks
- address: $(shoes_yaml_quote "$SS_ADDRESS")
  protocol:
    type: shadowsocks
    cipher: $(shoes_yaml_quote "$SS_CIPHER")
    password: $(shoes_yaml_quote "$SS_PASSWORD")
    udp_enabled: true

EOF
}

shoes_modify_shadowsocks() {
    while true; do
        clear
        echo -e "${BLUE}✦ Shadowsocks_Conf ✦${PLAIN}"

        if [[ "$ENABLE_SS" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改加密"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}切换STLS (当前: $(shoes_bool_label "$SS_SHADOWTLS_ENABLED"))"
            echo -e "${GREEN}  5.${PLAIN}修改STLS证书"
            echo -e "${GREEN}  6.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "SS_ADDRESS" ;;
                2) shoes_apply_shadowsocks_cipher_update ;;
                3) shoes_apply_shadowsocks_password_update ;;
                4) shoes_apply_shadowsocks_shadowtls_toggle ;;
                5) shoes_apply_shadowsocks_cert_update ;;
                6)
                    if shoes_disable_protocol_with_confirmation "ENABLE_SS" "Shadowsocks"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_SS" "shoes_configure_shadowsocks"; then
                break
            fi
        fi
    done
}

shoes_reset_trojan_state() {
    ENABLE_TROJAN="n"
    TROJAN_ADDRESS="[::]:4443"
    TROJAN_WS_PATH="/"
    TROJAN_PASSWORD=""
    TROJAN_CERT=""
    TROJAN_KEY=""
}

shoes_load_trojan_config() {
    local block
    block="$(shoes_extract_protocol_block "trojan")"
    if [[ -n "$block" ]]; then
        ENABLE_TROJAN="y"
        TROJAN_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        TROJAN_WS_PATH="$(shoes_extract_scalar_from_block "$block" "matching_path")"
        TROJAN_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        TROJAN_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        TROJAN_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
    fi
}

shoes_configure_trojan() {
    clear
    echo -e "${BLUE}===== Trojan =====${PLAIN}"
    shoes_read_port_value "TROJAN_ADDRESS"
    shoes_read_value "TROJAN_WS_PATH" "路径(默认:${TROJAN_WS_PATH}): " "$TROJAN_WS_PATH"
    shoes_read_value "TROJAN_PASSWORD" "密码(回车随机): " "$TROJAN_PASSWORD"
    if [[ -z "$TROJAN_PASSWORD" ]]; then
        TROJAN_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${TROJAN_PASSWORD}"
    fi
    shoes_select_cert "$TROJAN_CERT" "$TROJAN_KEY"
    TROJAN_CERT="$cert_path"
    TROJAN_KEY="$key_path"
}

shoes_append_trojan() {
    local out="$1"
    local trojan_sni
    trojan_sni="$(shoes_derive_name_from_cert_path "$TROJAN_CERT")"
    cat >> "$out" <<EOF
# shoes-managed: protocol=trojan
- address: $(shoes_yaml_quote "$TROJAN_ADDRESS")
  protocol:
    type: tls
    tls_targets:
      $(shoes_yaml_quote "$trojan_sni"):
        cert: $(shoes_yaml_quote "$TROJAN_CERT")
        key: $(shoes_yaml_quote "$TROJAN_KEY")
        protocol:
          type: websocket
          targets:
            - matching_path: $(shoes_yaml_quote "$TROJAN_WS_PATH")
              protocol:
                type: trojan
                password: $(shoes_yaml_quote "$TROJAN_PASSWORD")

EOF
}

shoes_modify_trojan() {
    while true; do
        clear
        echo -e "${BLUE}✦ Trojan_Conf ✦${PLAIN}"

        if [[ "$ENABLE_TROJAN" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改路径"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}修改证书"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "TROJAN_ADDRESS" ;;
                2) shoes_apply_value_update "TROJAN_WS_PATH" "新路径" ;;
                3) shoes_apply_password_update "TROJAN_PASSWORD" ;;
                4) shoes_apply_cert_update "TROJAN_CERT" "TROJAN_KEY" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_TROJAN" "Trojan"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_TROJAN" "shoes_configure_trojan"; then
                break
            fi
        fi
    done
}

shoes_reset_hysteria2_state() {
    ENABLE_HY2="n"
    HY2_ADDRESS="[::]:8443"
    HY2_PASSWORD=""
    HY2_CERT=""
    HY2_KEY=""
    HY2_BBR_ENABLED="false"
}

shoes_load_hysteria2_config() {
    local block congestion
    block="$(shoes_extract_protocol_block "hysteria2")"
    if [[ -n "$block" ]]; then
        ENABLE_HY2="y"
        HY2_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        HY2_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        HY2_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        HY2_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
        congestion="$(shoes_extract_scalar_from_block "$block" "congestion")"
        [[ "$congestion" == "bbr" ]] && HY2_BBR_ENABLED="true" || HY2_BBR_ENABLED="false"
    fi
}

shoes_configure_hysteria2() {
    clear
    echo -e "${BLUE}===== Hysteria2 =====${PLAIN}"
    shoes_read_port_value "HY2_ADDRESS"
    shoes_read_value "HY2_PASSWORD" "密码(回车随机): " "$HY2_PASSWORD"
    if [[ -z "$HY2_PASSWORD" ]]; then
        HY2_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${HY2_PASSWORD}"
    fi
    if shoes_ask_yes_no "BBR:" "$([[ "$HY2_BBR_ENABLED" == "true" ]] && echo y || echo n)"; then
        HY2_BBR_ENABLED="true"
    else
        HY2_BBR_ENABLED="false"
    fi
    shoes_select_cert "$HY2_CERT" "$HY2_KEY"
    HY2_CERT="$cert_path"
    HY2_KEY="$key_path"
}

shoes_append_hysteria2() {
    local out="$1"
    cat >> "$out" <<EOF
# shoes-managed: protocol=hysteria2
- address: $(shoes_yaml_quote "$HY2_ADDRESS")
  transport: quic
  quic_settings:
    cert: $(shoes_yaml_quote "$HY2_CERT")
    key: $(shoes_yaml_quote "$HY2_KEY")
    alpn_protocols:
      - "h3"
EOF
    if [[ "$HY2_BBR_ENABLED" == "true" ]]; then
        cat >> "$out" <<EOF
    congestion: bbr
EOF
    fi
    cat >> "$out" <<EOF
  protocol:
    type: hysteria2
    password: $(shoes_yaml_quote "$HY2_PASSWORD")
    udp_enabled: true

EOF
}

shoes_modify_hysteria() {
    while true; do
        clear
        echo -e "${BLUE}✦ Hysteria2_Conf ✦${PLAIN}"

        if [[ "$ENABLE_HY2" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改密码"
            echo -e "${GREEN}  3.${PLAIN}修改证书"
            echo -e "${GREEN}  4.${PLAIN}切换BBR (当前: $(shoes_bool_label "$HY2_BBR_ENABLED"))"
            echo -e "${GREEN}  5.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "HY2_ADDRESS" ;;
                2) shoes_apply_password_update "HY2_PASSWORD" ;;
                3) shoes_apply_cert_update "HY2_CERT" "HY2_KEY" ;;
                4) shoes_apply_boolean_toggle "HY2_BBR_ENABLED" ;;
                5)
                    if shoes_disable_protocol_with_confirmation "ENABLE_HY2" "Hysteria2"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_HY2" "shoes_configure_hysteria2"; then
                break
            fi
        fi
    done
}

shoes_reset_tuic_state() {
    ENABLE_TUIC="n"
    TUIC_ADDRESS="[::]:9443"
    TUIC_UUID=""
    TUIC_PASSWORD=""
    TUIC_CERT=""
    TUIC_KEY=""
    TUIC_BBR_ENABLED="false"
}

shoes_load_tuic_config() {
    local block congestion
    block="$(shoes_extract_protocol_block "tuic")"
    if [[ -n "$block" ]]; then
        ENABLE_TUIC="y"
        TUIC_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        TUIC_UUID="$(shoes_extract_scalar_from_block "$block" "uuid")"
        TUIC_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        TUIC_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        TUIC_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
        congestion="$(shoes_extract_scalar_from_block "$block" "congestion")"
        [[ "$congestion" == "bbr" ]] && TUIC_BBR_ENABLED="true" || TUIC_BBR_ENABLED="false"
    fi
}

shoes_configure_tuic() {
    clear
    echo -e "${BLUE}===== TUIC v5 =====${PLAIN}"
    shoes_read_port_value "TUIC_ADDRESS"
    shoes_read_value "TUIC_UUID" "UUID(回车随机): " "$TUIC_UUID"
    if [[ -z "$TUIC_UUID" ]]; then
        TUIC_UUID="$(shoes_random_uuid)"
        shoes_print_ok "UUID: ${TUIC_UUID}"
    fi
    shoes_read_value "TUIC_PASSWORD" "密码(回车随机): " "$TUIC_PASSWORD"
    if [[ -z "$TUIC_PASSWORD" ]]; then
        TUIC_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${TUIC_PASSWORD}"
    fi
    if shoes_ask_yes_no "BBR:" "$([[ "$TUIC_BBR_ENABLED" == "true" ]] && echo y || echo n)"; then
        TUIC_BBR_ENABLED="true"
    else
        TUIC_BBR_ENABLED="false"
    fi
    shoes_select_cert "$TUIC_CERT" "$TUIC_KEY"
    TUIC_CERT="$cert_path"
    TUIC_KEY="$key_path"
}

shoes_append_tuic() {
    local out="$1"
    cat >> "$out" <<EOF
# shoes-managed: protocol=tuic
- address: $(shoes_yaml_quote "$TUIC_ADDRESS")
  transport: quic
  quic_settings:
    cert: $(shoes_yaml_quote "$TUIC_CERT")
    key: $(shoes_yaml_quote "$TUIC_KEY")
    alpn_protocols:
      - "h3"
EOF
    if [[ "$TUIC_BBR_ENABLED" == "true" ]]; then
        cat >> "$out" <<EOF
    congestion: bbr
EOF
    fi
    cat >> "$out" <<EOF
  protocol:
    type: tuic
    uuid: $(shoes_yaml_quote "$TUIC_UUID")
    password: $(shoes_yaml_quote "$TUIC_PASSWORD")

EOF
}

shoes_modify_tuic() {
    while true; do
        clear
        echo -e "${BLUE}✦ TUIC_Conf ✦${PLAIN}"

        if [[ "$ENABLE_TUIC" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改UUID"
            echo -e "${GREEN}  3.${PLAIN}修改密码"
            echo -e "${GREEN}  4.${PLAIN}修改证书"
            echo -e "${GREEN}  5.${PLAIN}切换BBR (当前: $(shoes_bool_label "$TUIC_BBR_ENABLED"))"
            echo -e "${GREEN}  6.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "TUIC_ADDRESS" ;;
                2) shoes_apply_uuid_update "TUIC_UUID" ;;
                3) shoes_apply_password_update "TUIC_PASSWORD" ;;
                4) shoes_apply_cert_update "TUIC_CERT" "TUIC_KEY" ;;
                5) shoes_apply_boolean_toggle "TUIC_BBR_ENABLED" ;;
                6)
                    if shoes_disable_protocol_with_confirmation "ENABLE_TUIC" "TUIC v5"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_TUIC" "shoes_configure_tuic"; then
                break
            fi
        fi
    done
}

shoes_reset_anytls_state() {
    ENABLE_ANYTLS="n"
    ANYTLS_ADDRESS="[::]:443"
    ANYTLS_PASSWORD=""
    ANYTLS_CERT=""
    ANYTLS_KEY=""
}

shoes_load_anytls_config() {
    local block
    block="$(shoes_extract_protocol_block "anytls")"
    if [[ -n "$block" ]]; then
        ENABLE_ANYTLS="y"
        ANYTLS_ADDRESS="$(shoes_extract_scalar_from_block "$block" "address")"
        ANYTLS_PASSWORD="$(shoes_extract_scalar_from_block "$block" "password")"
        ANYTLS_CERT="$(shoes_extract_scalar_from_block "$block" "cert")"
        ANYTLS_KEY="$(shoes_extract_scalar_from_block "$block" "key")"
    fi
}

shoes_configure_anytls() {
    clear
    echo -e "${BLUE}===== AnyTLS =====${PLAIN}"
    shoes_read_port_value "ANYTLS_ADDRESS"
    shoes_read_value "ANYTLS_PASSWORD" "密码(回车随机): " "$ANYTLS_PASSWORD"
    if [[ -z "$ANYTLS_PASSWORD" ]]; then
        ANYTLS_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "密码: ${ANYTLS_PASSWORD}"
    fi
    shoes_select_cert "$ANYTLS_CERT" "$ANYTLS_KEY"
    ANYTLS_CERT="$cert_path"
    ANYTLS_KEY="$key_path"
}

shoes_append_anytls() {
    local out="$1"
    local anytls_sni
    anytls_sni="$(shoes_derive_name_from_cert_path "$ANYTLS_CERT")"
    cat >> "$out" <<EOF
# shoes-managed: protocol=anytls
- address: $(shoes_yaml_quote "$ANYTLS_ADDRESS")
  protocol:
    type: tls
    tls_targets:
      $(shoes_yaml_quote "$anytls_sni"):
        cert: $(shoes_yaml_quote "$ANYTLS_CERT")
        key: $(shoes_yaml_quote "$ANYTLS_KEY")
        protocol:
          type: anytls
          users:
            - name: "user1"
              password: $(shoes_yaml_quote "$ANYTLS_PASSWORD")
          udp_enabled: true
          padding_scheme:
            - "stop=8"
            - "0=30-30"
            - "1=100-400"
            - "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000"
            - "3=9-9,500-1000"
            - "4=500-1000"
            - "5=500-1000"
            - "6=500-1000"
            - "7=500-1000"

EOF
}

shoes_modify_anytls() {
    while true; do
        clear
        echo -e "${BLUE}✦ AnyTLS_Conf ✦${PLAIN}"

        if [[ "$ENABLE_ANYTLS" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改密码"
            echo -e "${GREEN}  3.${PLAIN}修改证书"
            echo -e "${GREEN}  4.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

            case "$opt" in
                1) shoes_apply_address_update "ANYTLS_ADDRESS" ;;
                2) shoes_apply_password_update "ANYTLS_PASSWORD" ;;
                3) shoes_apply_cert_update "ANYTLS_CERT" "ANYTLS_KEY" ;;
                4)
                    if shoes_disable_protocol_with_confirmation "ENABLE_ANYTLS" "AnyTLS"; then
                        break
                    fi
                    ;;
                0) break ;;
                *) shoes_print_warn "无效选项"; sleep 1 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            if ! shoes_prompt_enable_protocol "ENABLE_ANYTLS" "shoes_configure_anytls"; then
                break
            fi
        fi
    done
}

shoes_protocol_count() {
    local count=0
    local protocol_key
    while IFS= read -r protocol_key; do
        if shoes_protocol_enabled "$protocol_key"; then
            ((count++))
        fi
    done < <(shoes_protocol_keys)
    echo "$count"
}

shoes_run_configuration_wizard() {
    local protocol_key enable_var configure_fn
    local protocol_keys_list=()
    mapfile -t protocol_keys_list < <(shoes_protocol_keys)

    while true; do
        clear
        echo -e "${BLUE}选择要启用的协议${PLAIN}"

        for protocol_key in "${protocol_keys_list[@]}"; do
            enable_var="$(shoes_protocol_meta_value "$protocol_key" "enable_var")"
            if shoes_ask_yes_no "启用 $(shoes_protocol_meta_value "$protocol_key" "prompt_label")" "${!enable_var}"; then
                shoes_set_protocol_enabled "$protocol_key" "y"
            else
                shoes_set_protocol_enabled "$protocol_key" "n"
            fi
        done

        if [[ "$(shoes_protocol_count)" -gt 0 ]]; then
            for protocol_key in "${protocol_keys_list[@]}"; do
                if shoes_protocol_enabled "$protocol_key"; then
                    configure_fn="$(shoes_protocol_meta_value "$protocol_key" "configure_fn")"
                    "$configure_fn"
                fi
            done

            break
        fi

        shoes_print_err "至少需要启用一个协议"
        sleep 1
    done
}

shoes_render_config_file() {
    local out="$1"
    local protocol_key append_fn
    : > "$out"

    while IFS= read -r protocol_key; do
        if shoes_protocol_enabled "$protocol_key"; then
            append_fn="$(shoes_protocol_meta_value "$protocol_key" "append_fn")"
            "$append_fn" "$out"
        fi
    done < <(shoes_protocol_keys)

    if [[ "$(shoes_protocol_count)" -eq 0 ]]; then
        return 1
    fi

    return 0
}

shoes_create_systemd_service() {
    cat > "$SHOES_SERVICE_FILE" <<EOF
[Unit]
Description=shoes proxy service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SHOES_EXEC_PATH} ${SHOES_CONFIG_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SHOES_SERVICE_FILE"
}

shoes_validate_config_file() {
    local config_file="$1"
    local dry_run_log="$2"
    "$SHOES_EXEC_PATH" --dry-run "$config_file" > "$dry_run_log" 2>&1
}

shoes_install_config_file() {
    local staged_config="$1"
    mkdir -p "$SHOES_CONFIG_DIR" || return 1
    mv "$staged_config" "$SHOES_CONFIG_PATH" || return 1
}

shoes_reload_service_unit() {
    shoes_create_systemd_service
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        shoes_print_err "systemd daemon-reload 失败"
        return 1
    fi
    if ! systemctl enable "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
        shoes_print_err "启用 shoes 服务失败"
        return 1
    fi
    return 0
}

shoes_run_service_action_checked() {
    local action="$1"
    local fail_message="$2"

    if ! systemctl "$action" "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
        [[ -n "$fail_message" ]] && shoes_print_err "$fail_message"
        service_failure_hint "$SHOES_SERVICE_NAME"
        return 1
    fi
    return 0
}

shoes_apply_configuration() {
    local tmp_config dry_run_log
    tmp_config="$(mktemp)"
    dry_run_log="$(mktemp)"

    if ! shoes_render_config_file "$tmp_config"; then
        rm -f "$tmp_config" "$dry_run_log"
        shoes_print_err "未生成任何协议配置"
        return 1
    fi

    if ! shoes_validate_config_file "$tmp_config" "$dry_run_log"; then
        shoes_print_err "配置校验失败"
        echo -e "${YELLOW}---------------- 生成的配置 ----------------${PLAIN}"
        cat "$tmp_config"
        echo -e "${YELLOW}--------------------------------------------${PLAIN}"
        cat "$dry_run_log"
        rm -f "$tmp_config" "$dry_run_log"
        return 1
    fi

    if ! shoes_install_config_file "$tmp_config"; then
        shoes_print_err "写入配置文件失败"
        rm -f "$tmp_config" "$dry_run_log"
        return 1
    fi
    rm -f "$dry_run_log"

    if ! shoes_reload_service_unit; then
        return 1
    fi

    shoes_run_service_action_checked "restart" "重启 shoes 服务失败"
}

shoes_get_release_json() {
    curl -fsSL "$SHOES_LATEST_API_URL"
}

shoes_extract_tag_name() {
    awk -F '"' '/"tag_name":/ {print $4; exit}'
}

shoes_extract_download_url() {
    local asset_name="$1"
    awk -F '"' '/browser_download_url/ {print $4}' | grep -F "/${asset_name}" | head -n1
}

shoes_normalize_version() {
    echo "${1#v}"
}

shoes_extract_version_from_text() {
    local text="$1"
    local version=""
    version="$(printf '%s\n' "$text" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?' | head -n1)"
    if [[ -n "$version" ]]; then
        shoes_normalize_version "$version"
        return 0
    fi
    return 1
}

shoes_get_current_installed_version() {
    local output version

    output="$("$SHOES_EXEC_PATH" --version 2>&1 || true)"
    if version="$(shoes_extract_version_from_text "$output")"; then
        printf '%s\n' "$version"
        return 0
    fi

    output="$("$SHOES_EXEC_PATH" -V 2>&1 || true)"
    if version="$(shoes_extract_version_from_text "$output")"; then
        printf '%s\n' "$version"
        return 0
    fi

    return 1
}

shoes_install_binary_from_release() {
    local asset_name release_json download_url temp_dir bin_path

    if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "amd64" ]]; then
        shoes_print_err "当前架构 $(uname -m) 不支持此预编译 shoes 二进制"
        return 1
    fi
    asset_name="$SHOES_RELEASE_ASSET_NAME"

    shoes_print_info "[*] 获取 shoes 最新版本..."
    release_json="$(shoes_get_release_json)" || {
        shoes_print_err "获取 release 信息失败"
        return 1
    }

    download_url="$(printf '%s\n' "$release_json" | shoes_extract_download_url "$asset_name")"
    if [[ -z "$download_url" ]]; then
        shoes_print_err "未找到匹配的下载资产: ${asset_name}"
        return 1
    fi

    temp_dir="$(mktemp -d)"
    shoes_print_info "[*] 下载 ${asset_name}..."
    if ! curl -fL "$download_url" -o "${temp_dir}/shoes.tar.gz"; then
        rm -rf "$temp_dir"
        shoes_print_err "下载失败"
        return 1
    fi

    if ! tar -xzf "${temp_dir}/shoes.tar.gz" -C "$temp_dir"; then
        rm -rf "$temp_dir"
        shoes_print_err "解压失败"
        return 1
    fi

    bin_path="$(find "$temp_dir" -type f -name shoes | head -n1)"
    if [[ -z "$bin_path" ]]; then
        rm -rf "$temp_dir"
        shoes_print_err "压缩包中未找到 shoes 可执行文件"
        return 1
    fi

    if ! install -m 755 "$bin_path" "$SHOES_EXEC_PATH"; then
        rm -rf "$temp_dir"
        shoes_print_err "安装 shoes 可执行文件失败"
        return 1
    fi
    rm -rf "$temp_dir"
    return 0
}

shoes_install_shoes() {
    clear
    shoes_require_commands || {
        shoes_pause_and_return
        return
    }

    if [[ -x "$SHOES_EXEC_PATH" ]]; then
        shoes_print_warn "已安装，请使用管理服务功能"
        shoes_pause_and_return
        return
    fi

    shoes_load_current_config
    mkdir -p "$SHOES_CONFIG_DIR"
    if ! shoes_install_binary_from_release; then
        shoes_pause_and_return
        return
    fi
    shoes_run_configuration_wizard

    if ! shoes_apply_configuration; then
        shoes_pause_and_return
        return
    fi

    shoes_print_ok "安装完成,服务已启动"
    shoes_pause_and_return
}

shoes_protocol_status() {
    if [[ "$1" == "y" ]]; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

shoes_print_modify_protocol_entry() {
    local index="$1"
    local protocol_key="$2"
    local enable_var
    enable_var="$(shoes_protocol_meta_value "$protocol_key" "enable_var")"
    echo -e "${GREEN}  ${index}.${PLAIN}$(printf '%-12s' "$(shoes_protocol_meta_value "$protocol_key" "menu_label")") [${YELLOW}$(shoes_protocol_status "${!enable_var}")${PLAIN}]"
}

shoes_commit_changes() {
    if shoes_apply_configuration; then
        shoes_print_ok "配置已更新"
        sleep 1
        return 0
    fi

    shoes_load_current_config
    shoes_print_warn "未完成配置应用，已重新从当前配置文件加载状态"
    shoes_pause_here
    return 1
}

shoes_disable_protocol() {
    local __var="$1"

    if [[ "$(shoes_protocol_count)" -le 1 ]]; then
        shoes_print_err "至少保留一个已启用协议"
        sleep 1
        return 1
    fi

    printf -v "$__var" '%s' "n"
    return 0
}

shoes_apply_address_update() {
    local var_name="$1"
    local current_value="${!var_name}"
    shoes_read_address_value "$var_name" "新端口(当前:$(shoes_bind_port_display "$current_value")): " "$current_value"
    shoes_commit_changes
}

shoes_apply_value_update() {
    local var_name="$1"
    local label="$2"
    local current_value="${!var_name}"
    shoes_read_value "$var_name" "${label}(当前:${current_value}): " "$current_value"
    shoes_commit_changes
}

shoes_apply_password_update() {
    local var_name="$1"
    shoes_read_password_or_random "$var_name" "新密码(回车随机): "
    shoes_commit_changes
}

shoes_apply_shadowsocks_password_update() {
    shoes_read_shadowsocks_password_or_random "SS_PASSWORD" "新密码(回车随机): " "$SS_CIPHER"
    shoes_commit_changes
}

shoes_apply_shadowsocks_cipher_update() {
    shoes_read_shadowsocks_cipher_value "SS_CIPHER"
    if ! shoes_validate_shadowsocks_2022_password "$SS_CIPHER" "$SS_PASSWORD"; then
        SS_PASSWORD="$(shoes_generate_shadowsocks_2022_password "$SS_CIPHER")" || SS_PASSWORD="$(shoes_random_pass)"
        shoes_print_ok "已按新加密重新生成密码: ${SS_PASSWORD}"
    fi
    shoes_commit_changes
}

shoes_apply_shadowsocks_shadowtls_toggle() {
    if [[ "$SS_SHADOWTLS_ENABLED" == "true" ]]; then
        SS_SHADOWTLS_ENABLED="false"
        shoes_commit_changes
        return
    fi

    SS_SHADOWTLS_ENABLED="true"
    shoes_select_cert "$SS_CERT" "$SS_KEY"
    SS_CERT="$cert_path"
    SS_KEY="$key_path"
    shoes_commit_changes
}

shoes_apply_shadowsocks_cert_update() {
    if [[ "$SS_SHADOWTLS_ENABLED" != "true" ]]; then
        shoes_print_warn "请先开启 STLS"
        sleep 1
        return 1
    fi

    shoes_apply_cert_update "SS_CERT" "SS_KEY"
}

shoes_apply_uuid_update() {
    local var_name="$1"
    shoes_read_uuid_or_random "$var_name" "新 UUID(回车随机): "
    shoes_commit_changes
}

shoes_apply_cert_update() {
    local cert_var="$1"
    local key_var="$2"

    shoes_select_cert "${!cert_var}" "${!key_var}"
    printf -v "$cert_var" '%s' "$cert_path"
    printf -v "$key_var" '%s' "$key_path"

    shoes_commit_changes
}

shoes_apply_boolean_toggle() {
    local var_name="$1"

    if [[ "${!var_name}" == "true" ]]; then
        printf -v "$var_name" '%s' "false"
    else
        printf -v "$var_name" '%s' "true"
    fi

    shoes_commit_changes
}

shoes_disable_protocol_with_confirmation() {
    local enable_var="$1"
    local label="$2"

    if shoes_ask_yes_no "确定禁用 ${label}" "n" && shoes_disable_protocol "$enable_var"; then
        shoes_commit_changes
        return 0
    fi

    return 1
}

shoes_prompt_enable_protocol() {
    local enable_var="$1"
    local configure_fn="$2"

    if shoes_ask_yes_no "是否启用" "n"; then
        printf -v "$enable_var" '%s' "y"
        "$configure_fn"
        shoes_commit_changes
        return 0
    fi

    return 1
}

shoes_show_service_and_config() {
    clear
    echo -e "${BLUE}Shoes 服务状态:${PLAIN}"
    systemctl --no-pager --full status "$SHOES_SERVICE_NAME" || true
    pause_enter "按回车查看配置..."
    clear
    echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
    if [[ -f "$SHOES_CONFIG_PATH" ]]; then
        cat "$SHOES_CONFIG_PATH"
    else
        shoes_print_err "配置文件不存在"
    fi
    echo -e "${BLUE}------------------------------------------------------${PLAIN}"
    shoes_pause_and_return
}

shoes_modify_config() {
    local opt protocol_key index modify_fn
    shoes_load_current_config

    while true; do
        clear
        echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
        index=1
        while IFS= read -r protocol_key; do
            shoes_print_modify_protocol_entry "$index" "$protocol_key"
            ((index++))
        done < <(shoes_protocol_keys)
        echo -e "${GREEN}  0.${PLAIN}Return"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            0) break ;;
            *)
                if [[ "$opt" =~ ^[1-9][0-9]*$ ]]; then
                    protocol_key="$(shoes_protocol_keys | sed -n "${opt}p")"
                    if [[ -n "$protocol_key" ]]; then
                        modify_fn="$(shoes_protocol_meta_value "$protocol_key" "modify_fn")"
                        "$modify_fn"
                    else
                        shoes_print_warn "无效选项"
                        sleep 1
                    fi
                else
                    shoes_print_warn "无效选项"
                    sleep 1
                fi
                ;;
        esac
    done
}

shoes_manage_service() {
    while true; do
        shoes_load_current_config
        clear
        echo -e "${BLUE}✦ Shoes_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            1) shoes_show_service_and_config ;;
            2) shoes_modify_config ;;
            3)
                if shoes_run_service_action_checked "stop" "停止 shoes 服务失败"; then
                    shoes_print_ok "已停止"
                fi
                shoes_pause_and_return
                ;;
            4)
                if shoes_run_service_action_checked "restart" "重启 shoes 服务失败"; then
                    shoes_print_ok "已重启"
                fi
                shoes_pause_and_return
                ;;
            0) break ;;
            *) shoes_print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

shoes_update_shoes() {
    local current_version latest_tag latest_version release_json backup_path

    clear
    shoes_require_commands || {
        shoes_pause_and_return
        return
    }
    shoes_load_current_config

    if [[ ! -x "$SHOES_EXEC_PATH" ]]; then
        shoes_print_err "未安装 shoes"
        shoes_pause_and_return
        return
    fi

    current_version="$(shoes_get_current_installed_version || true)"
    current_version="${current_version:-未知}"

    release_json="$(shoes_get_release_json)" || {
        shoes_print_err "获取 release 信息失败"
        shoes_pause_and_return
        return
    }
    latest_tag="$(printf '%s\n' "$release_json" | shoes_extract_tag_name)"
    latest_version="$(shoes_normalize_version "$latest_tag")"

    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}最新版本: ${YELLOW}${latest_version}${PLAIN}"

    if [[ "$(shoes_normalize_version "$current_version")" == "$latest_version" ]]; then
        shoes_print_ok "已是最新版本"
        shoes_pause_and_return
        return
    fi

    if ! shoes_ask_yes_no "是否更新" "n"; then
        return
    fi

    backup_path="$(mktemp "${TMPDIR:-/tmp}/shoes-backup.XXXXXX")" || {
        shoes_print_err "创建旧版本备份失败"
        shoes_pause_and_return
        return
    }
    if ! cp -f "$SHOES_EXEC_PATH" "$backup_path"; then
        rm -f "$backup_path"
        shoes_print_err "备份当前 shoes 内核失败"
        shoes_pause_and_return
        return
    fi

    systemctl stop "$SHOES_SERVICE_NAME" 2>/dev/null || true
    if shoes_install_binary_from_release; then
        if systemctl start "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
            rm -f "$backup_path"
            shoes_print_ok "更新完成"
        else
            if install -m 755 "$backup_path" "$SHOES_EXEC_PATH" && systemctl start "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
                shoes_print_warn "新版本启动失败，已回滚到旧版本"
            else
                shoes_print_err "新版本启动失败，回滚失败"
                service_failure_hint "$SHOES_SERVICE_NAME"
            fi
            rm -f "$backup_path"
        fi
    else
        install -m 755 "$backup_path" "$SHOES_EXEC_PATH" >/dev/null 2>&1 || true
        rm -f "$backup_path"
        if ! systemctl start "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
            shoes_print_err "更新失败，旧版本未能重新启动"
            service_failure_hint "$SHOES_SERVICE_NAME"
            shoes_pause_and_return
            return
        fi
        shoes_print_err "更新失败，已恢复旧版本"
    fi
    shoes_pause_and_return
}

shoes_delete_shoes() {
    clear
    if ! shoes_ask_yes_no "确定删除 shoes 服务和配置" "n"; then
        return
    fi

    systemctl stop "$SHOES_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SHOES_SERVICE_NAME" 2>/dev/null || true
    rm -f "$SHOES_SERVICE_FILE"
    rm -f "$SHOES_EXEC_PATH"
    rm -rf "$SHOES_CONFIG_DIR"
    systemctl daemon-reload
    shoes_print_ok "已删除"
    shoes_pause_and_return
}

shoes_menu() {
    while true; do
        clear
        echo -e "${BLUE}✦ Shoes_Ver.1.0 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

        case "$option" in
            1) shoes_install_shoes ;;
            2)
                if [[ ! -x "$SHOES_EXEC_PATH" ]]; then
                    shoes_print_err "未安装"
                    shoes_pause_and_return
                    continue
                fi
                shoes_manage_service
                ;;
            3) shoes_update_shoes ;;
            4) shoes_delete_shoes ;;
            0) return ;;
            *) shoes_print_warn "无效选项"; sleep 1 ;;
        esac
    done
}

MIHOMO_EXEC_PATH="/usr/local/bin/mihomo"
MIHOMO_CONFIG_DIR="/etc/mihomo"
MIHOMO_CONFIG_PATH="${MIHOMO_CONFIG_DIR}/config.yaml"
MIHOMO_SERVICE_NAME="mihomo"
MIHOMO_SERVICE_FILE="/etc/systemd/system/mihomo.service"
MIHOMO_ALPHA_TAG="Prerelease-Alpha"

mihomo_pause_and_return() {
    pause_enter_and_clear "按回车返回..."
}

mihomo_get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        *)
            echo -e "${RED}不支持${PLAIN}" >&2
            return 1
            ;;
    esac
}

mihomo_random_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12
}

mihomo_validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

mihomo_channel_label() {
    case "$1" in
        alpha) echo "测试版" ;;
        release) echo "正式版" ;;
        *) return 1 ;;
    esac
}

mihomo_get_current_version_label() {
    local version_line current_version
    version_line=$("$MIHOMO_EXEC_PATH" -v 2>/dev/null | head -1)
    current_version=$(echo "$version_line" | grep -oE 'alpha-[0-9a-f]+' | head -1)
    if [[ -n "$current_version" ]]; then
        echo "$current_version"
        return
    fi

    current_version=$(echo "$version_line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "${current_version:-未知}"
}

mihomo_select_asset_name() {
    local release_json="$1"
    local arch="$2"
    local channel="$3"
    local asset_names asset_pattern asset_name

    asset_names=$(echo "$release_json" | grep -oE '"name":[[:space:]]*"mihomo-linux-[^"]+\.gz"' | sed -E 's/^"name":[[:space:]]*"//; s/"$//')
    if [[ -z "$asset_names" ]]; then
        return 1
    fi

    case "$channel" in
        alpha)
            [[ "$arch" == "amd64" ]] || return 1
            asset_pattern='^mihomo-linux-amd64-v3-alpha-[0-9a-f]+\.gz$'
            ;;
        release)
            [[ "$arch" == "amd64" ]] || return 1
            asset_pattern='^mihomo-linux-amd64-v3-v[0-9]+\.[0-9]+\.[0-9]+\.gz$'
            ;;
        *)
            return 1
            ;;
    esac

    asset_name=$(echo "$asset_names" | grep -E "$asset_pattern" | head -1)
    [[ -n "$asset_name" ]] || return 1
    echo "$asset_name"
}

mihomo_get_download_info() {
    local arch="$1"
    local channel="$2"
    local release_path latest_version asset_name download_url api_url release_json asset_version display_version

    case "$channel" in
        alpha) release_path="releases/tags/${MIHOMO_ALPHA_TAG}" ;;
        release) release_path="releases/latest" ;;
        *)
            return 1
            ;;
    esac

    api_url="https://api.github.com/repos/MetaCubeX/mihomo/${release_path}"

    release_json=$(curl -fsSL "$api_url") || return 1
    latest_version=$(echo "$release_json" | grep '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/' | head -1)
    [[ -n "$latest_version" ]] || return 1

    asset_name=$(mihomo_select_asset_name "$release_json" "$arch" "$channel") || return 1
    download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${asset_name}"

    display_version="$latest_version"
    if [[ "$channel" == "alpha" ]]; then
        asset_version=$(echo "$asset_name" | grep -oE 'alpha-[0-9a-f]+' | tail -1)
        display_version="${MIHOMO_ALPHA_TAG} (${asset_version})"
    fi

    echo "${download_url}|${display_version}|${asset_name}"
}

mihomo_download_binary() {
    local download_url="$1"

    rm -f "/tmp/mihomo.gz" "/tmp/mihomo"

    if ! wget -O "/tmp/mihomo.gz" "$download_url"; then
        echo -e "${RED}下载失败${PLAIN}"
        rm -f "/tmp/mihomo.gz" "/tmp/mihomo"
        return 1
    fi

    if ! gunzip -f "/tmp/mihomo.gz"; then
        echo -e "${RED}解压失败${PLAIN}"
        rm -f "/tmp/mihomo.gz" "/tmp/mihomo"
        return 1
    fi

    if ! mv "/tmp/mihomo" "$MIHOMO_EXEC_PATH"; then
        echo -e "${RED}安装内核失败${PLAIN}"
        rm -f "/tmp/mihomo"
        return 1
    fi

    if ! chmod +x "$MIHOMO_EXEC_PATH"; then
        echo -e "${RED}设置执行权限失败${PLAIN}"
        return 1
    fi
}

mihomo_select_cert() {
    local cert_files opt i

    while true; do
        clear
        echo -e "${BLUE}证书配置${PLAIN}"
        
        cert_files=()
        if compgen -G "/etc/cert/*.crt" > /dev/null 2>&1; then
            mapfile -t cert_files < <(ls /etc/cert/*.crt 2>/dev/null | sort)
        fi
        
        for ((i=0; i<${#cert_files[@]}; i++)); do
            echo -e "${GREEN}$((i+1)).${PLAIN}$(basename "${cert_files[$i]}")"
        done
        echo -e "${GREEN}0.${PLAIN}自定义路径"
        
        read -r -p "$(echo -e "${BLUE}输入选项: ${PLAIN}")" opt
        
        if [[ "$opt" == "0" ]]; then
            read -r -p "$(echo -e "${BLUE}证书路径: ${PLAIN}")" mihomo_cert_path
            read -r -p "$(echo -e "${BLUE}私钥路径: ${PLAIN}")" mihomo_key_path
            if [[ -f "$mihomo_cert_path" && -f "$mihomo_key_path" ]]; then
                return 0
            else
                echo -e "${RED}路径无效${PLAIN}"
                sleep 1
            fi
        elif [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#cert_files[@]} )); then
            mihomo_cert_path="${cert_files[$((opt-1))]}"
            mihomo_key_path="${mihomo_cert_path%.crt}.key"
            if [[ -f "$mihomo_key_path" ]]; then
                return 0
            else
                echo -e "${RED}未找到私钥${PLAIN}"
                sleep 1
            fi
        else
            echo -e "${YELLOW}无效选项${PLAIN}"
            sleep 0.5
        fi
    done
}

mihomo_create_systemd_service() {
    cat > "$MIHOMO_SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon, A rule-based tunnel in Go.
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=SKIP_SAFE_PATH_CHECK=1
ExecStart=${MIHOMO_EXEC_PATH} -d ${MIHOMO_CONFIG_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$MIHOMO_SERVICE_FILE"
}

mihomo_reload_systemd() {
    if systemctl daemon-reload >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${RED}systemd 重新加载失败${PLAIN}"
    return 1
}

mihomo_show_service_failure() {
    service_failure_hint "$MIHOMO_SERVICE_NAME"
}

mihomo_systemctl_checked() {
    local action="$1"
    local success_msg="$2"
    local failure_msg="${3:-Mihomo 服务操作失败}"

    if systemctl "$action" "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        [[ -n "$success_msg" ]] && echo -e "${GREEN}${success_msg}${PLAIN}"
        return 0
    fi

    echo -e "${RED}${failure_msg}${PLAIN}"
    mihomo_show_service_failure
    return 1
}

mihomo_start_checked() {
    mihomo_systemctl_checked "start" "$1" "${2:-Mihomo 服务启动失败}"
}

mihomo_restart_checked() {
    mihomo_systemctl_checked "restart" "$1" "${2:-Mihomo 服务重启失败}"
}

mihomo_make_config_backup() {
    local backup
    backup="$(mktemp)" || return 1
    cp "$MIHOMO_CONFIG_PATH" "$backup" || {
        rm -f "$backup"
        return 1
    }
    printf '%s\n' "$backup"
}

mihomo_restart_with_rollback() {
    local backup="$1"
    local success_msg="$2"
    local failure_msg="${3:-新配置重启失败}"

    if systemctl restart "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg}${PLAIN}"
        return 0
    fi

    if cp "$backup" "$MIHOMO_CONFIG_PATH" && systemctl restart "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        echo -e "${YELLOW}${failure_msg},已回滚到上一份可用配置${PLAIN}"
        return 1
    fi

    rm -f "$backup"
    echo -e "${RED}${failure_msg},回滚后服务仍未启动${PLAIN}"
    mihomo_show_service_failure
    return 1
}

mihomo_generate_config() {
    cat > "$MIHOMO_CONFIG_PATH" <<EOF
tcp-concurrent: true
find-process-mode: off
allow-lan: false
mode: rule
log-level: silent
ipv6: true
dns:
  enable: true
  listen: :1053
  ipv6: false
  nameserver:
    - system
  enhanced-mode: redir-host
profile:
  store-selected: false
  store-fake-ip: false
listeners:
EOF

    if [[ "$enable_anytls" == "y" ]]; then
        cat >> "$MIHOMO_CONFIG_PATH" <<EOF
- name: anytls-in
  type: anytls
  port: ${anytls_port}
  listen: ::0
  users:
    username1: ${anytls_pass}
  certificate: ${anytls_cert}
  private-key: ${anytls_key}
  padding-scheme: |
   stop=8
   0=30-30
   1=100-400
   2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
   3=9-9,500-1000
   4=500-1000
   5=500-1000
   6=500-1000
   7=500-1000

EOF
    fi

    if [[ "$enable_trojan" == "y" ]]; then
        cat >> "$MIHOMO_CONFIG_PATH" <<EOF
- name: trojan-in
  type: trojan
  port: ${trojan_port}
  listen: ::0
  users:
    - username: 1
      password: ${trojan_pass}
  ws-path: "/"
  certificate: ${trojan_cert}
  private-key: ${trojan_key}

EOF
    fi
    
    if [[ "$enable_snell" == "y" ]]; then
        cat >> "$MIHOMO_CONFIG_PATH" <<EOF
- name: snellv5-in
  type: snell
  port: ${snell_port}
  listen: ::0
  psk: ${snell_pass}
  version: 5
  udp: true
EOF
        if [[ "$snell_obfs" == "y" ]]; then
            cat >> "$MIHOMO_CONFIG_PATH" <<EOF
  obfs-opts:
    mode: http
    host: ${snell_obfs_host}
EOF
        fi
        cat >> "$MIHOMO_CONFIG_PATH" <<EOF

EOF
    fi

    if [[ "$enable_tuic" == "y" ]]; then
        cat >> "$MIHOMO_CONFIG_PATH" <<EOF
- name: tuicv5-in
  type: tuic
  port: ${tuic_port}
  listen: ::0
  users:
    ${tuic_uuid}: ${tuic_pass}
  certificate: ${tuic_cert}
  private-key: ${tuic_key}
  congestion-controller: bbr
  max-idle-time: 80000
  authentication-timeout: 8000
  alpn:
    - h3
  max-udp-relay-packet-size: 1408

EOF
    fi

    if [[ "$enable_hy2" == "y" ]]; then
        cat >> "$MIHOMO_CONFIG_PATH" <<EOF
- name: hysteria2-in
  type: hysteria2
  port: ${hy2_port}
  listen: ::0
  users:
    user1: ${hy2_pass}
  masquerade: ""
  alpn:
  - h3
  certificate: ${hy2_cert}
  private-key: ${hy2_key}

EOF
    fi

    cat >> "$MIHOMO_CONFIG_PATH" <<EOF
rules:
  - MATCH,DIRECT
EOF
}

mihomo_install() {
    clear
    if [[ -f "$MIHOMO_EXEC_PATH" && -f "$MIHOMO_CONFIG_PATH" ]]; then
        echo -e "${YELLOW}已安装,请使用管理服务功能${PLAIN}"
        mihomo_pause_and_return
        return
    fi

    mkdir -p "$MIHOMO_CONFIG_DIR"

    clear
    echo -e "${BLUE}选择要启用的监听器:${PLAIN}"
    local enable_anytls enable_trojan enable_snell enable_tuic enable_hy2
    read -r -p "$(echo -e "${BLUE}启用 Anytls?   [y/N]: ${PLAIN}")" enable_anytls
    read -r -p "$(echo -e "${BLUE}启用 Trojan?   [y/N]: ${PLAIN}")" enable_trojan
    read -r -p "$(echo -e "${BLUE}启用 Snellv5?  [y/N]: ${PLAIN}")" enable_snell
    read -r -p "$(echo -e "${BLUE}启用 Tuicv5?   [y/N]: ${PLAIN}")" enable_tuic
    read -r -p "$(echo -e "${BLUE}启用 Hysteria? [y/N]: ${PLAIN}")" enable_hy2
    [[ "$enable_anytls" =~ ^[Yy]$ ]] && enable_anytls="y" || enable_anytls="n"
    [[ "$enable_trojan" =~ ^[Yy]$ ]] && enable_trojan="y" || enable_trojan="n"
    [[ "$enable_snell" =~ ^[Yy]$ ]] && enable_snell="y" || enable_snell="n"
    [[ "$enable_tuic" =~ ^[Yy]$ ]] && enable_tuic="y" || enable_tuic="n"
    [[ "$enable_hy2" =~ ^[Yy]$ ]] && enable_hy2="y" || enable_hy2="n"

    if [[ "$enable_anytls" != "y" && "$enable_trojan" != "y" && "$enable_tuic" != "y" && "$enable_hy2" != "y" && "$enable_snell" != "y" ]]; then
        echo -e "${RED}至少需要启用一个监听器,已取消安装${PLAIN}"
        mihomo_pause_and_return
        return
    fi

    local install_label ARCH result download_url target_version target_asset
    install_label=$(mihomo_channel_label "release")
    echo -e "${BLUE}[*] 下载 Mihomo ${install_label}...${PLAIN}"
    
    if ! ARCH=$(mihomo_get_arch); then
        mihomo_pause_and_return
        return
    fi
    if ! result=$(mihomo_get_download_info "$ARCH" "release"); then
        echo -e "${RED}获取 Mihomo ${install_label}失败${PLAIN}"
        mihomo_pause_and_return
        return
    fi
    IFS='|' read -r download_url target_version target_asset <<< "$result"
    
    if ! mihomo_download_binary "$download_url"; then
        mihomo_pause_and_return
        return
    fi

    echo -e "${GREEN}内核安装完成: ${target_version}${PLAIN}"
    local random_summary=""
    

    if [[ "$enable_anytls" == "y" ]]; then
        clear
        echo -e "${BLUE}===== AnyTLS 配置 =====${PLAIN}"
        local anytls_port anytls_pass anytls_cert anytls_key
        read -r -p "$(echo -e "${BLUE}端口(默认:8443): ${PLAIN}")" anytls_port
        anytls_port=${anytls_port:-8443}
        if ! mihomo_validate_port "$anytls_port"; then
            echo -e "${RED}AnyTLS 端口无效${PLAIN}"
            rm -f "$MIHOMO_EXEC_PATH"
            mihomo_pause_and_return
            return
        fi
        read -r -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" anytls_pass
        if [[ -z "$anytls_pass" ]]; then
            anytls_pass=$(mihomo_random_pass)
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="AnyTLS 密码: $anytls_pass"
        fi
        mihomo_select_cert
        anytls_cert="$mihomo_cert_path"
        anytls_key="$mihomo_key_path"
    fi
    
    if [[ "$enable_trojan" == "y" ]]; then
        clear
        echo -e "${BLUE}===== Trojan 配置 =====${PLAIN}"
        local trojan_port trojan_pass trojan_cert trojan_key
        read -r -p "$(echo -e "${BLUE}端口(默认:10819): ${PLAIN}")" trojan_port
        trojan_port=${trojan_port:-10819}
        if ! mihomo_validate_port "$trojan_port"; then
            echo -e "${RED}Trojan 端口无效${PLAIN}"
            rm -f "$MIHOMO_EXEC_PATH"
            mihomo_pause_and_return
            return
        fi
        read -r -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" trojan_pass
        if [[ -z "$trojan_pass" ]]; then
            trojan_pass=$(mihomo_random_pass)
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="Trojan 密码: $trojan_pass"
        fi
        mihomo_select_cert
        trojan_cert="$mihomo_cert_path"
        trojan_key="$mihomo_key_path"
    fi

    if [[ "$enable_snell" == "y" ]]; then
        clear
        echo -e "${BLUE}===== Snell v5 配置 =====${PLAIN}"
        local snell_port snell_pass snell_obfs snell_obfs_host
        read -r -p "$(echo -e "${BLUE}端口(默认:10815): ${PLAIN}")" snell_port
        snell_port=${snell_port:-10815}
        if ! mihomo_validate_port "$snell_port"; then
            echo -e "${RED}Snell v5 端口无效${PLAIN}"
            rm -f "$MIHOMO_EXEC_PATH"
            mihomo_pause_and_return
            return
        fi
        read -r -p "$(echo -e "${BLUE}PSK(回车随机): ${PLAIN}")" snell_pass
        if [[ -z "$snell_pass" ]]; then
            snell_pass=$(mihomo_random_pass)
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="Snellv5 PSK: $snell_pass"
        fi
        read -r -p "$(echo -e "${BLUE}启用 OBFS(http)? [y/N]: ${PLAIN}")" snell_obfs
        if [[ "$snell_obfs" == "y" || "$snell_obfs" == "Y" ]]; then
            snell_obfs="y"
            read -r -p "$(echo -e "${BLUE}OBFS Host(默认:icloud.com.cn): ${PLAIN}")" snell_obfs_host
            snell_obfs_host=${snell_obfs_host:-icloud.com.cn}
        else
            snell_obfs="n"
            snell_obfs_host="icloud.com.cn"
        fi
    fi

    if [[ "$enable_tuic" == "y" ]]; then
        clear
        echo -e "${BLUE}===== TUIC 配置 =====${PLAIN}"
        local tuic_port tuic_uuid tuic_pass tuic_cert tuic_key
        read -r -p "$(echo -e "${BLUE}端口(默认:28443): ${PLAIN}")" tuic_port
        tuic_port=${tuic_port:-28443}
        if ! mihomo_validate_port "$tuic_port"; then
            echo -e "${RED}TUIC 端口无效${PLAIN}"
            rm -f "$MIHOMO_EXEC_PATH"
            mihomo_pause_and_return
            return
        fi
        read -r -p "$(echo -e "${BLUE}UUID(回车随机): ${PLAIN}")" tuic_uuid
        if [[ -z "$tuic_uuid" ]]; then
            tuic_uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="TUIC UUID: $tuic_uuid"
        fi
        read -r -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" tuic_pass
        if [[ -z "$tuic_pass" ]]; then
            tuic_pass=$(mihomo_random_pass)
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="TUIC 密码: $tuic_pass"
        fi
        mihomo_select_cert
        tuic_cert="$mihomo_cert_path"
        tuic_key="$mihomo_key_path"
    fi

    if [[ "$enable_hy2" == "y" ]]; then
        clear
        echo -e "${BLUE}===== Hysteria2 配置 =====${PLAIN}"
        local hy2_port hy2_pass hy2_cert hy2_key
        read -r -p "$(echo -e "${BLUE}端口(默认:18443): ${PLAIN}")" hy2_port
        hy2_port=${hy2_port:-18443}
        if ! mihomo_validate_port "$hy2_port"; then
            echo -e "${RED}Hysteria2 端口无效${PLAIN}"
            rm -f "$MIHOMO_EXEC_PATH"
            mihomo_pause_and_return
            return
        fi
        read -r -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" hy2_pass
        if [[ -z "$hy2_pass" ]]; then
            hy2_pass=$(mihomo_random_pass)
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="Hysteria2 密码: $hy2_pass"
        fi
        mihomo_select_cert
        hy2_cert="$mihomo_cert_path"
        hy2_key="$mihomo_key_path"
    fi

    if [[ -n "$random_summary" ]]; then
        echo -e "${GREEN}随机凭据:${PLAIN}"
        echo -e "${GREEN}${random_summary}${PLAIN}"
    fi

    mihomo_generate_config
    mihomo_create_systemd_service

    if ! mihomo_reload_systemd; then
        mihomo_pause_and_return
        return
    fi
    if ! systemctl enable "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        echo -e "${RED}Mihomo 设置开机自启失败${PLAIN}"
        mihomo_pause_and_return
        return
    fi
    if ! mihomo_start_checked "" "Mihomo 服务启动失败"; then
        mihomo_pause_and_return
        return
    fi

    echo -e "${GREEN}安装完成,服务已启动${PLAIN}"
    mihomo_pause_and_return
}

mihomo_manage_service() {
    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

        case "$opt" in
            1)
                clear
                echo -e "${BLUE}Mihomo 服务状态:${PLAIN}"
                systemctl status --no-pager "$MIHOMO_SERVICE_NAME"
                pause_enter "按回车查看配置..."
                clear
                echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
                if [[ -f "$MIHOMO_CONFIG_PATH" ]]; then
                    cat "$MIHOMO_CONFIG_PATH"
                else
                    echo -e "${RED}配置文件不存在${PLAIN}"
                fi
                echo -e "${BLUE}------------------------------------------------------${PLAIN}"
                mihomo_pause_and_return
                ;;
            2)
                if [[ ! -f "$MIHOMO_CONFIG_PATH" ]]; then
                    echo -e "${RED}配置文件不存在${PLAIN}"
                    mihomo_pause_and_return
                    continue
                fi
                mihomo_modify_config
                ;;
            3)
                mihomo_systemctl_checked "stop" "已停止" "Mihomo 服务停止失败"
                mihomo_pause_and_return
                ;;
            4)
                mihomo_restart_checked "已重启" "Mihomo 服务重启失败"
                mihomo_pause_and_return
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

mihomo_modify_config() {
    while true; do
        local anytls_status="未启用"
        local trojan_status="未启用"
        local hy2_status="未启用"
        local tuic_status="未启用"
        local snell_status="未启用"
        grep -q "name: anytls-in" "$MIHOMO_CONFIG_PATH" && anytls_status="已启用"
        grep -q "name: trojan-in" "$MIHOMO_CONFIG_PATH" && trojan_status="已启用"
        grep -q "name: snellv5-in" "$MIHOMO_CONFIG_PATH" && snell_status="已启用"
        grep -q "name: tuicv5-in" "$MIHOMO_CONFIG_PATH" && tuic_status="已启用"
        grep -q "name: hysteria2-in" "$MIHOMO_CONFIG_PATH" && hy2_status="已启用"
        
        clear
        echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}Anytls  [${YELLOW}${anytls_status}${PLAIN}]"
        echo -e "${GREEN}  2.${PLAIN}Trojan  [${YELLOW}${trojan_status}${PLAIN}]"
        echo -e "${GREEN}  3.${PLAIN}Snellv5 [${YELLOW}${snell_status}${PLAIN}]"
        echo -e "${GREEN}  4.${PLAIN}Tuicv5  [${YELLOW}${tuic_status}${PLAIN}]"
        echo -e "${GREEN}  5.${PLAIN}Hysteria[${YELLOW}${hy2_status}${PLAIN}]"
        echo -e "${GREEN}  0.${PLAIN}Return"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt
        
        case "$opt" in
            1) mihomo_toggle_or_modify_listener "anytls-in" "AnyTLS" "8443" ;;
            2) mihomo_toggle_or_modify_listener "trojan-in" "Trojan" "10819" ;;
            3) mihomo_toggle_or_modify_listener "snellv5-in" "Snellv5" "10815" ;;
            4) mihomo_toggle_or_modify_listener "tuicv5-in" "TUIC" "28443" ;;
            5) mihomo_toggle_or_modify_listener "hysteria2-in" "Hysteria2" "18443" ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

mihomo_toggle_or_modify_listener() {
    local name="$1"
    local display_name="$2"
    local default_port="$3"
    
    while true; do
        local is_enabled="n"
        grep -q "name: $name" "$MIHOMO_CONFIG_PATH" && is_enabled="y"
        
        clear
        echo -e "${BLUE}✦ ${display_name}_Conf ✦${PLAIN}"
        if [[ "$is_enabled" == "y" ]]; then
            if [[ "$name" == "snellv5-in" ]]; then
                echo -e "${GREEN}  1.${PLAIN}修改端口"
                echo -e "${GREEN}  2.${PLAIN}修改PSK"
                echo -e "${GREEN}  3.${PLAIN}切换OBFS"
                echo -e "${GREEN}  4.${PLAIN}禁用服务"
                echo -e "${GREEN}  0.${PLAIN}返回上级"
                read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

                case "$opt" in
                    1) mihomo_modify_listener_port "$name" ;;
                    2) mihomo_modify_listener_pass "$name" ;;
                    3) mihomo_toggle_snell_obfs ;;
                    4) mihomo_disable_listener "$name" "$display_name"; break ;;
                    0) break ;;
                    *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
                esac
            else
                echo -e "${GREEN}  1.${PLAIN}修改端口"
                echo -e "${GREEN}  2.${PLAIN}修改密码"
                echo -e "${GREEN}  3.${PLAIN}修改证书"
                echo -e "${GREEN}  4.${PLAIN}禁用服务"
                echo -e "${GREEN}  0.${PLAIN}返回上级"
                read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt
                
                case "$opt" in
                    1) mihomo_modify_listener_port "$name" ;;
                    2) mihomo_modify_listener_pass "$name" ;;
                    3) mihomo_modify_listener_cert "$name" ;;
                    4) mihomo_disable_listener "$name" "$display_name"; break ;;
                    0) break ;;
                    *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
                esac
            fi
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            read -r -p "$(echo -e "${BLUE}是否启用? [y/N]: ${PLAIN}")" enable
            if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
                mihomo_add_listener "$name" "$display_name" "$default_port"
            else
                break
            fi
        fi
    done
}

mihomo_add_listener() {
    local name="$1"
    local display_name="$2"
    local default_port="$3"
    
    clear
    echo -e "${BLUE}===== 添加 ${display_name} =====${PLAIN}"
    read -r -p "$(echo -e "${BLUE}端口(默认:${default_port}): ${PLAIN}")" port
    port=${port:-$default_port}
    if ! mihomo_validate_port "$port"; then
        echo -e "${RED}端口无效${PLAIN}"
        sleep 1
        return 1
    fi
    
    local uuid="" uuid_random="n" pass_random="n" snell_obfs="n" snell_obfs_host="icloud.com.cn"
    if [[ "$name" == "tuicv5-in" ]]; then
        read -r -p "$(echo -e "${BLUE}UUID(回车随机): ${PLAIN}")" uuid
        if [[ -z "$uuid" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid)
            uuid_random="y"
        fi
    fi
    
    if [[ "$name" == "snellv5-in" ]]; then
        read -r -p "$(echo -e "${BLUE}PSK(回车随机): ${PLAIN}")" pass
    else
        read -r -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" pass
    fi
    if [[ -z "$pass" ]]; then
        pass=$(mihomo_random_pass)
        pass_random="y"
    fi

    if [[ "$name" == "snellv5-in" ]]; then
        read -r -p "$(echo -e "${BLUE}启用 OBFS(http)? [y/N]: ${PLAIN}")" snell_obfs
        if [[ "$snell_obfs" == "y" || "$snell_obfs" == "Y" ]]; then
            snell_obfs="y"
            read -r -p "$(echo -e "${BLUE}OBFS Host(默认:icloud.com.cn): ${PLAIN}")" snell_obfs_host
            snell_obfs_host=${snell_obfs_host:-icloud.com.cn}
        else
            snell_obfs="n"
            snell_obfs_host="icloud.com.cn"
        fi
    fi
    
    if [[ "$name" != "snellv5-in" ]]; then
        mihomo_select_cert
        [[ "$uuid_random" == "y" ]] && echo -e "${GREEN}UUID: $uuid${PLAIN}"
        [[ "$pass_random" == "y" ]] && echo -e "${GREEN}密码: $pass${PLAIN}"
    else
        [[ "$pass_random" == "y" ]] && echo -e "${GREEN}PSK: $pass${PLAIN}"
    fi
    
    local tmp_config backup
    tmp_config=$(mktemp) || {
        echo -e "${RED}创建临时配置失败${PLAIN}"
        sleep 1
        return 1
    }
    backup=$(mihomo_make_config_backup) || {
        echo -e "${RED}备份配置失败${PLAIN}"
        rm -f "$tmp_config"
        sleep 1
        return 1
    }
    case "$name" in
        anytls-in)
            cat > "$tmp_config" <<LISTENER
- name: anytls-in
  type: anytls
  port: ${port}
  listen: ::0
  users:
    username1: ${pass}
  certificate: ${mihomo_cert_path}
  private-key: ${mihomo_key_path}
  padding-scheme: |
   stop=8
   0=30-30
   1=100-400
   2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
   3=9-9,500-1000
   4=500-1000
   5=500-1000
   6=500-1000
   7=500-1000

LISTENER
            ;;
        trojan-in)
            cat > "$tmp_config" <<LISTENER
- name: trojan-in
  type: trojan
  port: ${port}
  listen: ::0
  users:
    - username: 1
      password: ${pass}
  ws-path: "/"
  certificate: ${mihomo_cert_path}
  private-key: ${mihomo_key_path}

LISTENER
            ;;
        snellv5-in)
            cat > "$tmp_config" <<LISTENER
- name: snellv5-in
  type: snell
  port: ${port}
  listen: ::0
  psk: ${pass}
  version: 5
  udp: true
LISTENER
            if [[ "$snell_obfs" == "y" ]]; then
                cat >> "$tmp_config" <<LISTENER
  obfs-opts:
    mode: http
    host: ${snell_obfs_host}
LISTENER
            fi
            cat >> "$tmp_config" <<LISTENER

LISTENER
            ;;
        tuicv5-in)
            cat > "$tmp_config" <<LISTENER
- name: tuicv5-in
  type: tuic
  port: ${port}
  listen: ::0
  users:
    ${uuid}: ${pass}
  certificate: ${mihomo_cert_path}
  private-key: ${mihomo_key_path}
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 3000
  alpn:
    - h3
  max-udp-relay-packet-size: 1408

LISTENER
            ;;
        hysteria2-in)
            cat > "$tmp_config" <<LISTENER
- name: hysteria2-in
  type: hysteria2
  port: ${port}
  listen: ::0
  users:
    user1: ${pass}
  masquerade: ""
  alpn:
  - h3
  certificate: ${mihomo_cert_path}
  private-key: ${mihomo_key_path}

LISTENER
            ;;
    esac
    
    awk -v tmpfile="$tmp_config" '
        BEGIN {inserted=0}
        /^rules:/ && !inserted {
            while ((getline line < tmpfile) > 0) print line
            close(tmpfile)
            inserted=1
        }
        {print}
        END {
            if (!inserted) {
                while ((getline line < tmpfile) > 0) print line
                close(tmpfile)
            }
        }
    ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
        echo -e "${RED}配置写入失败${PLAIN}"
        rm -f "$tmp_config" "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
        sleep 1
        return 1
    }

    rm -f "$tmp_config"

    mihomo_restart_with_rollback "$backup" "${display_name} 已启用" "${display_name} 已写入,但服务重启失败"
    sleep 1
}

mihomo_snell_obfs_enabled() {
    awk '
        /^- name: /{block=($0 ~ "snellv5-in")}
        block && /^  obfs-opts:/{found=1}
        END {exit found ? 0 : 1}
    ' "$MIHOMO_CONFIG_PATH"
}

mihomo_toggle_snell_obfs() {
    local backup host

    if mihomo_snell_obfs_enabled; then
        echo -e "${BLUE}当前OBFS: 开启${PLAIN}"
        read -r -p "$(echo -e "${RED}确定关闭 Snell OBFS? [y/N]: ${PLAIN}")" confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            return
        fi

        backup=$(mihomo_make_config_backup) || {
            echo -e "${RED}备份配置失败${PLAIN}"
            sleep 1
            return 1
        }
        awk '
            /^- name: /{block=($0 ~ "snellv5-in"); skip=0}
            block && /^  obfs-opts:/{skip=1; next}
            block && skip && /^    /{next}
            {skip=0; print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
            echo -e "${RED}配置写入失败${PLAIN}"
            rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
            sleep 1
            return 1
        }

        mihomo_restart_with_rollback "$backup" "OBFS 已关闭" "OBFS 已移除,但服务重启失败"
        sleep 1
        return
    fi

    echo -e "${BLUE}当前OBFS: 关闭${PLAIN}"
    read -r -p "$(echo -e "${BLUE}OBFS Host(默认:icloud.com.cn): ${PLAIN}")" host
    host=${host:-icloud.com.cn}

    backup=$(mihomo_make_config_backup) || {
        echo -e "${RED}备份配置失败${PLAIN}"
        sleep 1
        return 1
    }
    awk -v host="$host" '
        /^- name: /{block=($0 ~ "snellv5-in")}
        {print}
        block && /^  udp:/ && !inserted {
            print "  obfs-opts:"
            print "    mode: http"
            print "    host: " host
            inserted=1
        }
    ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
        echo -e "${RED}配置写入失败${PLAIN}"
        rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
        sleep 1
        return 1
    }

    mihomo_restart_with_rollback "$backup" "OBFS 已开启" "OBFS 已写入,但服务重启失败"
    sleep 1
}

mihomo_disable_listener() {
    local name="$1"
    local display_name="$2"
    
    read -r -p "$(echo -e "${RED}确定禁用 ${display_name}? [y/N]: ${PLAIN}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        local backup
        backup=$(mihomo_make_config_backup) || {
            echo -e "${RED}备份配置失败${PLAIN}"
            sleep 1
            return 1
        }
        awk -v name="$name" '
            BEGIN {skip=0}
            /^- name: /{
                if ($0 ~ name) {skip=1; next}
                else {skip=0}
            }
            skip && /^- name: /{skip=0}
            skip && /^rules:/{skip=0; print; next}
            skip && /^[^ -]/{skip=0}
            !skip {print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
            echo -e "${RED}配置写入失败${PLAIN}"
            rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
            sleep 1
            return 1
        }

        mihomo_restart_with_rollback "$backup" "${display_name} 已禁用" "${display_name} 已移除,但服务重启失败"
    fi
    sleep 1
}

mihomo_modify_listener_port() {
    local name="$1"
    read -r -p "$(echo -e "${BLUE}新端口: ${PLAIN}")" new_port
    if mihomo_validate_port "$new_port"; then
        local backup
        backup=$(mihomo_make_config_backup) || {
            echo -e "${RED}备份配置失败${PLAIN}"
            sleep 1
            return 1
        }
        awk -v name="$name" -v port="$new_port" '
            /^- name: /{found=($0 ~ name)}
            found && /^  port:/{$0="  port: "port; found=0}
            {print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
            echo -e "${RED}配置写入失败${PLAIN}"
            rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
            sleep 1
            return 1
        }
        mihomo_restart_with_rollback "$backup" "已更新" "端口已写入,但服务重启失败"
    else
        echo -e "${RED}端口无效${PLAIN}"
    fi
    sleep 1
}

mihomo_modify_listener_pass() {
    local name="$1"
    local prompt_label="新密码"
    local failure_msg="密码已写入,但服务重启失败"
    if [[ "$name" == "snellv5-in" ]]; then
        prompt_label="新PSK"
        failure_msg="PSK已写入,但服务重启失败"
    fi

    read -r -p "$(echo -e "${BLUE}${prompt_label}: ${PLAIN}")" new_pass
    if [[ -n "$new_pass" ]]; then
        local backup
        backup=$(mihomo_make_config_backup) || {
            echo -e "${RED}备份配置失败${PLAIN}"
            sleep 1
            return 1
        }
        case "$name" in
            anytls-in)
                awk -v pass="$new_pass" '
                    /^- name: anytls-in/{found=1}
                    found && /username1:/{$0="    username1: "pass; found=0}
                    {print}
                ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
                    echo -e "${RED}配置写入失败${PLAIN}"
                    rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
                    sleep 1
                    return 1
                }
                ;;
            trojan-in)
                awk -v pass="$new_pass" '
                    /^- name: trojan-in/{found=1}
                    found && /password:/{$0="      password: "pass; found=0}
                    {print}
                ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
                    echo -e "${RED}配置写入失败${PLAIN}"
                    rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
                    sleep 1
                    return 1
                }
                ;;
            hysteria2-in)
                awk -v pass="$new_pass" '
                    /^- name: hysteria2-in/{found=1}
                    found && /user1:/{$0="    user1: "pass; found=0}
                    {print}
                ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
                    echo -e "${RED}配置写入失败${PLAIN}"
                    rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
                    sleep 1
                    return 1
                }
                ;;
            tuicv5-in)
                awk -v pass="$new_pass" '
                    /^- name: tuicv5-in/{found=1}
                    found && /^    [a-f0-9-]+:/{
                        split($0, arr, ":")
                        uuid = arr[1]
                        gsub(/^[[:space:]]+/, "", uuid)
                        $0 = "    " uuid ": " pass
                        found=0
                    }
                    {print}
                ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
                    echo -e "${RED}配置写入失败${PLAIN}"
                    rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
                    sleep 1
                    return 1
                }            
                ;;
            snellv5-in)
                awk -v pass="$new_pass" '
                    /^- name: snellv5-in/{found=1}
                    found && /^  psk:/{$0="  psk: "pass; found=0}
                    {print}
                ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
                    echo -e "${RED}配置写入失败${PLAIN}"
                    rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
                    sleep 1
                    return 1
                }
                ;;
        esac
        mihomo_restart_with_rollback "$backup" "已更新" "$failure_msg"
    fi
    sleep 1
}

mihomo_modify_listener_cert() {
    local name="$1"
    mihomo_select_cert
    local backup
    backup=$(mihomo_make_config_backup) || {
        echo -e "${RED}备份配置失败${PLAIN}"
        sleep 1
        return 1
    }
    awk -v name="$name" -v cert="$mihomo_cert_path" -v key="$mihomo_key_path" '
        /^- name: /{block=($0 ~ name)}
        block && /certificate:/{$0="  certificate: "cert}
        block && /private-key:/{$0="  private-key: "key; block=0}
        {print}
    ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" && mv "${MIHOMO_CONFIG_PATH}.tmp" "$MIHOMO_CONFIG_PATH" || {
        echo -e "${RED}配置写入失败${PLAIN}"
        rm -f "${MIHOMO_CONFIG_PATH}.tmp" "$backup"
        sleep 1
        return 1
    }
    mihomo_restart_with_rollback "$backup" "已更新" "证书已写入,但服务重启失败"
    sleep 1
}

mihomo_update_channel() {
    local channel="$1"
    local channel_label current_version ARCH result download_url target_version target_asset confirm backup_exec

    clear
    if [ ! -f "$MIHOMO_EXEC_PATH" ]; then
        echo -e "${RED}未安装${PLAIN}"
        mihomo_pause_and_return
        return
    fi

    channel_label=$(mihomo_channel_label "$channel")
    current_version=$(mihomo_get_current_version_label)
    
    if ! ARCH=$(mihomo_get_arch); then
        mihomo_pause_and_return
        return
    fi
    if ! result=$(mihomo_get_download_info "$ARCH" "$channel"); then
        echo -e "${RED}获取 Mihomo ${channel_label}失败${PLAIN}"
        mihomo_pause_and_return
        return
    fi
    IFS='|' read -r download_url target_version target_asset <<< "$result"
    
    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}目标版本: ${YELLOW}${target_version}${PLAIN}"
    echo -e "${BLUE}目标文件: ${YELLOW}${target_asset}${PLAIN}"
    
    if [[ "$channel" == "release" && "$current_version" == "$target_version" ]]; then
        echo -e "${GREEN}已是最新版本${PLAIN}"
        mihomo_pause_and_return
        return
    fi

    read -r -p "$(echo -e "${BLUE}是否更新到 Mihomo ${channel_label}? [y/N]: ${PLAIN}")" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    echo -e "${BLUE}[*] 更新 Mihomo ${channel_label}中...${PLAIN}"
    backup_exec="$(mktemp)" || {
        echo -e "${RED}创建内核备份失败${PLAIN}"
        mihomo_pause_and_return
        return
    }
    if ! cp "$MIHOMO_EXEC_PATH" "$backup_exec"; then
        rm -f "$backup_exec"
        echo -e "${RED}备份当前内核失败${PLAIN}"
        mihomo_pause_and_return
        return
    fi
    systemctl stop "$MIHOMO_SERVICE_NAME" 2>/dev/null || true

    if ! mihomo_download_binary "$download_url"; then
        install -m 755 "$backup_exec" "$MIHOMO_EXEC_PATH" 2>/dev/null || true
        rm -f "$backup_exec"
        if systemctl start "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
            echo -e "${RED}更新失败,已恢复旧版本${PLAIN}"
        else
            echo -e "${RED}更新失败,旧版本也未能重新启动${PLAIN}"
            mihomo_show_service_failure
        fi
        mihomo_pause_and_return
        return
    fi

    if systemctl start "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup_exec"
        echo -e "${GREEN}更新完成: ${target_version}${PLAIN}"
    else
        if install -m 755 "$backup_exec" "$MIHOMO_EXEC_PATH" && systemctl start "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
            rm -f "$backup_exec"
            echo -e "${YELLOW}新版本启动失败,已回滚旧版本${PLAIN}"
        else
            rm -f "$backup_exec"
            echo -e "${RED}新版本启动失败,回滚后仍未启动${PLAIN}"
            mihomo_show_service_failure
        fi
    fi
    mihomo_pause_and_return
}

mihomo_update() {
    local option

    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Update ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}更新测试版"
        echo -e "${GREEN}  2.${PLAIN}更新正式版"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

        case "$option" in
            1) mihomo_update_channel "alpha" ;;
            2) mihomo_update_channel "release" ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

mihomo_delete() {
    clear
    read -r -p "$(echo -e "${RED}确定删除? [y/N]: ${PLAIN}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop "$MIHOMO_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$MIHOMO_SERVICE_NAME" 2>/dev/null || true
        rm -f "$MIHOMO_SERVICE_FILE" "$MIHOMO_EXEC_PATH"
        rm -rf "$MIHOMO_CONFIG_DIR"
        mihomo_reload_systemd || true
        echo -e "${GREEN}已删除${PLAIN}"
    fi
    mihomo_pause_and_return
}

mihomo_menu() {
    local option

    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Ver.1.6 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

        case "$option" in
            1) mihomo_install ;;
            2)
                if [[ ! -f "$MIHOMO_EXEC_PATH" ]]; then
                    echo -e "${RED}未安装${PLAIN}"
                    mihomo_pause_and_return
                    continue
                fi
                mihomo_manage_service
                ;;
            3) mihomo_update ;;
            4) mihomo_delete ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

wireproxy_info()  { log_prefixed "$CYAN" "[INFO]" "$*"; }
wireproxy_ok()    { log_prefixed "$GREEN" "[ OK ]" "$*"; }
wireproxy_warn()  { log_prefixed "$YELLOW" "[WARN]" "$*"; }
wireproxy_err()   { log_prefixed "$RED" "[ERROR]" "$*"; exit 1; }

WIREPROXY_BIN="/usr/local/bin/wireproxy"
WIREPROXY_CONF_DIR="/etc/wireproxy"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
WIREPROXY_WG_WARP_CONF="/etc/wireproxy/wgcf-warp.conf"
WIREPROXY_SERVICE_NAME="wireproxy-warp"
WIREPROXY_SERVICE_FILE="/etc/systemd/system/${WIREPROXY_SERVICE_NAME}.service"

WIREPROXY_WGCF_REPO="ViRb3/wgcf"
WIREPROXY_BASE_URL="https://cdn-wireproxy.pages.dev/windtf/wireproxy"

WIREPROXY_WGCF_PATH="/usr/local/bin/wgcf"
WIREPROXY_WGCF_TMP=""
WIREPROXY_ARCH=""
WIREPROXY_WGCF_ARCH=""
WIREPROXY_NET_MODE=""

WIREPROXY_DEFAULT_SOCKS_BIND="127.0.0.1:40000"
WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
WIREPROXY_SOCKS_USER=""
WIREPROXY_SOCKS_PASS=""

wireproxy_check_root() { [[ $EUID -ne 0 ]] && wireproxy_err "请使用 root 用户运行此脚本"; }

wireproxy_require_apt() {
    command -v apt-get >/dev/null 2>&1 || wireproxy_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
}

wireproxy_check_dependencies() {
    local cmd
    wireproxy_require_apt
    for cmd in curl tar systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || wireproxy_err "缺少依赖: $cmd"
    done
}

wireproxy_ensure_wireguard_tools() {
    command -v wg >/dev/null 2>&1 && return 0

    wireproxy_info "安装 wireguard-tools ..."
    apt-get update -qq || wireproxy_err "apt update 失败"
    apt-get install -y -qq --no-install-recommends wireguard-tools || wireproxy_err "wireguard-tools 安装失败"
    command -v wg >/dev/null 2>&1 || wireproxy_err "wireguard-tools 安装后仍未检测到 wg 命令"
}

wireproxy_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            WIREPROXY_ARCH="amd64"
            WIREPROXY_WGCF_ARCH="amd64"
            ;;
        *)
            wireproxy_err "不支持的架构: $(uname -m)"
            ;;
    esac
}

wireproxy_detect_network() {
    local has_v4=false has_v6=false

    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show scope global 2>/dev/null | grep -q inet &&
            curl -4 --connect-timeout 3 --max-time 5 -s http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
            has_v4=true
        ip -6 addr show scope global 2>/dev/null | grep -q inet6 &&
            curl -6 -g --connect-timeout 3 --max-time 5 -s "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
            has_v6=true
    else
        curl -4 --connect-timeout 3 --max-time 5 -s http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
            has_v4=true
        curl -6 -g --connect-timeout 3 --max-time 5 -s "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
            has_v6=true
    fi

    if $has_v4 && $has_v6; then
        WIREPROXY_NET_MODE="dual"
    elif $has_v6; then
        WIREPROXY_NET_MODE="v6_only"
    elif $has_v4; then
        WIREPROXY_NET_MODE="v4_only"
    else
        WIREPROXY_NET_MODE="none"
    fi
}

wireproxy_latest_release_tag() {
    local repo="$1"
    curl --connect-timeout 5 --max-time 20 -fsSI "https://github.com/${repo}/releases/latest" \
        | awk 'tolower($1)=="location:" {print $2}' \
        | tail -n1 \
        | tr -d '\r' \
        | awk -F/ '{print $NF}'
}

wireproxy_download_binary() {
    local version asset url tmpdir bin_path

    if [[ -x "$WIREPROXY_BIN" ]]; then
        wireproxy_ok "wireproxy 已安装"
        return 0
    fi

    wireproxy_detect_arch
    wireproxy_info "获取 wireproxy 最新版本 ..."
    version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${WIREPROXY_BASE_URL}/releases/latest" \
        | grep -oE '/releases/tag/v[0-9.]+' \
        | sed 's#.*/##' \
        | head -n1)"
    [[ -n "$version" ]] || wireproxy_err "无法获取 wireproxy 最新版本"

    asset="wireproxy_linux_${WIREPROXY_ARCH}.tar.gz"
    url="${WIREPROXY_BASE_URL}/releases/download/${version}/${asset}"
    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"

    wireproxy_info "下载 wireproxy ${version} ..."
    if ! curl --connect-timeout 5 --max-time 120 -fL "$url" -o "${tmpdir}/wireproxy.tar.gz"; then
        rm -rf "$tmpdir"
        wireproxy_err "wireproxy 下载失败"
    fi

    tar -xzf "${tmpdir}/wireproxy.tar.gz" -C "$tmpdir" || {
        rm -rf "$tmpdir"
        wireproxy_err "wireproxy 解压失败"
    }

    bin_path="$(find "$tmpdir" -type f -name wireproxy | head -n1)"
    [[ -n "$bin_path" ]] || {
        rm -rf "$tmpdir"
        wireproxy_err "压缩包中未找到 wireproxy 可执行文件"
    }

    if ! install -m 755 "$bin_path" "$WIREPROXY_BIN"; then
        rm -rf "$tmpdir"
        wireproxy_err "安装 wireproxy 可执行文件失败"
    fi
    rm -rf "$tmpdir"
    wireproxy_ok "wireproxy 已安装到 ${WIREPROXY_BIN}"
}

wireproxy_ensure_wgcf() {
    local version url tmpdir wgcf_base_url

    if [[ -x "$WIREPROXY_WGCF_PATH" ]]; then
        return 0
    fi

    wireproxy_detect_arch
    wireproxy_detect_network
    wgcf_base_url="https://github.com/${WIREPROXY_WGCF_REPO}"
    wireproxy_info "获取 wgcf 最新版本 ..."
    if [[ "$WIREPROXY_NET_MODE" == "v6_only" ]]; then
        wgcf_base_url="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
        wireproxy_info "检测到纯 IPv6，wgcf 下载改用镜像: $wgcf_base_url"
        version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${wgcf_base_url}/releases/latest" \
            | grep -oE '/releases/tag/v[0-9.]+' \
            | sed 's#.*/##' \
            | head -n1)"
    else
        version="$(wireproxy_latest_release_tag "$WIREPROXY_WGCF_REPO")"
    fi
    [[ -n "$version" ]] || wireproxy_err "无法获取 wgcf 最新版本"

    url="${wgcf_base_url}/releases/download/${version}/wgcf_${version#v}_linux_${WIREPROXY_WGCF_ARCH}"
    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"
    WIREPROXY_WGCF_TMP="${tmpdir}/wgcf"

    wireproxy_info "下载 wgcf ${version} ..."
    if ! curl --connect-timeout 5 --max-time 120 -fL "$url" -o "$WIREPROXY_WGCF_TMP"; then
        rm -rf "$tmpdir"
        WIREPROXY_WGCF_TMP=""
        wireproxy_err "wgcf 下载失败"
    fi

    chmod +x "$WIREPROXY_WGCF_TMP"
    WIREPROXY_WGCF_PATH="$WIREPROXY_WGCF_TMP"
    wireproxy_ok "wgcf 已临时就绪"
}

wireproxy_cleanup_wgcf() {
    if [[ -n "$WIREPROXY_WGCF_TMP" ]]; then
        rm -rf "$(dirname "$WIREPROXY_WGCF_TMP")"
        WIREPROXY_WGCF_TMP=""
        WIREPROXY_WGCF_PATH="/usr/local/bin/wgcf"
    fi
}

wireproxy_is_valid_host_port() {
    local value="$1" port host
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    else
        return 1
    fi
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

wireproxy_escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

wireproxy_extract_ini_value() {
    local file="$1" section="$2" key="$3"
    awk -F' = ' -v section="$section" -v key="$key" '
        $0 == "[" section "]" { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $1 == key { print $2; exit }
    ' "$file"
}

wireproxy_endpoint_host() {
    local value="$1"
    if [[ "$value" =~ ^\[([0-9a-fA-F:]+)\]:[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]+):[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$value"
    fi
}

wireproxy_endpoint_port() {
    local value="$1"
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[^:]+:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

wireproxy_is_ipv4_literal() {
    local host="$1"
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

wireproxy_is_ipv6_literal() {
    local host="$1"
    [[ "$host" == *:* ]]
}

wireproxy_resolve_host_by_family() {
    local host="$1" family="$2"
    command -v getent >/dev/null 2>&1 || wireproxy_err "缺少 getent，无法解析 Endpoint"
    case "$family" in
        4) getent ahostsv4 "$host" | awk 'NR==1 { print $1; exit }' ;;
        6) getent ahostsv6 "$host" | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ { print $1; exit }' ;;
        *) return 1 ;;
    esac
}

wireproxy_select_endpoint_for_network() {
    local current="$1" preferred_v4="$2" preferred_v6="$3" preferred_port="$4"
    local host port resolved

    [[ -n "$WIREPROXY_NET_MODE" ]] || wireproxy_detect_network
    port="${preferred_port:-$(wireproxy_endpoint_port "$current")}"
    [[ -z "$port" ]] && port="2408"

    case "$WIREPROXY_NET_MODE" in
        v6_only)
            if [[ -n "$preferred_v6" ]]; then
                printf '[%s]:%s\n' "$preferred_v6" "$port"
                return 0
            fi
            host="$(wireproxy_endpoint_host "$current")"
            [[ -n "$host" ]] || wireproxy_err "无法确定 IPv6 Endpoint"
            if wireproxy_is_ipv6_literal "$host" && ! wireproxy_is_ipv4_literal "$host"; then
                printf '[%s]:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(wireproxy_resolve_host_by_family "$host" 6)"
            [[ -n "$resolved" ]] || wireproxy_err "无法解析 IPv6 Endpoint: $host"
            printf '[%s]:%s\n' "$resolved" "$port"
            ;;
        dual|v4_only)
            if [[ -n "$preferred_v4" ]]; then
                printf '%s:%s\n' "$preferred_v4" "$port"
                return 0
            fi
            host="$(wireproxy_endpoint_host "$current")"
            [[ -n "$host" ]] || wireproxy_err "无法确定 IPv4 Endpoint"
            if wireproxy_is_ipv4_literal "$host"; then
                printf '%s:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(wireproxy_resolve_host_by_family "$host" 4)"
            [[ -n "$resolved" ]] || wireproxy_err "无法解析 IPv4 Endpoint: $host"
            printf '%s:%s\n' "$resolved" "$port"
            ;;
        none)
            wireproxy_err "当前服务器无可用网络，无法确定 Endpoint"
            ;;
        *)
            wireproxy_err "未知网络模式: $WIREPROXY_NET_MODE"
            ;;
    esac
}

wireproxy_load_socks_settings() {
    WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
    WIREPROXY_SOCKS_USER=""
    WIREPROXY_SOCKS_PASS=""

    [[ -f "$WIREPROXY_CONF" ]] || return 0

    local bind user pass
    bind="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "BindAddress")"
    user="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "Username")"
    pass="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "Password")"

    [[ -n "$bind" ]] && WIREPROXY_SOCKS_BIND="$bind"
    [[ -n "$user" ]] && WIREPROXY_SOCKS_USER="$user"
    [[ -n "$pass" ]] && WIREPROXY_SOCKS_PASS="$pass"
}

wireproxy_prompt_socks_settings() {
    local input current_pass

    wireproxy_load_socks_settings
    current_pass="$WIREPROXY_SOCKS_PASS"

    while true; do
        read -rp "SOCKS 监听地址(默认:${WIREPROXY_SOCKS_BIND}): " input
        input="${input:-$WIREPROXY_SOCKS_BIND}"
        if wireproxy_is_valid_host_port "$input"; then
            WIREPROXY_SOCKS_BIND="$input"
            break
        fi
        wireproxy_warn "监听地址格式无效，请使用 127.0.0.1:40000 或 [::]:40000"
    done

    read -rp "SOCKS 用户名(留空为无认证，当前:${WIREPROXY_SOCKS_USER:-无}): " input
    if [[ -n "$input" ]]; then
        WIREPROXY_SOCKS_USER="$input"
        read -rsp "SOCKS 密码(留空保持当前，输入 - 清空): " input
        echo ""
        if [[ "$input" == "-" ]]; then
            WIREPROXY_SOCKS_PASS=""
        elif [[ -n "$input" ]]; then
            WIREPROXY_SOCKS_PASS="$input"
        else
            WIREPROXY_SOCKS_PASS="$current_pass"
        fi
    else
        WIREPROXY_SOCKS_USER=""
        WIREPROXY_SOCKS_PASS=""
    fi
}

wireproxy_write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5" account="$6"

    mkdir -p "$WIREPROXY_CONF_DIR"
    cat > "$WIREPROXY_WG_WARP_CONF" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${v4}/32, ${v6}/128
DNS = 2606:4700:4700::1111
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}
PersistentKeepalive = 25
EOF
    chmod 600 "$WIREPROXY_WG_WARP_CONF"
    wireproxy_ok "WireGuard 配置已写入 ${WIREPROXY_WG_WARP_CONF}"
}

wireproxy_write_conf() {
    mkdir -p "$WIREPROXY_CONF_DIR"

    cat > "$WIREPROXY_CONF" <<EOF
WGConfig = ${WIREPROXY_WG_WARP_CONF}

[Socks5]
BindAddress = ${WIREPROXY_SOCKS_BIND}
EOF

    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        cat >> "$WIREPROXY_CONF" <<EOF
Username = ${WIREPROXY_SOCKS_USER}
Password = ${WIREPROXY_SOCKS_PASS}
EOF
    fi

    chmod 600 "$WIREPROXY_CONF"
    wireproxy_ok "wireproxy 配置已写入 ${WIREPROXY_CONF}"
}

wireproxy_create_service() {
    cat > "$WIREPROXY_SERVICE_FILE" <<EOF
[Unit]
Description=WARP SOCKS proxy via wireproxy
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WIREPROXY_BIN} -c ${WIREPROXY_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$WIREPROXY_SERVICE_FILE"
}

wireproxy_validate_config() {
    "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" -n >/tmp/wireproxy-configtest.log 2>&1
}

wireproxy_try_restart_service() {
    local quiet="${1:-0}"

    if ! wireproxy_validate_config; then
        if (( quiet == 0 )); then
            wireproxy_warn "配置校验失败"
            cat /tmp/wireproxy-configtest.log
        fi
        return 1
    fi

    wireproxy_create_service
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || wireproxy_warn "设置开机自启失败"

    if systemctl restart "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1; then
        return 0
    fi

    (( quiet == 0 )) && service_failure_hint "$WIREPROXY_SERVICE_NAME"
    return 1
}

wireproxy_restart_service() {
    if wireproxy_try_restart_service; then
        wireproxy_ok "${WIREPROXY_SERVICE_NAME} 已启动"
    else
        wireproxy_err "${WIREPROXY_SERVICE_NAME} 启动失败"
    fi
}

wireproxy_make_backup() {
    local file="$1" backup
    backup="$(mktemp)" || wireproxy_err "创建配置备份失败"
    cp "$file" "$backup" || {
        rm -f "$backup"
        wireproxy_err "备份配置失败: $file"
    }
    printf '%s\n' "$backup"
}

wireproxy_restart_service_with_backup() {
    local backup="$1" target="$2"

    if wireproxy_try_restart_service 1; then
        rm -f "$backup"
        wireproxy_ok "${WIREPROXY_SERVICE_NAME} 已启动"
        return 0
    fi

    cp "$backup" "$target" || true
    rm -f "$backup"

    if wireproxy_try_restart_service 1; then
        wireproxy_warn "新配置启动失败，已回滚到上一份可用配置"
    else
        wireproxy_warn "新配置启动失败，回滚后服务仍未启动"
        wireproxy_try_restart_service 0 >/dev/null 2>&1 || service_failure_hint "$WIREPROXY_SERVICE_NAME"
    fi

    return 1
}

wireproxy_prepare_install() {
    local account_type="$1"
    wireproxy_check_dependencies
    wireproxy_detect_arch
    wireproxy_prompt_socks_settings
    wireproxy_download_binary
    [[ "$account_type" == "free" ]] && wireproxy_ensure_wgcf || wireproxy_ensure_wireguard_tools
}

wireproxy_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5" account="$6"
    wireproxy_info "Endpoint: $endpoint"
    wireproxy_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$endpoint" "$account"
    wireproxy_write_conf
    wireproxy_restart_service
}

wireproxy_service_running() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$WIREPROXY_SERVICE_NAME"
}

wireproxy_show_proxy_status() {
    wireproxy_load_socks_settings
    echo -e "  SOCKS: ${CYAN}${WIREPROXY_SOCKS_BIND}${NC}"
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        echo -e "  认证: ${GREEN}${WIREPROXY_SOCKS_USER}${NC}"
    else
        echo -e "  认证: ${YELLOW}无${NC}"
    fi

    if wireproxy_service_running; then
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
}

wireproxy_show_proxy_trace() {
    local v4_trace="" v6_trace="" ip4="" ip6="" warp_status="" attempt
    wireproxy_load_socks_settings

    [[ -f "$WIREPROXY_CONF" ]] || { wireproxy_warn "未找到配置文件"; return; }

    for attempt in 1 2 3; do
        v4_trace="$(wireproxy_fetch_trace_via_proxy_v4 || true)"
        [[ -n "$v4_trace" ]] && break
        sleep 1
    done

    [[ -n "$v4_trace" ]] && ip4="$(wireproxy_trace_value "$v4_trace" "ip")"

    for attempt in 1 2 3; do
        v6_trace="$(wireproxy_fetch_trace_via_proxy_v6 || true)"
        [[ -n "$v6_trace" ]] && break
        sleep 1
    done

    [[ -n "$v6_trace" ]] && ip6="$(wireproxy_trace_value "$v6_trace" "ip")"

    [[ -z "$ip6" ]] && ip6="$(wireproxy_fetch_ipv6_ip_via_proxy || true)"

    [[ -z "$ip4" ]] && ip4="无"
    [[ -z "$ip6" ]] && ip6="无"

    echo -e "  IPv4: ${GREEN}${ip4}${NC}"
    echo -e "  IPv6: ${CYAN}${ip6}${NC}"
    if [[ -n "$v4_trace" || -n "$v6_trace" ]]; then
        warp_status="$(wireproxy_merge_warp_status "$v4_trace" "$v6_trace")"
        echo -e "  Warp: ${YELLOW}${warp_status}${NC}"
    else
        wireproxy_warn "无法通过 SOCKS 代理获取 WARP 出口信息，可稍等几秒后再试一次"
    fi
    echo ""
}

wireproxy_fetch_trace_via_proxy_v4() {
    local proxy_url trace=""
    local curl_args=()

    proxy_url="socks5://${WIREPROXY_SOCKS_BIND}"
    curl_args=(-4 --proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s)
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

wireproxy_fetch_trace_via_proxy_v6() {
    local proxy_url trace=""
    local curl_args=()

    proxy_url="socks5://${WIREPROXY_SOCKS_BIND}"
    curl_args=(-g --proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s)
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")
    fi

    trace="$(curl "${curl_args[@]}" "http://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

wireproxy_fetch_ipv6_ip_via_proxy() {
    local proxy_url ip=""
    local curl_args=()

    proxy_url="socks5h://${WIREPROXY_SOCKS_BIND}"
    curl_args=(--proxy "$proxy_url" --connect-timeout 5 --max-time 10 -s https://api6.ipify.org)
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")
    fi

    ip="$(curl "${curl_args[@]}" 2>/dev/null || true)"
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    printf '%s\n' "$ip"
}

wireproxy_trace_value() {
    local trace="$1" key="$2"
    printf '%s\n' "$trace" | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

wireproxy_trace_warp_label() {
    local trace="$1" warp
    warp="$(wireproxy_trace_value "$trace" "warp")"
    [[ "$warp" == "on" ]] && warp="free"
    [[ -n "$warp" ]] && printf '%s\n' "$warp" || printf 'unknown\n'
}

wireproxy_merge_warp_status() {
    local status="unknown" trace warp
    for trace in "$@"; do
        [[ -z "$trace" ]] && continue
        warp="$(wireproxy_trace_warp_label "$trace")"
        case "$warp" in
            plus) printf 'plus\n'; return 0 ;;
            free) status="free" ;;
            off) [[ "$status" == "unknown" ]] && status="off" ;;
        esac
    done

    printf '%s\n' "$status"
}

wireproxy_install_free() {
    local tmpdir priv pub addr endpoint warp_v4 warp_v6 version

    echo ""
    wireproxy_info "免费账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install free

    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"
    cd "$tmpdir" || wireproxy_err "进入临时目录失败"

    wireproxy_info "注册 WARP 免费账户 ..."
    yes | "$WIREPROXY_WGCF_PATH" register >/dev/null 2>&1 || {
        cd / || true
        rm -rf "$tmpdir"
        wireproxy_cleanup_wgcf
        wireproxy_err "WARP 注册失败"
    }

    wireproxy_info "生成 WireGuard 配置 ..."
    "$WIREPROXY_WGCF_PATH" generate >/dev/null 2>&1 || {
        cd / || true
        rm -rf "$tmpdir"
        wireproxy_cleanup_wgcf
        wireproxy_err "配置生成失败"
    }

    priv="$(awk -F' = ' '/^PrivateKey = /{print $2}' wgcf-profile.conf)"
    pub="$(awk -F' = ' '/^PublicKey = /{print $2}' wgcf-profile.conf)"
    addr="$(awk -F' = ' '/^Address = /{print $2}' wgcf-profile.conf)"
    endpoint="$(awk -F' = ' '/^Endpoint = /{print $2}' wgcf-profile.conf)"
    warp_v4="$(printf '%s\n' "$addr" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    warp_v6="$(printf '%s\n' "$addr" | grep -oE '2606:[0-9a-f:]+' | head -n1)"

    [[ -n "$priv" && -n "$pub" && -n "$warp_v4" && -n "$warp_v6" && -n "$endpoint" ]] || {
        cd / || true
        rm -rf "$tmpdir"
        wireproxy_cleanup_wgcf
        wireproxy_err "无法从 wgcf-profile.conf 提取 WARP 配置"
    }

    endpoint="$(wireproxy_select_endpoint_for_network "$endpoint" "" "" "")"

    cd / || true
    rm -rf "$tmpdir"
    wireproxy_cleanup_wgcf

    wireproxy_finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$endpoint" "free"

    echo ""
    wireproxy_ok "WARP SOCKS 配置完成"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_install_team() {
    local jwt_token priv pub response warp_v4 warp_v6 peer_pub endpoint ep_host ep_v4 ep_v6 ep_port org api_ports

    echo ""
    wireproxy_info "团队账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install team

    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 -> Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}Token 有效期较短，复制后请立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " jwt_token
    echo ""
    [[ -z "$jwt_token" ]] && { wireproxy_warn "已取消"; return; }

    wireproxy_info "生成 WireGuard 密钥对 ..."
    priv="$(wg genkey)"
    pub="$(printf '%s' "$priv" | wg pubkey)"

    wireproxy_info "向 Cloudflare API 注册设备 ..."
    response="$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: ${jwt_token}" \
        -d "{
            \"key\": \"${pub}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"Linux\",
            \"serial_number\": \"$(cat /proc/sys/kernel/random/uuid)\"
        }" 2>/dev/null)"

    [[ -n "$response" ]] || wireproxy_err "Cloudflare API 无响应，请检查网络后重试"
    printf '%s' "$response" | grep -q '"account"' || wireproxy_err "团队设备注册失败，请检查 Token 是否过期"

    warp_v4="$(printf '%s' "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v4"\s*:\s*"\K[^"]+' | head -1)"
    warp_v6="$(printf '%s' "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[^"]+' | head -1)"
    [[ -z "$warp_v4" ]] && warp_v4="$(printf '%s' "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)"
    [[ -z "$warp_v6" ]] && warp_v6="$(printf '%s' "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)"
    peer_pub="$(printf '%s' "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | tail -1)"
    org="$(printf '%s' "$response" | grep -oP '"organization"\s*:\s*"\K[^"]+' | head -1)"

    [[ -n "$warp_v4" && -n "$warp_v6" && -n "$peer_pub" ]] || wireproxy_err "无法从 API 响应中提取配置"

    ep_port=2408
    api_ports="$(printf '%s' "$response" | grep -oP '"ports"\s*:\s*\[\K[^\]]+' | head -1)"
    [[ -n "$api_ports" ]] && ep_port="$(printf '%s' "$api_ports" | cut -d',' -f1 | tr -d ' ')"

    ep_host="$(printf '%s' "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)"
    ep_v4="$(printf '%s' "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1 | sed 's/:0$//g')"
    ep_v6="$(printf '%s' "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1 | sed 's/\[//g; s/\]//g; s/:0$//g')"

    if [[ -n "$ep_host" ]]; then
        endpoint="$ep_host"
    elif [[ -n "$ep_v4" && "$ep_v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        endpoint="${ep_v4}:${ep_port}"
    elif [[ -n "$ep_v6" ]]; then
        endpoint="[${ep_v6}]:${ep_port}"
    else
        wireproxy_err "API 未返回可用的 Endpoint"
    fi

    endpoint="$(wireproxy_select_endpoint_for_network "$endpoint" "$ep_v4" "$ep_v6" "$ep_port")"

    wireproxy_finish_install "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$endpoint" "team(${org:-unknown})"

    echo ""
    wireproxy_ok "团队 WARP SOCKS 配置完成"
    echo -e "  组织: ${CYAN}${org:-unknown}${NC}"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_modify_config() {
    local current_endpoint current_mtu new_ep new_bind new_mtu input escaped_value backup_file auth_label auth_color service_label service_color

    clear

    [[ -f "$WIREPROXY_CONF" && -f "$WIREPROXY_WG_WARP_CONF" ]] || { wireproxy_warn "未找到配置，请先安装"; return; }

    wireproxy_load_socks_settings
    current_endpoint="$(wireproxy_extract_ini_value "$WIREPROXY_WG_WARP_CONF" "Peer" "Endpoint")"
    current_mtu="$(wireproxy_extract_ini_value "$WIREPROXY_WG_WARP_CONF" "Interface" "MTU")"
    [[ -z "$current_mtu" ]] && current_mtu="1280"
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        auth_label="$WIREPROXY_SOCKS_USER"
        auth_color="$GREEN"
    else
        auth_label="无"
        auth_color="$YELLOW"
    fi
    if wireproxy_service_running; then
        service_label="运行中"
        service_color="$GREEN"
    else
        service_label="未运行"
        service_color="$YELLOW"
    fi

    wireproxy_menu_divider
    echo -e "  ${CYAN}WARP:${NC} ${service_color}${service_label}${NC}"
    echo -e "  ${CYAN}Endpoint:${NC} ${current_endpoint}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}  ${CYAN}SOCKS:${NC} ${WIREPROXY_SOCKS_BIND}"
    echo -e "  ${CYAN}认证:${NC} ${auth_color}${auth_label}${NC}"
    wireproxy_menu_divider
    echo -e "  ${GREEN}1)${NC} 改Endpoint     ${CYAN}2)${NC} 改MTU"
    echo -e "  ${YELLOW}3)${NC} 改SOCKS监听    ${GREEN}4)${NC} 改SOCKS认证"
    echo -e "  ${CYAN}5)${NC} 编辑WARP配置 ${RED}  0)${NC} 返回上级"
    echo
    read -rp "  请选择 [0-5]: " input

    case "$input" in
        1)
            echo -e "\n  当前 Endpoint: ${current_endpoint}\n"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                wireproxy_is_valid_host_port "$new_ep" || { wireproxy_warn "Endpoint 格式无效"; return; }
                backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")"
                escaped_value="$(wireproxy_escape_sed_replacement "$new_ep")"
                sed -i "s|^Endpoint = .*|Endpoint = ${escaped_value}|" "$WIREPROXY_WG_WARP_CONF"
                wireproxy_ok "Endpoint 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            fi
            ;;
        2)
            echo -e "\n  当前 MTU: ${current_mtu}\n"
            read -rp "新 MTU [1280-1500]: " new_mtu
            if [[ "$new_mtu" =~ ^[0-9]+$ ]] && (( new_mtu >= 1280 && new_mtu <= 1500 )); then
                backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")"
                sed -i "s|^MTU = .*|MTU = ${new_mtu}|" "$WIREPROXY_WG_WARP_CONF"
                wireproxy_ok "MTU 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            else
                wireproxy_warn "无效的 MTU 值"
            fi
            ;;
        3)
            echo -e "\n  当前 SOCKS 监听: ${WIREPROXY_SOCKS_BIND}\n"
            read -rp "新 SOCKS 监听地址: " new_bind
            if [[ -n "$new_bind" ]]; then
                wireproxy_is_valid_host_port "$new_bind" || { wireproxy_warn "监听地址格式无效"; return; }
                backup_file="$(wireproxy_make_backup "$WIREPROXY_CONF")"
                escaped_value="$(wireproxy_escape_sed_replacement "$new_bind")"
                sed -i "s|^BindAddress = .*|BindAddress = ${escaped_value}|" "$WIREPROXY_CONF"
                wireproxy_ok "SOCKS 监听地址已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            fi
            ;;
        4)
            echo -e "\n  当前认证: ${auth_label}\n"
            backup_file="$(wireproxy_make_backup "$WIREPROXY_CONF")"
            wireproxy_prompt_socks_settings
            wireproxy_write_conf
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            ;;
        5)
            backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")"
            ${EDITOR:-nano} "$WIREPROXY_WG_WARP_CONF"
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            ;;
        0) return 1 ;;
        *) wireproxy_warn "无效选择" ;;
    esac
}

wireproxy_show_ip() {
    clear
    wireproxy_load_socks_settings
    wireproxy_menu_divider
    echo -e "  ${CYAN}WARP 出口${NC}"
    echo -e "  ${CYAN}SOCKS:${NC} ${WIREPROXY_SOCKS_BIND}"
    wireproxy_menu_divider
    wireproxy_show_proxy_trace
}

wireproxy_uninstall() {
    clear
    wireproxy_menu_divider
    echo -e "  ${RED}删除 WARP SOCKS 服务${NC}"
    if wireproxy_service_running; then
        echo -e "  ${CYAN}WARP:${NC} ${GREEN}运行中${NC}"
    else
        echo -e "  ${CYAN}WARP:${NC} ${YELLOW}未运行${NC}"
    fi
    wireproxy_menu_divider
    echo -e "  ${RED}将停止服务并删除配置与程序文件${NC}"
    echo
    read -rp "  确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if wireproxy_service_running; then
        systemctl stop "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || wireproxy_err "服务停止失败，请先处理后再删除"
        wireproxy_service_running && wireproxy_err "服务仍在运行，请先处理后再删除"
        wireproxy_ok "服务已停止"
    fi

    systemctl disable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$WIREPROXY_SERVICE_FILE"
    rm -f "$WIREPROXY_BIN"
    rm -rf "$WIREPROXY_CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true

    wireproxy_ok "WARP SOCKS 服务已删除"
}

wireproxy_show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP SOCKS 管理 v3.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    wireproxy_show_proxy_status
    wireproxy_menu_divider
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 修改配置   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 退出脚本"
}

wireproxy_pause() {
    pause_enter "回车继续..."
}

wireproxy_menu_divider() {
    echo "  ══════════════════════════"
}

wireproxy_menu() {
    local choice

    wireproxy_check_root
    while true; do
        wireproxy_show_menu
        wireproxy_menu_divider
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) wireproxy_install_free; wireproxy_pause ;;
            2) wireproxy_install_team; wireproxy_pause ;;
            3) wireproxy_modify_config && wireproxy_pause ;;
            4) wireproxy_uninstall && wireproxy_pause ;;
            5) wireproxy_show_ip; wireproxy_pause ;;
            0) return 0 ;;
            *) wireproxy_warn "无效选项"; wireproxy_pause ;;
        esac
    done
}

warpstack_info()  { log_prefixed "$CYAN" "[INFO]" "$*"; }
warpstack_ok()    { log_prefixed "$GREEN" "[ OK ]" "$*"; }
warpstack_warn()  { log_prefixed "$YELLOW" "[WARN]" "$*"; }
warpstack_err()   { log_prefixed "$RED" "[ERROR]" "$*"; exit 1; }

WARPSTACK_WG_CONF="/etc/wireguard/wg0.conf"
WARPSTACK_WGCF_BIN="/usr/local/bin/wgcf"
WARPSTACK_APT_UPDATED=0
WARPSTACK_AUTOSTART_STATUS="未设置"

warpstack_check_root() { [[ $EUID -ne 0 ]] && warpstack_err "请使用 root 用户运行此脚本"; }

warpstack_install_pkg() {
    local packages=("$@")
    command -v apt-get &>/dev/null || warpstack_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
    if [[ "$WARPSTACK_APT_UPDATED" -eq 0 ]]; then
        apt-get update -qq || return 1
        WARPSTACK_APT_UPDATED=1
    fi
    apt-get install -y -qq "${packages[@]}"
}

warpstack_is_valid_endpoint() {
    local ep="$1" host port
    if [[ "$ep" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$ep" =~ ^([^:]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    else
        return 1
    fi
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

warpstack_endpoint_host() {
    local value="$1"
    if [[ "$value" =~ ^\[([0-9a-fA-F:]+)\]:[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]+):[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$value"
    fi
}

warpstack_endpoint_port() {
    local value="$1"
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[^:]+:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

warpstack_is_ipv4_literal() {
    local host="$1"
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

warpstack_is_ipv6_literal() {
    local host="$1"
    [[ "$host" == *:* ]]
}

warpstack_resolve_endpoint_host_by_family() {
    local host="$1" family="$2"
    command -v getent >/dev/null 2>&1 || warpstack_err "缺少 getent，无法解析 Endpoint"
    case "$family" in
        4) getent ahostsv4 "$host" | awk '$1 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ { print $1; exit }' ;;
        6) getent ahostsv6 "$host" | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ { print $1; exit }' ;;
        *) return 1 ;;
    esac
}

warpstack_select_endpoint_for_network() {
    local current="$1" preferred_v4="$2" preferred_v6="$3" preferred_port="$4"
    local host port resolved

    [[ -n "$WARPSTACK_NET_MODE" ]] || warpstack_detect_network
    port="${preferred_port:-$(warpstack_endpoint_port "$current")}"
    [[ -z "$port" ]] && port="2408"

    case "$WARPSTACK_NET_MODE" in
        v6_only)
            if [[ -n "$preferred_v6" ]]; then
                printf '[%s]:%s\n' "$preferred_v6" "$port"
                return 0
            fi
            host="$(warpstack_endpoint_host "$current")"
            [[ -n "$host" ]] || warpstack_err "无法确定 IPv6 Endpoint"
            if warpstack_is_ipv6_literal "$host" && ! warpstack_is_ipv4_literal "$host"; then
                printf '[%s]:%s\n' "$host" "$port"
                return 0
            fi
            resolved="$(warpstack_resolve_endpoint_host_by_family "$host" 6)"
            [[ -n "$resolved" ]] || warpstack_err "无法解析 IPv6 Endpoint: $host"
            printf '[%s]:%s\n' "$resolved" "$port"
            ;;
        dual|v4_only)
            host="$(warpstack_endpoint_host "$current")"
            [[ -n "$host" ]] || warpstack_err "无法确定 IPv4 Endpoint"
            if warpstack_is_ipv6_literal "$host" && ! warpstack_is_ipv4_literal "$host"; then
                if [[ -n "$preferred_v4" ]]; then
                    printf '%s:%s\n' "$preferred_v4" "$port"
                    return 0
                fi
                warpstack_err "当前为 IPv4 网络，无法使用 IPv6 Endpoint: $host"
            fi
            if [[ -n "$preferred_v4" ]]; then
                printf '%s:%s\n' "$preferred_v4" "$port"
                return 0
            fi
            if warpstack_is_ipv4_literal "$host" || [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]]; then
                printf '%s:%s\n' "$host" "$port"
                return 0
            fi
            warpstack_err "无法确定 IPv4 Endpoint: $host"
            ;;
        none)
            warpstack_err "当前服务器无可用网络，无法确定 Endpoint"
            ;;
        *)
            warpstack_err "未知网络模式: $WARPSTACK_NET_MODE"
            ;;
    esac
}

warpstack_escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

warpstack_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) WARPSTACK_WGCF_ARCH="amd64" ;;
        *)       warpstack_err "不支持的架构: $arch" ;;
    esac
}

warpstack_detect_network() {
    local has_v4=false has_v6=false

    ip -4 addr show scope global 2>/dev/null | grep -q inet &&
        curl -4 -s --max-time 2 http://1.1.1.1/cdn-cgi/trace &>/dev/null &&
        has_v4=true
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 &&
        curl -6 -g -s --max-time 2 "http://[2606:4700:4700::1111]/cdn-cgi/trace" &>/dev/null &&
        has_v6=true

    if $has_v4 && $has_v6; then WARPSTACK_NET_MODE="dual"
    elif $has_v6; then WARPSTACK_NET_MODE="v6_only"
    elif $has_v4; then WARPSTACK_NET_MODE="v4_only"
    else WARPSTACK_NET_MODE="none"; fi
}

warpstack_show_network_status() {
    warpstack_detect_network
    case "$WARPSTACK_NET_MODE" in
        dual)    echo -e "  网络: ${GREEN}IPv4✓${NC} ${GREEN}IPv6✓${NC}" ;;
        v6_only) echo -e "  网络: ${RED}IPv4✗${NC} ${GREEN}IPv6✓${NC}" ;;
        v4_only) echo -e "  网络: ${GREEN}IPv4✓${NC} ${RED}IPv6✗${NC}" ;;
        none)    echo -e "  网络: ${RED}IPv4✗${NC} ${RED}IPv6✗${NC}" ;;
    esac
    if ip link show wg0 &>/dev/null 2>&1; then
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
}

warpstack_install_wireguard_tools() {
    command -v wg &>/dev/null && { warpstack_ok "wireguard-tools 已安装"; return; }
    warpstack_info "安装 wireguard-tools ..."
    warpstack_install_pkg --no-install-recommends wireguard-tools || warpstack_err "wireguard-tools 安装失败"
    command -v wg &>/dev/null || warpstack_err "wireguard-tools 安装后仍未检测到 wg 命令"
    warpstack_ok "wireguard-tools 已安装"
}

warpstack_check_dependencies() {
    if ! command -v curl &>/dev/null; then
        warpstack_info "安装 curl ..."
        warpstack_install_pkg curl || warpstack_err "curl 安装失败"
    fi
    command -v curl &>/dev/null || warpstack_err "curl 不可用，无法继续"
}

warpstack_prepare_install() {
    local account_type="$1"
    warpstack_check_dependencies
    warpstack_determine_install_mode || return 1
    warpstack_check_wg0_exists
    [[ "$account_type" == "free" ]] && warpstack_detect_arch
    warpstack_install_wireguard_tools
}

warpstack_determine_install_mode() {
    warpstack_detect_network
    case "$WARPSTACK_NET_MODE" in
        dual)
            warpstack_warn "已是双栈，无需安装"
            return 1 ;;
        v6_only) WARPSTACK_INSTALL_MODE="add_v4"; warpstack_info "检测到纯 IPv6，将添加 IPv4 出口" ;;
        v4_only) WARPSTACK_INSTALL_MODE="add_v6"; warpstack_info "检测到纯 IPv4，将添加 IPv6 出口" ;;
        none)    warpstack_err "当前服务器无任何网络连接，无法继续" ;;
    esac
    return 0
}

warpstack_check_wg0_exists() {
    ip link show wg0 &>/dev/null 2>&1 && warpstack_err "检测到 wg0，请先删除后再安装"
}

warpstack_write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" mode="$6" acct="$7"
    mkdir -p /etc/wireguard

    if [[ "$mode" == "add_v4" ]]; then
        [[ -n "$v4" ]] || warpstack_err "缺少 WARP IPv4 地址，无法写入配置"
        cat > "$WARPSTACK_WG_CONF" << EOF
[Interface]
PrivateKey = ${priv}
Address = ${v4}/32
MTU = 1408

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ep}
PersistentKeepalive = 25
EOF
    elif [[ "$mode" == "add_v6" ]]; then
        [[ -n "$v6" ]] || warpstack_err "缺少 WARP IPv6 地址，无法写入配置"
        cat > "$WARPSTACK_WG_CONF" << EOF
[Interface]
PrivateKey = ${priv}
Address = ${v6}/128
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = ::/0
Endpoint = ${ep}
PersistentKeepalive = 25
EOF
    fi
    chmod 600 "$WARPSTACK_WG_CONF"
    warpstack_ok "wg0.conf 已写入"
}

warpstack_start_and_enable() {
    warpstack_info "启动 wg0 隧道 ..."
    wg-quick up wg0 || warpstack_err "wg0 启动失败，请检查配置"
    warpstack_ok "wg0 隧道已启动"
    if command -v systemctl &>/dev/null; then
        if systemctl enable wg-quick@wg0 &>/dev/null; then
            WARPSTACK_AUTOSTART_STATUS="已启用"
            warpstack_ok "已设置开机自启"
        else
            WARPSTACK_AUTOSTART_STATUS="启用失败"
            warpstack_warn "设置开机自启失败（可能不是 systemd 环境）"
        fi
    else
        WARPSTACK_AUTOSTART_STATUS="不支持(systemctl 不存在)"
        warpstack_warn "未检测到 systemctl，跳过开机自启设置"
    fi
}

warpstack_show_result() {
    local mode="$1"
    warpstack_ok "配置完成"

    local v4a v6a
    v4a=$(warpstack_public_ip "-4" "获取失败")
    v6a=$(warpstack_public_ip "-6" "获取失败")

    if [[ "$mode" == "add_v4" ]]; then
        echo -e "  模式: 纯 IPv6 -> 添加 IPv4"
        echo -e "  IPv4: ${GREEN}${v4a}${NC} (WARP)"
        echo -e "  IPv6: ${CYAN}${v6a}${NC} (原生)"
    else
        echo -e "  模式: 纯 IPv4 -> 添加 IPv6"
        echo -e "  IPv4: ${CYAN}${v4a}${NC} (原生)"
        echo -e "  IPv6: ${GREEN}${v6a}${NC} (WARP)"
    fi
    echo -e "  自启: ${WARPSTACK_AUTOSTART_STATUS}"
    echo -e "  配置: ${YELLOW}${WARPSTACK_WG_CONF}${NC}"
}

warpstack_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" acct="$6"
    warpstack_info "Endpoint: $ep"
    warpstack_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$ep" "$WARPSTACK_INSTALL_MODE" "$acct"
    warpstack_start_and_enable
    warpstack_show_result "$WARPSTACK_INSTALL_MODE"
}

warpstack_conf_value() {
    local key="$1"
    awk -F' = ' -v key="$key" '$1 == key { print $2; exit }' "$WARPSTACK_WG_CONF"
}

warpstack_public_ip() {
    local family="$1" fallback="$2" ip
    ip=$(curl -s "$family" --max-time 5 ip.gs 2>/dev/null || true)
    [[ -n "$ip" ]] && printf '%s' "$ip" || printf '%s' "$fallback"
}

warpstack_fetch_trace() {
    local family="$1" trace=""
    trace="$(curl -s "$family" --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    [[ -n "$trace" && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

warpstack_trace_value() {
    local trace="$1" key="$2"
    printf '%s\n' "$trace" | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

warpstack_trace_warp_label() {
    local trace="$1" warp
    warp="$(warpstack_trace_value "$trace" "warp")"
    [[ "$warp" == "on" ]] && warp="free"
    [[ -n "$warp" ]] && printf '%s\n' "$warp" || printf 'unknown\n'
}

warpstack_merge_warp_status() {
    local status="unknown" trace warp
    for trace in "$@"; do
        [[ -z "$trace" ]] && continue
        warp="$(warpstack_trace_warp_label "$trace")"
        case "$warp" in
            plus) printf 'plus\n'; return 0 ;;
            free) status="free" ;;
            off) [[ "$status" == "unknown" ]] && status="off" ;;
        esac
    done

    printf '%s\n' "$status"
}

warpstack_trace_is_warp() {
    local trace="$1" warp
    warp="$(warpstack_trace_value "$trace" "warp")"
    [[ -n "$warp" && "$warp" != "off" ]]
}

warpstack_install_free() {
    warpstack_prepare_install free || return 1

    local wgcf_downloaded=false
    if [[ ! -x "$WARPSTACK_WGCF_BIN" ]]; then
        warpstack_info "获取 wgcf 最新版本 ..."
        local wgcf_ver wgcf_host
        wgcf_host="https://github.com/ViRb3/wgcf"
        if [[ "$WARPSTACK_NET_MODE" == "v6_only" ]]; then
            wgcf_host="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
            warpstack_info "检测到纯 IPv6，wgcf 下载改用镜像: $wgcf_host"
            wgcf_ver=$(curl -fsSL "${wgcf_host}/releases/latest" | grep -oE '/releases/tag/v[0-9.]+' | sed 's#.*/##' | head -n1)
        else
            wgcf_ver=$(curl -fsSI "${wgcf_host}/releases/latest" | sed -nE 's/^[Ll]ocation:.*(v[0-9.]+).*/\1/p' | head -n1)
        fi
        [[ -z "$wgcf_ver" ]] && warpstack_err "无法获取 wgcf 最新版本号"
        local url="${wgcf_host}/releases/download/${wgcf_ver}/wgcf_${wgcf_ver#v}_linux_${WARPSTACK_WGCF_ARCH}"
        warpstack_info "下载 wgcf ${wgcf_ver} ..."
        curl -fsSL -o "$WARPSTACK_WGCF_BIN" "$url" || warpstack_err "wgcf 下载失败"
        chmod +x "$WARPSTACK_WGCF_BIN"; warpstack_ok "wgcf ${wgcf_ver} 已下载"
        wgcf_downloaded=true
    fi

    local tmpdir; tmpdir=$(mktemp -d)
    [[ -z "$tmpdir" ]] && warpstack_err "创建临时目录失败"
    cd "$tmpdir" || {
        rm -rf "$tmpdir"
        if $wgcf_downloaded; then
            rm -f "$WARPSTACK_WGCF_BIN"
        fi
        warpstack_err "进入临时目录失败: $tmpdir"
    }

    warpstack_info "注册 WARP 免费账户 ..."
    yes | "$WARPSTACK_WGCF_BIN" register || {
        cd / || true
        rm -rf "$tmpdir"
        if $wgcf_downloaded; then
            rm -f "$WARPSTACK_WGCF_BIN"
        fi
        warpstack_err "WARP 注册失败"
    }
    warpstack_ok "注册成功"

    warpstack_info "生成 WireGuard 配置 ..."
    "$WARPSTACK_WGCF_BIN" generate || {
        cd / || true
        rm -rf "$tmpdir"
        if $wgcf_downloaded; then
            rm -f "$WARPSTACK_WGCF_BIN"
        fi
        warpstack_err "配置生成失败"
    }

    local priv pub addr ep warp_v4 warp_v6
    priv=$(grep 'PrivateKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    pub=$(grep 'PublicKey' wgcf-profile.conf | awk -F' = ' '{print $2}')
    addr=$(grep 'Address' wgcf-profile.conf | awk -F' = ' '{print $2}')
    ep=$(grep 'Endpoint' wgcf-profile.conf | awk -F' = ' '{print $2}')
    warp_v4=$(echo "$addr" | grep -oP '\d+\.\d+\.\d+\.\d+')
    warp_v6=$(echo "$addr" | grep -oP '2606:[0-9a-f:]+')

    [[ -n "$priv" && -n "$pub" && -n "$warp_v4" && -n "$warp_v6" && -n "$ep" ]] || {
        cd / || true
        rm -rf "$tmpdir"
        if $wgcf_downloaded; then
            rm -f "$WARPSTACK_WGCF_BIN"
        fi
        warpstack_err "无法从 wgcf-profile.conf 提取 WARP 配置"
    }

    warpstack_info "WARP IPv4: $warp_v4 | IPv6: $warp_v6"

    cd / || true
    rm -rf "$tmpdir"
    if $wgcf_downloaded; then
        rm -f "$WARPSTACK_WGCF_BIN"
        warpstack_ok "wgcf 与临时文件已清理"
    else
        warpstack_ok "临时文件已清理"
    fi

    ep="$(warpstack_select_endpoint_for_network "$ep" "" "" "")"
    warpstack_finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$ep" "free"
}

warpstack_install_team() {
    local jwt_token priv pub response warp_v4 warp_v6 peer_pub org ep_port api_ports ep_host ep_v4 ep_v6 endpoint response_brief

    warpstack_prepare_install team || return 1
    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 → Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}⚠ Token 有效期 60 秒，复制后立即粘贴${NC}"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " jwt_token
    printf '\n'
    [[ -z "$jwt_token" ]] && { warpstack_warn "已取消"; return; }

    warpstack_info "生成 WireGuard 密钥对 ..."
    priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey)

    warpstack_info "向 Cloudflare API 注册设备 ..."
    response=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: ${jwt_token}" \
        -d "{
            \"key\": \"${pub}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"Linux\",
            \"serial_number\": \"$(cat /proc/sys/kernel/random/uuid)\"
        }" 2>/dev/null)

    [[ -z "$response" ]] && warpstack_err "Cloudflare API 无响应，请检查网络后重试"
    echo "$response" | grep -q '"account"' || {
        response_brief=$(echo "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)
        warpstack_warn "API 返回摘要: ${response_brief}"
        warpstack_err "注册失败，请检查 Token 是否过期"
    }
    warpstack_ok "团队设备注册成功"

    warp_v4=$(echo "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v4"\s*:\s*"\K[^"]+' | head -1)
    warp_v6=$(echo "$response" | grep -oP '"addresses"\s*:\s*\{[^}]*"v6"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$warp_v4" ]] && warp_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | head -1)
    [[ -z "$warp_v6" ]] && warp_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | head -1)
    peer_pub=$(echo "$response" | grep -oP '"public_key"\s*:\s*"\K[^"]+' | tail -1)

    [[ -z "$warp_v4" || -z "$warp_v6" || -z "$peer_pub" ]] && {
        echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        warpstack_err "无法从 API 响应中提取配置"
    }

    org=$(echo "$response" | grep -oP '"organization"\s*:\s*"\K[^"]+' | head -1)
    warpstack_info "WARP IPv4: $warp_v4 | IPv6: $warp_v6 | 组织: $org"

    ep_port=2408
    api_ports=$(echo "$response" | grep -oP '"ports"\s*:\s*\[\K[^\]]+' | head -1)
    [[ -n "$api_ports" ]] && ep_port=$(echo "$api_ports" | cut -d',' -f1 | tr -d ' ')

    ep_host=$(echo "$response" | grep -oP '"host"\s*:\s*"\K[^"]+' | head -1)
    ep_v4=$(echo "$response" | grep -oP '"v4"\s*:\s*"\K[^"]+' | tail -1)
    ep_v4=$(echo "$ep_v4" | sed 's/:0$//g')
    ep_v6=$(echo "$response" | grep -oP '"v6"\s*:\s*"\K[^"]+' | tail -1)
    ep_v6=$(echo "$ep_v6" | sed 's/\[//g; s/\]//g; s/:0$//g')

    case "$WARPSTACK_NET_MODE" in
        v6_only)
            [[ "$ep_v6" == *"cf1"* ]] && ep_v6=""
            endpoint="$(warpstack_select_endpoint_for_network "${ep_host:-$ep_v6}" "" "$ep_v6" "$ep_port")"
            ;;
        v4_only|dual)
            endpoint="$(warpstack_select_endpoint_for_network "${ep_host:-$ep_v4}" "" "" "$ep_port")"
            ;;
        *)
            warpstack_err "当前网络模式无法确定 Endpoint"
            ;;
    esac
    warpstack_finish_install "$priv" "$warp_v4" "$warp_v6" "$peer_pub" "$endpoint" "team($org)"
}

warpstack_modify_config() {
    clear
    warpstack_menu_divider
    [[ ! -f "$WARPSTACK_WG_CONF" ]] && { warpstack_warn "未找到 ${WARPSTACK_WG_CONF}，请先安装"; return; }

    local current_ep current_mtu
    current_ep=$(warpstack_conf_value "Endpoint")
    current_mtu=$(warpstack_conf_value "MTU")

    echo -e "  ${CYAN}Endpoint:${NC} ${current_ep}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}"
    warpstack_menu_divider
    echo -e "  ${GREEN}1)${NC} 改Endpoint   ${CYAN}2)${NC} 改MTU"
    echo -e "  ${YELLOW}3)${NC} 编辑配置     ${RED}0)${NC} 返回上级"
    echo
    read -rp "  请选择 [0-3]: " sub

    case "$sub" in
        1)
            echo -e "  ${CYAN}当前 Endpoint:${NC} ${current_ep}"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                if ! warpstack_is_valid_endpoint "$new_ep"; then
                    warpstack_warn "Endpoint 格式无效，请使用 域名/IP:端口 或 [IPv6]:端口"
                else
                    local escaped_ep
                    escaped_ep=$(warpstack_escape_sed_replacement "$new_ep")
                    sed -i "s|^Endpoint = .*|Endpoint = ${escaped_ep}|" "$WARPSTACK_WG_CONF"
                    warpstack_ok "已更新"
                    warpstack_restart_wg
                fi
            fi
            ;;
        2)
            echo -e "  ${CYAN}当前 MTU:${NC} ${current_mtu}  建议: 1280 或 1420"
            read -rp "新 MTU [1280-1500]: " mtu
            if [[ "$mtu" =~ ^[0-9]+$ ]] && [[ "$mtu" -ge 1280 ]] && [[ "$mtu" -le 1500 ]]; then
                sed -i "s|^MTU = .*|MTU = ${mtu}|" "$WARPSTACK_WG_CONF"; warpstack_ok "已更新"; warpstack_restart_wg
            else
                warpstack_warn "无效的 MTU 值"
            fi
            ;;
        3)
            ${EDITOR:-nano} "$WARPSTACK_WG_CONF"
            read -rp "重启 wg0？[y/N]: " yn
            [[ "$yn" =~ ^[Yy]$ ]] && warpstack_restart_wg
            ;;
        0) return 1 ;;
        *) warpstack_warn "无效选择" ;;
    esac
}

warpstack_stop_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_info "暂停 wg0 ..."
        warpstack_down_wg || warpstack_err "wg0 暂停失败"
        warpstack_ok "wg0 已暂停"
    else
        warpstack_warn "wg0 未运行"
    fi
}

warpstack_down_wg() {
    wg-quick down wg0 2>/dev/null || true
    ! ip link show wg0 &>/dev/null 2>&1
}

warpstack_restart_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_info "重启 wg0 ..."
        warpstack_down_wg || warpstack_err "wg0 停止失败"
        wg-quick up wg0 || warpstack_err "wg0 重启失败"; warpstack_ok "wg0 已重启"
    else
        warpstack_info "启动 wg0 ..."; wg-quick up wg0 || warpstack_err "wg0 启动失败"; warpstack_ok "wg0 已启动"
    fi
}

warpstack_manage_service() {
    while true; do
        clear
        warpstack_menu_divider
        if ip link show wg0 &>/dev/null 2>&1; then
            echo -e "  ${CYAN}WARP 状态:${NC} ${GREEN}运行中${NC}"
        else
            echo -e "  ${CYAN}WARP 状态:${NC} ${YELLOW}未运行${NC}"
        fi
        warpstack_menu_divider
        echo -e "  ${GREEN}1)${NC} 修改配置  ${CYAN}2)${NC} 暂停服务"
        echo -e "  ${YELLOW}3)${NC} 重启服务  ${RED}0)${NC} 返回上级"
        echo
        read -rp "  请选择 [0-3]: " sub

        case "$sub" in
            1) warpstack_modify_config && warpstack_pause ;;
            2) warpstack_stop_wg; warpstack_pause ;;
            3) warpstack_restart_wg; warpstack_pause ;;
            0) return 0 ;;
            *) warpstack_warn "无效选择"; warpstack_pause ;;
        esac
    done
}

warpstack_show_ip() {
    clear
    warpstack_info "当前出口 IP"
    local v4 v6 allowed v4_trace="" v6_trace="" v4_suffix="" v6_suffix="" warp_status="" has_target=false has_warp=false
    v4=$(warpstack_public_ip "-4" "无")
    v6=$(warpstack_public_ip "-6" "无")

    if [[ -f "$WARPSTACK_WG_CONF" ]]; then
        allowed="$(warpstack_conf_value "AllowedIPs")"
        if [[ "$allowed" == *"0.0.0.0/0"* ]]; then
            has_target=true
            v4_trace="$(warpstack_fetch_trace "-4" || true)"
            if warpstack_trace_is_warp "$v4_trace"; then
                has_warp=true
                v4_suffix=" ${GREEN}(WARP)${NC}"
            fi
        fi
        if [[ "$allowed" == *"::/0"* ]]; then
            has_target=true
            v6_trace="$(warpstack_fetch_trace "-6" || true)"
            if warpstack_trace_is_warp "$v6_trace"; then
                has_warp=true
                v6_suffix=" ${GREEN}(WARP)${NC}"
            fi
        fi
    fi

    echo -e "  IPv4: ${CYAN}${v4}${NC}${v4_suffix}"
    echo -e "  IPv6: ${CYAN}${v6}${NC}${v6_suffix}"
    warpstack_menu_divider
    if [[ ! -f "$WARPSTACK_WG_CONF" ]]; then
        warpstack_warn "未找到 ${WARPSTACK_WG_CONF}，无法判断 WARP 状态"
        return
    fi
    if [[ "$allowed" == *"0.0.0.0/0"* ]]; then
        [[ -z "$v4_trace" ]] && warpstack_warn "无法通过 IPv4 获取 Cloudflare trace"
    fi
    if [[ "$allowed" == *"::/0"* ]]; then
        [[ -z "$v6_trace" ]] && warpstack_warn "无法通过 IPv6 获取 Cloudflare trace"
    fi
    $has_target || warpstack_warn "配置中未找到可检查的 WARP AllowedIPs"
    if $has_warp; then
        warp_status="$(warpstack_merge_warp_status "$v4_trace" "$v6_trace")"
        echo -e "  Warp: ${YELLOW}${warp_status}${NC}"
    else
        warpstack_warn "未检测到 WARP 出口状态"
    fi
}

warpstack_uninstall() {
    clear
    warpstack_info "删除 WARP 服务"
    echo -e "  ${RED}将删除 wg0 与配置文件${NC}"
    read -rp "确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_down_wg || warpstack_err "隧道关闭失败，请先处理后再删除"
        warpstack_ok "隧道已关闭"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl disable wg-quick@wg0 &>/dev/null 2>&1 && warpstack_ok "已取消自启" || warpstack_warn "取消自启失败"
    else
        warpstack_warn "未检测到 systemctl，跳过取消自启"
    fi
    rm -f "$WARPSTACK_WG_CONF"; warpstack_ok "已删除 $WARPSTACK_WG_CONF"
    warpstack_ok "WARP 服务已完全删除"
}

warpstack_show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP 出口管理 v2.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    warpstack_show_network_status
    warpstack_menu_divider
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 管理服务   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 退出脚本"
}

warpstack_pause() {
    pause_enter "回车继续..."
}

warpstack_menu_divider() {
    echo "  ══════════════════════════"
}

warpstack_menu() {
    local choice

    warpstack_check_root
    while true; do
        warpstack_show_menu
        warpstack_menu_divider
        read -rp "  请输入选项 [0-5]: " choice
        case "$choice" in
            1) warpstack_install_free; warpstack_pause ;;
            2) warpstack_install_team; warpstack_pause ;;
            3) warpstack_manage_service ;;
            4) warpstack_uninstall && warpstack_pause ;;
            5) warpstack_show_ip; warpstack_pause ;;
            0) return 0 ;;
            *) warpstack_warn "无效选项"; warpstack_pause ;;
        esac
    done
}

reinstall_system_menu() { reinstall_menu; }
reboot_system()         { echo "系统将在 3 秒后重新启动..."; sleep 3; reboot_vps; }
configure_shoes()       { shoes_check_supported_os || { press_any_key_to_continue; return; }; shoes_menu; }
configure_mihomo()      { mihomo_menu; }
configure_wireproxy() {
    local rc
    ( wireproxy_menu )
    rc=$?
    (( rc == 0 )) || press_any_key_to_continue "WireProxy 已退出，按任意键返回菜单..."
}
configure_warpstack() {
    local rc
    ( warpstack_menu )
    rc=$?
    (( rc == 0 )) || press_any_key_to_continue "WarpStack 已退出，按任意键返回菜单..."
}

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
            firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -s fe80::/10 -p udp --sport 547 --dport 546 -j ACCEPT || return 1
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
        firewall_restore_with_notice "$backup" "端口跳跃规则写入失败,已回滚到修改前状态" "端口跳跃规则写入失败,回滚失败,请检查 NAT 规则"
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
        firewall_restore_with_notice "$backup" "删除端口跳跃规则失败,已恢复原状态" "删除端口跳跃规则失败,回滚失败,请检查 NAT 规则"
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
            if [[ -z "$input_ports" ]]; then
                echo -e "${YELLOW}[!] 未输入端口,已取消本次操作${PLAIN}"
                press_any_key_to_continue
                return 0
            fi
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
                firewall_restore_with_notice "$backup" "本次操作存在失败项,已回滚到修改前状态" "本次操作存在失败项,回滚失败,请检查规则"
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
                firewall_restore_with_notice "$backup" "清空规则失败,已恢复到清空前状态" "清空规则失败,回滚失败,请检查当前规则"
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
                firewall_restore_with_notice "$backup" "写入规则失败,已恢复到修改前状态" "写入规则失败,回滚失败,请检查当前规则"
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
