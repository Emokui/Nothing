#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then set -u; fi

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
        x86_64|amd64|aarch64|arm64) return 0 ;;
        *)
            echo -e "${RED}不支持${PLAIN}"
            return 1
            ;;
    esac
}


get_root_home() {
    local directory
    directory=$(getent passwd root 2>/dev/null | cut -d: -f6)
    printf '%s\n' "${directory:-/root}"
}

ROOT_HOME="$(get_root_home)"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Shared operations. Data goes to stdout; diagnostics go to stderr.
ZERO_VERSION="3.0"
ZERO_APT_UPDATED=0

zero_error() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }

zero_valid_uint() {
    local value="$1" minimum="$2" maximum="$3"
    [[ "$value" =~ ^(0|[1-9][0-9]{0,8})$ ]] || return 1
    (( value >= minimum && value <= maximum ))
}

zero_atomic_install() {
    local source_file="$1" target="$2" mode="${3:-600}" temp
    temp=$(mktemp "${target}.zero.XXXXXX") || return 1
    if install -m "$mode" "$source_file" "$temp" && mv -f "$temp" "$target"; then
        return 0
    fi
    rm -f "$temp"
    return 1
}

zero_apt_update() {
    command -v apt-get >/dev/null 2>&1 || { zero_error '未找到 apt-get'; return 1; }
    (( ZERO_APT_UPDATED == 1 )) && return 0
    apt-get -o DPkg::Lock::Timeout=60 update || return 1
    ZERO_APT_UPDATED=1
}

zero_service_healthy() {
    local unit="$1" attempt stable=0 state
    for ((attempt=0; attempt<12; attempt++)); do
        state=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null) || return 1
        case "$state" in
            active) stable=$((stable+1)); (( stable >= 4 )) && return 0 ;;
            activating) stable=0 ;;
            *) return 1 ;;
        esac
        sleep 1
    done
    return 1
}

zero_service_action() {
    local action="$1" unit="$2"
    systemctl "$action" "$unit" || return 1
    case "$action" in start|restart|reload) zero_service_healthy "$unit" ;; *) return 0 ;; esac
}

zero_dns_probe() {
    timeout 12 getent ahosts deb.debian.org >/dev/null 2>&1
}

zero_snapshot_paths() {
    local backup="$1" path
    install -d -m 700 "$backup/files" || return 1
    : > "$backup/present"; : > "$backup/absent"
    shift
    for path in "$@"; do
        if [[ -e "$path" || -L "$path" ]]; then
            mkdir -p "$backup/files$(dirname "$path")" || return 1
            cp -a "$path" "$backup/files$path" || return 1
            printf '%s\n' "$path" >> "$backup/present"
        else
            printf '%s\n' "$path" >> "$backup/absent"
        fi
    done
}

zero_restore_paths() {
    local backup="$1" path failed=0
    while IFS= read -r path; do
        [[ -n "$path" && "$path" == /* ]] || continue
        rm -rf -- "$path" || { failed=1; continue; }
        cp -a "$backup/files$path" "$path" || failed=1
    done < "$backup/present"
    while IFS= read -r path; do
        [[ -n "$path" && "$path" == /* ]] || continue
        rm -rf -- "$path" || failed=1
    done < "$backup/absent"
    return "$failed"
}

zero_confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
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
    if [[ "$value" =~ ^[0-9]{1,3}$ ]]; then
        printf '%s' "$((10#$value))"
    else
        printf '%s' "$value"
    fi
}

read_menu_choice() {
    local prompt="$1" value
    read -r -p "$(printf "${BLUE}%s${PLAIN}" "$prompt")" value || return 1
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
    local option="${1,,}" client server port output
    read -r client _ server port <<< "${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
    output=$(sshd -T -f "$SSHD_CONFIG" -C "user=root,host=localhost,addr=$client,laddr=$server,lport=$port" 2>/dev/null) || return 1
    awk -v key="$option" '$1 == key {print $2; exit}' <<< "$output"
}

update_sshd_option() {
    local option="$1" value="$2" candidate main_candidate
    local managed=/etc/ssh/sshd_config.d/00-zero.conf
    case "$option" in Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication) ;; *) return 1 ;; esac
    mkdir -p /etc/ssh/sshd_config.d || return 1
    if [[ "$option" == Port ]]; then
        local file count
        # Port supports multiple values. Refuse an implicit migration of a multi-listener setup.
        count=$(sshd -T -f "$SSHD_CONFIG" 2>/dev/null | awk '$1=="port" {n++} END {print n+0}')
        (( count <= 1 )) || { zero_error '检测到多个 SSH 端口，请人工迁移监听配置'; return 1; }
        for file in "$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$file" && "$file" != "$managed" ]] || continue
            # Retain comments and every other option; transaction snapshots preserve original files.
            sed -i '/^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]/s/^/# Zero.sh superseded Port: /' "$file" || return 1
        done
    fi
    candidate=$(mktemp) || return 1
    main_candidate=$(mktemp) || { rm -f "$candidate"; return 1; }
    if [[ -f "$managed" ]]; then
        awk -v key="${option,,}" 'tolower($1) != key' "$managed" > "$candidate"
    fi
    printf '%s %s\n' "$option" "$value" >> "$candidate"
    {
        echo 'Include /etc/ssh/sshd_config.d/00-zero.conf'
        awk '$0 != "Include /etc/ssh/sshd_config.d/00-zero.conf"' "$SSHD_CONFIG"
    } > "$main_candidate"
    zero_atomic_install "$candidate" "$managed" 600 &&
        zero_atomic_install "$main_candidate" "$SSHD_CONFIG" 644
    local result=$?
    rm -f "$candidate" "$main_candidate"
    return "$result"
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
    zero_apt_update && apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends "$@"
}

pkg_update() {
    ZERO_APT_UPDATED=0
    zero_apt_update && apt-get -o DPkg::Lock::Timeout=60 upgrade -y
}

pkg_clean() {
    apt-get autoclean && apt-get clean
}

linux_update() {
    clear
    echo -e "${YELLOW}正在更新系统...${PLAIN}"

    if ! pkg_update; then
        echo -e "${RED}系统更新失败，请查看上方 apt-get 错误${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${GREEN}系统更新完成${PLAIN}"
    [[ -f /var/run/reboot-required ]] && echo -e "${YELLOW}更新后需要重启，请在选项 09 中安排重启${PLAIN}"
    press_any_key_to_continue
}

zero_clean_packages() (
    local current version package simulation work
    local -a versions=() protect=() proposed=()
    current=$(uname -r)
    mapfile -t versions < <(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' |
        sed 's/^vmlinuz-//' | sort -Vr | head -n2)
    versions+=("$current")
    while IFS= read -r package; do
        for version in "${versions[@]}"; do
            if [[ "$package" == *"$version"* ]]; then protect+=("$package"); break; fi
        done
    done < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-*' 'linux-modules-*' 'linux-headers-*' 2>/dev/null |
        awk '$1 == "installed" {print $2}')
    [[ ${#protect[@]} -gt 0 ]] || { zero_error '未能确认保留的内核包，已取消'; return 1; }
    # Use a private copy of APT auto flags: preview/cancel must not change package state.
    work=$(mktemp -d /tmp/zero-apt-preview.XXXXXX) || return 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM HUP
    if [[ -f /var/lib/apt/extended_states ]]; then
        cp /var/lib/apt/extended_states "$work/extended_states" || return 1
    else
        : > "$work/extended_states"
    fi
    apt-mark -o "Dir::State::extended_states=$work/extended_states" manual "${protect[@]}" || return 1
    simulation=$(apt-get -o "Dir::State::extended_states=$work/extended_states" -s autoremove --purge) || return 1
    printf '%s\n' "$simulation"
    mapfile -t proposed < <(printf '%s\n' "$simulation" | awk '$1 == "Remv" || $1 == "Purg" {print $2}')
    [[ ${#proposed[@]} -gt 0 ]] || { echo '没有可自动移除的软件包'; return 0; }
    for package in "${proposed[@]}"; do
        [[ "$package" != *"$current"* ]] || { zero_error '预览包含当前内核，已拒绝清理'; return 1; }
    done
    zero_confirm '确认仅删除上述预览的软件包？' || return 0
    apt-get -o DPkg::Lock::Timeout=60 purge -y "${proposed[@]}"
)

linux_clean() {
    local choice
    while true; do
        clear
        echo '系统清理'
        echo '1. 常规清理（APT 下载缓存、14 天前归档日志）'
        echo '2. 软件包自动清理（先预览，保护当前及最新两个内核）'
        echo '3. Docker 未使用资源清理（保留卷）'
        echo '4. Docker 未使用匿名卷清理（可能包含数据）'
        echo '0. 返回'
        choice=$(read_menu_choice '请选择: ') || return
        case "$choice" in
            1)
                if pkg_clean && journalctl --vacuum-time=14d; then
                    echo '常规清理完成'
                else
                    zero_error '部分清理失败，请查看上方错误'
                fi
                ;;
            2) zero_clean_packages ;;
            3|4)
                command -v docker >/dev/null 2>&1 || { zero_error '未安装 Docker'; continue; }
                docker system df || continue
                if [[ "$choice" == 3 ]]; then
                    zero_confirm '清理停止的容器、未使用镜像、网络及构建缓存？' && docker system prune -af
                else
                    zero_confirm '删除未被容器引用的匿名卷及其中数据？' && docker volume prune -f
                fi
                ;;
            0) return ;;
            *) show_invalid_option; continue ;;
        esac
        press_any_key_to_continue
    done
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
    pkg_install xz-utils openssl gawk file wget cpio gzip iproute2 util-linux ca-certificates
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
    local source parent
    source=$(findmnt -n -o SOURCE /) || return 1
    [[ "$source" == /dev/* ]] || return 1
    source=$(readlink -f "$source") || return 1
    # Ambiguous RAID/LVM/multi-device roots are deliberately not guessed.
    parent=$(lsblk -ndo PKNAME "$source") || return 1
    if [[ -n "$parent" && "$parent" != *$'\n'* && "$(lsblk -ndo TYPE "/dev/$parent")" == disk ]]; then
        printf '/dev/%s\n' "$parent"
    elif [[ "$(lsblk -ndo TYPE "$source")" == disk ]]; then
        printf '%s\n' "$source"
    else
        zero_error '无法唯一确定系统物理磁盘（可能是 LVM/RAID），已停止自动重装'
        return 1
    fi
}





reinstall_validate_grub_config() {
    command -v grub-script-check >/dev/null 2>&1 || { zero_error '缺少 grub-script-check'; return 1; }
    grub-script-check "$1"
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

    cat > "${REINSTALL_BOOT_DIR}/post-install.sh" <<EOF
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
    chmod 700 "${REINSTALL_BOOT_DIR}/post-install.sh"
}

reinstall_install_target_system() (
    local debian_version="$1" dist mirror target_disk stable_disk='' candidate boot_uuid boot_prefix
    local work backup committed=0 hash boot_fstype entry_id=zero-reinstall
    case "$debian_version" in 11) dist=bullseye ;; 12) dist=bookworm ;; 13) dist=trixie ;; *) exit 1 ;; esac
    for candidate in ip wget cpio gzip openssl findmnt lsblk readlink grub-probe grub-reboot grub-editenv update-grub grub-script-check sha256sum; do
        command -v "$candidate" >/dev/null 2>&1 || { zero_error "缺少依赖: $candidate"; exit 1; }
    done
    target_disk=$(reinstall_get_target_disk) || exit 1
    [[ "$target_disk" == "${REINSTALL_TARGET_DISK:-}" ]] || { zero_error '目标磁盘在确认后发生变化'; exit 1; }
    for candidate in /dev/disk/by-id/*; do
        [[ -L "$candidate" && "$candidate" != *-part[0-9]* ]] || continue
        [[ "$(readlink -f "$candidate")" == "$target_disk" ]] && { stable_disk="$candidate"; break; }
    done
    [[ -n "$stable_disk" ]] || { zero_error '磁盘没有稳定的 by-id 标识，无法确保安装环境选中同一磁盘'; exit 1; }
    [[ "$stable_disk" =~ ^/dev/disk/by-id/[A-Za-z0-9._:+-]+$ ]] || exit 1
    boot_fstype=$(findmnt -n -o FSTYPE -T /boot)
    case "$boot_fstype" in ext2|ext3|ext4|xfs) ;; *) zero_error "暂不自动重装 /boot 文件系统 $boot_fstype"; exit 1 ;; esac
    [[ -f /boot/grub/grub.cfg && -f /boot/grub/grubenv ]] || { zero_error '需要标准 GRUB2 配置和环境块'; exit 1; }
    # Check that GRUB environment storage is accessible before modifying boot files.
    grub-editenv /boot/grub/grubenv list >/dev/null || exit 1
    reinstall_gather_network_state
    mirror=$(reinstall_select_debian_mirror "$dist") || exit 1
    boot_uuid=$(grub-probe --target=fs_uuid /boot) || exit 1
    [[ "$boot_uuid" =~ ^[A-Za-z0-9-]+$ ]] || exit 1
    if [[ "$(findmnt -n -o TARGET -T /boot)" == /boot ]]; then boot_prefix=/zero-reinstall
    else boot_prefix=/boot/zero-reinstall; fi
    work=$(mktemp -d /tmp/zero-reinstall.XXXXXX) || exit 1
    backup=$(mktemp -d /root/zero-reinstall-backup.XXXXXX) || { rm -rf "$work"; exit 1; }
    zero_snapshot_paths "$backup" /etc/grub.d/99_zero_reinstall /boot/zero-reinstall /boot/grub/grub.cfg /boot/grub/grubenv || exit 1
    trap 'rm -rf "$work"; if (( committed == 0 )); then
        if zero_restore_paths "$backup"; then rm -rf "$backup"; else zero_error "启动配置恢复失败，备份: $backup"; fi
    fi' EXIT
    trap 'exit 130' INT TERM HUP
    local base="$mirror/dists/$dist/main/installer-amd64/current/images"
    wget -q --timeout=30 --tries=3 "$base/SHA256SUMS" -O "$work/SHA256SUMS" || exit 1
    for candidate in initrd.gz linux; do
        local relative="netboot/debian-installer/amd64/$candidate" expected
        wget -q --timeout=30 --tries=3 "$base/$relative" -O "$work/$candidate" || exit 1
        expected=$(awk -v file="$relative" '{name=$2; sub(/^\*/, "", name); sub(/^\.\//,"",name); if(name==file) print $1}' "$work/SHA256SUMS")
        [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "$(sha256sum "$work/$candidate" | cut -d' ' -f1)" == "$expected" ]] || {
            zero_error "$candidate 摘要校验失败"; exit 1;
        }
    done
    mkdir "$work/initrd" || exit 1
    (set -o pipefail; cd "$work/initrd" && gzip -dc "$work/initrd.gz" | cpio -id --no-absolute-filenames) || exit 1
    hash=$(printf '%s\n' "$REINSTALL_ROOT_PASSWORD" | openssl passwd -6 -stdin) || exit 1
    unset REINSTALL_ROOT_PASSWORD
    # This helper writes into the per-run staging tree only.
    REINSTALL_BOOT_DIR="$work/initrd"
    reinstall_write_post_install_script || exit 1
    local mirror_host="${mirror#https://}"
    mirror_host="${mirror_host%%/*}"
    cat > "$work/initrd/preseed.cfg" <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string ${REINSTALL_IPV4_ADDR}
d-i netcfg/get_netmask string ${REINSTALL_IPV4_MASK}
d-i netcfg/get_gateway string ${REINSTALL_IPV4_GATE}
d-i netcfg/get_nameservers string ${REINSTALL_DNS_LIST}
d-i netcfg/confirm_static boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string ${mirror_host}
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password ${hash}
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i partman-auto/disk string /dev/zero-no-matching-disk
d-i grub-installer/bootdev string /dev/zero-no-matching-disk
d-i partman/early_command string disk=\$(readlink -f '${stable_disk}'); test -b "\$disk" && debconf-set partman-auto/disk "\$disk" && debconf-set grub-installer/bootdev "\$disk"
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server isc-dhcp-client ifupdown
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string cp /post-install.sh /target/root/reinstall-post.sh && in-target /bin/sh /root/reinstall-post.sh && rm /target/root/reinstall-post.sh
EOF
    (set -o pipefail; cd "$work/initrd" && find . -print0 | cpio --null -o -H newc | gzip -9 > "$work/initrd.ready") || exit 1
    gzip -t "$work/initrd.ready" || exit 1
    install -d -m 700 /boot/zero-reinstall || exit 1
    install -m 600 "$work/initrd.ready" /boot/zero-reinstall/initrd.img &&
        install -m 600 "$work/linux" /boot/zero-reinstall/vmlinuz || exit 1
    cat > "$work/grub-entry" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'Zero Debian ${debian_version} installer' --id '${entry_id}' {
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    linux ${boot_prefix}/vmlinuz auto=true priority=critical hostname=debian domain= quiet
    initrd ${boot_prefix}/initrd.img
}
EOF
    zero_atomic_install "$work/grub-entry" /etc/grub.d/99_zero_reinstall 755 || exit 1
    update-grub && reinstall_validate_grub_config /boot/grub/grub.cfg || exit 1
    grep -q next_entry /boot/grub/grub.cfg || { zero_error 'GRUB 未提供一次性启动支持'; exit 1; }
    echo "启动文件已校验，目标磁盘: $target_disk ($stable_disk)"
    zero_confirm '立即执行一次性启动并开始清空目标磁盘重装？' || exit 0
    grub-reboot "$entry_id" || exit 1
    systemctl reboot || exit 1
    committed=1
    echo "已提交重启请求；原启动配置备份: $backup"
)

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
    target_disk=$(reinstall_get_target_disk) || return 1
    REINSTALL_TARGET_DISK="$target_disk"

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
    local result=$?
    unset REINSTALL_ROOT_PASSWORD
    return "$result"
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
    local choice input_code zone_tab tz_idx sel_tz manual_tz detected_tz
    local sys_tz pause_after
    local -a lines=()

    if ! command -v timedatectl >/dev/null; then
        echo -e "${RED}未安装 timedatectl,无法自动设置时区${PLAIN}"
        press_any_key_to_continue
        return
    fi

    _timezone_is_valid() {
        local tz="$1"
        [[ -n "$tz" ]] || return 1
        timedatectl list-timezones 2>/dev/null | grep -Fxq -- "$tz"
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
            echo -e "${YELLOW}未安装 curl，无法自动检测时区${PLAIN}" >&2
            return 1
        fi

        tz=$(curl -A 'Zero.sh/2.4' -fsSL --connect-timeout 5 --max-time 8 \
            'https://ipwho.is/?fields=timezone.id' 2>/dev/null | jq -er '.timezone.id // empty')
        tz=$(trim_input "$tz")
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

    while true; do
        pause_after=0
        sys_tz=$(_timezone_get_system_tz)
        clear
        echo -e "${BLUE}======= 时区管理 =====${PLAIN}"
        echo -e "${YELLOW}当前 ${sys_tz}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}自动检测  ${GREEN}2.${PLAIN}国家代码"
        echo -e "${GREEN}3.${PLAIN}手动输入  ${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"
        
        choice=$(read_menu_choice "请输入选项 [0-3]: ")
        
        case "$choice" in
            1)
                echo -e "${YELLOW}正在检测时区...${PLAIN}"
                command -v jq >/dev/null 2>&1 || pkg_install jq || continue
                echo '检测的是服务器出口位置对应时区。'
                detected_tz=$(_timezone_detect_recommended || true)
                if [[ -n "$detected_tz" ]]; then
                    echo -e "${GREEN}检测结果: ${detected_tz}${PLAIN}"
                    _timezone_apply "$detected_tz"
                else
                    echo -e "${YELLOW}自动检测失败，请使用国家代码或手动输入${PLAIN}"
                fi
                pause_after=1
                ;;
            2)
                clear
                read -r -p "$(echo -e "${BLUE}请输入国家代码 (如 CN,US,JP): ${PLAIN}")" input_code
                input_code=$(trim_input "$input_code")
                input_code=$(printf '%s' "$input_code" | tr '[:lower:]' '[:upper:]')
                [ -z "$input_code" ] && continue
                if [[ ! "$input_code" =~ ^[A-Z]{2}$ ]]; then
                    echo -e "${RED}国家代码必须是两个英文字母${PLAIN}"
                    press_any_key_to_continue
                    continue
                fi

                zone_tab=$(_timezone_get_zone_tab || true)
                if [ -z "$zone_tab" ]; then
                    echo -e "${RED}系统缺失时区索引文件 (zone1970.tab/zone.tab)，无法自动列表。${PLAIN}"
                    pause_after=1
                else
                    lines=()
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
                    if zero_valid_uint "$tz_idx" 1 "${#lines[@]}"; then
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
    local gai_conf="/etc/gai.conf"
    local backup_conf="/etc/gai.conf.zero.bak"
    local managed_begin="# Zero.sh IP Priority BEGIN"
    local managed_end="# Zero.sh IP Priority END"
    local choice current_priority

    _priority_rule_exists() {
        local precedence_value="$1"
        [[ -f "$gai_conf" ]] || return 1
        sed -n "/^${managed_begin}$/,/^${managed_end}$/p" "$gai_conf" |
            grep -qE "^precedence[[:space:]]+::ffff:0:0/96[[:space:]]+${precedence_value}[[:space:]]*$"
    }

    _managed_priority_exists() {
        [[ -f "$gai_conf" ]] && grep -Fxq -- "$managed_begin" "$gai_conf"
    }

    _unmanaged_priority_exists() {
        [[ -f "$gai_conf" ]] || return 1
        awk -v begin="$managed_begin" -v end="$managed_end" '
            $0 == begin { managed = 1; next }
            $0 == end   { managed = 0; next }
            !managed && $0 ~ /^[[:space:]]*precedence[[:space:]]+/ { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "$gai_conf"
    }

    _get_current_priority() {
        if _priority_rule_exists 100; then
            echo "IPv4 优先"
        elif _priority_rule_exists 10; then
            echo "IPv6 优先"
        elif _managed_priority_exists; then
            echo "Zero.sh 自定义"
        elif _unmanaged_priority_exists; then
            echo "用户自定义"
        else
            echo "IPv6 优先（系统默认）"
        fi
    }

    _write_priority_config() {
        local mode="$1"
        local temp_file ipv4_precedence

        temp_file=$(mktemp /etc/gai.conf.zero.XXXXXX) || return 1
        if [[ -f "$gai_conf" ]]; then
            cp -p "$gai_conf" "$backup_conf" || {
                rm -f "$temp_file"
                return 1
            }
            if ! awk -v begin="$managed_begin" -v end="$managed_end" '
                $0 == begin { managed = 1; next }
                $0 == end   { managed = 0; next }
                !managed    { print }
                END         { if (managed) exit 1 }
            ' "$gai_conf" > "$temp_file"; then
                rm -f "$temp_file"
                echo -e "${RED}检测到不完整的 Zero.sh 配置块，未修改 ${gai_conf}${PLAIN}"
                return 1
            fi
        else
            : > "$temp_file"
        fi

        case "$mode" in
            ipv4) ipv4_precedence=100 ;;
            ipv6) ipv4_precedence=10 ;;
            default) ipv4_precedence="" ;;
            *)
                rm -f "$temp_file"
                return 1
                ;;
        esac

        if [[ -n "$ipv4_precedence" ]]; then
            if ! {
                echo
                echo "$managed_begin"
                echo "precedence ::1/128 50"
                echo "precedence ::/0 40"
                echo "precedence 2002::/16 30"
                echo "precedence ::/96 20"
                echo "precedence ::ffff:0:0/96 ${ipv4_precedence}"
                echo "$managed_end"
            } >> "$temp_file"; then
                rm -f "$temp_file"
                return 1
            fi
        fi

        chmod 644 "$temp_file" || {
            rm -f "$temp_file"
            return 1
        }
        if ! mv -f "$temp_file" "$gai_conf"; then
            rm -f "$temp_file"
            return 1
        fi
    }

    _apply_priority_mode() {
        local mode="$1"
        local label="$2"

        if [[ "$mode" == "default" ]] && ! _managed_priority_exists; then
            if _unmanaged_priority_exists; then
                echo -e "${YELLOW}当前由用户自定义规则管理，Zero.sh 没有可移除的配置${PLAIN}"
            else
                echo -e "${GREEN}当前已是 IPv6 优先（系统默认）${PLAIN}"
            fi
            press_any_key_to_continue
            return 0
        fi

        if [[ "$mode" != default ]] && _unmanaged_priority_exists; then
            zero_error '存在用户自定义 precedence 规则；请先处理冲突，再设置优先级'
            press_any_key_to_continue
            return 1
        fi
        if _write_priority_config "$mode"; then
            if [[ "$mode" == "default" ]] && _unmanaged_priority_exists; then
                echo -e "${GREEN}✔ 已移除 Zero.sh 设置，保留用户自定义规则${PLAIN}"
            else
                echo -e "${GREEN}✔ 已设置为 ${label}${PLAIN}"
            fi
            [[ -f "$backup_conf" ]] && echo -e "${YELLOW}备份: ${backup_conf}${PLAIN}"
        else
            echo -e "${RED}✘ IP 连接优先级设置失败${PLAIN}"
        fi
        press_any_key_to_continue
    }

    while true; do
        clear
        current_priority=$(_get_current_priority)
        echo -e "${BLUE}=== IP连接优先级 ===${PLAIN}"
        echo '作用于使用 glibc 地址排序的程序；应用自有 DNS/连接策略可能不跟随。' 
        echo -e "${YELLOW}当前优先级: ${GREEN}${current_priority}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}IPv4 优先"
        echo -e "${GREEN}2.${PLAIN}IPv6 优先"
        echo -e "${GREEN}3.${PLAIN}移除本脚本设置"
        echo -e "${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"
        read -rp "$(echo -e "${BLUE}请输入选项 [0-3]: ${PLAIN}")" choice

        case "$choice" in
            1)
                _apply_priority_mode "ipv4" "IPv4 优先"
                ;;
            2)
                _apply_priority_mode "ipv6" "IPv6 优先"
                ;;
            3)
                _apply_priority_mode "default" "IPv6 优先（系统默认）"
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

bbr_get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

bbr_get_speedtest_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

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
    local package command_name missing=()
    for package in "$@"; do
        command_name="$package"
        case "$package" in gnupg) command_name=gpg ;; ca-certificates) command_name=update-ca-certificates ;; esac
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$package")
    done
    (( ${#missing[@]} == 0 )) || pkg_install "${missing[@]}"
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
        set_swap "$target_swapfile" || return 1
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
    local speedtest_arch="$1" page_content download_url
    page_content=$(bbr_fetch_text_url "https://speedtest-static-dev.speedtest.dev/apps/cli") || return 1
    download_url=$(printf '%s\n' "$page_content" | grep -Eo "https://install\\.speedtest\\.net/app/cli/ookla-speedtest-[0-9.]+-linux-${speedtest_arch}\\.tgz" | head -n 1)
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
    local cpu_arch speedtest_arch download_url
    cpu_arch=$(uname -m)
    speedtest_arch=$(bbr_get_speedtest_arch) || {
        echo -e "${RED}错误: 不支持的架构 ${cpu_arch}${PLAIN}" >&2
        return 1
    }

    if command -v speedtest >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}speedtest 未安装，正在临时安装...${PLAIN}" >&2
    download_url=$(bbr_get_speedtest_download_url "$speedtest_arch" 2>/dev/null || true)
    if [[ -z "$download_url" ]]; then
        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${speedtest_arch}.tgz"
    fi

    bbr_install_speedtest_from_url "$download_url" || return 1
}

bbr_detect_bandwidth() {
    echo -e "${BLUE}======== BBR调优 ========${PLAIN}" >&2
    echo -e "${GREEN}1.${PLAIN}自动检测    ${GREEN}2.${PLAIN}预设档位" >&2
    echo -e "${GREEN}3.${PLAIN}恢复网络    ${YELLOW}0.${PLAIN}返回上级" >&2
    echo -e "${BLUE}==========================${PLAIN}" >&2
    bw_choice=$(read_menu_choice "请输入选项 [0-3]: ")
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        0)
            return 2
            ;;
        1)
            echo -e "${YELLOW}正在运行 speedtest 自动测速...${PLAIN}" >&2
            bbr_ensure_speedtest >/dev/null 2>&1 || {
                echo -e "${YELLOW}测速工具安装失败，请返回后选择手动带宽${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                echo ""
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
                echo -e "${YELLOW}测速失败，请返回后选择手动带宽${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                echo ""
                return 1
            fi

            upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || (( upload_mbps <= 0 )); then
                echo -e "${YELLOW}检测值异常 (${upload_speed})，请返回后选择手动带宽${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                echo ""
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
                6) echo "" ;;
                7) echo 1500 ;;
                8) echo 2000 ;;
                9) echo 2500 ;;
                10)
                    read -r -p "请输入带宽值（Mbps）: " manual_bandwidth
                    manual_bandwidth=$(trim_input "$manual_bandwidth")
                    if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && (( manual_bandwidth > 0 )); then
                        echo "$manual_bandwidth"
                    else
                        echo ""
                        return 1
                    fi
                    ;;
                *) echo ""; return 1 ;;
            esac
            ;;
        3)
            return 3
            ;;
        *)
            echo ""
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
    local bandwidth="$1" region="${2:-asia}" profile="${3:-balanced}" memory="${4:-0}"
    local rtt default_rtt=80 size cap factor=2 answer
    [[ "$region" == overseas ]] && default_rtt=180
    zero_valid_uint "$bandwidth" 1 100000 || return 1
    read -r -p "实际业务路径 RTT（毫秒，经验默认 ${default_rtt}）: " rtt || return 1
    rtt="${rtt:-$default_rtt}"
    zero_valid_uint "$rtt" 1 2000 || { zero_error 'RTT 必须为 1-2000 的十进制整数'; return 1; }
    [[ "$profile" == download ]] && factor=3
    size=$(((bandwidth * rtt * factor + 7999) / 8000))
    (( size < 4 )) && size=4
    cap=$(bbr_buffer_memory_cap_mb "$memory" "$profile")
    (( size > cap )) && size="$cap"
    echo "经验缓冲上限: $size MiB（按带宽×RTT计算；这是每 socket 上限，不是总内存预算）" >&2
    read -r -p "缓冲上限 MiB（回车采用 ${size}，最大 ${cap}）: " answer || return 1
    answer="${answer:-$size}"
    zero_valid_uint "$answer" 1 "$cap" || { zero_error '缓冲区大小无效'; return 1; }
    printf '%s\n' "$answer"
}

bbr_check_conflicts() {
    echo -e "${BLUE}=== 检查 sysctl 配置冲突 ===${PLAIN}"
    local conflicts=()
    local conf
    local tune_key_regex='net\.(core\.(rmem_max|wmem_max|default_qdisc|somaxconn|netdev_max_backlog)|ipv4\.(ip_local_port_range|udp_(rmem_min|wmem_min)|tcp_(rmem|wmem|congestion_control|tw_reuse|max_syn_backlog|slow_start_after_idle|mtu_probing|notsent_lowat|fin_timeout|max_tw_buckets|fastopen|keepalive_time|keepalive_intvl|keepalive_probes|syncookies)))'
    local active_tune_regex="^[[:space:]]*${tune_key_regex}[[:space:]]*="

    for conf in /etc/sysctl.d/*.conf; do
        [[ -f "$conf" ]] || continue
        [[ "$conf" == "$BBR_SYSCTL_CONF" ]] && continue
        if grep -qE "$active_tune_regex" "$conf" 2>/dev/null; then
            conflicts+=("$conf")
        fi
    done

    local has_sysctl_conflict=0
    if [[ -f /etc/sysctl.conf ]] && grep -qE "$active_tune_regex" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [[ "${#conflicts[@]}" -eq 0 && "$has_sysctl_conflict" -eq 0 ]]; then
        echo -e "${GREEN}✓ 未发现可能的覆盖配置${PLAIN}"
        return 0
    fi

    echo -e "${YELLOW}发现可能重复的网络参数，Zero.sh 不会修改这些文件:${PLAIN}"
    if [[ "${#conflicts[@]}" -gt 0 ]]; then
        printf '  - %s\n' "${conflicts[@]}"
    fi
    [[ "$has_sysctl_conflict" -eq 1 ]] && echo "  - /etc/sysctl.conf"
    echo -e "${YELLOW}若有同名参数，实际生效值以 sysctl 加载顺序为准${PLAIN}"
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
    echo '已保留现有网卡根队列；default_qdisc 将用于后续创建的适用队列。'
    command -v tc >/dev/null 2>&1 && tc qdisc show || true
}

bbr_apply_mss_clamp() {
    local action="$1" cmd
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        while "$cmd" -w 3 -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment zero-bbr-mss -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
            "$cmd" -w 3 -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment zero-bbr-mss -j TCPMSS --clamp-mss-to-pmtu || return 1
        done
        [[ "$action" == enable ]] && "$cmd" -w 3 -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment zero-bbr-mss -j TCPMSS --clamp-mss-to-pmtu
    done
    return 0
}

bbr_cleanup_persist() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$BBR_PERSIST_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$BBR_PERSIST_SERVICE" "$BBR_PERSIST_SCRIPT"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

bbr_configure_direct() (
    local bandwidth result region=asia profile=balanced choice memory buffer bytes key current
    local work committed=0 baseline=/var/lib/zero/bbr.original.sysctl
    bandwidth=$(bbr_detect_bandwidth); result=$?
    case "$result" in 2) exit 0 ;; 3) bbr_restore_original_network_config; exit $? ;; 0) ;; *) zero_error '带宽检测失败，请手动选择带宽'; press_any_key_to_continue; exit 1 ;; esac
    zero_valid_uint "$bandwidth" 1 100000 || exit 1
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || {
        zero_error '当前内核不提供 BBR，请先安装支持的内核并重启'; press_any_key_to_continue; exit 1;
    }
    read -r -p '路径地区：1 亚太 / 2 欧美 [1]: ' choice || exit 1
    [[ "$choice" == 2 ]] && region=overseas
    read -r -p '经验预设：1 均衡 / 2 下载 [1]: ' choice || exit 1
    [[ "$choice" == 2 ]] && profile=download
    memory=$(free -m | awk '/Mem:/ {print $2}')
    buffer=$(bbr_calculate_buffer_size "$bandwidth" "$region" "$profile" "$memory") || exit 1
    bytes=$((buffer * 1024 * 1024))
    bbr_check_conflicts
    work=$(mktemp -d /tmp/zero-bbr.XXXXXX) || exit 1
    zero_snapshot_paths "$work" "$BBR_SYSCTL_CONF" || { rm -rf "$work"; exit 1; }
    for key in net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
        current=$(sysctl -n "$key") || { rm -rf "$work"; exit 1; }
        printf '%s = %s\n' "$key" "$current" >> "$work/runtime.before"
    done
    trap 'if (( committed == 0 )); then
        if zero_restore_paths "$work" && sysctl -p "$work/runtime.before"; then rm -rf "$work"
        else zero_error "BBR 回滚失败，备份保留: $work"; fi
    else rm -rf "$work"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    install -d -m 700 /var/lib/zero || exit 1
    [[ -f "$baseline" ]] || zero_atomic_install "$work/runtime.before" "$baseline" 600 || exit 1
    cat > "$work/candidate" <<EOF
# Managed by Zero.sh; empirical per-socket limits, not a throughput guarantee.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=$bytes
net.core.wmem_max=$bytes
net.ipv4.tcp_rmem=4096 131072 $bytes
net.ipv4.tcp_wmem=4096 65536 $bytes
EOF
    zero_atomic_install "$work/candidate" "$BBR_SYSCTL_CONF" 644 && sysctl -p "$BBR_SYSCTL_CONF" || exit 1
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || exit 1
    bbr_cleanup_persist
    bbr_apply_tc_fq_now
    committed=1
    echo "BBR 已验证；TCP 缓冲上限 $buffer MiB。恢复基线: $baseline"
    echo 'TCP 参数不直接设置 TUIC/Hysteria2 的用户态 QUIC 拥塞控制。'
    press_any_key_to_continue
)

bbr_install_xanmod_kernel() {
    local action_label="安装"
    bbr_xanmod_installed && action_label="更新"

    if [[ "$(bbr_get_arch 2>/dev/null || true)" != "amd64" ]]; then
        bbr_fail_and_pause "错误: XanMod 官方仓库仅提供 amd64/x86_64 内核，ARM64 请直接使用原生内核进行 BBR 调优"
        return 1
    fi

    echo -e "${BLUE}=== ${action_label} XanMod 内核与 BBR v3 ===${PLAIN}"
    echo "支持系统: Debian/Ubuntu (x86_64)"
    echo -e "${YELLOW}警告: 将升级 Linux 内核，请提前备份重要数据${PLAIN}"
    if ! bbr_confirm "确定继续${action_label}吗？(Y/N): "; then
        echo "已取消${action_label}"
        press_any_key_to_continue
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

    local package_info package_status

    package_info=$(bbr_select_xanmod_package "$version") || {
        bbr_fail_and_pause "错误: 当前仓库中未找到适配 x64v${version} 的 XanMod 内核包"
        return 1
    }

    package_name="${package_info%%|*}"
    package_hint="${package_info#*|}"

    echo -e "${GREEN}目标通道: ${package_name}${PLAIN}"
    echo -e "${YELLOW}说明: ${package_hint}${PLAIN}"
    echo -e "${YELLOW}安装元包: ${package_name}${PLAIN}"

    if ! apt-get install -y "$package_name"; then
        bbr_fail_and_pause "XanMod 内核安装失败"
        return 1
    fi

    package_status=$(dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null || true)
    if [[ "$package_status" != "install ok installed" ]] || ! bbr_xanmod_installed; then
        bbr_fail_and_pause "未检测到 XanMod 内核安装成功"
        return 1
    fi

    echo -e "${GREEN}XanMod 内核${action_label}成功${PLAIN}"
    echo -e "${YELLOW}提示: 请先重启系统加载新内核，然后再进行 BBR 调优${PLAIN}"
    press_any_key_to_continue
}

bbr_uninstall_xanmod_kernel() {
    if [[ "$(bbr_get_arch 2>/dev/null || true)" == "arm64" ]]; then
        bbr_fail_and_pause "提示: ARM64 不使用 XanMod，无需执行卸载"
        return 1
    fi

    if uname -r | grep -qi xanmod; then
        bbr_fail_and_pause '当前正运行 XanMod，请先重启进入其他内核后再卸载'; return 1
    fi
    echo -e "${YELLOW}警告: 即将卸载 XanMod 内核${PLAIN}"
    local non_xanmod_kernels
    non_xanmod_kernels=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' ! -iname '*xanmod*' | wc -l)
    if [[ "$non_xanmod_kernels" -eq 0 ]]; then
        local default_kernel_package="linux-image-amd64"
        [[ "$(bbr_get_arch 2>/dev/null || true)" == "arm64" ]] && default_kernel_package="linux-image-arm64"
        echo -e "${RED}安全检查未通过：未检测到非 XanMod 的回退内核${PLAIN}"
        echo "建议先安装默认内核:"
        echo "  apt install -y ${default_kernel_package}   # Debian"
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
        echo "BBR 网络参数已保留；如需还原，请使用菜单中的恢复网络参数。"
        bbr_cleanup_managed_speedtest
        echo -e "${GREEN}XanMod 内核已卸载${PLAIN}"
        bbr_prompt_reboot
    else
        echo "已取消"
    fi
    press_any_key_to_continue
}

bbr_restore_original_network_config() {
    local baseline=/var/lib/zero/bbr.original.sysctl
    [[ -s "$baseline" ]] || { zero_error '没有原始运行参数备份；旧版配置无法自动推断原值，请人工处理'; press_any_key_to_continue; return 1; }
    zero_confirm '恢复首次使用此版本前记录的网络参数？' || return 0
    sysctl -p "$baseline" || { zero_error '恢复部分失败，已保留配置和基线'; return 1; }
    rm -f "$BBR_SYSCTL_CONF" /etc/sysctl.d/99-zero-bbr.conf || return 1
    bbr_apply_mss_clamp disable
    bbr_cleanup_persist
    bbr_cleanup_managed_speedtest
    echo '已恢复记录的运行参数并移除脚本持久化配置；其他文件的同名参数仍可能在重启时覆盖。'
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

    if [[ "$(bbr_get_arch 2>/dev/null || true)" == "arm64" ]]; then
        xanmod_state="${YELLOW}ARM64不适用${PLAIN}"
    elif [[ "$xanmod_installed" == "yes" ]]; then
        xanmod_state="${GREEN}已安装${PLAIN}"
    else
        xanmod_state="${YELLOW}未安装${PLAIN}"
    fi

    echo -e "${BLUE}内核: ${YELLOW}${current_kernel:-unknown}${PLAIN}"
    echo -e "${BLUE}状态: XanMod ${xanmod_state} | BBR ${GREEN}${cc:-unknown}${PLAIN} | 队列 ${GREEN}${qdisc:-unknown}${PLAIN}"
}

bbr_show_manage_menu() {
    local xanmod_action="安装XanMod"

    bbr_xanmod_installed && xanmod_action="更新XanMod"
    clear
    echo -e "${BLUE}=========== BBR ===========${PLAIN}"
    bbr_menu_status_line
    echo -e "${BLUE}===========================${PLAIN}"
    if [[ "$(bbr_get_arch 2>/dev/null || true)" != "arm64" ]]; then
        echo -e "${GREEN}1.BBR调优${PLAIN}         ${GREEN}2.${xanmod_action}${PLAIN}"
        echo -e "${RED}3.卸载XanMod${PLAIN}      ${YELLOW}0.返回菜单${PLAIN}"
    else
        echo -e "${GREEN}1.BBR调优${PLAIN}         ${YELLOW}0.返回菜单${PLAIN}"
    fi
    echo -e "${BLUE}===========================${PLAIN}"
}

handle_bbr_manage_choice() {
    case "$1" in
        1) clear; bbr_configure_direct ;;
        2) clear; bbr_install_xanmod_kernel ;;
        3) clear; bbr_uninstall_xanmod_kernel ;;
        0) return 1 ;;
        *) show_invalid_option ;;
    esac

    return 0
}

bbr_manage_menu() {
    local opt
    while true; do
        bbr_show_manage_menu
        if [[ "$(bbr_get_arch 2>/dev/null || true)" == "arm64" ]]; then
            opt=$(read_menu_choice "请输入选项 [0-1]: ")
        else
            opt=$(read_menu_choice "请输入选项 [0-3]: ")
        fi
        handle_bbr_manage_choice "$opt" || return
    done
}

DNS_RESOLV_CONF="/etc/resolv.conf"
DNS_RESOLV_BACKUP="/etc/resolv.conf.zero.bak"
DNS_RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
DNS_RESOLVED_DROPIN_FILE="$DNS_RESOLVED_DROPIN_DIR/90-zero-dns.conf"
DNS_RESOLVED_LEGACY_FILE="$DNS_RESOLVED_DROPIN_DIR/99-custom-dns.conf"

dns_read_runtime_status() {
    local active="0" iface="" dns_list=""

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        active="1"
        iface="$(get_default_interface)"
        if command -v resolvectl >/dev/null 2>&1; then
            dns_list="$(resolvectl dns 2>/dev/null | awk -F':[[:space:]]+' '
                NF > 1 {
                    count = split($2, server, /[[:space:]]+/)
                    for (i = 1; i <= count; i++)
                        if (server[i] != "" && server[i] != "(none)" && !seen[server[i]]++) print server[i]
                }
            ')"
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
            [[ "$dns" =~ ^[[:space:]]*nameserver[[:space:]]+ ]] || continue
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
        else
            echo -e "  (未检测到默认网卡)"
        fi
        if [[ -n "$dns_list" ]]; then
            echo -e "  可见 DNS Servers:"
            while read -r dns; do
                echo -e "    ${GREEN}- ${dns}${PLAIN}"
            done <<< "$dns_list"
        else
            echo -e "  (未检测到 systemd-resolved DNS)"
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
        [[ "$o" == "0" || "$o" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

dns_is_valid_ipv6() {
    local ip="$1" address zone=""

    [[ "$ip" == *:* ]] || return 1
    if [[ "$ip" == *%* ]]; then
        [[ "$ip" != *%*%* ]] || return 1
        address="${ip%%%*}"
        zone="${ip#*%}"
        [[ "$zone" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    else
        address="$ip"
    fi

    command -v perl >/dev/null 2>&1 || return 1
    perl -MSocket=AF_INET6,inet_pton -e 'exit(inet_pton(AF_INET6, $ARGV[0]) ? 0 : 1)' "$address" >/dev/null 2>&1
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

dns_apply_resolved() {
    local temp_file backup_file="" had_previous=0

    if [[ -e "$DNS_RESOLVED_LEGACY_FILE" ]]; then
        echo -e "${RED}检测到旧 DNS 配置: ${DNS_RESOLVED_LEGACY_FILE}${PLAIN}"
        echo -e "${YELLOW}为避免覆盖来源不明的配置，请先手动确认或移除该文件${PLAIN}"
        return 1
    fi

    mkdir -p "$DNS_RESOLVED_DROPIN_DIR" || return 1
    temp_file=$(mktemp "$DNS_RESOLVED_DROPIN_DIR/.90-zero-dns.XXXXXX") || return 1

    if [[ -f "$DNS_RESOLVED_DROPIN_FILE" ]]; then
        backup_file=$(mktemp "$DNS_RESOLVED_DROPIN_DIR/.90-zero-dns.backup.XXXXXX") || {
            rm -f "$temp_file"
            return 1
        }
        cp -p "$DNS_RESOLVED_DROPIN_FILE" "$backup_file" || {
            rm -f "$temp_file" "$backup_file"
            return 1
        }
        had_previous=1
    fi

    {
        echo "# Managed by Zero.sh"
        echo "[Resolve]"
        echo "DNS="
        printf 'DNS=%s\n' "$*"
        echo "Domains=~."
    } > "$temp_file" || {
        rm -f "$temp_file" "$backup_file"
        return 1
    }
    chmod 644 "$temp_file" || {
        rm -f "$temp_file" "$backup_file"
        return 1
    }
    mv -f "$temp_file" "$DNS_RESOLVED_DROPIN_FILE" || {
        rm -f "$temp_file" "$backup_file"
        return 1
    }

    if ! systemctl restart systemd-resolved 2>/dev/null || ! dns_systemd_resolved_active || ! zero_dns_probe; then
        if (( had_previous == 1 )); then
            mv -f "$backup_file" "$DNS_RESOLVED_DROPIN_FILE" 2>/dev/null || true
        else
            rm -f "$DNS_RESOLVED_DROPIN_FILE"
        fi
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
        echo -e "${RED}DNS 服务或解析验证失败，已尝试恢复原配置${PLAIN}"
        return 1
    fi

    [[ -n "$backup_file" ]] && rm -f "$backup_file"
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
    return 0
}

dns_apply_static() (
    local candidate backup dns committed=0
    [[ -f "$DNS_RESOLV_CONF" && ! -L "$DNS_RESOLV_CONF" ]] || { zero_error 'resolv.conf 不存在或由其他管理器接管'; exit 1; }
    if grep -Eiq 'generated by.*(NetworkManager|dhclient|resolvconf)|managed by.*(NetworkManager|dhclient)' "$DNS_RESOLV_CONF"; then
        zero_error 'resolv.conf 标记为动态管理，请使用网络管理器修改 DNS'; exit 1
    fi
    backup=$(mktemp -d /tmp/zero-dns.XXXXXX) || exit 1
    cp -p "$DNS_RESOLV_CONF" "$backup/before" || exit 1
    trap 'if (( committed == 0 )); then
        if zero_atomic_install "$backup/before" "$DNS_RESOLV_CONF" 644; then rm -rf "$backup"
        else zero_error "DNS 恢复失败，备份: $backup"; fi
    else rm -rf "$backup"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    [[ -f "$DNS_RESOLV_BACKUP" ]] || cp -p "$DNS_RESOLV_CONF" "$DNS_RESOLV_BACKUP" || exit 1
    candidate="$backup/candidate"
    awk '!/^[[:space:]]*nameserver[[:space:]]+/' "$DNS_RESOLV_CONF" > "$candidate" || exit 1
    for dns in "$@"; do printf 'nameserver %s\n' "$dns" >> "$candidate"; done
    zero_atomic_install "$candidate" "$DNS_RESOLV_CONF" 644 && zero_dns_probe || {
        zero_error 'DNS 解析验证失败，将恢复本次修改前的配置'; exit 1;
    }
    sha256sum "$DNS_RESOLV_CONF" | awk '{print $1}' > "${DNS_RESOLV_BACKUP}.last-sha256" || exit 1
    committed=1
)

dns_apply() {
    local dns_list=("$@")
    local ok=() bad=()
    local dns
    local -A seen=()

    for dns in "${dns_list[@]}"; do
        if dns_is_valid_ip "$dns"; then
            if [[ -z "${seen[$dns]+x}" ]]; then
                ok+=("$dns")
                seen["$dns"]=1
            fi
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
        dns_apply_resolved "${dns_list[@]}"
    else
        dns_apply_static "${dns_list[@]}"
    fi
}

dns_restore() (
    local work resolved_active=0 committed=0 actual expected
    [[ -f "$DNS_RESOLVED_DROPIN_FILE" || -f "$DNS_RESOLV_BACKUP" ]] || {
        echo '未找到 Zero.sh 创建的 DNS 配置或备份'; return 2;
    }
    if [[ -f "$DNS_RESOLV_BACKUP" ]]; then
        [[ ! -L "$DNS_RESOLV_CONF" ]] || { zero_error 'resolv.conf 已改为符号链接，请人工处理静态备份'; return 1; }
        if [[ -f "${DNS_RESOLV_BACKUP}.last-sha256" ]]; then
            actual=$(sha256sum "$DNS_RESOLV_CONF" | awk '{print $1}') || return 1
            expected=$(cat "${DNS_RESOLV_BACKUP}.last-sha256") || return 1
            [[ "$actual" == "$expected" ]] || { zero_error 'DNS 文件已被其他程序或用户修改，保留旧备份供人工恢复'; return 1; }
        fi
    fi
    work=$(mktemp -d /tmp/zero-dns-restore.XXXXXX) || return 1
    zero_snapshot_paths "$work" "$DNS_RESOLVED_DROPIN_FILE" "$DNS_RESOLV_CONF" \
        "$DNS_RESOLV_BACKUP" "${DNS_RESOLV_BACKUP}.last-sha256" || { rm -rf "$work"; return 1; }
    dns_systemd_resolved_active && resolved_active=1
    trap 'if (( committed == 0 )); then
        if zero_restore_paths "$work"; then
            if (( resolved_active )) && ! systemctl restart systemd-resolved; then
                zero_error "DNS 文件已恢复，但服务重启失败；备份: $work"
            else rm -rf "$work"; fi
        else zero_error "DNS 恢复失败；备份: $work"; fi
    else rm -rf "$work"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    rm -f "$DNS_RESOLVED_DROPIN_FILE" || return 1
    if [[ -f "$DNS_RESOLV_BACKUP" ]]; then
        zero_atomic_install "$DNS_RESOLV_BACKUP" "$DNS_RESOLV_CONF" 644 || return 1
    fi
    if (( resolved_active )); then
        systemctl restart systemd-resolved && dns_systemd_resolved_active || return 1
    fi
    zero_dns_probe || { zero_error '还原后的 DNS 解析失败，将退回本次操作前的配置'; return 1; }
    rm -f "$DNS_RESOLV_BACKUP" "${DNS_RESOLV_BACKUP}.last-sha256" || return 1
    committed=1
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
    return 0
)

dns_apply_with_feedback() {
    if dns_apply "$@"; then
        echo -e "${GREEN}DNS 配置已更新${PLAIN}"
    else
        echo -e "${RED}DNS修改失败${PLAIN}"
    fi
    press_any_key_to_continue
}

dns_restore_with_feedback() {
    local result

    dns_restore
    result=$?
    case "$result" in
        0) echo -e "${GREEN}DNS 已恢复${PLAIN}" ;;
        2) ;;
        *) echo -e "${RED}DNS 恢复失败${PLAIN}" ;;
    esac
    press_any_key_to_continue
}

dns_show_menu() {
    clear
    echo -e "${BLUE}======== DNS 配置工具 ========${PLAIN}\n"
    dns_show_current
    echo -e "${GREEN}1.${PLAIN}使用公共DNS ${GREEN}8.8.8.8${PLAIN} / ${GREEN}1.1.1.1${PLAIN}"
    echo -e "${GREEN}2.${PLAIN}自定义DNS"
    echo -e "${GREEN}3.${PLAIN}恢复原始DNS配置"
    echo -e "${YELLOW}0.${PLAIN}返回主菜单"
    echo -e "${BLUE}==============================${PLAIN}"
}

dns_read_custom_servers() {
    local dns=""

    echo -e "\n${YELLOW}请输入DNS(每行一个,空行结束):${PLAIN}" >&2
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
        3)
            dns_restore_with_feedback
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
        choice=$(read_menu_choice "请输入选项 [0-3]: ")
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

ssh_apply_options() (
    local expected_port="$1" old_port backup committed=0 option value effective
    shift
    old_port=$(ssh_get_current_port)
    backup=$(mktemp -d /tmp/zero-ssh.XXXXXX) || exit 1
    zero_snapshot_paths "$backup" "$SSHD_CONFIG" /etc/ssh/sshd_config.d \
        /etc/systemd/system/ssh.socket.d /etc/systemd/system/sshd.socket.d || { rm -rf "$backup"; exit 1; }
    trap 'if (( committed == 0 )); then
        if zero_restore_paths "$backup" && restart_sshd_safe "$old_port"; then
            zero_error "SSH 修改失败，已恢复原配置"; rm -rf "$backup"
        else zero_error "SSH 自动恢复失败，备份保留在 $backup"; fi
    else rm -rf "$backup"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    local -a options=("$@")
    while (( $# >= 2 )); do
        update_sshd_option "$1" "$2" || exit 1
        shift 2
    done
    sshd -t -f "$SSHD_CONFIG" || exit 1
    if [[ -n "$expected_port" ]]; then
        local port_count
        port_count=$(sshd -T -f "$SSHD_CONFIG" | awk '$1=="port" {n++} END {print n+0}')
        (( port_count == 1 )) || { zero_error '其他 Include 文件仍声明 SSH 端口，请人工处理'; exit 1; }
    fi
    set -- "${options[@]}"
    while (( $# >= 2 )); do
        option="$1"; value="$2"; shift 2
        effective=$(get_sshd_effective_option "$option") || exit 1
        [[ "$effective" == "$value" ]] || {
            zero_error "$option 实际为 ${effective}，可能受 Match/其他配置限制，已取消"; exit 1;
        }
    done
    restart_sshd_safe "$expected_port" || exit 1
    committed=1
)

ssh_has_local_root_key() {
    local configured file
    configured=$(get_sshd_effective_option AuthorizedKeysFile) || return 1
    file="${configured//%h/$ROOT_HOME}"
    file="${file//%u/root}"
    [[ "$file" == /* ]] || file="$ROOT_HOME/$file"
    [[ -s "$file" ]] && ssh-keygen -l -f "$file" >/dev/null 2>&1
}

change_ssh_port() {
    local old_port new_port
    old_port=$(ssh_get_current_port)
    echo "当前 SSH 端口: $old_port"
    read -r -p '新端口（1-65535，不带前导零；0 返回）: ' new_port || return
    [[ "$new_port" == 0 ]] && return
    zero_valid_uint "$new_port" 1 65535 || { zero_error '端口无效'; return 1; }
    [[ "$new_port" == "$old_port" ]] && return 0
    ssh_port_is_listening "$new_port" && { zero_error '新端口已被监听'; return 1; }
    firewall_can_change_ssh_port "$new_port" || { zero_error '请先在防火墙中放行新端口'; return 1; }
    echo '请确认云平台安全组也允许新端口，并保留当前 SSH 会话进行新连接测试。'
    if ssh_apply_options "$new_port" Port "$new_port"; then
        echo "SSH 端口已改为 $new_port"
    fi
    press_any_key_to_continue
}

enable_or_change_root_password() {
    zero_confirm '设置 root 密码并启用 root 密码登录？' || return
    passwd root || { zero_error '密码设置失败'; return 1; }
    if ssh_apply_options '' PermitRootLogin yes PasswordAuthentication yes; then
        echo 'root 密码及密码登录已设置'
    else
        zero_error 'root 密码已更改，但 SSH 配置未成功应用，请查看上方提示'
    fi
    press_any_key_to_continue
}

enable_root_key_login() (
    local directory="$ROOT_HOME/.ssh" authorized="$ROOT_HOME/.ssh/authorized_keys"
    local work choice public passphrase="" backup had_keys=0 committed=0
    work=$(mktemp -d /tmp/zero-key.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM HUP
    echo '1. 导入客户端公钥（推荐）'
    echo '2. 生成新的独立临时密钥对'
    echo '0. 返回'
    choice=$(read_menu_choice '请选择: ') || exit 1
    case "$choice" in
        0) exit 0 ;;
        1)
            read -r -p '粘贴一行 OpenSSH 公钥: ' public || exit 1
            printf '%s\n' "$public" > "$work/key.pub"
            ssh-keygen -l -f "$work/key.pub" || { zero_error '公钥无效'; exit 1; }
            ;;
        2)
            read -r -s -p '私钥口令（可留空）: ' passphrase || exit 1
            echo
            ssh-keygen -q -t ed25519 -N "$passphrase" -f "$work/key" || exit 1
            cat "$work/key"
            zero_confirm '已安全保存上方私钥，继续安装公钥？' || exit 0
            ;;
        *) exit 1 ;;
    esac
    local actual_keys
    actual_keys=$(get_sshd_effective_option AuthorizedKeysFile) || exit 1
    actual_keys="${actual_keys//%h/$ROOT_HOME}"; actual_keys="${actual_keys//%u/root}"
    [[ "$actual_keys" == /* ]] || actual_keys="$ROOT_HOME/$actual_keys"
    [[ "$actual_keys" == "$authorized" ]] || { zero_error "实际 AuthorizedKeysFile=${actual_keys}，请将公钥导入该路径"; exit 1; }
    install -d -m 700 "$directory" || exit 1
    [[ -e "$authorized" ]] && { cp -p "$authorized" "$work/authorized.before" || exit 1; had_keys=1; }
    [[ -f "$authorized" ]] && cat "$authorized" > "$work/authorized.new"
    public=$(cat "$work/key.pub")
    grep -qxF -- "$public" "$work/authorized.new" 2>/dev/null || printf '\n%s\n' "$public" >> "$work/authorized.new"
    zero_atomic_install "$work/authorized.new" "$authorized" 600 || exit 1
    if ssh_apply_options '' PermitRootLogin yes PubkeyAuthentication yes; then
        echo '公钥已安装；请保留当前会话，用新连接验证密钥登录后再关闭密码登录。'
    else
        if (( had_keys )); then zero_atomic_install "$work/authorized.before" "$authorized" 600
        else rm -f "$authorized"; fi
        exit 1
    fi
    press_any_key_to_continue
)

disable_ssh_login_menu() {
    local choice methods password_status
    methods=$(get_sshd_effective_option AuthenticationMethods) || return 1
    [[ "$methods" == any ]] || { zero_error "AuthenticationMethods=${methods}，请人工调整组合认证"; return 1; }
    echo '1. 关闭密码及键盘交互认证'
    echo '2. 关闭公钥认证'
    echo '0. 返回'
    choice=$(read_menu_choice '请选择: ') || return
    case "$choice" in
        1)
            [[ "$(get_sshd_effective_option PubkeyAuthentication)" == yes ]] && ssh_has_local_root_key || {
                zero_error '无法确认 root 有可用的本地公钥，已取消'; return 1;
            }
            [[ "$(get_sshd_effective_option PermitRootLogin)" =~ ^(yes|prohibit-password|without-password)$ ]] || return 1
            zero_confirm '已通过独立新连接验证 root 密钥登录成功？' || return
            ssh_apply_options '' PasswordAuthentication no KbdInteractiveAuthentication no
            ;;
        2)
            password_status=$(passwd -S root 2>/dev/null | awk '{print $2}')
            [[ "$password_status" == P && "$(get_sshd_effective_option PasswordAuthentication)" == yes &&
               "$(get_sshd_effective_option PermitRootLogin)" == yes ]] || {
                zero_error '无法确认 root 密码登录可用，已取消'; return 1;
            }
            zero_confirm '已通过独立新连接验证 root 密码登录成功？' || return
            ssh_apply_options '' PubkeyAuthentication no
            ;;
        0) return ;;
        *) return 1 ;;
    esac
    press_any_key_to_continue
}

reboot_vps() {
    local answer
    echo '将在 5 秒后重启；按任意键取消。'
    if read -r -n 1 -t 5 answer; then echo; echo '已取消重启'; return 0; fi
    systemctl reboot || { zero_error '重启失败'; return 1; }
}

swap_is_valid_size_mb() {
    zero_valid_uint "$1" 128 1048576
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

set_swap() {
    local size_mb="$1"
    local avail_kb avail_mb root_fstype
    local temp_swap_path="${swapfile_path}.zero.tmp"
    local backup_swap_path="${swapfile_path}.zero.bak"
    local had_existing=0 old_active=0

    echo -e "${YELLOW}正在检查环境...${PLAIN}"
    if ! swap_is_valid_size_mb "$size_mb"; then
        echo -e "${RED}无效的 Swap 大小${PLAIN}"
        return 1
    fi

    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024)) # Old and candidate swap coexist until commit.
    
    if (( avail_mb < size_mb + 500 )); then
        echo -e "${RED}磁盘空间不足!当前可用: ${avail_mb}MB, 需要: ${size_mb}MB (+预留500MB)${PLAIN}"
        return 1
    fi

    root_fstype=$(trim_input "$(df --output=fstype / | tail -1)")
    [[ -f "$swapfile_path" ]] && had_existing=1
    grep -q "$swapfile_path" /proc/swaps 2>/dev/null && old_active=1

    if grep -q "$temp_swap_path" /proc/swaps 2>/dev/null; then
        swapoff "$temp_swap_path" 2>/dev/null || true
    fi
    rm -f "$temp_swap_path"
    if [[ -e "$backup_swap_path" ]]; then
        zero_error "检测到上次遗留的 Swap 备份，请先确认恢复状态: $backup_swap_path"; return 1
    fi

    echo -e "${BLUE}正在创建 ${size_mb}MB 的 Swap 文件...${PLAIN}"
    if ! create_swap_file "$temp_swap_path" "$size_mb" "$root_fstype"; then
        echo -e "${RED}Swap 文件创建失败${PLAIN}"
        rm -f "$temp_swap_path"
        return 1
    fi

    if (( old_active )); then
        echo -e "${YELLOW}正在切换旧 Swap...${PLAIN}"
        if ! swapoff "$swapfile_path"; then
            echo -e "${RED}旧 Swap 卸载失败,已保留原配置${PLAIN}"
            rm -f "$temp_swap_path"
            return 1
        fi
    fi

    if (( had_existing )); then
        if ! mv "$swapfile_path" "$backup_swap_path"; then
            echo -e "${RED}旧 Swap 备份失败,已保留原配置${PLAIN}"
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
            rm -f "$temp_swap_path"
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
        return 1
    fi

    if ! swapon "$swapfile_path"; then
        echo -e "${RED}新 Swap 启用失败,已尝试恢复旧配置${PLAIN}"
        rm -f "$swapfile_path"
        if (( had_existing )); then
            mv "$backup_swap_path" "$swapfile_path" 2>/dev/null || true
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    local fstab_candidate
    fstab_candidate=$(mktemp /etc/fstab.zero.XXXXXX) || return 1
    if ! awk -v path="$swapfile_path" -v temp="$temp_swap_path" -v backup="$backup_swap_path" \
        '$1!=path && $1!=temp && $1!=backup {print} END {print path " none swap sw 0 0"}' /etc/fstab > "$fstab_candidate" ||
       ! zero_atomic_install "$fstab_candidate" /etc/fstab 644; then
        rm -f "$fstab_candidate"
        zero_error "新 Swap 已启用，但 fstab 提交失败；旧 Swap 备份保留: $backup_swap_path"
        return 1
    fi
    rm -f "$fstab_candidate"

    rm -f "$backup_swap_path"

    echo -e "${GREEN}✓ Swap 设置成功!${PLAIN}"
    free -h
    return 0
}

ACME_HOME="$ROOT_HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
ACME_CERT_PATH="/etc/cert"
ACME_PORT80_OPEN_HOOK="/usr/local/bin/zero-acme-port80-open"
ACME_PORT80_CLOSE_HOOK="/usr/local/bin/zero-acme-port80-close"
ACME_CF_API="https://api.cloudflare.com/client/v4"

ACME_CF_TOKEN=""
ACME_CF_RESPONSE=""
ACME_CF_HTTP_STATUS=""
ACME_CF_ZONE_ID=""
ACME_CF_ZONE_NAME=""
ACME_CF_ZONE_STATUS=""
ACME_CF_ACCOUNT_ID=""
ACME_CF_EXPECTED_NS=""
ACME_CF_CREDENTIAL_BACKUP=""
ACME_CF_CREDENTIALS_REMOVED=0

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
        jq
        cron
        tar
        ca-certificates
    )

    echo -e "${YELLOW}正在安装 ACME 依赖...${PLAIN}"
    pkg_install "${packages[@]}"
}

acme_install_port80_hook_scripts() {
    install -d -m 700 /run/zero-acme-port80 || return 1
    cat > "$ACME_PORT80_OPEN_HOOK" <<'HOOK'
#!/bin/bash
set -u
state=/run/zero-acme-port80
install -d -m 700 "$state" || exit 1
exec 8>"$state/lock"
flock -x 8 || exit 1
: > "$state/added"
for cmd in iptables ip6tables; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    "$cmd" -w 5 -t filter -C INPUT -j ZERO_INPUT 2>/dev/null || continue
    echo "$cmd" >> "$state/added"
    "$cmd" -w 5 -N ZERO_ACME_PORT80 2>/dev/null || "$cmd" -w 5 -S ZERO_ACME_PORT80 >/dev/null || exit 1
    "$cmd" -w 5 -C ZERO_ACME_PORT80 -p tcp --dport 80 -m comment --comment zero-acme-temporary -j ACCEPT 2>/dev/null ||
        "$cmd" -w 5 -A ZERO_ACME_PORT80 -p tcp --dport 80 -m comment --comment zero-acme-temporary -j ACCEPT || exit 1
    "$cmd" -w 5 -C INPUT -j ZERO_ACME_PORT80 2>/dev/null ||
        "$cmd" -w 5 -I INPUT 1 -j ZERO_ACME_PORT80 || exit 1
done
HOOK
    cat > "$ACME_PORT80_CLOSE_HOOK" <<'HOOK'
#!/bin/bash
set -u
state=/run/zero-acme-port80
[[ -d "$state" ]] || exit 0
exec 8>"$state/lock"
flock -x 8 || exit 1
[[ -f "$state/added" ]] || exit 0
failed=0
while read -r cmd; do
    case "$cmd" in iptables|ip6tables) ;; *) continue ;; esac
    if "$cmd" -w 5 -C INPUT -j ZERO_ACME_PORT80 2>/dev/null; then
        "$cmd" -w 5 -D INPUT -j ZERO_ACME_PORT80 || failed=1
    fi
    if "$cmd" -w 5 -S ZERO_ACME_PORT80 >/dev/null 2>&1; then
        "$cmd" -w 5 -F ZERO_ACME_PORT80 && "$cmd" -w 5 -X ZERO_ACME_PORT80 || failed=1
    fi
done < "$state/added"
(( failed == 0 )) && rm -f "$state/added"
exit "$failed"
HOOK
    chmod 700 "$ACME_PORT80_OPEN_HOOK" "$ACME_PORT80_CLOSE_HOOK"
}

acme_guard_cron() {
    local old candidate
    old=$(mktemp); candidate=$(mktemp) || return 1
    crontab -l > "$old" 2>/dev/null || true
    awk -v binary="$ACME_BIN" '
        index($0,binary) && $0 !~ /^[[:space:]]*#/ && $0 !~ /zero-acme-issue.lock/ && NF>=6 {
            printf "%s %s %s %s %s flock -n /run/zero-acme-issue.lock ",$1,$2,$3,$4,$5
            for(i=6;i<=NF;i++) printf "%s%s",$i,(i==NF?"\n":" ")
            next
        } {print}
    ' "$old" > "$candidate"
    crontab "$candidate"
    local result=$?; rm -f "$old" "$candidate"; return "$result"
}

acme_enable_cron() {
    systemctl start cron 2>/dev/null || systemctl start cronie 2>/dev/null || true
    systemctl enable cron 2>/dev/null || systemctl enable cronie 2>/dev/null || true
}

acme_install_core() {
    local tempdir tarball acme_tar_url automail email current_version

    acme_ensure_cert_path

    if acme_is_installed; then
        acme_guard_cron || return 1
        current_version=$(acme_exec -v 2>/dev/null | head -n1)
        echo -e "${YELLOW}检测到 acme.sh 已安装${PLAIN}${current_version:+: ${GREEN}${current_version}${PLAIN}}"
        echo -e "${YELLOW}正在更新 acme.sh...${PLAIN}"
        acme_exec --upgrade --auto-upgrade >/dev/null 2>&1 || {
            echo -e "${RED}acme.sh 更新失败${PLAIN}"
            return 1
        }
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
    acme_guard_cron || return 1
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
        if [[ -x "$ACME_PORT80_CLOSE_HOOK" ]]; then
            "$ACME_PORT80_CLOSE_HOOK" >/dev/null 2>&1 || true
        fi
        rm -rf "$ACME_HOME"
        rm -f "$ACME_PORT80_OPEN_HOOK" "$ACME_PORT80_CLOSE_HOOK"
        rm -rf /run/zero-acme-port80
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
    acme_exec --list --listraw 2>/dev/null | tail -n +2
}

acme_display_cert_list() {
    local cert_list
    cert_list=$(acme_get_cert_list)

    if [[ -z "$cert_list" ]]; then
        echo -e "${YELLOW}暂无已申请的证书${PLAIN}"
        return 1
    fi

    printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | ${GREEN}%-15s${PLAIN}\n" "序号" "域名" "计划续期"
    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"

    local index=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local main_domain expire_time
        main_domain="${line%%|*}"
        expire_time="${line##*|}"
        expire_time="${expire_time%%T*}"
        expire_time="${expire_time%$'\r'}"
        [[ -n "$expire_time" ]] || expire_time="-"

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

acme_cf_require_dependencies() {
    local missing_packages=()
    local command_name package

    for package in curl jq dnsutils openssl; do
        case "$package" in
            dnsutils) command_name="dig" ;;
            *) command_name="$package" ;;
        esac
        command -v "$command_name" >/dev/null 2>&1 || missing_packages+=("$package")
    done

    [[ "${#missing_packages[@]}" -eq 0 ]] && return 0
    echo -e "${YELLOW}正在安装 Cloudflare API 检查依赖: ${missing_packages[*]}${PLAIN}"
    pkg_install "${missing_packages[@]}"
}

acme_prompt_cf_token() {
    local token=""

    ACME_CF_TOKEN=""
    if ! read -r -s -p "$(echo -e "${BLUE}请输入 Cloudflare API Token: ${PLAIN}")" token; then
        echo
        echo -e "${RED}读取 Cloudflare API Token 失败${PLAIN}"
        return 1
    fi
    echo
    token=$(trim_input "$token")
    if [[ -z "$token" ]]; then
        echo -e "${RED}未输入 Cloudflare API Token${PLAIN}"
        return 1
    fi
    if [[ ! "$token" =~ ^[A-Za-z0-9._~-]+$ ]]; then
        echo -e "${RED}Cloudflare API Token 包含非法字符${PLAIN}"
        return 1
    fi
    ACME_CF_TOKEN="$token"
}

acme_cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local response_file header_file curl_rc
    local -a curl_args

    response_file=$(mktemp /tmp/zero-cf-api.XXXXXX) || return 1
    header_file=$(mktemp /tmp/zero-cf-header.XXXXXX) || {
        rm -f "$response_file"
        return 1
    }
    chmod 600 "$response_file"
    chmod 600 "$header_file"
    {
        printf 'Authorization: Bearer %s\n' "$ACME_CF_TOKEN"
        printf 'Content-Type: application/json\n'
    } > "$header_file"
    curl_args=(
        --silent --show-error
        --connect-timeout 10 --max-time 30
        --request "$method"
        --header "@${header_file}"
        --output "$response_file"
        --write-out "%{http_code}"
    )
    [[ -n "$data" ]] && curl_args+=(--data "$data")

    ACME_CF_HTTP_STATUS=$(curl "${curl_args[@]}" "${ACME_CF_API}/${endpoint}")
    curl_rc=$?
    ACME_CF_RESPONSE=$(<"$response_file")
    rm -f "$response_file" "$header_file"

    if (( curl_rc != 0 )); then
        ACME_CF_HTTP_STATUS="000"
        return 1
    fi
    return 0
}

acme_cf_response_success() {
    [[ "$ACME_CF_HTTP_STATUS" =~ ^2[0-9][0-9]$ ]] &&
        [[ $(jq -r '.success // false' <<<"$ACME_CF_RESPONSE" 2>/dev/null) == "true" ]]
}

acme_cf_print_errors() {
    local summary

    summary=$(jq -r '
        if (.errors // [] | length) > 0 then
            [.errors[] | "[\(.code // "unknown")] \(.message // "unknown error")"] | join("; ")
        elif .message then .message
        else "Cloudflare API 未返回具体错误"
        end
    ' <<<"$ACME_CF_RESPONSE" 2>/dev/null)
    echo -e "${RED}${summary:-Cloudflare API 请求失败} (HTTP ${ACME_CF_HTTP_STATUS:-000})${PLAIN}"
}

acme_cf_verify_token() {
    echo -e "${YELLOW}正在验证 Cloudflare API Token...${PLAIN}"
    if ! acme_cf_api GET "user/tokens/verify" || ! acme_cf_response_success; then
        acme_cf_print_errors
        return 1
    fi
    if [[ $(jq -r '.result.status // empty' <<<"$ACME_CF_RESPONSE") != "active" ]]; then
        echo -e "${RED}Cloudflare API Token 不是 active 状态${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✓ API Token 有效且处于 active 状态${PLAIN}"
}

acme_cf_find_zone() {
    local domain="$1"
    local candidate="$domain"
    local count

    echo -e "${YELLOW}正在确认 ${domain} 所属的 Cloudflare Zone...${PLAIN}"
    while [[ "$candidate" == *.* ]]; do
        if ! acme_cf_api GET "zones?name=${candidate}&per_page=1"; then
            acme_cf_print_errors
            return 1
        fi
        if ! acme_cf_response_success; then
            acme_cf_print_errors
            echo -e "${RED}Token 需要目标 Zone 的 Zone Read 权限${PLAIN}"
            return 1
        fi

        count=$(jq -r '.result_info.total_count // (.result | length) // 0' <<<"$ACME_CF_RESPONSE")
        if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
            ACME_CF_ZONE_ID=$(jq -r '.result[0].id // empty' <<<"$ACME_CF_RESPONSE")
            ACME_CF_ZONE_NAME=$(jq -r '.result[0].name // empty' <<<"$ACME_CF_RESPONSE")
            ACME_CF_ZONE_STATUS=$(jq -r '.result[0].status // empty' <<<"$ACME_CF_RESPONSE")
            ACME_CF_ACCOUNT_ID=$(jq -r '.result[0].account.id // empty' <<<"$ACME_CF_RESPONSE")
            ACME_CF_EXPECTED_NS=$(jq -r '.result[0].name_servers[]? // empty' <<<"$ACME_CF_RESPONSE" \
                | tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | sort -u)
            break
        fi
        candidate="${candidate#*.}"
    done

    if [[ -z "$ACME_CF_ZONE_ID" || -z "$ACME_CF_ZONE_NAME" ]]; then
        echo -e "${RED}Token 无法读取目标域名对应的 Cloudflare Zone${PLAIN}"
        echo -e "${YELLOW}请确认 Token 已包含目标 Zone，并拥有 Zone Read 权限${PLAIN}"
        return 1
    fi
    if [[ "$ACME_CF_ZONE_STATUS" != "active" ]]; then
        echo -e "${RED}Cloudflare Zone 状态为 ${ACME_CF_ZONE_STATUS:-unknown}，不是 active${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✓ Zone Read 验证通过: ${ACME_CF_ZONE_NAME}${PLAIN}"
}

acme_cf_public_authoritative_ns() {
    local zone="$1"
    local resolver result=""

    for resolver in 1.1.1.1 8.8.8.8 ""; do
        if [[ -n "$resolver" ]]; then
            result=$(dig +short +time=4 +tries=1 NS "$zone" "@$resolver" 2>/dev/null)
        else
            result=$(dig +short +time=4 +tries=1 NS "$zone" 2>/dev/null)
        fi
        [[ -n "$result" ]] && break
    done
    printf '%s\n' "$result" | tr '[:upper:]' '[:lower:]' | sed '/^$/d; s/\.$//' | sort -u
}

acme_cf_check_authoritative_ns() {
    local actual_ns

    echo -e "${YELLOW}正在检查 ${ACME_CF_ZONE_NAME} 的公网权威 NS...${PLAIN}"
    actual_ns=$(acme_cf_public_authoritative_ns "$ACME_CF_ZONE_NAME")
    if [[ -z "$actual_ns" ]]; then
        echo -e "${RED}无法从公共 DNS 查询权威 NS${PLAIN}"
        return 1
    fi
    if [[ -z "$ACME_CF_EXPECTED_NS" ]]; then
        echo -e "${RED}Cloudflare API 未返回 Zone 的预期 NS${PLAIN}"
        return 1
    fi
    if [[ "$actual_ns" != "$ACME_CF_EXPECTED_NS" ]]; then
        echo -e "${RED}域名当前的公网权威 NS 与 Cloudflare 分配的 NS 不一致${PLAIN}"
        echo "Cloudflare 预期 NS: $(tr '\n' ' ' <<<"$ACME_CF_EXPECTED_NS")"
        echo "公网实际 NS:      $(tr '\n' ' ' <<<"$actual_ns")"
        return 1
    fi
    echo -e "${GREEN}✓ 权威 NS 检查通过: $(tr '\n' ' ' <<<"$actual_ns")${PLAIN}"
}

acme_cf_probe_dns_write() {
    local probe_name probe_value payload record_id

    probe_name="_zero-acme-permission-check.${ACME_CF_ZONE_NAME}"
    probe_value="zero-acme-check-$(openssl rand -hex 12)"
    payload=$(jq -nc \
        --arg type "TXT" \
        --arg name "$probe_name" \
        --arg content "$probe_value" \
        '{type:$type,name:$name,content:$content,ttl:120}')

    echo -e "${YELLOW}正在通过临时 TXT 记录验证 DNS Write 权限...${PLAIN}"
    if ! acme_cf_api POST "zones/${ACME_CF_ZONE_ID}/dns_records" "$payload" || ! acme_cf_response_success; then
        acme_cf_print_errors
        echo -e "${RED}Token 需要目标 Zone 的 DNS Write 权限${PLAIN}"
        return 1
    fi
    record_id=$(jq -r '.result.id // empty' <<<"$ACME_CF_RESPONSE")
    if [[ -z "$record_id" ]]; then
        echo -e "${RED}临时 TXT 已提交，但 Cloudflare 未返回记录 ID，无法清理${PLAIN}"
        echo -e "${YELLOW}请手动检查并删除可能残留的记录: ${probe_name}${PLAIN}"
        return 1
    fi

    if ! acme_cf_api DELETE "zones/${ACME_CF_ZONE_ID}/dns_records/${record_id}" || ! acme_cf_response_success; then
        acme_cf_print_errors
        echo -e "${YELLOW}临时 TXT 可能残留，请手动删除: ${probe_name} (记录 ID: ${record_id})${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✓ DNS Write/Delete 权限验证通过，临时 TXT 已删除${PLAIN}"
}

acme_cf_preflight() {
    local domain="$1"

    ACME_CF_RESPONSE=""
    ACME_CF_HTTP_STATUS=""
    ACME_CF_ZONE_ID=""
    ACME_CF_ZONE_NAME=""
    ACME_CF_ZONE_STATUS=""
    ACME_CF_ACCOUNT_ID=""
    ACME_CF_EXPECTED_NS=""

    acme_cf_verify_token || return 1
    acme_cf_find_zone "$domain" || return 1
    acme_cf_check_authoritative_ns || return 1
    acme_cf_probe_dns_write || return 1
    echo -e "${GREEN}✓ Cloudflare Token、Zone 权限和权威 NS 前置检查全部通过${PLAIN}"
}

acme_cf_clean_old_credentials() {
    local account_conf="$ACME_HOME/account.conf"
    local backup_dir backup_file temp_file

    ACME_CF_CREDENTIAL_BACKUP=""
    ACME_CF_CREDENTIALS_REMOVED=0
    [[ -f "$account_conf" ]] || return 0
    if ! grep -Eq '^(SAVED_)?CF_(Token|Key|Email|Account_ID|Zone_ID)=' "$account_conf"; then
        return 0
    fi

    backup_dir="$ACME_HOME/credential-backups"
    mkdir -p "$backup_dir" || return 1
    chmod 700 "$backup_dir"
    backup_file=$(mktemp "$backup_dir/account.conf.bak.XXXXXX") || return 1
    if ! cp -p "$account_conf" "$backup_file"; then
        rm -f "$backup_file"
        return 1
    fi
    temp_file=$(mktemp "$backup_dir/account.conf.clean.XXXXXX") || return 1
    if ! awk '!/^(SAVED_)?CF_(Token|Key|Email|Account_ID|Zone_ID)=/' "$account_conf" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    chmod 600 "$temp_file"
    if ! mv -f "$temp_file" "$account_conf"; then
        rm -f "$temp_file"
        cp -p "$backup_file" "$account_conf" >/dev/null 2>&1 || true
        return 1
    fi
    ACME_CF_CREDENTIAL_BACKUP="$backup_file"
    ACME_CF_CREDENTIALS_REMOVED=1
    echo -e "${GREEN}已临时清理账户级旧 Cloudflare 凭据${PLAIN}"
    echo -e "${YELLOW}凭据备份: ${backup_file}${PLAIN}"
}

acme_cf_restore_old_credentials() {
    local account_conf="$ACME_HOME/account.conf"

    if (( ACME_CF_CREDENTIALS_REMOVED != 1 )); then
        return 0
    fi
    if [[ -z "$ACME_CF_CREDENTIAL_BACKUP" || ! -f "$ACME_CF_CREDENTIAL_BACKUP" ]]; then
        echo -e "${RED}找不到旧 Cloudflare 凭据备份，无法自动恢复${PLAIN}"
        return 1
    fi
    if ! cp -p "$ACME_CF_CREDENTIAL_BACKUP" "$account_conf"; then
        echo -e "${RED}恢复旧 Cloudflare 凭据失败${PLAIN}"
        return 1
    fi
    chmod 600 "$account_conf"
    ACME_CF_CREDENTIALS_REMOVED=0
    echo -e "${YELLOW}已恢复申请前的账户级 Cloudflare 凭据${PLAIN}"
}

acme_cf_has_legacy_global_users() {
    local domain_conf

    while IFS= read -r domain_conf; do
        grep -Eq '^Le_Webroot=.*dns_cf' "$domain_conf" 2>/dev/null || continue
        grep -Eq '^CF_Token=' "$domain_conf" 2>/dev/null && continue
        return 0
    done < <(find "$ACME_HOME" -mindepth 2 -maxdepth 2 -type f -name '*.conf' -print 2>/dev/null)
    return 1
}

acme_cf_finish_credentials_cleanup() {
    if (( ACME_CF_CREDENTIALS_REMOVED != 1 )); then
        return 0
    fi

    if acme_cf_has_legacy_global_users; then
        echo -e "${YELLOW}检测到其他旧 dns_cf 证书仍依赖账户级凭据，为保证其续期将保留旧凭据${PLAIN}"
        acme_cf_restore_old_credentials || return 1
    else
        ACME_CF_CREDENTIALS_REMOVED=0
        echo -e "${GREEN}旧 Cloudflare 凭据已清理，新 Token 仅保存在当前域名配置中${PLAIN}"
    fi
}

acme_cf_persist_domain_credentials() {
    local domain="$1"
    local domain_conf="$ACME_HOME/${domain}_ecc/${domain}.conf"
    local backup_file temp_file

    if [[ ! -f "$domain_conf" ]]; then
        echo -e "${RED}找不到域名配置: ${domain_conf}${PLAIN}"
        return 1
    fi
    if [[ ! "$ACME_CF_ZONE_ID" =~ ^[A-Za-z0-9_-]+$ ]] ||
       [[ -n "$ACME_CF_ACCOUNT_ID" && ! "$ACME_CF_ACCOUNT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Cloudflare Zone/Account ID 格式异常，拒绝写入证书配置${PLAIN}"
        return 1
    fi

    backup_file=$(mktemp "${domain_conf}.zero-cf.bak.XXXXXX") || return 1
    if ! cp -p "$domain_conf" "$backup_file"; then
        rm -f "$backup_file"
        return 1
    fi
    temp_file=$(mktemp "${domain_conf}.tmp.XXXXXX") || return 1
    if ! awk '!/^(CF_Token|CF_Zone_ID|CF_Account_ID)=/' "$domain_conf" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    {
        printf "CF_Token='%s'\n" "$ACME_CF_TOKEN"
        printf "CF_Zone_ID='%s'\n" "$ACME_CF_ZONE_ID"
        if [[ -n "$ACME_CF_ACCOUNT_ID" ]]; then
            printf "CF_Account_ID='%s'\n" "$ACME_CF_ACCOUNT_ID"
        fi
    } >> "$temp_file"
    chmod 600 "$temp_file"
    if ! mv -f "$temp_file" "$domain_conf"; then
        rm -f "$temp_file"
        return 1
    fi
    echo -e "${GREEN}当前域名的 Cloudflare Token/Zone 凭据已保存，可用于自动续期${PLAIN}"
    echo -e "${YELLOW}域名配置备份: ${backup_file}${PLAIN}"
}

acme_cf_issue_with_token() {
    local -a issue_args=("$@")

    (
        unset CF_Key CF_Email
        export CF_Token="$ACME_CF_TOKEN"
        export CF_Zone_ID="$ACME_CF_ZONE_ID"
        if [[ -n "$ACME_CF_ACCOUNT_ID" ]]; then
            export CF_Account_ID="$ACME_CF_ACCOUNT_ID"
        else
            unset CF_Account_ID
        fi
        acme_exec --issue --dns dns_cf -k ec-256 "${issue_args[@]}"
    )
}

acme_cf_prepare_and_issue() (
    exec 7>/run/zero-acme-issue.lock
    flock -n 7 || { zero_error '另一个 ACME 任务正在运行'; exit 1; }
    trap 'if (( ACME_CF_CREDENTIALS_REMOVED == 1 )); then acme_cf_restore_old_credentials; fi' EXIT
    trap 'exit 130' INT TERM HUP
    local domain="$1"
    local issue_rc
    shift

    acme_cf_clean_old_credentials || return 1
    acme_cf_issue_with_token "$@"
    issue_rc=$?

    case "$issue_rc" in
        0)
            ;;
        2)
            echo -e "${YELLOW}现有证书尚未到续期时间，将更新 Token 凭据并继续安装现有证书${PLAIN}"
            ;;
        *)
            acme_cf_restore_old_credentials || true
            return "$issue_rc"
            ;;
    esac

    if ! acme_cf_persist_domain_credentials "$domain"; then
        acme_cf_restore_old_credentials || true
        return 1
    fi
    if ! acme_cf_finish_credentials_cleanup; then
        acme_cf_restore_old_credentials || true
        return 1
    fi
    return 0
)

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
    local issue_domain="$1" save_name="$2" service reload='' result
    local -a services=()
    for service in mihomo sing-box-zero nginx apache2; do
        systemctl is-active --quiet "$service" && services+=("$service")
    done
    echo "当前运行的常见证书服务: ${services[*]:-无}"
    read -r -p '证书更新后需重启的服务名（空格分隔，留空不设置）: ' reload || return 1
    if [[ -n "$reload" ]]; then
        services=()
        for service in $reload; do
            [[ "$service" =~ ^[A-Za-z0-9_.@-]+$ && "$service" != -* ]] || { zero_error '服务名无效'; return 1; }
            systemctl cat "$service" >/dev/null 2>&1 || { zero_error "服务不存在: $service"; return 1; }
            services+=("$service")
        done
        reload="systemctl try-restart ${services[*]}"
    else
        echo '已跳过服务重载；若服务不自动读取新证书，请在证书更新后自行重载。'
    fi
    acme_exec --install-cert -d "$issue_domain" --key-file "$ACME_CERT_PATH/$save_name.key" \
        --fullchain-file "$ACME_CERT_PATH/$save_name.crt" --ecc --reloadcmd "$reload" || return 1
    chmod 600 "$ACME_CERT_PATH/$save_name.key" || return 1
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



acme_restore_port_80_firewall_if_needed() {
    [[ ! -x "$ACME_PORT80_CLOSE_HOOK" ]] || "$ACME_PORT80_CLOSE_HOOK"
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
    command -v ss >/dev/null 2>&1 || pkg_install iproute2 || return 1
    if ss -H -lnt | awk '$4 ~ /:80$/ {found=1} END {exit !found}'; then
        zero_error '80 端口被占用，请使用 DNS 申请，或自行暂停对应服务后再试'
        return 1
    fi
    echo '请确认云安全组和其他防火墙放行 TCP 80。'
}

acme_issue_standalone() (
    local domain
    acme_require_installed && acme_require_port80_hook_scripts && acme_check_port_80 || exit 1
    acme_prompt_validated_domain '请输入已解析到本机的域名: ' || exit 1
    domain="$ACME_PROMPT_DOMAIN"
    exec 7>/run/zero-acme-issue.lock
    flock -n 7 || { zero_error '另一个 ACME 任务正在运行'; exit 1; }
    trap '"$ACME_PORT80_CLOSE_HOOK" || zero_error "临时 80 端口规则清理失败"' EXIT
    trap 'exit 130' INT TERM HUP
    local -a args=(--issue -d "$domain" --standalone -k ec-256 --pre-hook "$ACME_PORT80_OPEN_HOOK" --post-hook "$ACME_PORT80_CLOSE_HOOK")
    acme_has_ipv4 || args+=(--listen-v6)
    local result
    acme_exec "${args[@]}"; result=$?
    [[ "$result" == 0 || "$result" == 2 ]] || { acme_print_issue_failed; exit "$result"; }
    acme_install_issued_cert "$domain" "$domain"
    press_any_key_to_continue
)

acme_issue_cf_single() {
    local domain

    acme_require_installed || return
    acme_cf_require_dependencies || {
        echo -e "${RED}Cloudflare API 检查依赖安装失败${PLAIN}"
        press_any_key_to_continue
        return
    }

    acme_prompt_validated_domain "请输入需要申请证书的域名: " || return
    domain=$(printf '%s' "$ACME_PROMPT_DOMAIN" | tr '[:upper:]' '[:lower:]')
    if ! acme_prompt_cf_token; then
        press_any_key_to_continue
        return
    fi
    if ! acme_cf_preflight "$domain"; then
        ACME_CF_TOKEN=""
        echo -e "${RED}Cloudflare 前置检查失败，已取消证书申请${PLAIN}"
        press_any_key_to_continue
        return
    fi
    acme_ensure_cert_path
    if ! acme_cf_prepare_and_issue "$domain" -d "$domain"; then
        ACME_CF_TOKEN=""
        acme_issue_failed_cleanup
        return
    fi
    ACME_CF_TOKEN=""
    acme_finalize_issue "$domain" "$domain"
}

acme_issue_cf_wildcard() {
    local domain

    acme_require_installed || return
    acme_cf_require_dependencies || {
        echo -e "${RED}Cloudflare API 检查依赖安装失败${PLAIN}"
        press_any_key_to_continue
        return
    }

    acme_prompt_validated_domain "请输入需要申请证书的泛域名根域名: " || return
    domain=$(printf '%s' "$ACME_PROMPT_DOMAIN" | tr '[:upper:]' '[:lower:]')
    if ! acme_prompt_cf_token; then
        press_any_key_to_continue
        return
    fi
    if ! acme_cf_preflight "$domain"; then
        ACME_CF_TOKEN=""
        echo -e "${RED}Cloudflare 前置检查失败，已取消证书申请${PLAIN}"
        press_any_key_to_continue
        return
    fi
    acme_ensure_cert_path
    if ! acme_cf_prepare_and_issue "$domain" -d "$domain" -d "*.${domain}"; then
        ACME_CF_TOKEN=""
        acme_issue_failed_cleanup
        return
    fi
    ACME_CF_TOKEN=""
    acme_finalize_issue "$domain" "$domain"
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
        domains+=("${line%%|*}")
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

    if flock -n /run/zero-acme-issue.lock bash "$ACME_BIN" --cron; then
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
    echo -e "${GREEN}1.LetsEncrypt${PLAIN}  ${GREEN}2.ZeroSSL${PLAIN}"
    echo -e "${YELLOW}0.返回菜单${PLAIN}"
    echo -e "${BLUE}========================${PLAIN}"
    provider=$(read_menu_choice "请输入选项 [0-2]: ")

    case "$provider" in
        1)
            acme_exec --set-default-ca --server letsencrypt && echo -e "${GREEN}已切换到 LetsEncrypt${PLAIN}" || echo -e "${RED}切换失败${PLAIN}"
            ;;
        2)
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

acme_generate_self_signed_cert() (
    local domain key_file crt_file work
    read -r -p '自签证书域名: ' domain || exit 1
    acme_validate_domain "$domain" || { zero_error '域名无效'; exit 1; }
    acme_ensure_cert_path || exit 1
    key_file="$ACME_CERT_PATH/$domain.selfsigned.key"
    crt_file="$ACME_CERT_PATH/$domain.selfsigned.crt"
    [[ ! -e "$key_file" && ! -e "$crt_file" ]] || { zero_error '同名自签证书已存在，未覆盖'; exit 1; }
    command -v openssl >/dev/null 2>&1 || pkg_install openssl || exit 1
    work=$(mktemp -d /tmp/zero-selfsigned.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM HUP
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/key" &&
        openssl req -new -x509 -key "$work/key" -out "$work/cert" -days 365 \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" &&
        openssl x509 -in "$work/cert" -noout || exit 1
    zero_atomic_install "$work/key" "$key_file" 600 || exit 1
    zero_atomic_install "$work/cert" "$crt_file" 644 || { rm -f "$key_file"; exit 1; }
    echo "自签证书: $crt_file"
    echo "私钥: $key_file"
    press_any_key_to_continue
)

acme_show_menu() {
    clear
    echo -e "${BLUE}===============================${PLAIN}"
    echo -e "         ${RED}证书申请${PLAIN}"
    echo -e "${BLUE}===============================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN}安装Acme"
    echo -e " ${GREEN}2.${PLAIN}卸载Acme"
    echo -e "${BLUE}-------------${PLAIN}"
    echo -e " ${GREEN}3.${PLAIN}申请单域名证书 ${YELLOW}(80 端口申请)${PLAIN}"
    echo -e " ${GREEN}4.${PLAIN}申请单域名证书 ${YELLOW}(CF API Token)${PLAIN}"
    echo -e " ${GREEN}5.${PLAIN}申请泛域名证书 ${YELLOW}(CF API Token)${PLAIN}"
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
        aarch64|arm64) echo "arm64" ;;
        *)
            echo -e "${RED}不支持${PLAIN}" >&2
            return 1
            ;;
    esac
}

mihomo_random_pass() {
    singbox_random_password
}

mihomo_validate_port() {
    zero_valid_uint "$1" 1 65535
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
    local release_json="$1" arch="$2" channel="$3" level pattern
    if [[ "$arch" == amd64 ]]; then
        level=$(bbr_detect_x86_64_level_local); (( level > 3 )) && level=3
        pattern="^mihomo-linux-amd64-v${level}-"
    else pattern='^mihomo-linux-arm64-'; fi
    [[ "$channel" == alpha ]] && pattern+='alpha-[0-9a-f]+\.gz$' || pattern+='v[0-9]+\.[0-9]+\.[0-9]+\.gz$'
    jq -er --arg pattern "$pattern" '[.assets[] | select(.name | test($pattern))][0].name // empty' <<< "$release_json"
}

mihomo_get_download_info() {
    local arch="$1" channel="$2" path json asset
    [[ "$channel" == alpha ]] && path="tags/$MIHOMO_ALPHA_TAG" || path=latest
    json=$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/MetaCubeX/mihomo/releases/$path") || return 1
    asset=$(mihomo_select_asset_name "$json" "$arch" "$channel") || return 1
    jq -er --arg asset "$asset" '.tag_name as $tag | .assets[] | select(.name==$asset) |
        select((.digest // "") | test("^sha256:[a-fA-F0-9]{64}$")) |
        [.browser_download_url,$tag,.name,.digest] | join("|")' <<< "$json"
}

mihomo_download_binary() {
    local url="$1" digest="$2" target="$3" work actual
    digest="${digest#sha256:}"
    [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || { zero_error '缺少可信下载摘要'; return 1; }
    work=$(mktemp -d /tmp/zero-mihomo-download.XXXXXX) || return 1
    if curl -fL --connect-timeout 10 --max-time 180 "$url" -o "$work/binary.gz" &&
       [[ "$(sha256sum "$work/binary.gz" | cut -d' ' -f1)" == "${digest,,}" ]] &&
       gunzip -c "$work/binary.gz" > "$work/binary" && chmod 755 "$work/binary" &&
       "$work/binary" -v && zero_atomic_install "$work/binary" "$target" 755; then
        rm -rf "$work"; return 0
    fi
    rm -rf "$work"; zero_error 'Mihomo 下载、摘要验证或执行检查失败'; return 1
}

mihomo_install_dependencies() {
    [[ -d /run/systemd/system ]] || { zero_error 'Mihomo 需要 systemd'; return 1; }
    local package
    for package in curl jq python3 gunzip sha256sum ss; do
        command -v "$package" >/dev/null 2>&1 || {
            pkg_install curl jq python3 python3-yaml gzip ca-certificates coreutils iproute2 || return 1; break;
        }
    done
    python3 -c 'import yaml' 2>/dev/null || pkg_install python3-yaml
}

mihomo_select_cert() {
    local cert_files opt i

    while true; do
        clear
        echo -e "${BLUE}证书配置${PLAIN}"
        
        cert_files=()
        if compgen -G "/etc/cert/*.crt" > /dev/null 2>&1; then
            mapfile -t cert_files < <(find /etc/cert -maxdepth 1 -type f -name "*.crt" | sort)
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
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
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

    if zero_service_action "$action" "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
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





mihomo_config_json() {
    python3 - "$1" <<'PY'
import sys, json, yaml
try:
    with open(sys.argv[1]) as f: value = yaml.safe_load(f)
    if not isinstance(value, dict): raise ValueError('配置必须是对象')
    json.dump(value, sys.stdout, ensure_ascii=False)
except Exception as exc:
    print(str(exc), file=sys.stderr); sys.exit(1)
PY
}

mihomo_has_listener() {
    local json
    json=$(mihomo_config_json "$MIHOMO_CONFIG_PATH") || return 1
    jq -e --arg name "$1" 'any(.listeners[]?; .name==$name)' <<< "$json" >/dev/null
}

mihomo_listener_json() {
    local name="$1" port="$2" password="$3" uuid="${4:-}" cert="${5:-}" key="${6:-}" obfs="${7:-n}" host="${8:-}"
    jq -n --arg name "$name" --argjson port "$port" --arg password "$password" --arg uuid "$uuid" \
        --arg cert "$cert" --arg key "$key" --arg obfs "$obfs" --arg host "$host" '
        {name:$name,port:$port,listen:"::"} +
        (if $name=="anytls-in" then {type:"anytls",users:{username1:$password}}
         elif $name=="trojan-in" then {type:"trojan",users:[{username:"user1",password:$password}],"ws-path":"/"}
         elif $name=="snellv5-in" then {type:"snell",psk:$password,version:5,udp:true} +
             (if $obfs=="y" then {"obfs-opts":{mode:"http",host:$host}} else {} end)
         elif $name=="tuicv5-in" then {type:"tuic",users:{($uuid):$password},"congestion-controller":"bbr",alpn:["h3"]}
         elif $name=="hysteria2-in" then {type:"hysteria2",users:{user1:$password},alpn:["h3"]}
         else error("未知监听器") end) +
        (if $name=="snellv5-in" then {} else {certificate:$cert,"private-key":$key} end)'
}

mihomo_prompt_listener() {
    local name="$1" label="$2" default_port="$3" port password uuid='' obfs=n host=''
    read -r -p "$label 端口 [$default_port]: " port || return 1
    port="${port:-$default_port}"
    mihomo_validate_port "$port" || { zero_error '端口无效（不能带前导零）'; return 1; }
    singbox_port_is_listening "$port" && { zero_error '端口已被系统进程占用'; return 1; }
    password=$(singbox_prompt_password "$label 密码/PSK") || return 1
    if [[ "$name" == tuicv5-in ]]; then
        read -r -p 'UUID（回车生成）: ' uuid || return 1
        uuid="${uuid:-$(singbox_random_uuid)}"
        singbox_validate_uuid "$uuid" || { zero_error 'UUID 无效'; return 1; }
    fi
    if [[ "$name" == snellv5-in ]]; then
        if zero_confirm '启用 Snell v5 HTTP 混淆？'; then
            obfs=y; read -r -p 'OBFS Host [icloud.com.cn]: ' host || return 1
            host="${host:-icloud.com.cn}"
        fi
        mihomo_cert_path=''; mihomo_key_path=''
    else mihomo_select_cert || return 1; fi
    MIHOMO_NEW_LISTENER=$(mihomo_listener_json "$name" "$port" "$password" "$uuid" "$mihomo_cert_path" "$mihomo_key_path" "$obfs" "$host") || return 1
    printf '%s\n' "$label 端口: $port" "密码/PSK: $password" "UUID: $uuid"
}

mihomo_apply_candidate() (
    local candidate="$1" message="$2" backup active=0 committed=0
    "$MIHOMO_EXEC_PATH" -t -d "$MIHOMO_CONFIG_DIR" -f "$candidate" || exit 1
    backup=$(mktemp -d /tmp/zero-mihomo-config.XXXXXX) || exit 1
    zero_snapshot_paths "$backup" "$MIHOMO_CONFIG_PATH" || exit 1
    systemctl is-active --quiet "$MIHOMO_SERVICE_NAME" && active=1
    trap 'if (( committed == 0 )); then
        if zero_restore_paths "$backup" && { (( active == 0 )) || zero_service_action restart "$MIHOMO_SERVICE_NAME"; }; then
            rm -rf "$backup"; zero_error "修改未成功，已恢复原配置"
        else zero_error "恢复失败，备份: $backup"; fi
    else rm -rf "$backup"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    zero_atomic_install "$candidate" "$MIHOMO_CONFIG_PATH" 600 || exit 1
    (( active == 0 )) || zero_service_action restart "$MIHOMO_SERVICE_NAME" || exit 1
    committed=1
    echo "$message"
)

mihomo_edit_listener() {
    local name="$1" operation="$2" value="${3:-}" extra="${4:-}" json candidate result
    json=$(mihomo_config_json "$MIHOMO_CONFIG_PATH") || return 1
    candidate=$(mktemp) || return 1
    if ! jq --arg name "$name" --arg op "$operation" --arg value "$value" --arg extra "$extra" '
        if (any(.listeners[]?; .name==$name) | not) then error("监听器不存在") else . end |
        if $op=="delete" then
            if (.listeners | length)<=1 then error("至少保留一个监听器") else .listeners |= map(select(.name!=$name)) end
        else .listeners |= map(if .name!=$name then . else
            if $op=="port" then .port=($value|tonumber)
            elif $op=="cert" then .certificate=$value | ."private-key"=$extra
            elif $op=="obfs-off" then del(."obfs-opts")
            elif $op=="obfs-on" then ."obfs-opts"={mode:"http",host:$value}
            elif $op=="password" then
                if .type=="snell" then .psk=$value
                elif .type=="trojan" then .users[0].password=$value
                else .users |= with_entries(.value=$value) end
            else error("未知操作") end
        end) end |
        if ([.listeners[].port] | length) != ([.listeners[].port] | unique | length)
        then error("监听端口重复") else . end' <<< "$json" > "$candidate"; then
        rm -f "$candidate"; return 1
    fi
    mihomo_apply_candidate "$candidate" '配置已校验并更新'; result=$?
    rm -f "$candidate"; return "$result"
}

mihomo_generate_config() {
    jq -n '{"tcp-concurrent":true,"find-process-mode":"off","allow-lan":false,mode:"rule", "log-level":"info",ipv6:true,listeners:[],rules:["MATCH,DIRECT"]}'
}

mihomo_install() (
    local work arch info url version asset digest name label port spec committed=0
    [[ ! -e "$MIHOMO_EXEC_PATH" && ! -e "$MIHOMO_CONFIG_DIR" && ! -e "$MIHOMO_SERVICE_FILE" ]] || {
        zero_error '检测到现有 Mihomo 文件，请使用管理/更新功能'; press_any_key_to_continue; exit 1;
    }
    mihomo_install_dependencies || exit 1
    work=$(mktemp -d /tmp/zero-mihomo-install.XXXXXX) || exit 1
    zero_snapshot_paths "$work" "$MIHOMO_EXEC_PATH" "$MIHOMO_CONFIG_DIR" "$MIHOMO_SERVICE_FILE" || exit 1
    trap 'if (( committed == 0 )); then
        systemctl disable --now "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1 || true
        if zero_restore_paths "$work"; then rm -rf "$work"; else zero_error "恢复失败，备份: $work"; fi
        systemctl daemon-reload
    else rm -rf "$work"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    arch=$(mihomo_get_arch) || exit 1
    info=$(mihomo_get_download_info "$arch" release) || exit 1
    IFS='|' read -r url version asset digest <<< "$info"
    mihomo_download_binary "$url" "$digest" "$work/binary" || exit 1
    mihomo_generate_config > "$work/config" || exit 1
    for spec in 'anytls-in AnyTLS 8443' 'trojan-in Trojan 10819' 'snellv5-in Snellv5 10815' 'tuicv5-in TUICv5 28443' 'hysteria2-in Hysteria2 18443'; do
        read -r name label port <<< "$spec"
        zero_confirm "启用 ${label}？" || continue
        mihomo_prompt_listener "$name" "$label" "$port" || exit 1
        jq --argjson listener "$MIHOMO_NEW_LISTENER" '.listeners += [$listener]' "$work/config" > "$work/next" &&
            mv "$work/next" "$work/config" || exit 1
    done
    jq -e '(.listeners|length)>0 and (([.listeners[].port]|length)==([.listeners[].port]|unique|length))' "$work/config" >/dev/null || { zero_error '至少选择一个监听器且端口不可重复'; exit 1; }
    "$work/binary" -t -d "$work" -f "$work/config" || exit 1
    install -d -m 700 "$MIHOMO_CONFIG_DIR" &&
        zero_atomic_install "$work/binary" "$MIHOMO_EXEC_PATH" 755 &&
        zero_atomic_install "$work/config" "$MIHOMO_CONFIG_PATH" 600 &&
        mihomo_create_systemd_service && systemctl daemon-reload &&
        systemctl enable "$MIHOMO_SERVICE_NAME" && zero_service_action start "$MIHOMO_SERVICE_NAME" || exit 1
    printf 'managed_by=Zero.sh\n' > "$MIHOMO_CONFIG_DIR/.zero-managed" || exit 1
    committed=1
    echo "Mihomo $version 安装完成，请确认防火墙端口放行。"
    press_any_key_to_continue
)

mihomo_manage_service() {
    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
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
        mihomo_has_listener "anytls-in" && anytls_status="已启用"
        mihomo_has_listener "trojan-in" && trojan_status="已启用"
        mihomo_has_listener "snellv5-in" && snell_status="已启用"
        mihomo_has_listener "tuicv5-in" && tuic_status="已启用"
        mihomo_has_listener "hysteria2-in" && hy2_status="已启用"
        
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
        mihomo_has_listener "$name" && is_enabled="y"
        
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
    local name="$1" label="$2" port="$3" json candidate result
    mihomo_prompt_listener "$name" "$label" "$port" || return 1
    json=$(mihomo_config_json "$MIHOMO_CONFIG_PATH") || return 1
    candidate=$(mktemp) || return 1
    if ! jq --argjson listener "$MIHOMO_NEW_LISTENER" '
        if any(.listeners[]?; .port==$listener.port or .name==$listener.name) then error("端口/名称重复")
        else .listeners += [$listener] end' <<< "$json" > "$candidate"; then rm -f "$candidate"; return 1; fi
    mihomo_apply_candidate "$candidate" "$label 已启用"; result=$?
    rm -f "$candidate"; return "$result"
}

mihomo_snell_obfs_enabled() {
    local json
    json=$(mihomo_config_json "$MIHOMO_CONFIG_PATH") || return 1
    jq -e 'any(.listeners[]?; .name=="snellv5-in" and ."obfs-opts"!=null)' <<< "$json" >/dev/null
}

mihomo_toggle_snell_obfs() {
    local host
    if mihomo_snell_obfs_enabled; then
        zero_confirm '关闭 Snell HTTP 混淆？' && mihomo_edit_listener snellv5-in obfs-off
    else
        read -r -p 'OBFS Host [icloud.com.cn]: ' host || return 1
        mihomo_edit_listener snellv5-in obfs-on "${host:-icloud.com.cn}"
    fi
}

mihomo_disable_listener() {
    zero_confirm "禁用 $2？" && mihomo_edit_listener "$1" delete
}

mihomo_modify_listener_port() {
    local port old json
    read -r -p '新端口: ' port || return 1
    mihomo_validate_port "$port" || return 1
    json=$(mihomo_config_json "$MIHOMO_CONFIG_PATH") || return 1
    old=$(jq -r --arg name "$1" '.listeners[] | select(.name==$name) | .port' <<< "$json")
    [[ "$port" == "$old" ]] && return 0
    singbox_port_is_listening "$port" && { zero_error '端口已被占用'; return 1; }
    mihomo_edit_listener "$1" port "$port"
}

mihomo_modify_listener_pass() {
    local password
    password=$(singbox_prompt_password '新密码/PSK') || return 1
    mihomo_edit_listener "$1" password "$password"
}

mihomo_modify_listener_cert() {
    mihomo_select_cert && mihomo_edit_listener "$1" cert "$mihomo_cert_path" "$mihomo_key_path"
}

mihomo_update_channel() (
    local channel="$1" work arch info url version asset digest committed=0 active=0
    [[ -x "$MIHOMO_EXEC_PATH" && -f "$MIHOMO_CONFIG_PATH" ]] || { zero_error '未安装 Mihomo'; exit 1; }
    mihomo_install_dependencies || exit 1
    arch=$(mihomo_get_arch) && info=$(mihomo_get_download_info "$arch" "$channel") || exit 1
    IFS='|' read -r url version asset digest <<< "$info"
    echo "目标: $version ($asset)"
    zero_confirm '下载并切换到此版本？' || exit 0
    work=$(mktemp -d /tmp/zero-mihomo-update.XXXXXX) || exit 1
    zero_snapshot_paths "$work" "$MIHOMO_EXEC_PATH" || exit 1
    systemctl is-active --quiet "$MIHOMO_SERVICE_NAME" && active=1
    trap 'if (( committed == 0 )); then
        if zero_restore_paths "$work" && { (( active == 0 )) || zero_service_action restart "$MIHOMO_SERVICE_NAME"; }; then rm -rf "$work"
        else zero_error "更新回滚失败，备份: $work"; fi
    else rm -rf "$work"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    mihomo_download_binary "$url" "$digest" "$work/binary" || exit 1
    "$work/binary" -t -d "$MIHOMO_CONFIG_DIR" -f "$MIHOMO_CONFIG_PATH" || exit 1
    zero_atomic_install "$work/binary" "$MIHOMO_EXEC_PATH" 755 || exit 1
    (( active == 0 )) || zero_service_action restart "$MIHOMO_SERVICE_NAME" || exit 1
    committed=1
    echo "已切换到 $version"
    press_any_key_to_continue
)

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
    if [[ ! -f "$MIHOMO_CONFIG_DIR/.zero-managed" ]]; then
        zero_confirm '现有安装没有管理标记，确认这是要删除的 Mihomo？' || return
    fi
    zero_confirm '删除 Mihomo 程序、配置及服务？' || return
    systemctl stop "$MIHOMO_SERVICE_NAME" && systemctl disable "$MIHOMO_SERVICE_NAME" || return 1
    rm -f "$MIHOMO_SERVICE_FILE" "$MIHOMO_EXEC_PATH" && rm -rf "$MIHOMO_CONFIG_DIR" && systemctl daemon-reload || return 1
    echo '已删除 Mihomo'
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

# ============================ Sing-box ============================

SINGBOX_EXEC_PATH="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/etc/sing-box"
SINGBOX_CONFIG_PATH="${SINGBOX_CONFIG_DIR}/config.json"
SINGBOX_SERVICE_NAME="sing-box-zero.service"
SINGBOX_SERVICE_FILE="/etc/systemd/system/${SINGBOX_SERVICE_NAME}"
SINGBOX_MANAGED_MARKER="${SINGBOX_CONFIG_DIR}/.zero-managed"
SINGBOX_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases"
SINGBOX_SHADOWTLS_TAG="stls-in"
SINGBOX_WARP_TAG="WARP"
SINGBOX_WARP_ADDRESS=""
SINGBOX_WARP_PRIVATE_KEY=""
SINGBOX_WARP_SERVER=""
SINGBOX_WARP_PORT=""
SINGBOX_WARP_PUBLIC_KEY=""

SINGBOX_STAGE_DIR=""
SINGBOX_STAGE_BIN=""
SINGBOX_STAGE_VERSION=""
SINGBOX_STAGE_ASSET=""
SINGBOX_STAGE_URL=""
SINGBOX_STAGE_DIGEST=""
SINGBOX_NEW_INBOUND=""
SINGBOX_NEW_SUMMARY=""
SINGBOX_CERT_PATH=""
SINGBOX_KEY_PATH=""

singbox_pause_and_return() {
    pause_enter_and_clear "按回车返回..."
}

singbox_is_managed() {
    [[ -f "$SINGBOX_MANAGED_MARKER" ]]
}

singbox_is_installed() {
    [[ -x "$SINGBOX_EXEC_PATH" && -f "$SINGBOX_CONFIG_PATH" && -f "$SINGBOX_SERVICE_FILE" ]]
}

singbox_atomic_install() {
    zero_atomic_install "$@"
}

singbox_get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            echo -e "${RED}Sing-box 暂不支持当前架构: $(uname -m)${PLAIN}" >&2
            return 1
            ;;
    esac
}

singbox_install_dependencies() {
    local missing=() package command_name
    local packages=(curl jq tar ca-certificates openssl coreutils iproute2 python3)

    for package in "${packages[@]}"; do
        command_name="$package"
        case "$package" in
            ca-certificates) command_name="update-ca-certificates" ;;
            coreutils) command_name="sha256sum" ;;
            iproute2) command_name="ss" ;;
        esac
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$package")
    done

    command -v systemctl >/dev/null 2>&1 || {
        echo -e "${RED}未检测到 systemctl,无法管理 Sing-box 服务${PLAIN}"
        return 1
    }
    [[ -d /run/systemd/system ]] || {
        echo -e "${RED}当前环境没有运行 systemd,无法管理 Sing-box 服务${PLAIN}"
        return 1
    }

    [[ ${#missing[@]} -eq 0 ]] && return 0
    echo -e "${YELLOW}正在安装 Sing-box 依赖: ${missing[*]}${PLAIN}"
    apt-get update && apt-get install -y --no-install-recommends "${missing[@]}"
}

singbox_random_password() {
    local password
    password=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9') || return 1
    password="${password:0:16}"
    [[ "$password" =~ ^[A-Za-z0-9]{16}$ ]] || return 1
    printf '%s' "$password"
}

singbox_random_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        return 1
    fi
}

singbox_random_ss_password() {
    local bytes="$1"
    openssl rand -base64 "$bytes" 2>/dev/null | tr -d '\r\n'
}

singbox_validate_snell_psk() {
    local bytes
    bytes=$(LC_ALL=C printf '%s' "$1" | wc -c | tr -d ' ')
    [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes >= 12 && bytes <= 255 ))
}

singbox_validate_port() {
    zero_valid_uint "$1" 1 65535
}

singbox_validate_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

singbox_validate_ss_password() {
    local password="$1"
    local expected_bytes="$2"
    local decoded_bytes

    [[ "$password" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    printf '%s' "$password" | base64 -d >/dev/null 2>&1 || return 1
    decoded_bytes=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [[ "$decoded_bytes" =~ ^[0-9]+$ ]] && (( decoded_bytes == expected_bytes ))
}

singbox_get_current_version() {
    local version_line version
    [[ -x "$SINGBOX_EXEC_PATH" ]] || return 1
    version_line=$("$SINGBOX_EXEC_PATH" version 2>/dev/null | head -n1)
    version=$(printf '%s\n' "$version_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' | head -n1)
    printf '%s\n' "${version:-未知}"
}

singbox_version_supports_snell() {
    local version="${1#v}" core major minor
    core="${version%%-*}"
    major="${core%%.*}"
    core="${core#*.}"
    minor="${core%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    (( major > 1 || (major == 1 && minor >= 14) ))
}

singbox_supports_snell() {
    local version
    version=$(singbox_get_current_version) || return 1
    singbox_version_supports_snell "$version"
}

singbox_cleanup_stage() {
    [[ -n "$SINGBOX_STAGE_DIR" && -d "$SINGBOX_STAGE_DIR" ]] && rm -rf "$SINGBOX_STAGE_DIR"
    SINGBOX_STAGE_DIR=""
    SINGBOX_STAGE_BIN=""
    SINGBOX_STAGE_VERSION=""
    SINGBOX_STAGE_ASSET=""
    SINGBOX_STAGE_URL=""
    SINGBOX_STAGE_DIGEST=""
}

singbox_get_release_object() {
    local channel="$1"

    case "$channel" in
        release)
            curl -fsSL --connect-timeout 10 --max-time 30 \
                -H 'Accept: application/vnd.github+json' \
                "${SINGBOX_RELEASE_API}/latest"
            ;;
        beta)
            curl -fsSL --connect-timeout 10 --max-time 30 \
                -H 'Accept: application/vnd.github+json' \
                "${SINGBOX_RELEASE_API}?per_page=30" \
                | jq -c '[.[] | select(.draft == false and .prerelease == true)][0]'
            ;;
        *) return 1 ;;
    esac
}

singbox_prepare_release() {
    local channel="$1"
    local arch release_json tag version asset_name url digest

    singbox_cleanup_stage
    arch=$(singbox_get_arch) || return 1
    release_json=$(singbox_get_release_object "$channel") || {
        echo -e "${RED}获取 Sing-box Release 信息失败${PLAIN}"
        return 1
    }
    [[ -n "$release_json" && "$release_json" != "null" ]] || {
        echo -e "${RED}未找到可用的 Sing-box Release${PLAIN}"
        return 1
    }

    tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty')
    version="${tag#v}"
    [[ -n "$version" ]] || {
        echo -e "${RED}无法读取 Sing-box 版本号${PLAIN}"
        return 1
    }

    asset_name="sing-box-${version}-linux-${arch}.tar.gz"
    url=$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' | head -n1)
    digest=$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | (.digest // empty)' | head -n1)
    digest="${digest#sha256:}"
    digest=$(printf '%s' "$digest" | tr '[:upper:]' '[:lower:]')

    [[ -n "$url" ]] || {
        echo -e "${RED}Release 中未找到 ${asset_name}${PLAIN}"
        return 1
    }
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || {
        echo -e "${RED}Release 未提供有效 SHA-256,已拒绝安装未校验文件${PLAIN}"
        return 1
    }

    SINGBOX_STAGE_VERSION="$version"
    SINGBOX_STAGE_ASSET="$asset_name"
    SINGBOX_STAGE_URL="$url"
    SINGBOX_STAGE_DIGEST="$digest"
}

singbox_download_prepared_release() {
    local archive extracted_bin actual_sha

    [[ -n "$SINGBOX_STAGE_VERSION" && -n "$SINGBOX_STAGE_ASSET" && \
       -n "$SINGBOX_STAGE_URL" && "$SINGBOX_STAGE_DIGEST" =~ ^[0-9a-f]{64}$ ]] || {
        echo -e "${RED}Sing-box Release 信息不完整,无法下载${PLAIN}"
        return 1
    }

    SINGBOX_STAGE_DIR=$(mktemp -d /tmp/zero-singbox.XXXXXX) || return 1
    archive="${SINGBOX_STAGE_DIR}/${SINGBOX_STAGE_ASSET}"
    echo -e "${BLUE}正在下载 Sing-box ${SINGBOX_STAGE_VERSION} (${SINGBOX_STAGE_ASSET})...${PLAIN}"
    if ! curl -fL --connect-timeout 10 --max-time 180 "$SINGBOX_STAGE_URL" -o "$archive"; then
        echo -e "${RED}Sing-box 下载失败${PLAIN}"
        singbox_cleanup_stage
        return 1
    fi

    actual_sha=$(sha256sum "$archive" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    if [[ "$actual_sha" != "$SINGBOX_STAGE_DIGEST" ]]; then
        echo -e "${RED}Sing-box SHA-256 校验失败,已删除下载文件${PLAIN}"
        singbox_cleanup_stage
        return 1
    fi

    if ! tar -xzf "$archive" -C "$SINGBOX_STAGE_DIR"; then
        echo -e "${RED}Sing-box 解压失败${PLAIN}"
        singbox_cleanup_stage
        return 1
    fi

    extracted_bin=$(find "$SINGBOX_STAGE_DIR" -type f -name sing-box -perm -u+x | head -n1)
    [[ -n "$extracted_bin" ]] || {
        echo -e "${RED}压缩包中未找到 Sing-box 可执行文件${PLAIN}"
        singbox_cleanup_stage
        return 1
    }
    "$extracted_bin" version >/dev/null 2>&1 || {
        echo -e "${RED}下载的 Sing-box 无法执行${PLAIN}"
        singbox_cleanup_stage
        return 1
    }

    SINGBOX_STAGE_BIN="$extracted_bin"
    echo -e "${GREEN}SHA-256 校验通过${PLAIN}"
}

singbox_stage_release() {
    local channel="$1"
    singbox_prepare_release "$channel" && singbox_download_prepared_release
}

singbox_version_is_newer() {
    local candidate="${1#v}" current="${2#v}" dpkg_prerelease='~'

    # dpkg 的 ~ 会把 alpha/beta/rc 正确视为正式版之前的预发行版本。
    # 通过变量传入字面量 ~，避免 Bash 在参数替换中将其展开为运行用户的家目录。
    candidate="${candidate/-/$dpkg_prerelease}"
    current="${current/-/$dpkg_prerelease}"
    dpkg --compare-versions "$candidate" gt "$current"
}

singbox_select_cert() {
    local cert_files=() opt i cert_path key_path

    while true; do
        clear
        echo -e "${BLUE}===== Sing-box 证书配置 =====${PLAIN}"
        if compgen -G "/etc/cert/*.crt" >/dev/null 2>&1; then
            mapfile -t cert_files < <(find /etc/cert -maxdepth 1 -type f -name '*.crt' | sort)
        else
            cert_files=()
        fi

        for ((i=0; i<${#cert_files[@]}; i++)); do
            echo -e "${GREEN}$((i+1)).${PLAIN}$(basename "${cert_files[$i]}")"
        done
        echo -e "${GREEN}0.${PLAIN}自定义路径"
        read -r -p "$(echo -e "${BLUE}输入选项: ${PLAIN}")" opt
        opt=$(trim_input "$opt")

        if [[ "$opt" == "0" ]]; then
            read -r -p "$(echo -e "${BLUE}证书路径: ${PLAIN}")" cert_path
            read -r -p "$(echo -e "${BLUE}私钥路径: ${PLAIN}")" key_path
        elif [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#cert_files[@]} )); then
            cert_path="${cert_files[$((opt-1))]}"
            key_path="${cert_path%.crt}.key"
        else
            echo -e "${YELLOW}无效选项${PLAIN}"
            sleep 0.5
            continue
        fi

        if [[ -r "$cert_path" && -r "$key_path" ]]; then
            SINGBOX_CERT_PATH="$cert_path"
            SINGBOX_KEY_PATH="$key_path"
            return 0
        fi
        echo -e "${RED}证书或私钥不存在/不可读${PLAIN}"
        sleep 1
    done
}

singbox_tag_for_type() {
    case "$1" in
        anytls) echo "anytls-in" ;;
        trojan) echo "trojan-in" ;;
        shadowsocks) echo "ss-in" ;;
        tuic) echo "tuic-in" ;;
        hysteria2) echo "hy2-in" ;;
        snell) echo "snell-in" ;;
        *) return 1 ;;
    esac
}

singbox_default_port_for_type() {
    case "$1" in
        anytls) echo 8443 ;;
        trojan) echo 10819 ;;
        shadowsocks) echo 10818 ;;
        tuic) echo 28443 ;;
        hysteria2) echo 18443 ;;
        snell) echo 10815 ;;
        *) return 1 ;;
    esac
}

singbox_label_for_type() {
    case "$1" in
        anytls) echo "AnyTLS" ;;
        trojan) echo "Trojan + WS + TLS" ;;
        shadowsocks) echo "Shadowsocks 2022" ;;
        tuic) echo "TUIC v5" ;;
        hysteria2) echo "Hysteria2" ;;
        snell) echo "Snell v6" ;;
        *) echo "$1" ;;
    esac
}

singbox_type_uses_tls() {
    case "$1" in
        anytls|trojan|tuic|hysteria2) return 0 ;;
        *) return 1 ;;
    esac
}

singbox_config_has_tag() {
    local config_file="$1" tag="$2"
    jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$config_file" >/dev/null 2>&1
}

singbox_shadowsocks_uses_shadowtls() {
    local config_file="$1"
    jq -e --arg tag "$SINGBOX_SHADOWTLS_TAG" \
        '.inbounds[]? | select(.type == "shadowtls" and .tag == $tag and .version == 3 and .detour == "ss-in")' \
        "$config_file" >/dev/null 2>&1
}

singbox_config_uses_port() {
    local config_file="$1" port="$2" exclude_tag="${3:-}"
    jq -e --argjson port "$port" --arg exclude "$exclude_tag" \
        '.inbounds[]? | select(.listen_port == $port and .tag != $exclude)' \
        "$config_file" >/dev/null 2>&1
}

singbox_port_is_listening() {
    local port="$1"
    ss -H -lntu 2>/dev/null | awk -v port="$port" '
        {
            address=$5
            if (address ~ (":" port "$")) found=1
        }
        END {exit found ? 0 : 1}
    '
}

singbox_port_available() {
    local config_file="$1" port="$2" exclude_tag="${3:-}"
    if singbox_config_uses_port "$config_file" "$port" "$exclude_tag"; then
        echo -e "${RED}端口 ${port} 已被另一项 Sing-box 入站使用${PLAIN}" >&2
        return 1
    fi
    if singbox_port_is_listening "$port"; then
        echo -e "${RED}端口 ${port} 已被系统中的进程占用${PLAIN}" >&2
        return 1
    fi
    return 0
}

singbox_prompt_password() {
    local label="$1" value
    read -r -s -p "${label}(回车随机生成): " value
    # 本函数通过命令替换返回凭据。交互换行必须写入 stderr，否则会被
    # $(singbox_prompt_password ...) 一并捕获并成为密码/PSK 的首字符。
    printf '\n' >&2
    [[ -n "$value" ]] || value=$(singbox_random_password) || return 1
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf '%s' "$value"
}

singbox_prompt_port() {
    local label="$1" default_port="$2" config_file="$3"
    local port

    while true; do
        read -r -p "$(echo -e "${BLUE}${label}端口(默认:${default_port}): ${PLAIN}")" port
        port=$(trim_input "$port")
        port="${port:-$default_port}"
        if ! singbox_validate_port "$port"; then
            echo -e "${RED}端口必须在 1-65535 之间${PLAIN}" >&2
            continue
        fi
        if singbox_port_available "$config_file" "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
}

singbox_validate_ws_path() {
    [[ "$1" =~ ^/[^[:space:]]*$ ]]
}

singbox_prompt_ws_path() {
    local default_path="${1:-/}" path

    while true; do
        read -r -p "$(echo -e "${BLUE}WebSocket 路径(默认:${default_path}): ${PLAIN}")" path
        path=$(trim_input "$path")
        path="${path:-$default_path}"
        if singbox_validate_ws_path "$path"; then
            printf '%s' "$path"
            return 0
        fi
        echo -e "${RED}路径必须以 / 开头，且不能包含空白字符${PLAIN}" >&2
    done
}

singbox_prompt_shadowsocks() {
    local config_file="$1" port method="2022-blake3-aes-128-gcm" bytes=16 password
    local enable_shadowtls shadowtls_password handshake_server handshake_port

    clear
    echo -e "${BLUE}===== Shadowsocks 2022 配置 =====${PLAIN}"
    echo -e "${GREEN}加密方式: ${method}${PLAIN}"

    port=$(singbox_prompt_port "Shadowsocks " 10818 "$config_file") || return 1
    while true; do
        read -r -s -p "密码(回车生成符合密钥长度的 Base64 密码): " password
        echo
        [[ -n "$password" ]] || password=$(singbox_random_ss_password "$bytes")
        if singbox_validate_ss_password "$password" "$bytes"; then
            break
        fi
        echo -e "${RED}该加密方式要求 Base64 解码后为 ${bytes} 字节${PLAIN}"
    done

    read -r -p "$(echo -e "${BLUE}开启 ShadowTLS v3? [y/N]: ${PLAIN}")" enable_shadowtls
    if [[ "$enable_shadowtls" =~ ^[Yy]$ ]]; then
        while true; do
            read -r -p "$(echo -e "${BLUE}伪装握手域名: ${PLAIN}")" handshake_server
            handshake_server=$(trim_input "$handshake_server")
            [[ -n "$handshake_server" ]] && break
            echo -e "${RED}伪装握手域名不能为空${PLAIN}"
        done
        while true; do
            read -r -p "$(echo -e "${BLUE}伪装握手端口(默认:443): ${PLAIN}")" handshake_port
            handshake_port=$(trim_input "$handshake_port")
            handshake_port="${handshake_port:-443}"
            singbox_validate_port "$handshake_port" && break
            echo -e "${RED}端口必须在 1-65535 之间${PLAIN}"
        done
        shadowtls_password=$(singbox_prompt_password "ShadowTLS 密码") || return 1

        # ShadowTLS 仅承载 TCP，因此内部 Shadowsocks 入站显式限制为 TCP。
        SINGBOX_NEW_INBOUND=$(jq -n \
            --arg stls_tag "$SINGBOX_SHADOWTLS_TAG" \
            --arg ss_tag "ss-in" \
            --argjson port "$port" \
            --arg stls_password "$shadowtls_password" \
            --arg handshake_server "$handshake_server" \
            --argjson handshake_port "$handshake_port" \
            --arg method "$method" \
            --arg password "$password" \
            '[
                {
                    type:"shadowtls",tag:$stls_tag,listen:"::",listen_port:$port,
                    version:3,users:[{name:"user1",password:$stls_password}],
                    handshake:{server:$handshake_server,server_port:$handshake_port},detour:$ss_tag
                },
                {type:"shadowsocks",tag:$ss_tag,network:"tcp",method:$method,password:$password}
            ]')
        SINGBOX_NEW_SUMMARY="Shadowsocks 端口: ${port}\n加密: ${method}\n密码: ${password}\nShadowTLS: v3 已开启 (仅 TCP)\nShadowTLS 密码: ${shadowtls_password}\n伪装握手域名: ${handshake_server}:${handshake_port}\n客户端 SNI: ${handshake_server}"
    else
        SINGBOX_NEW_INBOUND=$(jq -n \
            --arg tag "ss-in" \
            --argjson port "$port" \
            --arg method "$method" \
            --arg password "$password" \
            '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$password}')
        SINGBOX_NEW_SUMMARY="Shadowsocks 端口: ${port}\n加密: ${method}\n密码: ${password}"
    fi
}

singbox_prompt_snell() {
    local config_file="$1" port psk option mode

    clear
    echo -e "${BLUE}===== Snell v6 配置 (Sing-box 1.14+) =====${PLAIN}"

    port=$(singbox_prompt_port "Snell " 10815 "$config_file") || return 1
    while true; do
        psk=$(singbox_prompt_password "PSK") || return 1
        if singbox_validate_snell_psk "$psk"; then
            break
        fi
        echo -e "${RED}Snell PSK 必须为 12-255 字节${PLAIN}"
    done

    echo -e "${GREEN}1.${PLAIN}default (推荐)"
    echo -e "${GREEN}2.${PLAIN}unshaped"
    echo -e "${RED}3.${PLAIN}unsafe-raw"
    read -r -p "$(echo -e "${BLUE}流量整形模式 [1-3,默认1]: ${PLAIN}")" option
    case "${option:-1}" in
        1) mode="default" ;;
        2) mode="unshaped" ;;
        3) mode="unsafe-raw" ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            return 1
            ;;
    esac
    SINGBOX_NEW_INBOUND=$(jq -n \
        --argjson port "$port" --arg psk "$psk" --arg mode "$mode" \
        '{type:"snell",tag:"snell-in",listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}')
    SINGBOX_NEW_SUMMARY="Snell v6 端口: ${port}\nPSK: ${psk}\n整形模式: ${mode}"
}

singbox_prompt_tls_inbound() {
    local type="$1" config_file="$2"
    local tag label default_port port password uuid ws_path

    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    default_port=$(singbox_default_port_for_type "$type") || return 1

    clear
    echo -e "${BLUE}===== ${label} 配置 =====${PLAIN}"
    port=$(singbox_prompt_port "${label} " "$default_port" "$config_file") || return 1
    if [[ "$type" == "trojan" ]]; then
        ws_path=$(singbox_prompt_ws_path) || return 1
    fi
    password=$(singbox_prompt_password "密码") || return 1

    uuid=""
    if [[ "$type" == "tuic" ]]; then
        while true; do
            read -r -p "$(echo -e "${BLUE}UUID(回车随机生成): ${PLAIN}")" uuid
            uuid=$(trim_input "$uuid")
            [[ -n "$uuid" ]] || uuid=$(singbox_random_uuid)
            singbox_validate_uuid "$uuid" && break
            echo -e "${RED}UUID 格式无效${PLAIN}"
        done
    fi

    singbox_select_cert || return 1
    case "$type" in
        anytls)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg password "$password" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
            SINGBOX_NEW_SUMMARY="AnyTLS 端口: ${port}\n密码: ${password}"
            ;;
        trojan)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg password "$password" --arg ws_path "$ws_path" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key},transport:{type:"ws",path:$ws_path}}')
            SINGBOX_NEW_SUMMARY="Trojan + WS + TLS 端口: ${port}\nWebSocket 路径: ${ws_path}\n密码: ${password}"
            ;;
        tuic)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",uuid:$uuid,password:$password}],congestion_control:"bbr",auth_timeout:"3s",zero_rtt_handshake:false,heartbeat:"10s",tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
            SINGBOX_NEW_SUMMARY="TUIC 端口: ${port}\nUUID: ${uuid}\n密码: ${password}"
            ;;
        hysteria2)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg password "$password" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
            SINGBOX_NEW_SUMMARY="Hysteria2 端口: ${port}\n密码: ${password}"
            ;;
        *) return 1 ;;
    esac
}

singbox_prompt_inbound() {
    local type="$1" config_file="$2"
    SINGBOX_NEW_INBOUND=""
    SINGBOX_NEW_SUMMARY=""
    case "$type" in
        shadowsocks) singbox_prompt_shadowsocks "$config_file" ;;
        snell) singbox_prompt_snell "$config_file" ;;
        anytls|trojan|tuic|hysteria2) singbox_prompt_tls_inbound "$type" "$config_file" ;;
        *) return 1 ;;
    esac
}

singbox_append_inbound() {
    local config_file="$1" output_file
    output_file=$(mktemp) || return 1
    if ! jq --argjson inbound "$SINGBOX_NEW_INBOUND" \
        '.inbounds += (if ($inbound | type) == "array" then $inbound else [$inbound] end)' \
        "$config_file" > "$output_file"; then
        rm -f "$output_file"
        return 1
    fi
    if ! mv "$output_file" "$config_file"; then
        rm -f "$output_file"
        return 1
    fi
    chmod 600 "$config_file" || return 1
}

singbox_check_config_with() {
    local binary="$1" config_file="$2"
    "$binary" check -c "$config_file"
}

singbox_create_systemd_service() {
    local temp_file
    temp_file=$(mktemp) || return 1
    cat > "$temp_file" <<EOF
[Unit]
Description=Sing-box service managed by Zero.sh
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
ExecStart=${SINGBOX_EXEC_PATH} run -c ${SINGBOX_CONFIG_PATH}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    if singbox_atomic_install "$temp_file" "$SINGBOX_SERVICE_FILE" 644; then
        rm -f "$temp_file"
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

singbox_apply_candidate() {
    local candidate="$1" success_msg="$2" failure_msg="${3:-新配置应用失败}"
    local backup was_active=0

    if ! singbox_check_config_with "$SINGBOX_EXEC_PATH" "$candidate"; then
        echo -e "${RED}配置检查失败,未修改当前配置${PLAIN}"
        return 1
    fi

    backup=$(mktemp) || return 1
    chmod 600 "$backup"
    cp "$SINGBOX_CONFIG_PATH" "$backup" || {
        rm -f "$backup"
        return 1
    }
    systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" && was_active=1

    if ! singbox_atomic_install "$candidate" "$SINGBOX_CONFIG_PATH" 600; then
        rm -f "$backup"
        echo -e "${RED}配置写入失败${PLAIN}"
        return 1
    fi

    if (( was_active == 0 )); then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg},服务保持停止状态${PLAIN}"
        return 0
    fi

    if zero_service_action restart "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg}${PLAIN}"
        return 0
    fi

    if singbox_atomic_install "$backup" "$SINGBOX_CONFIG_PATH" 600 &&
       zero_service_action restart "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        echo -e "${YELLOW}${failure_msg},已恢复上一份可用配置${PLAIN}"
        return 1
    fi

    echo -e "${RED}${failure_msg},自动恢复失败;备份保留在 ${backup}${PLAIN}"
    service_failure_hint "$SINGBOX_SERVICE_NAME"
    return 1
}

singbox_apply_and_cleanup() {
    local candidate="$1" success_msg="$2" failure_msg="$3" result
    singbox_apply_candidate "$candidate" "$success_msg" "$failure_msg"
    result=$?
    rm -f "$candidate"
    return "$result"
}

singbox_install() {
    local enable_anytls enable_trojan enable_ss enable_tuic enable_hy2 enable_snell="n"
    local candidate summary="" type install_channel channel_choice

    clear
    if singbox_is_managed; then
        echo -e "${YELLOW}Sing-box 已由 Zero.sh 管理,请使用管理或更新功能${PLAIN}"
        singbox_pause_and_return
        return
    fi
    if [[ -e "$SINGBOX_EXEC_PATH" || -e "$SINGBOX_CONFIG_DIR" || -e "$SINGBOX_SERVICE_FILE" ]]; then
        echo -e "${RED}检测到现有 Sing-box 文件,为避免覆盖非本脚本安装的服务已停止${PLAIN}"
        echo -e "${YELLOW}请先备份并移除现有安装,或继续使用原管理方式${PLAIN}"
        singbox_pause_and_return
        return 1
    fi

    singbox_install_dependencies || {
        singbox_pause_and_return
        return 1
    }

    clear
    echo -e "${BLUE}选择 Sing-box 内核:${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}正式版"
    echo -e "${GREEN}2.${PLAIN}测试版"
    read -r -p "$(echo -e "${BLUE}请选择 [1-2,默认1]: ${PLAIN}")" channel_choice
    case "${channel_choice:-1}" in
        1) install_channel="release" ;;
        2) install_channel="beta" ;;
        *)
            echo -e "${RED}无效选项,已取消安装${PLAIN}"
            singbox_pause_and_return
            return 1
            ;;
    esac

    singbox_stage_release "$install_channel" || {
        singbox_pause_and_return
        return 1
    }

    clear
    echo -e "${BLUE}选择要启用的 Sing-box 入站:${PLAIN}"
    read -r -p "启用 AnyTLS?          [y/N]: " enable_anytls
    read -r -p "启用 Trojan + WS + TLS?[y/N]: " enable_trojan
    read -r -p "启用 Shadowsocks 2022?[y/N]: " enable_ss
    read -r -p "启用 TUIC v5?         [y/N]: " enable_tuic
    read -r -p "启用 Hysteria2?       [y/N]: " enable_hy2
    read -r -p "启用 Snell v6?        [y/N]: " enable_snell
    [[ "$enable_anytls" =~ ^[Yy]$ ]] && enable_anytls="y" || enable_anytls="n"
    [[ "$enable_trojan" =~ ^[Yy]$ ]] && enable_trojan="y" || enable_trojan="n"
    [[ "$enable_ss" =~ ^[Yy]$ ]] && enable_ss="y" || enable_ss="n"
    [[ "$enable_tuic" =~ ^[Yy]$ ]] && enable_tuic="y" || enable_tuic="n"
    [[ "$enable_hy2" =~ ^[Yy]$ ]] && enable_hy2="y" || enable_hy2="n"
    [[ "$enable_snell" =~ ^[Yy]$ ]] && enable_snell="y" || enable_snell="n"

    if [[ "$enable_anytls" == "n" && "$enable_trojan" == "n" && "$enable_ss" == "n" && "$enable_tuic" == "n" && "$enable_hy2" == "n" && "$enable_snell" == "n" ]]; then
        echo -e "${YELLOW}至少需要启用一个入站,已取消安装${PLAIN}"
        singbox_cleanup_stage
        singbox_pause_and_return
        return
    fi

    candidate=$(mktemp) || {
        singbox_cleanup_stage
        return 1
    }
    chmod 600 "$candidate"
    jq -n '{
        log:{level:"info",timestamp:true},
        dns:{
            servers:[{type:"local",tag:"local"}],
            final:"local",
            strategy:"prefer_ipv4",
            cache_capacity:4096
        },
        inbounds:[],
        outbounds:[{type:"direct",tag:"direct"}],
        route:{final:"direct",default_domain_resolver:"local"}
    }' > "$candidate"

    for type in anytls trojan shadowsocks tuic hysteria2 snell; do
        case "$type" in
            anytls) [[ "$enable_anytls" == "y" ]] || continue ;;
            trojan) [[ "$enable_trojan" == "y" ]] || continue ;;
            shadowsocks) [[ "$enable_ss" == "y" ]] || continue ;;
            tuic) [[ "$enable_tuic" == "y" ]] || continue ;;
            hysteria2) [[ "$enable_hy2" == "y" ]] || continue ;;
            snell) [[ "$enable_snell" == "y" ]] || continue ;;
        esac

        if ! singbox_prompt_inbound "$type" "$candidate" || ! singbox_append_inbound "$candidate"; then
            echo -e "${RED}生成 $(singbox_label_for_type "$type") 配置失败,安装已取消${PLAIN}"
            rm -f "$candidate"
            singbox_cleanup_stage
            singbox_pause_and_return
            return 1
        fi
        [[ -n "$summary" ]] && summary+=$'\n\n'
        summary+="$SINGBOX_NEW_SUMMARY"
    done

    if ! singbox_check_config_with "$SINGBOX_STAGE_BIN" "$candidate"; then
        echo -e "${RED}Sing-box 配置检查失败,安装已取消${PLAIN}"
        rm -f "$candidate"
        singbox_cleanup_stage
        singbox_pause_and_return
        return 1
    fi

    install -d -m 700 "$SINGBOX_CONFIG_DIR" || {
        rm -f "$candidate"
        singbox_cleanup_stage
        return 1
    }
    if ! singbox_atomic_install "$SINGBOX_STAGE_BIN" "$SINGBOX_EXEC_PATH" 755 ||
       ! singbox_atomic_install "$candidate" "$SINGBOX_CONFIG_PATH" 600 ||
       ! singbox_create_systemd_service; then
        echo -e "${RED}Sing-box 文件安装失败${PLAIN}"
        rm -f "$candidate" "$SINGBOX_EXEC_PATH" "$SINGBOX_SERVICE_FILE"
        rm -rf "$SINGBOX_CONFIG_DIR"
        singbox_cleanup_stage
        singbox_pause_and_return
        return 1
    fi
    rm -f "$candidate"
    if ! printf 'managed_by=Zero.sh\n' > "$SINGBOX_MANAGED_MARKER" ||
       ! chmod 600 "$SINGBOX_MANAGED_MARKER"; then
        echo -e "${RED}Sing-box 管理标记写入失败${PLAIN}"
        rm -f "$SINGBOX_SERVICE_FILE" "$SINGBOX_EXEC_PATH"
        rm -rf "$SINGBOX_CONFIG_DIR"
        singbox_cleanup_stage
        singbox_pause_and_return
        return 1
    fi

    if ! systemctl daemon-reload >/dev/null 2>&1 ||
       ! systemctl enable "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 ||
       ! zero_service_action start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
        echo -e "${RED}Sing-box 服务启动失败,已撤销本次安装${PLAIN}"
        systemctl --no-pager --full status "$SINGBOX_SERVICE_NAME" || true
        systemctl disable --now "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SINGBOX_SERVICE_FILE" "$SINGBOX_EXEC_PATH"
        rm -rf "$SINGBOX_CONFIG_DIR"
        systemctl daemon-reload >/dev/null 2>&1 || true
        singbox_cleanup_stage
        singbox_pause_and_return
        return 1
    fi

    echo -e "${GREEN}Sing-box ${SINGBOX_STAGE_VERSION} 安装完成${PLAIN}"
    echo -e "${YELLOW}请确认防火墙已放行所选 TCP/UDP 端口${PLAIN}"
    echo -e "${BLUE}---------------- 随机/当前凭据 ----------------${PLAIN}"
    echo -e "${GREEN}${summary}${PLAIN}"
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    singbox_cleanup_stage
    singbox_pause_and_return
}

singbox_protocol_status() {
    local type="$1" tag port suffix=""
    tag=$(singbox_tag_for_type "$type") || return 1
    if singbox_config_has_tag "$SINGBOX_CONFIG_PATH" "$tag"; then
        if [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
            tag="$SINGBOX_SHADOWTLS_TAG"
            suffix=" (ShadowTLS v3)"
        fi
        port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .listen_port' "$SINGBOX_CONFIG_PATH")
        echo "已启用:${port}${suffix}"
    else
        echo "未启用"
    fi
}

singbox_add_inbound() {
    local type="$1" label candidate result=0
    label=$(singbox_label_for_type "$type")
    if [[ "$type" == "snell" ]] && ! singbox_supports_snell; then
        echo -e "${RED}当前 Sing-box 内核不支持 Snell 入站${PLAIN}"
        echo -e "${YELLOW}请先将 Sing-box 内核更新到 1.14.0 或更高版本${PLAIN}"
        return 1
    fi
    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    cp "$SINGBOX_CONFIG_PATH" "$candidate" || {
        rm -f "$candidate"
        return 1
    }

    if ! singbox_prompt_inbound "$type" "$candidate" || ! singbox_append_inbound "$candidate"; then
        rm -f "$candidate"
        echo -e "${RED}${label} 配置生成失败${PLAIN}"
        return 1
    fi

    if singbox_apply_candidate "$candidate" "${label} 已启用" "${label} 启动失败"; then
        echo -e "${GREEN}${SINGBOX_NEW_SUMMARY}${PLAIN}"
    else
        result=$?
    fi
    rm -f "$candidate"
    return "$result"
}

singbox_modify_port() {
    local type="$1" tag label current_port new_port candidate
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    if [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
        tag="$SINGBOX_SHADOWTLS_TAG"
    fi
    current_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .listen_port' "$SINGBOX_CONFIG_PATH")
    read -r -p "$(echo -e "${BLUE}新端口(当前:${current_port}): ${PLAIN}")" new_port
    new_port=$(trim_input "$new_port")
    [[ -n "$new_port" ]] || return 0
    if ! singbox_validate_port "$new_port"; then
        echo -e "${RED}端口无效${PLAIN}"
        return 1
    fi
    [[ "$new_port" == "$current_port" ]] && return 0
    singbox_port_available "$SINGBOX_CONFIG_PATH" "$new_port" "$tag" || return 1

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    jq --arg tag "$tag" --argjson port "$new_port" \
        '(.inbounds[] | select(.tag == $tag) | .listen_port) = $port' \
        "$SINGBOX_CONFIG_PATH" > "$candidate" || {
        rm -f "$candidate"
        return 1
    }
    singbox_apply_and_cleanup "$candidate" "${label} 端口已更新为 ${new_port}" "${label} 新端口启动失败"
}

singbox_modify_auth() {
    local type="$1" tag label password psk uuid current_method bytes candidate
    local result=0
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"

    if [[ "$type" == "shadowsocks" ]]; then
        current_method=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .method' "$SINGBOX_CONFIG_PATH")
        case "$current_method" in
            2022-blake3-aes-128-gcm) bytes=16 ;;
            2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) bytes=32 ;;
            *)
                echo -e "${RED}当前 Shadowsocks 加密方式不在本脚本管理范围${PLAIN}"
                rm -f "$candidate"
                return 1
                ;;
        esac
        while true; do
            read -r -s -p "新密码(回车随机生成): " password
            echo
            [[ -n "$password" ]] || password=$(singbox_random_ss_password "$bytes")
            singbox_validate_ss_password "$password" "$bytes" && break
            echo -e "${RED}密码 Base64 解码后必须为 ${bytes} 字节${PLAIN}"
        done
        jq --arg tag "$tag" --arg password "$password" \
            '(.inbounds[] | select(.tag == $tag) | .password) = $password' \
            "$SINGBOX_CONFIG_PATH" > "$candidate" || {
            rm -f "$candidate"
            return 1
        }
    elif [[ "$type" == "snell" ]]; then
        while true; do
            psk=$(singbox_prompt_password "新 PSK")
            singbox_validate_snell_psk "$psk" && break
            echo -e "${RED}Snell PSK 必须为 12-255 字节${PLAIN}"
        done
        password="$psk"
        jq --arg tag "$tag" --arg psk "$psk" \
            '(.inbounds[] | select(.tag == $tag) | .psk) = $psk' \
            "$SINGBOX_CONFIG_PATH" > "$candidate" || {
            rm -f "$candidate"
            return 1
        }
    elif [[ "$type" == "tuic" ]]; then
        read -r -p "$(echo -e "${BLUE}新 UUID(回车保持,R随机): ${PLAIN}")" uuid
        uuid=$(trim_input "$uuid")
        if [[ "$uuid" =~ ^[Rr]$ ]]; then
            uuid=$(singbox_random_uuid)
        elif [[ -z "$uuid" ]]; then
            uuid=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .users[0].uuid' "$SINGBOX_CONFIG_PATH")
        fi
        if ! singbox_validate_uuid "$uuid"; then
            echo -e "${RED}UUID 无效${PLAIN}"
            rm -f "$candidate"
            return 1
        fi
        password=$(singbox_prompt_password "新密码")
        jq --arg tag "$tag" --arg uuid "$uuid" --arg password "$password" \
            '(.inbounds[] | select(.tag == $tag) | .users[0]) |= (.uuid = $uuid | .password = $password)' \
            "$SINGBOX_CONFIG_PATH" > "$candidate" || {
            rm -f "$candidate"
            return 1
        }
    else
        password=$(singbox_prompt_password "新密码")
        jq --arg tag "$tag" --arg password "$password" \
            '(.inbounds[] | select(.tag == $tag) | .users[0].password) = $password' \
            "$SINGBOX_CONFIG_PATH" > "$candidate" || {
            rm -f "$candidate"
            return 1
        }
    fi

    if singbox_apply_candidate "$candidate" "${label} 认证信息已更新" "${label} 新认证信息启动失败"; then
        [[ "$type" == "tuic" ]] && echo -e "${GREEN}UUID: ${uuid}${PLAIN}"
        if [[ "$type" == "snell" ]]; then
            echo -e "${GREEN}PSK: ${password}${PLAIN}"
        else
            echo -e "${GREEN}密码: ${password}${PLAIN}"
        fi
    else
        result=$?
    fi
    rm -f "$candidate"
    return "$result"
}

singbox_modify_cert() {
    local type="$1" tag label candidate
    singbox_type_uses_tls "$type" || return 1
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    singbox_select_cert || return 1
    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    jq --arg tag "$tag" --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
        '(.inbounds[] | select(.tag == $tag) | .tls) |= (.enabled = true | .certificate_path = $cert | .key_path = $key)' \
        "$SINGBOX_CONFIG_PATH" > "$candidate" || {
        rm -f "$candidate"
        return 1
    }
    singbox_apply_and_cleanup "$candidate" "${label} 证书已更新" "${label} 新证书启动失败"
}

singbox_modify_trojan_ws_path() {
    local tag="trojan-in" current_path new_path candidate

    current_path=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | (.transport.path // empty)' "$SINGBOX_CONFIG_PATH")
    new_path=$(singbox_prompt_ws_path "${current_path:-/}") || return 1
    [[ "$new_path" == "$current_path" ]] && return 0

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    jq --arg tag "$tag" --arg path "$new_path" \
        '(.inbounds[] | select(.tag == $tag) | .transport) = {type:"ws",path:$path}' \
        "$SINGBOX_CONFIG_PATH" > "$candidate" || {
        rm -f "$candidate"
        return 1
    }
    singbox_apply_and_cleanup "$candidate" "Trojan WebSocket 路径已更新为 ${new_path}" "Trojan WebSocket 路径更新后启动失败"
}

singbox_modify_snell_mode() {
    local tag="snell-in" option mode candidate description

    clear
    echo -e "${BLUE}===== Snell v6 流量整形 =====${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}v6 / default 整形"
    echo -e "${GREEN}2.${PLAIN}v6 / unshaped"
    echo -e "${RED}3.${PLAIN}v6 / unsafe-raw"
    echo -e "${YELLOW}0.${PLAIN}取消"
    read -r -p "$(echo -e "${BLUE}请选择 [0-3]: ${PLAIN}")" option
    case "$option" in
        1) mode="default"; description="v6 / default" ;;
        2) mode="unshaped"; description="v6 / unshaped" ;;
        3) mode="unsafe-raw"; description="v6 / unsafe-raw" ;;
        0) return ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            return 1
            ;;
    esac

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    jq --arg tag "$tag" --arg mode "$mode" \
        '(.inbounds[] | select(.tag == $tag) | .mode) = $mode' \
        "$SINGBOX_CONFIG_PATH" > "$candidate" || {
        rm -f "$candidate"
        return 1
    }

    singbox_apply_and_cleanup "$candidate" "Snell 已切换为 ${description}" "Snell 模式切换后启动失败"
}

singbox_modify_shadowtls() {
    local tag="$SINGBOX_SHADOWTLS_TAG" password handshake_server handshake_port candidate
    local current_password current_server current_port result=0

    singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH" || return 1
    current_password=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .users[0].password' "$SINGBOX_CONFIG_PATH")
    current_server=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .handshake.server' "$SINGBOX_CONFIG_PATH")
    current_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .handshake.server_port' "$SINGBOX_CONFIG_PATH")

    clear
    echo -e "${BLUE}===== ShadowTLS v3 配置 =====${PLAIN}"
    echo -e "${YELLOW}当前伪装握手: ${current_server}:${current_port}${PLAIN}"
    read -r -s -p "新 ShadowTLS 密码(回车保持): " password
    echo
    password="${password:-$current_password}"
    read -r -p "$(echo -e "${BLUE}伪装握手域名(回车保持): ${PLAIN}")" handshake_server
    handshake_server=$(trim_input "$handshake_server")
    handshake_server="${handshake_server:-$current_server}"
    read -r -p "$(echo -e "${BLUE}伪装握手端口(当前:${current_port}): ${PLAIN}")" handshake_port
    handshake_port=$(trim_input "$handshake_port")
    handshake_port="${handshake_port:-$current_port}"
    if ! singbox_validate_port "$handshake_port"; then
        echo -e "${RED}端口必须在 1-65535 之间${PLAIN}"
        return 1
    fi

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    jq --arg tag "$tag" --arg password "$password" \
        --arg server "$handshake_server" --argjson port "$handshake_port" \
        '(.inbounds[] | select(.tag == $tag)) |= (.users[0].password = $password | .handshake.server = $server | .handshake.server_port = $port)' \
        "$SINGBOX_CONFIG_PATH" > "$candidate" || {
        rm -f "$candidate"
        return 1
    }
    if singbox_apply_candidate "$candidate" "ShadowTLS v3 配置已更新" "ShadowTLS v3 新配置启动失败"; then
        echo -e "${GREEN}ShadowTLS 密码: ${password}${PLAIN}"
        echo -e "${GREEN}客户端 SNI: ${handshake_server}${PLAIN}"
    else
        result=$?
    fi
    rm -f "$candidate"
    return "$result"
}

singbox_remove_inbound() {
    local type="$1" tag label count remove_count=1 confirm candidate use_shadowtls=0
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    if [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
        use_shadowtls=1
        remove_count=2
    fi
    count=$(jq '.inbounds | length' "$SINGBOX_CONFIG_PATH")
    if (( count <= remove_count )); then
        echo -e "${RED}至少需要保留一个入站,不能删除 ${label}${PLAIN}"
        return 1
    fi
    read -r -p "$(echo -e "${RED}确定禁用 ${label}? [y/N]: ${PLAIN}")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    if (( use_shadowtls == 1 )); then
        if ! jq --arg ss_tag "$tag" --arg stls_tag "$SINGBOX_SHADOWTLS_TAG" \
            '.inbounds |= map(select(.tag != $ss_tag and .tag != $stls_tag))' \
            "$SINGBOX_CONFIG_PATH" > "$candidate"; then
            rm -f "$candidate"
            return 1
        fi
    else
        if ! jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))' "$SINGBOX_CONFIG_PATH" > "$candidate"; then
            rm -f "$candidate"
            return 1
        fi
    fi
    singbox_apply_and_cleanup "$candidate" "${label} 已禁用" "删除 ${label} 后服务启动失败"
}

singbox_manage_protocol() {
    local type="$1" tag label confirm option
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")

    if ! singbox_config_has_tag "$SINGBOX_CONFIG_PATH" "$tag"; then
        if [[ "$type" == "snell" ]] && ! singbox_supports_snell; then
            echo -e "${RED}当前内核不支持 Snell 入站${PLAIN}"
            echo -e "${YELLOW}请先更新到 Sing-box 1.14.0 或更高版本${PLAIN}"
            sleep 2
            return 1
        fi
        read -r -p "$(echo -e "${BLUE}${label} 当前未启用,是否添加? [y/N]: ${PLAIN}")" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && singbox_add_inbound "$type"
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}===== ${label} 管理 =====${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}修改端口"
        echo -e "${GREEN}2.${PLAIN}修改认证"
        if singbox_type_uses_tls "$type"; then
            echo -e "${GREEN}3.${PLAIN}修改证书"
        elif [[ "$type" == "snell" ]]; then
            echo -e "${GREEN}3.${PLAIN}修改 v6 流量整形模式"
        elif [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
            echo -e "${GREEN}3.${PLAIN}修改 ShadowTLS v3"
        fi
        if [[ "$type" == "trojan" ]]; then
            echo -e "${GREEN}4.${PLAIN}修改 WebSocket 路径"
            echo -e "${RED}5.${PLAIN}禁用入站"
        else
            echo -e "${RED}4.${PLAIN}禁用入站"
        fi
        echo -e "${YELLOW}0.${PLAIN}返回上级"
        read -r -p "$(echo -e "${BLUE}请输入选项: ${PLAIN}")" option
        case "$option" in
            1) singbox_modify_port "$type"; sleep 1 ;;
            2) singbox_modify_auth "$type"; sleep 1 ;;
            3)
                if singbox_type_uses_tls "$type"; then
                    singbox_modify_cert "$type"
                elif [[ "$type" == "snell" ]]; then
                    singbox_modify_snell_mode
                elif [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
                    singbox_modify_shadowtls
                else
                    echo -e "${RED}${label} 没有可修改的证书或模式${PLAIN}"
                fi
                sleep 1
                ;;
            4)
                if [[ "$type" == "trojan" ]]; then
                    singbox_modify_trojan_ws_path
                    sleep 1
                else
                    singbox_remove_inbound "$type"
                    sleep 1
                    return
                fi
                ;;
            5)
                if [[ "$type" == "trojan" ]]; then
                    singbox_remove_inbound "$type"
                    sleep 1
                    return
                fi
                echo -e "${RED}无效选项${PLAIN}"
                sleep 0.5
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_warp_enabled() {
    jq -e --arg tag "$SINGBOX_WARP_TAG" \
        'any(.endpoints[]?; .type == "wireguard" and .tag == $tag)' \
        "$SINGBOX_CONFIG_PATH" >/dev/null 2>&1
}

singbox_warp_status() {
    if singbox_warp_enabled; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

singbox_import_warp() {
    local file profile address
    read -r -p '自己的 WireGuard/WARP 配置文件路径: ' file || return 1
    [[ -r "$file" ]] || { zero_error '配置文件不可读'; return 1; }
    profile=$(warp_read_profile_json "$file") || return 1
    address=$(jq -r '.addresses[] | select(contains(":"))' <<< "$profile" | head -n1)
    [[ -n "$address" ]] || { zero_error '当前 IPv6 分流预设需要配置中有 IPv6 地址'; return 1; }
    SINGBOX_WARP_ADDRESS="$address"
    SINGBOX_WARP_PRIVATE_KEY=$(jq -r '.private_key' <<< "$profile")
    SINGBOX_WARP_PUBLIC_KEY=$(jq -r '.public_key' <<< "$profile")
    SINGBOX_WARP_SERVER=$(jq -r '.host' <<< "$profile")
    SINGBOX_WARP_PORT=$(jq -r '.port' <<< "$profile")
}

singbox_enable_warp() {
    local candidate
    singbox_import_warp || return 1

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    if ! jq \
        --arg tag "$SINGBOX_WARP_TAG" \
        --arg address "$SINGBOX_WARP_ADDRESS" \
        --arg private_key "$SINGBOX_WARP_PRIVATE_KEY" \
        --arg server "$SINGBOX_WARP_SERVER" \
        --argjson port "$SINGBOX_WARP_PORT" \
        --arg public_key "$SINGBOX_WARP_PUBLIC_KEY" '
        def is_warp_resolve:
            .action == "resolve" and
            .strategy == "ipv6_only" and
            ((.domain_suffix // []) == ["challenges.cloudflare.com", "googlevideo.com", "youtube.com"]);
        def is_warp_rule:
            (.outbound // "") == $tag or is_warp_resolve;

        .endpoints = ((.endpoints // []) | map(select(.tag != $tag))) |
        .endpoints += [{
            type: "wireguard",
            tag: $tag,
            system: false,
            mtu: 1408,
            address: [$address],
            private_key: $private_key,
            peers: [{
                address: $server,
                port: $port,
                public_key: $public_key,
                allowed_ips: ["::/0"],
                persistent_keepalive_interval: 25
            }]
        }] |
        .route = (.route // {}) |
        .route.rules = ((.route.rules // []) |
            map(select((is_warp_rule | not)))) |
        .route.rules = [
            {
                domain_suffix: ["challenges.cloudflare.com", "googlevideo.com", "youtube.com"],
                action: "resolve",
                strategy: "ipv6_only"
            },
            {
                domain_suffix: ["challenges.cloudflare.com", "googlevideo.com", "youtube.com"],
                action: "route",
                outbound: $tag
            }
        ] + .route.rules
        ' "$SINGBOX_CONFIG_PATH" > "$candidate"; then
        rm -f "$candidate"
        echo -e "${RED}WARP 分流配置生成失败${PLAIN}"
        return 1
    fi

    singbox_apply_and_cleanup "$candidate" "WARP 分流已开启" "WARP 分流启用后服务启动失败"
}

singbox_disable_warp() {
    local candidate

    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    if ! jq --arg tag "$SINGBOX_WARP_TAG" '
        def is_warp_resolve:
            .action == "resolve" and
            .strategy == "ipv6_only" and
            ((.domain_suffix // []) == ["challenges.cloudflare.com", "googlevideo.com", "youtube.com"]);
        def is_warp_rule:
            (.outbound // "") == $tag or is_warp_resolve;

        .endpoints = ((.endpoints // []) | map(select(.tag != $tag))) |
        if (.endpoints | length) == 0 then del(.endpoints) else . end |
        .route = (.route // {}) |
        .route.rules = ((.route.rules // []) |
            map(select((is_warp_rule | not)))) |
        if (.route.rules | length) == 0 then del(.route.rules) else . end
        ' "$SINGBOX_CONFIG_PATH" > "$candidate"; then
        rm -f "$candidate"
        echo -e "${RED}WARP 分流配置清理失败${PLAIN}"
        return 1
    fi

    singbox_apply_and_cleanup "$candidate" "WARP 分流已关闭" "WARP 分流关闭后服务启动失败"
}

singbox_manage_warp() {
    local confirm
    if singbox_warp_enabled; then
        read -r -p "$(echo -e "${RED}WARP 分流当前已启用,是否关闭? [y/N]: ${PLAIN}")" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && singbox_disable_warp
    else
        read -r -p "$(echo -e "${BLUE}WARP 分流当前未启用,是否开启? [y/N]: ${PLAIN}")" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && singbox_enable_warp
    fi
}

singbox_modify_config() {
    local option snell_status
    while true; do
        snell_status=$(singbox_protocol_status snell)
        if [[ "$snell_status" == "未启用" ]] && ! singbox_supports_snell; then
            snell_status="需 Sing-box 1.14+"
        fi
        clear
        echo -e "${BLUE}===== Sing-box 配置管理 =====${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}AnyTLS          [${YELLOW}$(singbox_protocol_status anytls)${PLAIN}]"
        echo -e "${GREEN}2.${PLAIN}Trojan + WS + TLS [${YELLOW}$(singbox_protocol_status trojan)${PLAIN}]"
        echo -e "${GREEN}3.${PLAIN}Shadowsocks 2022[${YELLOW}$(singbox_protocol_status shadowsocks)${PLAIN}]"
        echo -e "${GREEN}4.${PLAIN}TUIC v5         [${YELLOW}$(singbox_protocol_status tuic)${PLAIN}]"
        echo -e "${GREEN}5.${PLAIN}Hysteria2       [${YELLOW}$(singbox_protocol_status hysteria2)${PLAIN}]"
        echo -e "${GREEN}6.${PLAIN}Snell v6        [${YELLOW}${snell_status}${PLAIN}]"
        echo -e "${GREEN}7.${PLAIN}WARP 分流       [${YELLOW}$(singbox_warp_status)${PLAIN}]"
        echo -e "${YELLOW}0.${PLAIN}返回上级"
        read -r -p "$(echo -e "${BLUE}请输入选项 [0-7]: ${PLAIN}")" option
        case "$option" in
            1) singbox_manage_protocol anytls ;;
            2) singbox_manage_protocol trojan ;;
            3) singbox_manage_protocol shadowsocks ;;
            4) singbox_manage_protocol tuic ;;
            5) singbox_manage_protocol hysteria2 ;;
            6) singbox_manage_protocol snell ;;
            7) singbox_manage_warp; sleep 1 ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_manage_service() {
    local option
    while true; do
        clear
        echo -e "${BLUE}✦ SingBox_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看配置"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option
        case "$option" in
            1)
                clear
                echo -e "${BLUE}===== Sing-box 当前状态 =====${PLAIN}"
                systemctl --no-pager --full status "$SINGBOX_SERVICE_NAME" || true
                pause_enter "按回车查看配置..."
                clear
                echo -e "${BLUE}===== Sing-box 当前配置 =====${PLAIN}"
                jq . "$SINGBOX_CONFIG_PATH"
                singbox_pause_and_return
                ;;
            2) singbox_modify_config ;;
            3)
                systemctl stop "$SINGBOX_SERVICE_NAME" && echo -e "${GREEN}Sing-box 已停止${PLAIN}" || echo -e "${RED}Sing-box 停止失败${PLAIN}"
                singbox_pause_and_return
                ;;
            4)
                if singbox_check_config_with "$SINGBOX_EXEC_PATH" "$SINGBOX_CONFIG_PATH" && zero_service_action restart "$SINGBOX_SERVICE_NAME"; then
                    echo -e "${GREEN}Sing-box 已重启${PLAIN}"
                else
                    echo -e "${RED}Sing-box 重启失败${PLAIN}"
                    service_failure_hint "$SINGBOX_SERVICE_NAME"
                fi
                singbox_pause_and_return
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_update_channel() {
    local channel="$1" channel_label current_version confirm backup was_active=0

    clear
    if ! singbox_is_managed || ! singbox_is_installed; then
        echo -e "${RED}未检测到由 Zero.sh 管理的 Sing-box${PLAIN}"
        singbox_pause_and_return
        return 1
    fi
    singbox_install_dependencies || {
        singbox_pause_and_return
        return 1
    }

    [[ "$channel" == "release" ]] && channel_label="正式版" || channel_label="测试版"
    current_version=$(singbox_get_current_version)
    if [[ -z "$current_version" || "$current_version" == "未知" ]]; then
        echo -e "${RED}无法读取当前 Sing-box 版本,已取消更新${PLAIN}"
        singbox_pause_and_return
        return 1
    fi

    echo -e "${BLUE}正在检查 Sing-box ${channel_label}版本...${PLAIN}"
    singbox_prepare_release "$channel" || {
        singbox_pause_and_return
        return 1
    }

    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}最新版本: ${YELLOW}${SINGBOX_STAGE_VERSION}${PLAIN}"
    if [[ "$SINGBOX_STAGE_VERSION" == "$current_version" ]]; then
        echo -e "${GREEN}当前已是最新版本,无需更新${PLAIN}"
        singbox_cleanup_stage
        singbox_pause_and_return
        return
    fi

    read -r -p "$(echo -e "${BLUE}确认切换到所选通道（可能降级），目标 Sing-box ${SINGBOX_STAGE_VERSION}? [y/N]: ${PLAIN}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        singbox_cleanup_stage
        return
    fi

    if ! singbox_download_prepared_release; then
        singbox_pause_and_return
        return 1
    fi

    if ! singbox_check_config_with "$SINGBOX_STAGE_BIN" "$SINGBOX_CONFIG_PATH"; then
        echo -e "${RED}当前配置与新版本不兼容,已取消更新${PLAIN}"
        singbox_cleanup_stage
        singbox_pause_and_return
        return 1
    fi

    backup=$(mktemp) || {
        singbox_cleanup_stage
        return 1
    }
    cp "$SINGBOX_EXEC_PATH" "$backup" || {
        rm -f "$backup"
        singbox_cleanup_stage
        return 1
    }
    systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" && was_active=1
    if (( was_active == 1 )) && ! systemctl stop "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        singbox_cleanup_stage
        echo -e "${RED}无法停止当前 Sing-box 服务,已取消更新${PLAIN}"
        singbox_pause_and_return
        return 1
    fi

    if ! singbox_atomic_install "$SINGBOX_STAGE_BIN" "$SINGBOX_EXEC_PATH" 755; then
        singbox_cleanup_stage
        if (( was_active == 0 )) || zero_service_action start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            rm -f "$backup"
            echo -e "${RED}Sing-box 更新失败,旧版本未被替换${PLAIN}"
        else
            echo -e "${RED}Sing-box 更新失败且旧服务恢复失败;备份保留在 ${backup}${PLAIN}"
            service_failure_hint "$SINGBOX_SERVICE_NAME"
        fi
        singbox_pause_and_return
        return 1
    fi

    if (( was_active == 0 )) || zero_service_action start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        echo -e "${GREEN}Sing-box 已更新到 ${SINGBOX_STAGE_VERSION}${PLAIN}"
    else
        if systemctl stop "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 &&
           singbox_atomic_install "$backup" "$SINGBOX_EXEC_PATH" 755 &&
           zero_service_action start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            rm -f "$backup"
            echo -e "${YELLOW}新版本启动失败,已恢复旧版本${PLAIN}"
        else
            echo -e "${RED}新版本启动失败且自动恢复失败;备份保留在 ${backup}${PLAIN}"
            service_failure_hint "$SINGBOX_SERVICE_NAME"
        fi
        singbox_cleanup_stage
        singbox_pause_and_return
        return 1
    fi
    singbox_cleanup_stage
    singbox_pause_and_return
}

singbox_update() {
    local option
    while true; do
        clear
        echo -e "${BLUE}✦ SingBox_Update ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}更新正式版"
        echo -e "${GREEN}  2.${PLAIN}更新测试版"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option
        case "$option" in
            1) singbox_update_channel release ;;
            2) singbox_update_channel beta ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_delete() {
    local confirm
    clear
    if ! singbox_is_managed; then
        echo -e "${YELLOW}没有检测到由 Zero.sh 管理的 Sing-box${PLAIN}"
        singbox_pause_and_return
        return
    fi
    read -r -p "$(echo -e "${RED}确定删除 Sing-box、配置和服务? [y/N]: ${PLAIN}")" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" &&
           ! systemctl stop "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            echo -e "${RED}Sing-box 服务停止失败,已取消删除${PLAIN}"
            singbox_pause_and_return
            return 1
        fi
        if ! systemctl disable "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            echo -e "${RED}Sing-box 服务禁用失败,已取消删除${PLAIN}"
            singbox_pause_and_return
            return 1
        fi
        if ! rm -f "$SINGBOX_SERVICE_FILE" "$SINGBOX_EXEC_PATH" ||
           ! rm -rf "$SINGBOX_CONFIG_DIR" ||
           ! systemctl daemon-reload >/dev/null 2>&1; then
            echo -e "${RED}Sing-box 删除不完整,请检查残留文件${PLAIN}"
            singbox_pause_and_return
            return 1
        fi
        systemctl reset-failed "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
        echo -e "${GREEN}Sing-box 已删除${PLAIN}"
    fi
    singbox_pause_and_return
}

singbox_menu() {
    local option

    while true; do
        clear
        echo -e "${BLUE}✦ SingBox_Ver.1.2 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        read -r -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option
        case "$option" in
            1) singbox_install ;;
            2)
                if ! singbox_is_managed || ! singbox_is_installed; then
                    echo -e "${RED}未安装由 Zero.sh 管理的 Sing-box${PLAIN}"
                    singbox_pause_and_return
                else
                    singbox_manage_service
                fi
                ;;
            3) singbox_update ;;
            4) singbox_delete ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

wireproxy_info()  { log_prefixed "$CYAN" "[INFO]" "$*" >&2; }
wireproxy_ok()    { log_prefixed "$GREEN" "[ OK ]" "$*" >&2; }
wireproxy_warn()  { log_prefixed "$YELLOW" "[WARN]" "$*" >&2; }
wireproxy_err()   { log_prefixed "$RED" "[ERROR]" "$*" >&2; exit 1; }

WIREPROXY_BIN="/usr/local/bin/wireproxy"
WIREPROXY_CONF_DIR="/etc/wireproxy"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
WIREPROXY_WG_WARP_CONF="/etc/wireproxy/wgcf-warp.conf"
WIREPROXY_SERVICE_NAME="wireproxy-warp"
WIREPROXY_SERVICE_FILE="/etc/systemd/system/${WIREPROXY_SERVICE_NAME}.service"

WIREPROXY_REPO="windtf/wireproxy"
WIREPROXY_WGCF_REPO="ViRb3/wgcf"
WIREPROXY_MIRROR_URL="https://cdn-wireproxy.pages.dev/windtf/wireproxy"
WIREPROXY_WGCF_MIRROR_URL="https://cdn-wgcf.pages.dev/ViRb3/wgcf"

WIREPROXY_WGCF_PATH=""
WIREPROXY_WGCF_TMP=""
WIREPROXY_ARCH=""
WIREPROXY_WGCF_ARCH=""
WIREPROXY_NET_MODE=""

WIREPROXY_DEFAULT_SOCKS_BIND="127.0.0.1:40000"
WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
WIREPROXY_SOCKS_USER=""
WIREPROXY_SOCKS_PASS=""

warp_release_latest_tag() {
    local repo="$1" mirror_url="$2" net_mode="$3" version=""

    if [[ "$net_mode" != "v6_only" ]]; then
        version="$(curl --connect-timeout 5 --max-time 20 -fsSI "https://github.com/${repo}/releases/latest" 2>/dev/null \
            | awk 'tolower($1)=="location:" {print $2}' \
            | tail -n1 \
            | tr -d '\r' \
            | awk -F/ '{print $NF}')"
    fi

    if [[ -z "$version" ]]; then
        version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${mirror_url}/releases/latest" 2>/dev/null \
            | grep -oE '/releases/tag/v[0-9.]+' \
            | sed 's#.*/##' \
            | head -n1)"
    fi

    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

warp_download_verified_asset() {
    local repo="$1" mirror_url="$2" version="$3" asset="$4" target="$5" net_mode="$6"
    local official_url="https://github.com/${repo}" source_url checksum_file expected actual

    source_url="$official_url"
    [[ "$net_mode" == "v6_only" ]] && source_url="$mirror_url"

    if ! curl --connect-timeout 5 --max-time 120 -fL \
        "${source_url}/releases/download/${version}/${asset}" -o "$target"; then
        rm -f "$target"
        [[ "$source_url" == "$mirror_url" ]] && return 1
        source_url="$mirror_url"
        curl --connect-timeout 5 --max-time 120 -fL \
            "${source_url}/releases/download/${version}/${asset}" -o "$target" || {
            rm -f "$target"
            return 1
        }
    fi

    checksum_file="${target}.checksums"
    if [[ "$net_mode" != "v6_only" ]]; then
        curl --connect-timeout 5 --max-time 30 -fsSL \
            "${official_url}/releases/download/${version}/checksums.txt" -o "$checksum_file" 2>/dev/null || true
    fi
    if [[ ! -s "$checksum_file" ]]; then
        curl --connect-timeout 5 --max-time 30 -fsSL \
            "${mirror_url}/releases/download/${version}/checksums.txt" -o "$checksum_file" 2>/dev/null || {
            rm -f "$target" "$checksum_file"
            return 1
        }
    fi

    expected="$(awk -v wanted="$asset" '{file=$2; sub(/^\*/, "", file); if (file == wanted) {print $1; exit}}' "$checksum_file")"
    actual="$(sha256sum "$target" 2>/dev/null | awk '{print $1}')"
    rm -f "$checksum_file"

    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        rm -f "$target"
        return 1
    fi

    return 0
}

wireproxy_check_root() { [[ $EUID -ne 0 ]] && wireproxy_err "请使用 root 用户运行此脚本"; }

wireproxy_require_apt() {
    command -v apt-get >/dev/null 2>&1 || wireproxy_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
}

wireproxy_check_dependencies() {
    [[ -d /run/systemd/system ]] || wireproxy_err '需要正在运行的 systemd'
    local cmd
    for cmd in curl tar systemctl sha256sum python3 jq ss; do
        command -v "$cmd" >/dev/null 2>&1 || { pkg_install curl tar coreutils python3 jq iproute2 ca-certificates || wireproxy_err '依赖安装失败'; break; }
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
        aarch64|arm64)
            WIREPROXY_ARCH="arm64"
            WIREPROXY_WGCF_ARCH="arm64"
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

wireproxy_installed_version() {
    [[ -x "$WIREPROXY_BIN" ]] || return 1
    "$WIREPROXY_BIN" --version 2>/dev/null \
        | grep -oE 'v?[0-9]+(\.[0-9]+){1,3}' \
        | head -n1 \
        | sed 's/^v//'
}

wireproxy_download_binary() {
    local version current_version asset tmpdir bin_path

    wireproxy_detect_arch
    wireproxy_detect_network
    wireproxy_info "获取 wireproxy 最新版本 ..."
    version="$(warp_release_latest_tag "$WIREPROXY_REPO" "$WIREPROXY_MIRROR_URL" "$WIREPROXY_NET_MODE" || true)"
    if [[ -z "$version" ]]; then
        [[ -x "$WIREPROXY_BIN" ]] && { wireproxy_warn "无法检查最新版本，继续使用现有 wireproxy"; return 0; }
        wireproxy_err "无法获取 wireproxy 最新版本"
    fi

    current_version="$(wireproxy_installed_version || true)"
    if [[ -n "$current_version" && "v${current_version}" == "$version" ]]; then
        wireproxy_ok "wireproxy ${version} 已是最新版本"
        return 0
    fi

    asset="wireproxy_linux_${WIREPROXY_ARCH}.tar.gz"
    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"

    if [[ -n "$current_version" ]]; then
        wireproxy_info "更新 wireproxy v${current_version} -> ${version} ..."
    else
        wireproxy_info "下载 wireproxy ${version} ..."
    fi
    if ! warp_download_verified_asset "$WIREPROXY_REPO" "$WIREPROXY_MIRROR_URL" "$version" "$asset" \
        "${tmpdir}/wireproxy.tar.gz" "$WIREPROXY_NET_MODE"; then
        rm -rf "$tmpdir"
        wireproxy_err "wireproxy 下载或 SHA256 校验失败"
    fi
    wireproxy_ok "wireproxy SHA256 校验通过"

    tar -xzf "${tmpdir}/wireproxy.tar.gz" -C "$tmpdir" || {
        rm -rf "$tmpdir"
        wireproxy_err "wireproxy 解压失败"
    }

    bin_path="$(find "$tmpdir" -type f -name wireproxy | head -n1)"
    [[ -n "$bin_path" ]] || {
        rm -rf "$tmpdir"
        wireproxy_err "压缩包中未找到 wireproxy 可执行文件"
    }

    if ! zero_atomic_install "$bin_path" "$WIREPROXY_BIN" 755; then
        rm -rf "$tmpdir"
        wireproxy_err "安装 wireproxy 可执行文件失败"
    fi
    rm -rf "$tmpdir"
    wireproxy_ok "wireproxy ${version} 已安装到 ${WIREPROXY_BIN}"
}

wireproxy_ensure_wgcf() {
    local version tmpdir asset

    wireproxy_info "获取 wgcf 最新版本 ..."
    version="$(warp_release_latest_tag "$WIREPROXY_WGCF_REPO" "$WIREPROXY_WGCF_MIRROR_URL" "$WIREPROXY_NET_MODE" || true)"
    [[ -n "$version" ]] || wireproxy_err "无法获取 wgcf 最新版本"

    asset="wgcf_${version#v}_linux_${WIREPROXY_WGCF_ARCH}"
    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"
    WIREPROXY_WGCF_TMP="${tmpdir}/wgcf"

    wireproxy_info "下载 wgcf ${version} ..."
    if ! warp_download_verified_asset "$WIREPROXY_WGCF_REPO" "$WIREPROXY_WGCF_MIRROR_URL" "$version" "$asset" \
        "$WIREPROXY_WGCF_TMP" "$WIREPROXY_NET_MODE"; then
        rm -rf "$tmpdir"
        WIREPROXY_WGCF_TMP=""
        wireproxy_err "wgcf 下载或 SHA256 校验失败"
    fi

    chmod +x "$WIREPROXY_WGCF_TMP" || {
        rm -rf "$tmpdir"
        WIREPROXY_WGCF_TMP=""
        wireproxy_err "无法设置 wgcf 执行权限"
    }
    WIREPROXY_WGCF_PATH="$WIREPROXY_WGCF_TMP"
    wireproxy_ok "wgcf SHA256 校验通过，已临时就绪"
}

wireproxy_cleanup_wgcf() {
    if [[ -n "$WIREPROXY_WGCF_TMP" ]]; then
        rm -rf "$(dirname "$WIREPROXY_WGCF_TMP")"
        WIREPROXY_WGCF_TMP=""
        WIREPROXY_WGCF_PATH=""
    fi
}

warp_valid_endpoint() {
    python3 - "$1" <<'PY'
import sys, ipaddress, re
try:
    raw=sys.argv[1]
    if raw.startswith('['):
        host,port=raw[1:].split(']:',1); ipaddress.IPv6Address(host)
    else:
        host,port=raw.rsplit(':',1)
        if ':' in host: raise ValueError()
        try: ipaddress.IPv4Address(host)
        except ValueError:
            if re.fullmatch(r'[0-9.]+',host): raise ValueError()
            if len(host)>253 or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?',label) for label in host.rstrip('.').split('.')): raise ValueError()
    if not re.fullmatch(r'[1-9][0-9]{0,4}',port) or int(port)>65535: raise ValueError()
except (ValueError,IndexError): sys.exit(1)
PY
}

warp_read_profile_json() {
    python3 - "$1" <<'PY'
import sys,configparser,json,ipaddress,base64
try:
    c=configparser.ConfigParser(interpolation=None,strict=True)
    with open(sys.argv[1]) as f:c.read_file(f)
    private=c['Interface']['PrivateKey'].strip(); public=c['Peer']['PublicKey'].strip()
    for key in (private,public):
        if len(base64.b64decode(key,validate=True))!=32:raise ValueError('WireGuard 密钥格式无效')
    addresses=[str(ipaddress.ip_interface(a.strip())) for a in c['Interface']['Address'].split(',')]
    raw=c['Peer']['Endpoint'].strip()
    if raw.startswith('['):host,port=raw[1:].split(']:',1)
    else:host,port=raw.rsplit(':',1)
    port=int(port)
    if not 1<=port<=65535 or any(x.isspace() for x in host):raise ValueError('Endpoint 无效')
    json.dump(dict(private_key=private,public_key=public,addresses=addresses,host=host,port=port),sys.stdout)
except Exception as exc:print(str(exc),file=sys.stderr);sys.exit(1)
PY
}

warp_team_register() (
    local token="$1" private public work code
    work=$(mktemp -d /tmp/zero-warp-register.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM HUP
    [[ "$token" =~ ^[A-Za-z0-9._~-]+$ ]] || { zero_error 'Token 格式无效'; exit 1; }
    private=$(wg genkey) && public=$(printf '%s' "$private" | wg pubkey) || exit 1
    printf 'Cf-Access-Jwt-Assertion: %s\nContent-Type: application/json\n' "$token" > "$work/headers"
    chmod 600 "$work/headers"
    jq -n --arg key "$public" --arg tos "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        --arg serial "$(cat /proc/sys/kernel/random/uuid)" \
        '{key:$key,install_id:"",fcm_token:"",tos:$tos,model:"Linux",serial_number:$serial}' > "$work/request"
    code=$(curl -sS --connect-timeout 10 --max-time 30 -X POST \
        https://api.cloudflareclient.com/v0a2158/reg -H "@$work/headers" \
        --data-binary "@$work/request" -o "$work/response" -w '%{http_code}') || exit 1
    [[ "$code" == 2[0-9][0-9] ]] || { zero_error "团队设备注册失败 HTTP $code"; exit 1; }
    jq -e --arg private "$private" '
        .config.interface.addresses as $addresses | .config.peers[0] as $peer |
        {private_key:$private,public_key:$peer.public_key,v4:$addresses.v4,v6:$addresses.v6,
         endpoint:$peer.endpoint.host,endpoint_v4:$peer.endpoint.v4,endpoint_v6:$peer.endpoint.v6,
         port:($peer.endpoint.ports[0] // 2408)} |
        if (.public_key|type)!="string" or (.v4|type)!="string" or (.v6|type)!="string"
        then error("注册响应结构不符合预期") else . end' "$work/response"
)

warp_team_prompt() {
    local token profile
    echo '通过 https://<组织名>.cloudflareaccess.com/warp 获取组织注册 Token。' >&2
    echo '此兼容接口可能受上游调整影响；本地卸载后仍需在组织后台清理设备。' >&2
    read -r -s -p 'JWT Token（空值取消）: ' token || return 1
    echo >&2
    [[ -n "$token" ]] || return 1
    profile=$(warp_team_register "$token") || return 1
    printf '%s\n' "$profile"
}

warp_team_endpoint() {
    local profile="$1" mode="$2" host port
    port=$(jq -r '.port' <<< "$profile")
    zero_valid_uint "$port" 1 65535 || return 1
    if [[ "$mode" == v6_only ]]; then
        host=$(jq -r '.endpoint_v6 // empty' <<< "$profile")
        if [[ "$host" == \[*\]* ]]; then host="${host#\[}"; host="${host%%\]*}"; fi
        [[ -n "$host" ]] || { zero_error '注册响应缺少 IPv6 Endpoint'; return 1; }
        printf '[%s]:%s\n' "$host" "$port"
    else
        host=$(jq -r '.endpoint // .endpoint_v4 // empty' <<< "$profile")
        [[ -n "$host" ]] || return 1
        if [[ "$host" == *:* ]]; then host="${host%:*}"; fi
        printf '%s:%s\n' "$host" "$port"
    fi
}

wireproxy_is_valid_host_port() {
    warp_valid_endpoint "$1"
}

wireproxy_is_local_bind() {
    [[ "$1" =~ ^127\.([0-9]{1,3}\.){2}[0-9]{1,3}:[0-9]{1,5}$ ||
       "$1" =~ ^localhost:[0-9]{1,5}$ ||
       "$1" =~ ^\[::1\]:[0-9]{1,5}$ ]]
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
    local input current_pass confirm

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

        if [[ -z "$WIREPROXY_SOCKS_PASS" ]]; then
            wireproxy_warn "设置用户名时密码不能为空"
            return 1
        fi
        if [[ "$WIREPROXY_SOCKS_USER" =~ [[:space:]] || "$WIREPROXY_SOCKS_PASS" =~ [[:space:]] ]]; then
            wireproxy_warn "SOCKS 用户名和密码不能包含空白字符"
            return 1
        fi
    else
        WIREPROXY_SOCKS_USER=""
        WIREPROXY_SOCKS_PASS=""
    fi

    if ! wireproxy_is_local_bind "$WIREPROXY_SOCKS_BIND" && [[ -z "$WIREPROXY_SOCKS_USER" ]]; then
        wireproxy_warn "当前监听地址可能暴露到公网，且未设置 SOCKS 认证"
        read -rp "确认继续 [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { wireproxy_warn "已取消"; return 1; }
    fi

    return 0
}

wireproxy_write_wg_conf() (
    umask 077
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5"

    install -d -m 700 "$WIREPROXY_CONF_DIR" || return 1
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
    [[ $? == 0 ]] || return 1
    chmod 600 "$WIREPROXY_WG_WARP_CONF" || return 1
    wireproxy_ok "WireGuard 配置已写入 ${WIREPROXY_WG_WARP_CONF}"
)

wireproxy_write_conf() (
    umask 077
    install -d -m 700 "$WIREPROXY_CONF_DIR" || return 1

    cat > "$WIREPROXY_CONF" <<EOF
WGConfig = ${WIREPROXY_WG_WARP_CONF}

[Socks5]
BindAddress = ${WIREPROXY_SOCKS_BIND}
EOF
    [[ $? == 0 ]] || return 1

    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        cat >> "$WIREPROXY_CONF" <<EOF
Username = ${WIREPROXY_SOCKS_USER}
Password = ${WIREPROXY_SOCKS_PASS}
EOF
    [[ $? == 0 ]] || return 1
    fi

    chmod 600 "$WIREPROXY_CONF" || return 1
    wireproxy_ok "wireproxy 配置已写入 ${WIREPROXY_CONF}"
)

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
    [[ $? == 0 ]] || return 1
    chmod 644 "$WIREPROXY_SERVICE_FILE" || return 1
}

wireproxy_validate_config() {
    local log_file="$1"
    "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" -n >"$log_file" 2>&1
}

wireproxy_try_restart_service() {
    local quiet="${1:-0}" validation_log

    validation_log="$(mktemp)" || {
        (( quiet == 0 )) && wireproxy_warn "无法创建配置校验日志"
        return 1
    }

    if ! wireproxy_validate_config "$validation_log"; then
        if (( quiet == 0 )); then
            wireproxy_warn "配置校验失败"
            cat "$validation_log"
        fi
        rm -f "$validation_log"
        return 1
    fi
    rm -f "$validation_log"

    wireproxy_create_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || wireproxy_warn "设置开机自启失败"

    if zero_service_action restart "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1; then
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

    if ! cp "$backup" "$target"; then
        wireproxy_warn "恢复文件失败，备份保留: $backup"; return 1
    fi

    if wireproxy_try_restart_service 1; then
        rm -f "$backup"
        wireproxy_warn "新配置启动失败，已回滚到上一份可用配置"
    else
        wireproxy_warn "新配置启动失败，回滚后服务仍未启动；备份: $backup"
        wireproxy_try_restart_service 0 >/dev/null 2>&1 || service_failure_hint "$WIREPROXY_SERVICE_NAME"
    fi

    return 1
}

wireproxy_prepare_install() {
    local account_type="$1"
    wireproxy_check_dependencies
    wireproxy_prompt_socks_settings || return 1
    wireproxy_download_binary
    if [[ "$account_type" == "free" ]]; then
        wireproxy_ensure_wgcf
    else
        wireproxy_ensure_wireguard_tools
    fi
}

wireproxy_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5"
    wireproxy_info "Endpoint: $endpoint"
    wireproxy_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$endpoint" || return 1
    wireproxy_write_conf || return 1
    wireproxy_restart_service || return 1
    wireproxy_fetch_trace_via_proxy_v4 | grep -Eq '^warp=(on|plus)$' ||
        { zero_error 'WireProxy 已运行但 WARP 出口验证失败'; return 1; }
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

wireproxy_cleanup_free_install() {
    local tmpdir="$1"
    cd / || true
    rm -rf "$tmpdir"
    wireproxy_cleanup_wgcf
}

# Flags in this function are read by its EXIT trap.
# shellcheck disable=SC2034
wireproxy_install_transaction() (
    local kind="$1" backup active=0 enabled=0 committed=0
    backup=$(mktemp -d /tmp/zero-wireproxy-install.XXXXXX) || exit 1
    zero_snapshot_paths "$backup" "$WIREPROXY_BIN" "$WIREPROXY_CONF_DIR" "$WIREPROXY_SERVICE_FILE" || exit 1
    systemctl is-active --quiet "$WIREPROXY_SERVICE_NAME" && active=1
    systemctl is-enabled --quiet "$WIREPROXY_SERVICE_NAME" && enabled=1
    if [[ -e "$WIREPROXY_BIN" || -d "$WIREPROXY_CONF_DIR" ]]; then
        zero_confirm '已有 WireProxy，本次将更新程序并重新配置账户，继续？' || { rm -rf "$backup"; exit 0; }
    fi
    trap 'wireproxy_cleanup_wgcf
        if (( committed == 0 )); then
            systemctl stop "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || true
            if zero_restore_paths "$backup" && systemctl daemon-reload; then
                (( enabled == 1 )) && systemctl enable "$WIREPROXY_SERVICE_NAME" || systemctl disable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || true
                if (( active == 0 )) || zero_service_action start "$WIREPROXY_SERVICE_NAME"; then rm -rf "$backup"
                else zero_error "旧服务恢复失败，备份: $backup"; fi
            else zero_error "WireProxy 回滚失败，备份: $backup"; fi
        else rm -rf "$backup"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    case "$kind" in free) wireproxy_install_free ;; team) wireproxy_install_team ;; *) exit 1 ;; esac || exit 1
    committed=1
)

wireproxy_install_free() {
    local tmpdir priv pub addr endpoint warp_v4 warp_v6

    echo ""
    wireproxy_info "免费账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install free || return 1

    tmpdir="$(mktemp -d)" || wireproxy_err "创建临时目录失败"
    cd "$tmpdir" || {
        wireproxy_cleanup_free_install "$tmpdir"
        wireproxy_err "进入临时目录失败"
    }

    wireproxy_info "注册 WARP 免费账户 ..."
    yes | "$WIREPROXY_WGCF_PATH" register >/dev/null 2>&1 || {
        wireproxy_cleanup_free_install "$tmpdir"
        wireproxy_err "WARP 注册失败"
    }

    wireproxy_info "生成 WireGuard 配置 ..."
    "$WIREPROXY_WGCF_PATH" generate >/dev/null 2>&1 || {
        wireproxy_cleanup_free_install "$tmpdir"
        wireproxy_err "配置生成失败"
    }

    priv="$(awk -F' = ' '/^PrivateKey = /{print $2}' wgcf-profile.conf)"
    pub="$(awk -F' = ' '/^PublicKey = /{print $2}' wgcf-profile.conf)"
    addr="$(awk -F' = ' '/^Address = /{print $2}' wgcf-profile.conf)"
    endpoint="$(awk -F' = ' '/^Endpoint = /{print $2}' wgcf-profile.conf)"
    warp_v4="$(printf '%s\n' "$addr" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    warp_v6="$(printf '%s\n' "$addr" | grep -oE '2606:[0-9a-f:]+' | head -n1)"

    [[ -n "$priv" && -n "$pub" && -n "$warp_v4" && -n "$warp_v6" && -n "$endpoint" ]] || {
        wireproxy_cleanup_free_install "$tmpdir"
        wireproxy_err "无法从 wgcf-profile.conf 提取 WARP 配置"
    }

    endpoint="$(wireproxy_select_endpoint_for_network "$endpoint" "" "" "")" || return 1

    wireproxy_cleanup_free_install "$tmpdir"

    wireproxy_finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$endpoint" || return 1

    echo ""
    wireproxy_ok "WARP SOCKS 配置完成"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_install_team() {
    local profile endpoint
    wireproxy_prepare_install team || return 1
    profile=$(warp_team_prompt) || return 1
    endpoint=$(warp_team_endpoint "$profile" "$WIREPROXY_NET_MODE") || return 1
    warp_valid_endpoint "$endpoint" || return 1
    wireproxy_finish_install "$(jq -r '.private_key' <<< "$profile")" "$(jq -r '.v4' <<< "$profile")" \
        "$(jq -r '.v6' <<< "$profile")" "$(jq -r '.public_key' <<< "$profile")" "$endpoint"
}

wireproxy_modify_config() {
    local current_endpoint current_mtu new_ep new_bind new_mtu input confirm escaped_value backup_file auth_label auth_color service_label service_color

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
                backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")" || return 1
                escaped_value="$(wireproxy_escape_sed_replacement "$new_ep")"
                sed -i "s|^Endpoint = .*|Endpoint = ${escaped_value}|" "$WIREPROXY_WG_WARP_CONF"
                wireproxy_ok "Endpoint 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            fi
            ;;
        2)
            echo -e "\n  当前 MTU: ${current_mtu}\n"
            read -rp "新 MTU [1280-1500]: " new_mtu
            if zero_valid_uint "$new_mtu" 1280 1500; then
                backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")" || return 1
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
                if ! wireproxy_is_local_bind "$new_bind" && [[ -z "$WIREPROXY_SOCKS_USER" ]]; then
                    wireproxy_warn "该地址可能将未认证的 SOCKS 代理暴露到公网"
                    read -rp "确认继续 [y/N]: " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] || { wireproxy_warn "已取消"; return; }
                fi
                backup_file="$(wireproxy_make_backup "$WIREPROXY_CONF")" || return 1
                escaped_value="$(wireproxy_escape_sed_replacement "$new_bind")"
                sed -i "s|^BindAddress = .*|BindAddress = ${escaped_value}|" "$WIREPROXY_CONF"
                wireproxy_ok "SOCKS 监听地址已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            fi
            ;;
        4)
            echo -e "\n  当前认证: ${auth_label}\n"
            backup_file="$(wireproxy_make_backup "$WIREPROXY_CONF")" || return 1
            if ! wireproxy_prompt_socks_settings; then
                rm -f "$backup_file"
                return
            fi
            wireproxy_write_conf
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            ;;
        5)
            backup_file="$(wireproxy_make_backup "$WIREPROXY_WG_WARP_CONF")" || return 1
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
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 返回上级"
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
            1) wireproxy_install_transaction free; wireproxy_pause ;;
            2) wireproxy_install_transaction team; wireproxy_pause ;;
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
warpstack_err()   { log_prefixed "$RED" "[ERROR]" "$*" >&2; exit 1; }

WARPSTACK_IFACE="zero-warp"
WARPSTACK_WG_CONF="/etc/wireguard/${WARPSTACK_IFACE}.conf"
WARPSTACK_WGCF_REPO="ViRb3/wgcf"
WARPSTACK_WGCF_MIRROR_URL="https://cdn-wgcf.pages.dev/ViRb3/wgcf"
WARPSTACK_APT_UPDATED=0
WARPSTACK_AUTOSTART_STATUS="未设置"
WARPSTACK_V4_ADDR=false
WARPSTACK_V6_ADDR=false
WARPSTACK_V4_READY=false
WARPSTACK_V6_READY=false

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
    warp_valid_endpoint "$1"
}

warpstack_endpoint_host() {
    wireproxy_endpoint_host "$@"
}

warpstack_endpoint_port() {
    wireproxy_endpoint_port "$@"
}

warpstack_is_ipv4_literal() {
    wireproxy_is_ipv4_literal "$@"
}

warpstack_is_ipv6_literal() {
    wireproxy_is_ipv6_literal "$@"
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
    wireproxy_escape_sed_replacement "$@"
}

warpstack_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) WARPSTACK_WGCF_ARCH="amd64" ;;
        aarch64|arm64) WARPSTACK_WGCF_ARCH="arm64" ;;
        *) warpstack_err "不支持的架构: $arch" ;;
    esac
}

warpstack_probe_network_family() {
    warpstack_fetch_trace "$1" 3 6 >/dev/null
}

warpstack_detect_network() {
    WARPSTACK_V4_ADDR=false
    WARPSTACK_V6_ADDR=false
    WARPSTACK_V4_READY=false
    WARPSTACK_V6_READY=false

    ip -4 addr show scope global 2>/dev/null | grep -q inet && WARPSTACK_V4_ADDR=true
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 && WARPSTACK_V6_ADDR=true

    $WARPSTACK_V4_ADDR && warpstack_probe_network_family -4 && WARPSTACK_V4_READY=true
    $WARPSTACK_V6_ADDR && warpstack_probe_network_family -6 && WARPSTACK_V6_READY=true

    # 私网地址也属于 scope global；网络模式应优先依据已验证的公网连通性。
    if $WARPSTACK_V4_READY && $WARPSTACK_V6_READY; then
        WARPSTACK_NET_MODE="dual"
    elif $WARPSTACK_V6_READY; then
        WARPSTACK_NET_MODE="v6_only"
    elif $WARPSTACK_V4_READY; then
        WARPSTACK_NET_MODE="v4_only"
    elif $WARPSTACK_V4_ADDR || $WARPSTACK_V6_ADDR; then
        WARPSTACK_NET_MODE="uncertain"
    else
        WARPSTACK_NET_MODE="none"
    fi
}

warpstack_show_network_status() {
    local warp_running=false config_mode=""
    if (( ${SECONDS:-0} - ${WARPSTACK_STATUS_AT:--60} >= 60 )); then
        warpstack_detect_network
        WARPSTACK_STATUS_AT=$SECONDS
    fi
    if ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1; then
        warp_running=true
        config_mode="$(warpstack_config_mode 2>/dev/null || true)"
    fi
    case "$WARPSTACK_NET_MODE" in
        dual)
            if $warp_running && [[ "$config_mode" == "add_v4" ]]; then
                echo -e "  网络: ${GREEN}IPv4✓(WARP)${NC} ${GREEN}IPv6✓(原生)${NC}"
            elif $warp_running && [[ "$config_mode" == "add_v6" ]]; then
                echo -e "  网络: ${GREEN}IPv4✓(原生)${NC} ${GREEN}IPv6✓(WARP)${NC}"
            else
                echo -e "  网络: ${GREEN}IPv4✓${NC} ${GREEN}IPv6✓${NC}"
            fi
            ;;
        v6_only) echo -e "  网络: ${RED}IPv4✗${NC} ${GREEN}IPv6✓${NC}" ;;
        v4_only) echo -e "  网络: ${GREEN}IPv4✓${NC} ${RED}IPv6✗${NC}" ;;
        uncertain) echo -e "  网络: ${YELLOW}地址存在，但联网检测异常${NC}" ;;
        none)    echo -e "  网络: ${RED}IPv4✗${NC} ${RED}IPv6✗${NC}" ;;
    esac
    if $warp_running; then
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
    command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 ||
        warpstack_install_pkg python3 jq || warpstack_err 'JSON/地址校验依赖安装失败' 
    if ! command -v curl &>/dev/null; then
        warpstack_info "安装 curl ..."
        warpstack_install_pkg curl || warpstack_err "curl 安装失败"
    fi
    if ! command -v ip &>/dev/null; then
        warpstack_info "安装 iproute2 ..."
        warpstack_install_pkg iproute2 || warpstack_err "iproute2 安装失败"
    fi
    command -v curl &>/dev/null || warpstack_err "curl 不可用，无法继续"
    command -v ip &>/dev/null || warpstack_err "ip 不可用，无法继续"
    command -v sha256sum &>/dev/null || warpstack_err "缺少依赖: sha256sum"
}

warpstack_prepare_install() {
    local account_type="$1"
    warpstack_check_dependencies
    warpstack_check_wg0_exists
    warpstack_determine_install_mode || return 1
    if [[ "$account_type" == "free" ]]; then
        warpstack_detect_arch
    fi
    warpstack_install_wireguard_tools
}

warpstack_determine_install_mode() {
    warpstack_detect_network
    case "$WARPSTACK_NET_MODE" in
        dual)
            warpstack_warn "已是双栈，无需安装"
            return 1 ;;
        uncertain)
            warpstack_err "检测到 IP 地址但联网测试失败，为避免误改路由已停止安装" ;;
        v6_only) WARPSTACK_INSTALL_MODE="add_v4"; warpstack_info "检测到纯 IPv6，将添加 IPv4 出口" ;;
        v4_only) WARPSTACK_INSTALL_MODE="add_v6"; warpstack_info "检测到纯 IPv4，将添加 IPv6 出口" ;;
        none)    warpstack_err "当前服务器无任何网络连接，无法继续" ;;
    esac
    return 0
}

warpstack_check_wg0_exists() {
    ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1 && warpstack_err "检测到 ${WARPSTACK_IFACE} 接口，请先处理后再安装"
    [[ -e "$WARPSTACK_WG_CONF" || -L "$WARPSTACK_WG_CONF" ]] &&
        warpstack_err "检测到已有 ${WARPSTACK_WG_CONF}，为避免覆盖已停止安装"
    if command -v systemctl &>/dev/null && systemctl is-enabled --quiet wg-quick@${WARPSTACK_IFACE} 2>/dev/null; then
        warpstack_err "检测到 wg-quick@${WARPSTACK_IFACE} 已启用，请先处理后再安装"
    fi
}

warpstack_write_wg_conf() (
    umask 077
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" mode="$6"
    local address allowed_ips conf_dir

    case "$mode" in
        add_v4)
            [[ -n "$v4" ]] || warpstack_err "缺少 WARP IPv4 地址，无法写入配置"
            address="${v4}/32"
            allowed_ips="0.0.0.0/0"
            ;;
        add_v6)
            [[ -n "$v6" ]] || warpstack_err "缺少 WARP IPv6 地址，无法写入配置"
            address="${v6}/128"
            allowed_ips="::/0"
            ;;
        *)
            warpstack_err "未知的 WARP 安装模式: ${mode}"
            ;;
    esac

    conf_dir="$(dirname "$WARPSTACK_WG_CONF")"
    mkdir -p "$conf_dir" || warpstack_err "无法创建 WireGuard 配置目录: ${conf_dir}"
    if ! cat > "$WARPSTACK_WG_CONF" << EOF
# Managed by Zero.sh WarpStack
[Interface]
PrivateKey = ${priv}
Address = ${address}
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = ${allowed_ips}
Endpoint = ${ep}
PersistentKeepalive = 25
EOF
    then
        rm -f "$WARPSTACK_WG_CONF"
        warpstack_err "写入 WireGuard 配置失败: ${WARPSTACK_WG_CONF}"
    fi
    if ! chmod 600 "$WARPSTACK_WG_CONF"; then
        rm -f "$WARPSTACK_WG_CONF"
        warpstack_err "设置 WireGuard 配置权限失败: ${WARPSTACK_WG_CONF}"
    fi
    warpstack_ok "${WARPSTACK_IFACE}.conf 已写入"
)

warpstack_verify_tunnel() {
    local mode="$1" attempts="${2:-3}" family trace attempt

    [[ "$mode" == "add_v4" ]] && family="-4" || family="-6"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        trace="$(warpstack_fetch_trace "$family" || true)"
        warpstack_trace_is_warp "$trace" && return 0
        (( attempt < attempts )) && sleep 1
    done
    return 1
}

warpstack_latest_handshake() {
    wg show ${WARPSTACK_IFACE} latest-handshakes 2>/dev/null |
        awk '$2 ~ /^[0-9]+$/ && $2 > latest { latest=$2 } END { print latest+0 }'
}

warpstack_cleanup_failed_install() {
    warpstack_down_wg || true
    rm -f "$WARPSTACK_WG_CONF"
}

warpstack_start_and_enable() {
    local mode="$1" handshake endpoint failure_reason
    warpstack_info "启动 ${WARPSTACK_IFACE} 隧道 ..."
    if ! wg-quick up ${WARPSTACK_IFACE}; then
        warpstack_cleanup_failed_install
        warpstack_err "${WARPSTACK_IFACE} 启动失败，本次配置已撤销"
    fi
    if ! warpstack_verify_tunnel "$mode"; then
        handshake="$(warpstack_latest_handshake)"
        endpoint="$(wg show ${WARPSTACK_IFACE} endpoints 2>/dev/null | awk 'NF { print $2; exit }')"
        if [[ "$handshake" == "0" ]]; then
            failure_reason="WireGuard 未完成握手，请检查 Endpoint 与上游 UDP 放行"
        else
            failure_reason="WireGuard 已完成握手，但隧道内 WARP 出口验证失败，请检查路由或 MTU"
        fi
        [[ -n "$endpoint" ]] && failure_reason="${failure_reason}；Endpoint: ${endpoint}"
        warpstack_cleanup_failed_install
        warpstack_err "${failure_reason}；本次配置已撤销"
    fi
    warpstack_ok "${WARPSTACK_IFACE} 隧道与 WARP 出口验证通过"
    if command -v systemctl &>/dev/null; then
        if systemctl enable wg-quick@${WARPSTACK_IFACE} &>/dev/null; then
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
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5"
    warpstack_info "Endpoint: $ep"
    warpstack_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$ep" "$WARPSTACK_INSTALL_MODE" || return 1
    warpstack_start_and_enable "$WARPSTACK_INSTALL_MODE"
    warpstack_show_result "$WARPSTACK_INSTALL_MODE"
}

warpstack_conf_value() {
    local key="$1"
    awk -F' = ' -v key="$key" '$1 == key { print $2; exit }' "$WARPSTACK_WG_CONF"
}

warpstack_public_ip() {
    local family="$1" fallback="$2" ip
    ip=$(curl -s "$family" --noproxy '*' --max-time 5 ip.gs 2>/dev/null || true)
    [[ -n "$ip" ]] && printf '%s' "$ip" || printf '%s' "$fallback"
}

warpstack_fetch_trace() {
    local family="$1" connect_timeout="${2:-5}" max_time="${3:-10}" trace=""
    trace="$(curl -fsS "$family" --noproxy '*' --connect-timeout "$connect_timeout" --max-time "$max_time" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    printf '%s\n' "$trace" | grep -q '^ip=' || return 1
    printf '%s\n' "$trace" | grep -q '^warp=' || return 1
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
    [[ "$warp" == on || "$warp" == plus ]]
}

warpstack_install_free() {
    warpstack_prepare_install free || return 1

    local tmpdir wgcf_bin wgcf_ver asset priv pub addr ep warp_v4 warp_v6
    tmpdir="$(mktemp -d)" || warpstack_err "创建临时目录失败"
    wgcf_bin="${tmpdir}/wgcf"

    warpstack_info "获取 wgcf 最新版本 ..."
    wgcf_ver="$(warp_release_latest_tag "$WARPSTACK_WGCF_REPO" "$WARPSTACK_WGCF_MIRROR_URL" "$WARPSTACK_NET_MODE" || true)"
    [[ -n "$wgcf_ver" ]] || { rm -rf "$tmpdir"; warpstack_err "无法获取 wgcf 最新版本号"; }
    asset="wgcf_${wgcf_ver#v}_linux_${WARPSTACK_WGCF_ARCH}"
    warpstack_info "下载 wgcf ${wgcf_ver} ..."
    warp_download_verified_asset "$WARPSTACK_WGCF_REPO" "$WARPSTACK_WGCF_MIRROR_URL" "$wgcf_ver" "$asset" \
        "$wgcf_bin" "$WARPSTACK_NET_MODE" || { rm -rf "$tmpdir"; warpstack_err "wgcf 下载或 SHA256 校验失败"; }
    chmod +x "$wgcf_bin" || { rm -rf "$tmpdir"; warpstack_err "无法设置 wgcf 执行权限"; }
    warpstack_ok "wgcf ${wgcf_ver} SHA256 校验通过"

    cd "$tmpdir" || { rm -rf "$tmpdir"; warpstack_err "进入临时目录失败: $tmpdir"; }

    warpstack_info "注册 WARP 免费账户 ..."
    yes | "$wgcf_bin" register || {
        cd / || true
        rm -rf "$tmpdir"
        warpstack_err "WARP 注册失败"
    }
    warpstack_ok "注册成功"

    warpstack_info "生成 WireGuard 配置 ..."
    "$wgcf_bin" generate || {
        cd / || true
        rm -rf "$tmpdir"
        warpstack_err "配置生成失败"
    }

    priv=$(awk -F' = ' '/^PrivateKey = /{print $2}' wgcf-profile.conf)
    pub=$(awk -F' = ' '/^PublicKey = /{print $2}' wgcf-profile.conf)
    addr=$(awk -F' = ' '/^Address = /{print $2}' wgcf-profile.conf)
    ep=$(awk -F' = ' '/^Endpoint = /{print $2}' wgcf-profile.conf)
    warp_v4=$(printf '%s\n' "$addr" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    warp_v6=$(printf '%s\n' "$addr" | grep -oE '2606:[0-9a-f:]+' | head -n1)

    [[ -n "$priv" && -n "$pub" && -n "$warp_v4" && -n "$warp_v6" && -n "$ep" ]] || {
        cd / || true
        rm -rf "$tmpdir"
        warpstack_err "无法从 wgcf-profile.conf 提取 WARP 配置"
    }

    warpstack_info "WARP IPv4: $warp_v4 | IPv6: $warp_v6"

    cd / || true
    rm -rf "$tmpdir"
    warpstack_ok "临时文件已清理"

    ep="$(warpstack_select_endpoint_for_network "$ep" "" "" "")" || return 1
    warpstack_finish_install "$priv" "$warp_v4" "$warp_v6" "$pub" "$ep"
}

warpstack_install_team() {
    local profile endpoint
    warpstack_prepare_install team || return 1
    profile=$(warp_team_prompt) || return 1
    endpoint=$(warp_team_endpoint "$profile" "$WARPSTACK_NET_MODE") || return 1
    warp_valid_endpoint "$endpoint" || return 1
    warpstack_finish_install "$(jq -r '.private_key' <<< "$profile")" "$(jq -r '.v4' <<< "$profile")" \
        "$(jq -r '.v6' <<< "$profile")" "$(jq -r '.public_key' <<< "$profile")" "$endpoint"
}

warpstack_config_mode() {
    local allowed
    [[ -f "$WARPSTACK_WG_CONF" ]] || return 1
    allowed="$(warpstack_conf_value "AllowedIPs")"
    if [[ "$allowed" == *"0.0.0.0/0"* ]]; then
        printf 'add_v4\n'
    elif [[ "$allowed" == *"::/0"* ]]; then
        printf 'add_v6\n'
    else
        return 1
    fi
}

warpstack_make_backup() {
    local backup
    backup="$(mktemp)" || warpstack_err "创建配置备份失败"
    cp "$WARPSTACK_WG_CONF" "$backup" || {
        rm -f "$backup"
        warpstack_err "备份配置失败"
    }
    printf '%s\n' "$backup"
}

warpstack_try_restart_wg() {
    local mode
    mode="$(warpstack_config_mode)" || return 1

    if ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1; then
        warpstack_down_wg || return 1
    fi
    if ! wg-quick up ${WARPSTACK_IFACE}; then
        warpstack_down_wg || true
        return 1
    fi
    if ! warpstack_verify_tunnel "$mode"; then
        warpstack_down_wg || true
        return 1
    fi
    return 0
}

warpstack_restart_wg_with_backup() {
    local backup="$1"

    warpstack_info "应用配置并验证 WARP 出口 ..."
    if warpstack_try_restart_wg; then
        rm -f "$backup"
        warpstack_ok "配置已生效，WARP 出口正常"
        return 0
    fi

    cp "$backup" "$WARPSTACK_WG_CONF" || {
        warpstack_warn "备份保留: $backup"
        warpstack_warn "新配置启动失败，且无法恢复原配置"
        return 1
    }
    if warpstack_try_restart_wg; then
        rm -f "$backup"
        warpstack_warn "新配置启动失败，已回滚到上一份可用配置"
    else
        warpstack_warn "新配置启动失败，回滚后隧道仍未启动；备份: $backup"
    fi
    return 1
}

warpstack_require_managed() {
    grep -qx '# Managed by Zero.sh WarpStack' "$WARPSTACK_WG_CONF" 2>/dev/null || {
        warpstack_warn '未找到本脚本管理的 ${WARPSTACK_IFACE} 配置'; return 1;
    }
}

warpstack_modify_config() {
    warpstack_require_managed || return 1
    clear
    warpstack_menu_divider
    [[ ! -f "$WARPSTACK_WG_CONF" ]] && { warpstack_warn "未找到 ${WARPSTACK_WG_CONF}，请先安装"; return; }

    local current_ep current_mtu sub new_ep escaped_ep backup_file mtu yn
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
                    backup_file="$(warpstack_make_backup)" || return 1
                    escaped_ep=$(warpstack_escape_sed_replacement "$new_ep")
                    sed -i "s|^Endpoint = .*|Endpoint = ${escaped_ep}|" "$WARPSTACK_WG_CONF"
                    warpstack_restart_wg_with_backup "$backup_file" || true
                fi
            fi
            ;;
        2)
            echo -e "  ${CYAN}当前 MTU:${NC} ${current_mtu}  建议: 1280 或 1420"
            read -rp "新 MTU [1280-1500]: " mtu
            if zero_valid_uint "$mtu" 1280 1500; then
                backup_file="$(warpstack_make_backup)" || return 1
                sed -i "s|^MTU = .*|MTU = ${mtu}|" "$WARPSTACK_WG_CONF"
                warpstack_restart_wg_with_backup "$backup_file" || true
            else
                warpstack_warn "无效的 MTU 值"
            fi
            ;;
        3)
            backup_file="$(warpstack_make_backup)" || return 1
            ${EDITOR:-nano} "$WARPSTACK_WG_CONF"
            read -rp "保存并重启验证？[Y/n]: " yn
            if [[ "$yn" =~ ^[Nn]$ ]]; then
                cp "$backup_file" "$WARPSTACK_WG_CONF"
                rm -f "$backup_file"
                warpstack_warn "已取消，配置未更改"
            else
                warpstack_restart_wg_with_backup "$backup_file" || true
            fi
            ;;
        0) return 1 ;;
        *) warpstack_warn "无效选择" ;;
    esac
}

warpstack_stop_wg() {
    warpstack_require_managed || return 1
    if ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1; then
        warpstack_info "暂停 ${WARPSTACK_IFACE} ..."
        warpstack_down_wg || warpstack_err "${WARPSTACK_IFACE} 暂停失败"
        warpstack_ok "${WARPSTACK_IFACE} 已暂停"
    else
        warpstack_warn "${WARPSTACK_IFACE} 未运行"
    fi
}

warpstack_down_wg() {
    wg-quick down ${WARPSTACK_IFACE} 2>/dev/null || true
    ! ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1
}

warpstack_restart_wg() {
    warpstack_require_managed || return 1
    warpstack_info "启动 ${WARPSTACK_IFACE} 并验证 WARP 出口 ..."
    warpstack_try_restart_wg || warpstack_err "${WARPSTACK_IFACE} 启动或 WARP 出口验证失败，隧道已停止"
    warpstack_ok "${WARPSTACK_IFACE} 已启动，WARP 出口正常"
}

warpstack_manage_service() {
    while true; do
        clear
        warpstack_menu_divider
        if ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1; then
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
    warpstack_require_managed || return 1
    local yn
    clear
    warpstack_info "删除 WARP 服务"
    echo -e "  ${RED}将删除 ${WARPSTACK_IFACE} 与配置文件${NC}"
    if { [[ -f "$WARPSTACK_WG_CONF" ]] || ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1; } &&
       ! grep -q '^# Managed by Zero.sh WarpStack$' "$WARPSTACK_WG_CONF" 2>/dev/null; then
        warpstack_warn "当前 ${WARPSTACK_IFACE} 没有 Zero.sh 标记，可能属于其他 WireGuard 服务"
        read -rp "仍要删除未标记的 ${WARPSTACK_IFACE} [y/N]: " yn
    else
        read -rp "确认删除 [y/N]: " yn
    fi
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if ip link show ${WARPSTACK_IFACE} &>/dev/null 2>&1; then
        warpstack_down_wg || warpstack_err "隧道关闭失败，请先处理后再删除"
        warpstack_ok "隧道已关闭"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl disable wg-quick@${WARPSTACK_IFACE} &>/dev/null 2>&1 && warpstack_ok "已取消自启" || warpstack_warn "取消自启失败"
    else
        warpstack_warn "未检测到 systemctl，跳过取消自启"
    fi
    rm -f "$WARPSTACK_WG_CONF"; warpstack_ok "已删除 $WARPSTACK_WG_CONF"
    warpstack_ok "WARP 服务已完全删除"
}

warpstack_show_menu() {
    echo '' 
    clear
    echo -e "${BOLD}  ╔══════════════════════════╗"
    echo -e "  ║    WARP 出口管理 v2.0 ║"
    echo -e "  ╚══════════════════════════╝${NC}"
    warpstack_show_network_status
    warpstack_menu_divider
    echo -e "  ${BOLD}操作:${NC}"
    echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
    echo -e "  ${YELLOW}3)${NC} 管理服务   ${RED}4)${NC} 删除服务"
    echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 返回上级"
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
            5) warpstack_detect_network; WARPSTACK_STATUS_AT=$SECONDS; warpstack_show_ip; warpstack_pause ;;
            0) return 0 ;;
            *) warpstack_warn "无效选项"; warpstack_pause ;;
        esac
    done
}

reinstall_system_menu() { ( reinstall_menu ); press_any_key_to_continue; }
reboot_system()         { reboot_vps; }
configure_mihomo()      { mihomo_menu; }
configure_singbox()     { singbox_menu; }
configure_wireproxy() {
    local rc
    ( wireproxy_menu )
    rc=$?
    (( rc == 0 )) || press_any_key_to_continue "WireProxy 已退出，按任意键返回菜单..."
}
configure_warpstack() {
    local rc
    WARPSTACK_IFACE=zero-warp
    if [[ ! -e /etc/wireguard/zero-warp.conf ]] && grep -qx '# Managed by Zero.sh WarpStack' /etc/wireguard/wg0.conf 2>/dev/null; then
        WARPSTACK_IFACE=wg0
    fi
    WARPSTACK_WG_CONF="/etc/wireguard/$WARPSTACK_IFACE.conf"
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

firewall_owned_snapshot() {
    local command="$1" destination="$2" temp
    temp=$(mktemp) || return 1
    "$command-save" > "$temp" || { rm -f "$temp"; return 1; }
    awk '
        /^\*/ {table=substr($0,2); body=""; found=0; next}
        /^:ZERO_INPUT / || /^:ZERO_PORT_JUMP / {body=body $0 "\n"; found=1; next}
        /zero-acme-temporary/ {next}
        /^-A ZERO_INPUT / || /^-A ZERO_PORT_JUMP / {body=body $0 "\n"; next}
        /^COMMIT/ {if(found) printf "*%s\n%sCOMMIT\n",table,body}
    ' "$temp" > "$destination"
    local result=$?; rm -f "$temp"; return "$result"
}

firewall_restore_owned_file() {
    local cmd="$1" file="$2" table chain parent
    for table in filter nat; do
        [[ "$table" == filter ]] && { chain="$ZERO_FW_CHAIN"; parent=INPUT; } || { chain="$ZERO_PORT_JUMP_CHAIN"; parent=PREROUTING; }
        firewall_supports_table "$cmd" "$table" || continue
        if ! grep -q "^:$chain " "$file"; then
            firewall_ensure_rule_absent "$cmd" "$table" "$parent" -j "$chain" &&
                firewall_delete_chain "$cmd" "$table" "$chain" || return 1
        fi
    done
    if [[ -s "$file" ]]; then "$cmd-restore" -w 5 --noflush < "$file" || return 1; fi
    for table in filter nat; do
        [[ "$table" == filter ]] && { chain="$ZERO_FW_CHAIN"; parent=INPUT; } || { chain="$ZERO_PORT_JUMP_CHAIN"; parent=PREROUTING; }
        grep -q "^:$chain " "$file" || continue
        firewall_rule_exists "$cmd" "$table" "$parent" -j "$chain" ||
            firewall_exec "$cmd" -t "$table" -I "$parent" 1 -j "$chain" || return 1
    done
}

firewall_write_restore_service() {
    local helper=/usr/local/lib/zero-firewall-restore.sh function
    install -d -m 700 /usr/local/lib || return 1
    {
        echo '#!/bin/bash'
        echo 'set -u'
        printf 'ZERO_FW_CHAIN=%q\nZERO_PORT_JUMP_CHAIN=%q\nRED=%q\nPLAIN=%q\n' "$ZERO_FW_CHAIN" "$ZERO_PORT_JUMP_CHAIN" "$RED" "$PLAIN"
        for function in firewall_exec_quiet firewall_exec firewall_supports_table firewall_chain_exists firewall_flush_chain firewall_delete_chain firewall_rule_exists firewall_ensure_rule_absent firewall_restore_owned_file; do
            declare -f "$function"
        done
        printf '[[ ! -f %q ]] || firewall_restore_owned_file iptables %q || exit 1\n' "$FIREWALL_RULES_V4" "$FIREWALL_RULES_V4"
        printf '[[ ! -f %q ]] || firewall_restore_owned_file ip6tables %q || exit 1\n' "$FIREWALL_RULES_V6" "$FIREWALL_RULES_V6"
    } > "$helper" || return 1
    chmod 700 "$helper" || return 1
    cat > "$ZERO_FIREWALL_SERVICE" <<EOF
[Unit]
Description=Restore only Zero.sh managed firewall chains
After=network-pre.target
Before=network.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=$helper
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
    local cmd target candidate
    install -d -m 700 "$FIREWALL_RULE_DIR" || return 1
    for cmd in iptables ip6tables; do
        command -v "$cmd-save" >/dev/null 2>&1 || continue
        [[ "$cmd" == iptables ]] && target="$FIREWALL_RULES_V4" || target="$FIREWALL_RULES_V6"
        candidate=$(mktemp) || return 1
        if ! firewall_owned_snapshot "$cmd" "$candidate" || ! zero_atomic_install "$candidate" "$target" 600; then
            rm -f "$candidate"; zero_error '防火墙规则当前已应用，但持久化失败'; return 1
        fi
        rm -f "$candidate"
    done
    firewall_setup_persistence || { zero_error '规则已保存，但自启动配置失败'; return 1; }
}

firewall_create_backup() {
    local v4='' v6=''
    if command -v iptables-save >/dev/null 2>&1; then
        v4=$(mktemp) || return 1
        firewall_owned_snapshot iptables "$v4" || { rm -f "$v4"; return 1; }
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        v6=$(mktemp) || { rm -f "$v4"; return 1; }
        firewall_owned_snapshot ip6tables "$v6" || { rm -f "$v4" "$v6"; return 1; }
    fi
    [[ -n "$v4$v6" ]] || return 1
    printf '%s|%s\n' "$v4" "$v6"
}

firewall_restore_backup() {
    local v4 v6 restored=0
    IFS='|' read -r v4 v6 <<< "$1"
    if [[ -n "$v4" && -f "$v4" ]]; then firewall_restore_owned_file iptables "$v4" || return 1; restored=1; fi
    if [[ -n "$v6" && -f "$v6" ]]; then firewall_restore_owned_file ip6tables "$v6" || return 1; restored=1; fi
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
        FIREWALL_FAILED_BACKUP="$backup"
        echo -e "${RED}${failed_msg}; 备份: $backup${PLAIN}"
    fi
}

firewall_dispose_backup() {
    local backup="${1:-}"
    [[ -n "$backup" && "$backup" != "${FIREWALL_FAILED_BACKUP:-}" ]] && firewall_remove_backup "$backup"
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





firewall_render_merged_chain() {
    local table="$1" chain="$2" title="$3" cmd
    echo "${title}（逐地址族，按实际匹配顺序）:"
    for cmd in iptables ip6tables; do
        firewall_chain_exists "$cmd" "$table" "$chain" || continue
        echo "[$cmd]"
        "$cmd" -t "$table" -S "$chain" || return 1
    done
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
        echo -e "${YELLOW}已检测到当前脚本管理的端口跳跃规则,请先使用「修改跳跃」或「删除跳跃」${PLAIN}"
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
    if ! zero_valid_uint "$start_port" 1 65535 || ! zero_valid_uint "$end_port" 1 65535 || (( start_port > end_port )); then
        echo -e "${RED}无效端口范围,必须在 1-65535 且起始不大于结束${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local target_port
    read -r -p "$(echo -e "${YELLOW}请输入目标 UDP 端口: ${PLAIN}")" target_port
    target_port=$(trim_input "$target_port")
    if ! zero_valid_uint "$target_port" 1 65535; then
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

    firewall_save_rules || zero_error "当前规则已应用，但持久化失败，请修复后重新保存"
    firewall_dispose_backup "$backup"
    echo -e "${YELLOW}请在入站规则中放行目标 UDP ${target_port}；云安全组需放行外部跳跃端口范围。${PLAIN}"
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

    firewall_save_rules || zero_error "当前规则已应用，但持久化失败，请修复后重新保存"
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
    echo -e "${GREEN}3.清空脚本入站规则（保留端口跳跃）${PLAIN}"
    echo -e "${RED}4.新入站仅放行SSH（保留必要基础流量）${PLAIN}"
    echo -e "${BLUE}5.查看脚本规则（保留真实顺序）${PLAIN}"
    echo -e "${GREEN}6.配置端口跳跃${PLAIN}"
    echo -e "${YELLOW}0.返回主菜单${PLAIN}"
    echo -e "${BLUE}===============================${PLAIN}"
}

# Flags in this function are read by its EXIT trap.
# shellcheck disable=SC2034
handle_firewall_action_choice() (
    local action="$1" port="$2" backup completed=0
    case "$action" in 1|2|3|4|6) ;; *) handle_firewall_action_choice_impl "$@"; exit $? ;; esac
    backup=$(firewall_create_backup) || { zero_error '不能创建修改前备份'; exit 1; }
    trap 'if (( completed == 0 )); then
        if firewall_restore_backup "$backup"; then firewall_remove_backup "$backup"
        else zero_error "中断后防火墙恢复失败，备份: $backup"; fi
    else firewall_remove_backup "$backup"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    handle_firewall_action_choice_impl "$action" "$port"
    completed=1
)

handle_firewall_action_choice_impl() {
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

                if ! zero_valid_uint "$start_port" 1 65535 || ! zero_valid_uint "$end_port" 1 65535 || (( start_port > end_port )); then
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
                firewall_save_rules || zero_error "当前规则已应用，但持久化失败，请修复后重新保存"
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
                firewall_save_rules || zero_error "当前规则已应用，但持久化失败，请修复后重新保存"
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
                firewall_save_rules || zero_error "当前规则已应用，但持久化失败，请修复后重新保存"
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

    firewall_setup_persistence || zero_error "防火墙开机恢复服务尚未就绪"

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
    echo -e "${BLUE}✦ Steins Gate_Ver.${ZERO_VERSION} ✦${PLAIN}"
    echo -e "${GREEN}  01.${PLAIN}系统更新"
    echo -e "${GREEN}  02.${PLAIN}系统清理"
    echo -e "${GREEN}  03.${PLAIN}重装系统"
    echo -e "${GREEN}  04.${PLAIN}设置时区"
    echo -e "${GREEN}  05.${PLAIN}IP优先级"
    echo -e "${GREEN}  06.${PLAIN}配置BBR"
    echo -e "${GREEN}  07.${PLAIN}配置DNS"
    echo -e "${GREEN}  08.${PLAIN}配置SSH"
    echo -e "${GREEN}  09.${PLAIN}重启VPS"
    echo -e "${GREEN}  10.${PLAIN}配置ACME"
    echo -e "${GREEN}  11.${PLAIN}配置Mihomo"
    echo -e "${GREEN}  12.${PLAIN}配置SingBox"
    echo -e "${GREEN}  13.${PLAIN}配置FireWall"
    echo -e "${GREEN}  14.${PLAIN}配置WireProxy"
    echo -e "${GREEN}  15.${PLAIN}配置WarpStack"
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
        10) acme_menu ;;
        11) configure_mihomo ;;
        12) configure_singbox ;;
        13) configure_firewall ;;
        14) configure_wireproxy ;;
        15) configure_warpstack ;;
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
        choice=$(read_menu_choice "✦ Choice [0-15] ✦ : ") || break
        handle_main_menu_choice "$choice" || break
    done
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if (( BASH_VERSINFO[0] < 4 )); then
        zero_error '需要 Bash 4 或更高版本'; exit 1
    fi
    (( EUID == 0 )) || { zero_error '请用 root 用户运行本脚本'; exit 1; }
    check_supported_system || exit 1
    [[ -t 0 ]] || { zero_error '请在交互终端中运行'; exit 1; }
    exec 9>/run/zero-manager.lock
    flock -n 9 || { zero_error '另一个 Zero.sh 实例正在运行'; exit 1; }
    main_menu
fi
