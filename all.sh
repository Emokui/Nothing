#!/usr/bin/env bash

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

DNS_V4_LIST='8.8.8.8 1.1.1.1'
DNS_V6_LIST='2001:4860:4860::8888 2606:4700:4700::1111'
DNS_LIST="${DNS_V4_LIST} ${DNS_V6_LIST}"

check_sys() {
    release=''
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) release="$ID" ;;
        esac
    fi
}

install_dependencies() {
    apt-get update
    apt-get install -y xz-utils openssl gawk file wget cpio gzip iproute2 util-linux
}

require_commands() {
    local missing=0 cmd=''
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "[${Green_font_prefix}ok${Font_color_suffix}]\t${cmd}"
        else
            echo -e "[${Red_font_prefix}missing${Font_color_suffix}]\t${cmd}"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || {
        echo -e "${Error} 缺少依赖，请先修复环境。"
        exit 1
    }
}

cidr_to_netmask() {
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

get_default_interface() {
    local iface=''
    iface=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    fi
    echo "$iface"
}

ipv6_prefix_to_netmask() {
    local n="${1:-128}" mask='' i='' bits='' value=''
    for ((i = 0; i < 8; i++)); do
        bits=$((n - i * 16))
        if ((bits >= 16)); then
            value='ffff'
        elif ((bits <= 0)); then
            value='0'
        else
            value=$(printf '%x' $(((0xffff << (16 - bits)) & 0xffff)))
        fi
        if [[ -z "$mask" ]]; then
            mask="$value"
        else
            mask="${mask}:$value"
        fi
    done
    echo "$mask"
}

is_private_or_special_ipv4() {
    local ip="$1"
    case "$ip" in
        10.*|127.*|169.254.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[0-1].*|192.168.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

get_public_ipv4_from_imds() {
    local value=''
    value=$(wget -qO- --timeout=1 --tries=1 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null | tr -d '\r' | head -n1)
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$value"
    fi
}

get_target_disk() {
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

get_grub() {
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

low_mem() {
    local mem=''
    mem=$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | grep -o "[0-9]*")
    [[ -n "$mem" ]] || return 0
    [[ "$mem" -le "524288" ]] && return 1 || return 0
}

validate_grub_config() {
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

detect_current_ssh_port() {
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

select_debian_mirror() {
    local dist="$1" current='' url=''
    for current in "https://deb.debian.org/debian" "https://archive.debian.org/debian"; do
        url="${current}/dists/${dist}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz"
        if wget --spider --timeout=3 -o /dev/null "$url"; then
            echo "$current"
            return 0
        fi
    done
    return 1
}

gather_network_state() {
    local iaddr='' ip6_line='' ip6_route=''

    NETWORK_INTERFACE=$(get_default_interface)
    [[ -n "$NETWORK_INTERFACE" ]] || {
        echo -e "${Error} 未检测到默认网卡。"
        exit 1
    }

    IPV4_ADDR=''
    IPV4_PREFIX=''
    IPV4_MASK=''
    IPV4_GATE=''
    PUBLIC_IPV4_ADDR=''
    iaddr=$(ip -4 addr show dev "$NETWORK_INTERFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    if [[ -n "$iaddr" ]]; then
        IPV4_ADDR="${iaddr%/*}"
        IPV4_PREFIX="${iaddr#*/}"
        IPV4_MASK=$(cidr_to_netmask "$IPV4_PREFIX")
        IPV4_GATE=$(ip -4 route show default dev "$NETWORK_INTERFACE" 2>/dev/null | awk '/^default/ {print $3; exit}')
        [[ -n "$IPV4_GATE" ]] || IPV4_GATE=$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $3; exit}')
        if ! is_private_or_special_ipv4 "$IPV4_ADDR"; then
            PUBLIC_IPV4_ADDR="$IPV4_ADDR"
        fi
    fi
    if [[ -z "$PUBLIC_IPV4_ADDR" ]]; then
        PUBLIC_IPV4_ADDR=$(get_public_ipv4_from_imds)
    fi

    IPV6_MODE='none'
    IPV6_ADDR=''
    IPV6_PREFIX=''
    IPV6_GATE=''
    IPV6_NETMASK=''

    ip6_line=$(ip -6 addr show dev "$NETWORK_INTERFACE" scope global 2>/dev/null | awk '/inet6 / && $0 !~ / temporary / && $0 !~ / deprecated / {print; exit}')
    if [[ -n "$ip6_line" ]]; then
        IPV6_ADDR=$(echo "$ip6_line" | awk '{print $2}' | cut -d/ -f1)
        IPV6_PREFIX=$(echo "$ip6_line" | awk '{print $2}' | cut -d/ -f2)
        IPV6_NETMASK=$(ipv6_prefix_to_netmask "$IPV6_PREFIX")
        ip6_route=$(ip -6 route show default dev "$NETWORK_INTERFACE" 2>/dev/null | head -n1)
        IPV6_GATE=$(echo "$ip6_route" | awk '/^default/ {print $3; exit}')
        if echo "$ip6_line $ip6_route" | grep -Eq 'proto[[:space:]]+ra|(^|[[:space:]])dynamic([[:space:]]|$)|(^|[[:space:]])mngtmpaddr([[:space:]]|$)'; then
            IPV6_MODE='auto'
        elif [[ -n "$IPV6_GATE" ]]; then
            IPV6_MODE='static'
        else
            IPV6_MODE='auto'
        fi
    fi

    if [[ -n "$PUBLIC_IPV4_ADDR" && "$IPV6_MODE" != 'none' ]]; then
        NETWORK_STACK='dual-stack'
    elif [[ -n "$PUBLIC_IPV4_ADDR" ]]; then
        NETWORK_STACK='ipv4-only'
    elif [[ "$IPV6_MODE" != 'none' ]]; then
        NETWORK_STACK='ipv6-only'
    elif [[ -n "$IPV4_ADDR" ]]; then
        NETWORK_STACK='private-ipv4-only'
    else
        echo -e "${Error} 当前既未检测到可用 IPv4，也未检测到可用 IPv6。"
        exit 1
    fi
}

build_ipv4_block() {
    [[ -n "$IPV4_ADDR" ]] || return
    cat <<EOF
iface \$iface inet static
    address ${IPV4_ADDR}
    netmask ${IPV4_MASK}
    gateway ${IPV4_GATE}
    dns-nameservers ${DNS_V4_LIST}
EOF
}

build_ipv6_block() {
    local gateway_line=''
    case "$IPV6_MODE" in
        auto)
            cat <<EOF
iface \$iface inet6 dhcp
    accept_ra 2
    autoconf 1
    dns-nameservers ${DNS_V6_LIST}
EOF
            ;;
        static)
            if [[ -n "$IPV6_GATE" ]]; then
                gateway_line="    gateway ${IPV6_GATE}"
            else
                gateway_line=''
            fi
            cat <<EOF
iface \$iface inet6 static
    address ${IPV6_ADDR}/${IPV6_PREFIX}
${gateway_line}
    dns-nameservers ${DNS_V6_LIST}
EOF
            ;;
        *)
            ;;
    esac
}

build_preseed_network_block() {
    case "$NETWORK_STACK" in
        dual-stack|ipv4-only|private-ipv4-only)
            cat <<EOF
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string ${IPV4_ADDR}
d-i netcfg/get_netmask string ${IPV4_MASK}
d-i netcfg/get_gateway string ${IPV4_GATE}
d-i netcfg/get_nameservers string ${DNS_V4_LIST}
d-i netcfg/confirm_static boolean true
EOF
            ;;
        ipv6-only)
            if [[ -n "$IPV6_ADDR" && -n "$IPV6_NETMASK" ]]; then
                cat <<EOF
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string ${IPV6_ADDR}
d-i netcfg/get_netmask string ${IPV6_NETMASK}
d-i netcfg/get_gateway string ${IPV6_GATE:-none}
d-i netcfg/get_nameservers string ${DNS_V6_LIST}
d-i netcfg/confirm_static boolean true
EOF
            else
                cat <<EOF
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string ${IPV6_ADDR}
d-i netcfg/get_netmask string ${IPV6_NETMASK}
d-i netcfg/get_gateway string ${IPV6_GATE:-none}
d-i netcfg/get_nameservers string ${DNS_V6_LIST}
d-i netcfg/confirm_static boolean true
EOF
            fi
            ;;
    esac
}

write_post_install_script() {
    local ipv4_block='' ipv6_block=''
    ipv4_block=$(build_ipv4_block)
    ipv6_block=$(build_ipv6_block)

    cat > /tmp/boot/post-install.sh <<EOF
#!/bin/sh
set -eu

iface=\$(awk '/^(auto|allow-hotplug)[[:space:]]+/ {for (i = 2; i <= NF; i++) if (\$i != "lo") {print \$i; exit}}' /etc/network/interfaces 2>/dev/null || true)
[ -n "\$iface" ] || iface='${NETWORK_INTERFACE}'

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
EOF_INTERFACES
${ipv4_block}
${ipv6_block}

update_sshd_option Port ${SSH_PORT}
update_sshd_option PermitRootLogin yes
update_sshd_option PasswordAuthentication yes
update_sshd_option PubkeyAuthentication yes
EOF
    chmod 700 /tmp/boot/post-install.sh
}

install_target_system() {
    local debian_version="$1"
    local dist='' grub='' grub_dir='' grub_file='' grub_ver='' grub_backup=''
    local mirror='' mirror_host='' mirror_folder='' target_disk=''
    local read_grub='' load_num='' cfg0='' cfg1='' cfg2='' insert_grub=''
    local type='' linux_kernel='' linux_img='' add_option='' boot_option='' grub_tmp=''
    local root_password_hash='' partman_early_command='' late_command='' network_preseed=''

    case "$debian_version" in
        11) dist='bullseye' ;;
        12) dist='bookworm' ;;
        13) dist='trixie' ;;
        *)
            echo -e "${Error} 不支持的 Debian 版本: ${debian_version}"
            exit 1
            ;;
    esac

    require_commands ip wget awk grep sed cut cat lsblk cpio gzip find dirname basename openssl findmnt xargs
    gather_network_state

    target_disk=$(get_target_disk)
    [[ -n "$target_disk" ]] || {
        echo -e "${Error} 未检测到目标磁盘。"
        exit 1
    }

    grub=$(get_grub "/boot")
    [[ -n "$grub" ]] || {
        echo -e "${Error} 未找到 GRUB 配置。"
        exit 1
    }
    grub_dir=$(echo "$grub" | cut -d: -f1)
    grub_file=$(echo "$grub" | cut -d: -f2)
    grub_ver=$(echo "$grub" | cut -d: -f3)
    [[ "$grub_ver" == "0" ]] || {
        echo -e "${Error} 当前仅支持 GRUB2。"
        exit 1
    }

    mirror=$(select_debian_mirror "$dist")
    [[ -n "$mirror" ]] || {
        echo -e "${Error} 未找到可用 Debian 镜像。"
        exit 1
    }

    root_password_hash=$(openssl passwd -1 "$ROOT_PASSWORD")

    clear
    echo -e "\n${Blue_font_prefix}# Install${Font_color_suffix}\n"
    echo -e "${Tip} 目标系统: Debian ${debian_version} (${dist})"
    echo -e "${Tip} 目标磁盘: ${target_disk}"
    case "$NETWORK_STACK" in
        dual-stack) echo -e "${Tip} 网络类型: 双栈" ;;
        ipv4-only) echo -e "${Tip} 网络类型: 仅 IPv4" ;;
        ipv6-only)
            if [[ -n "$IPV4_ADDR" ]]; then
                echo -e "${Tip} 网络类型: 仅 IPv6（带私有 IPv4）"
            else
                echo -e "${Tip} 网络类型: 仅 IPv6"
            fi
            ;;
        private-ipv4-only) echo -e "${Tip} 网络类型: 仅私有 IPv4" ;;
    esac
    if [[ -n "$IPV4_ADDR" ]]; then
        if [[ -n "$PUBLIC_IPV4_ADDR" ]]; then
            echo -e "${Tip} IPv4: ${IPV4_ADDR}/${IPV4_PREFIX} gw ${IPV4_GATE} (公网 IPv4: ${PUBLIC_IPV4_ADDR})"
        else
            echo -e "${Tip} IPv4: ${IPV4_ADDR}/${IPV4_PREFIX} gw ${IPV4_GATE} (仅私有 IPv4)"
        fi
    else
        echo -e "${Tip} IPv4: 当前未检测到"
    fi
    case "$IPV6_MODE" in
        auto) echo -e "${Tip} IPv6: 自动继承（当前环境检测为自动下发）" ;;
        static) echo -e "${Tip} IPv6: 静态继承 ${IPV6_ADDR}/${IPV6_PREFIX} gw ${IPV6_GATE}" ;;
        none) echo -e "${Tip} IPv6: 当前未检测到可继承配置" ;;
    esac

    mirror_host=$(echo "$mirror" | awk -F'://|/' '{print $2}')
    mirror_folder=$(echo "$mirror" | awk -F"${mirror_host}" '{print $2}')
    [[ -n "$mirror_folder" ]] || mirror_folder='/'

    wget -qO /tmp/initrd.img "${mirror}/dists/${dist}/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz" || {
        echo -e "${Error} 下载 initrd 失败。"
        exit 1
    }
    wget -qO /tmp/vmlinuz "${mirror}/dists/${dist}/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux" || {
        echo -e "${Error} 下载内核失败。"
        exit 1
    }

    [[ -f "${grub_dir}/${grub_file}" ]] || {
        echo -e "${Error} 找不到 ${grub_file}。"
        exit 1
    }
    grub_backup="${grub_dir}/${grub_file}.installnet.$(date +%Y%m%d%H%M%S).bak"
    cp -f "${grub_dir}/${grub_file}" "$grub_backup" || {
        echo -e "${Error} 备份 GRUB 失败。"
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
            echo -e "${Error} 解析 GRUB 菜单失败。"
            exit 1
        }
        sed -n "${cfg0},${cfg1}p" "$read_grub" > /tmp/grub.new
    else
        echo -e "${Error} 未找到可复用的 GRUB 菜单项。"
        exit 1
    fi

    sed -i "/menuentry.*/c\\menuentry\\ 'Install OS [${dist} amd64]' --class debian --class gnu-linux --class gnu --class os {" /tmp/grub.new
    sed -i "/echo.*Loading/d" /tmp/grub.new
    insert_grub=$(awk '/menuentry / {print NR}' "${grub_dir}/${grub_file}" | head -n1)
    [[ -n "$insert_grub" && "$insert_grub" -gt 0 ]] || {
        echo -e "${Error} 定位 GRUB 插入位置失败。"
        exit 1
    }

    if grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new | awk '{print $2}' | tail -n1 | grep -q '^/boot/'; then
        type='InBoot'
    else
        type='NoBoot'
    fi
    linux_kernel=$(grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new | awk '{print $1}' | head -n1)
    [[ -n "$linux_kernel" ]] || {
        echo -e "${Error} 读取 GRUB 内核项失败。"
        exit 1
    }
    linux_img=$(grep 'initrd.*/' /tmp/grub.new | awk '{print $1}' | tail -n1)
    if [[ -z "$linux_img" ]]; then
        sed -i "/$linux_kernel.*\//a\\\tinitrd /" /tmp/grub.new
        linux_img='initrd'
    fi

    add_option=''
    low_mem || add_option=' lowmem=+0'
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

    if ! validate_grub_config "${grub_dir}/${grub_file}"; then
        cp -f "$grub_backup" "${grub_dir}/${grub_file}"
        echo -e "${Error} GRUB 语法校验失败，已回滚。"
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

    write_post_install_script

    partman_early_command='debconf-set partman-auto/disk "$(list-devices disk | head -n1)"'
    late_command='cp /post-install.sh /target/root/reinstall-post.sh; chmod 700 /target/root/reinstall-post.sh; in-target /bin/sh /root/reinstall-post.sh; rm -f /target/root/reinstall-post.sh'
    network_preseed=$(build_preseed_network_block)

    cat > /tmp/boot/preseed.cfg <<EOF
d-i debian-installer/locale string en_US
d-i console-setup/layoutcode string us
d-i keyboard-configuration/xkb-keymap string us

${network_preseed}

d-i hw-detect/load_firmware boolean true

d-i mirror/country string manual
d-i mirror/http/hostname string ${mirror_host}
d-i mirror/http/directory string ${mirror_folder}
d-i mirror/http/proxy string
d-i apt-setup/contrib boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/non-free-firmware boolean true

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
d-i pkgsel/include string openssh-server isc-dhcp-client
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

    echo -e "${Info} 安装引导已写入，系统将在 3 秒后自动重启继续安装。"
    sleep 3
    reboot || sudo reboot >/dev/null 2>&1
}

reinstall_debian() {
    local debian_version="$1" pw='' pw2='' confirm='' target_disk=''

    read -r -s -p " 请设置 root 密码: " pw
    echo
    [[ -n "$pw" ]] || {
        echo -e "${Error} 密码不能为空。"
        return
    }

    read -r -s -p " 请再次输入 root 密码: " pw2
    echo
    [[ "$pw" == "$pw2" ]] || {
        echo -e "${Error} 两次输入密码不一致。"
        return
    }

    SSH_PORT=$(detect_current_ssh_port)
    ROOT_PASSWORD="$pw"
    target_disk=$(get_target_disk)

    echo -e "${Tip} 将使用 Debian ${debian_version} 执行重装。"
    echo -e "${Tip} 目标磁盘: ${target_disk:-未检测到}"
    echo -e "${Tip} 重装后 SSH 端口将保持为: ${SSH_PORT}"
    echo -e "${Tip} 默认 DNS: ${DNS_LIST}"
    echo -e "${Tip} 输入 YES 后将写入安装引导并自动重启。"
    read -r -p " 输入「YES」确认开始重装，其它键取消: " confirm
    [[ "$confirm" == "YES" ]] || {
        echo -e "${Tip} 已取消重装。"
        return
    }

    install_target_system "$debian_version"
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
    echo -e "${Blue_font_prefix}一键网络重装管理脚本${Font_color_suffix}"
    echo
    echo -e "————————————重装系统————————————"
    echo -e " ${Green_font_prefix}1.${Font_color_suffix} 重装 Debian 11"
    echo -e " ${Green_font_prefix}2.${Font_color_suffix} 重装 Debian 12"
    echo -e " ${Green_font_prefix}3.${Font_color_suffix} 重装 Debian 13"
    echo -e " ${Green_font_prefix}0.${Font_color_suffix} 退出脚本"
    echo
}

main_loop() {
    local num=''
    while true; do
        start_menu
        read -r -p " 请输入数字 [0-3]: " num
        num=$(echo "$num" | grep -oE '^[0-9]+$')
        case "$num" in
            1) reinstall_debian11 ;;
            2) reinstall_debian12 ;;
            3) reinstall_debian13 ;;
            0)
                echo -e "${Info} 脚本已退出。"
                break
                ;;
            *)
                echo -e "${Error} 请输入正确数字 [0-3]"
                sleep 1
                ;;
        esac
    done
}

check_sys
[[ "$EUID" -eq 0 ]] || {
    echo -e "${Error} 请使用 root 权限运行此脚本。"
    exit 1
}
[[ -n "${release:-}" ]] || {
    echo -e "${Error} 当前仅支持在 Debian/Ubuntu 环境中运行。"
    exit 1
}

install_dependencies
main_loop
