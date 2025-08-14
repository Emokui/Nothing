#!/bin/bash

RED='\033[0;31m'
GREEN="\033[1;32m"
YELLOW='\033[1;33m'
BLUE="\033[1;34m"
PLAIN='\033[0m'

readonly SNELL_DIR="/root/snell"
readonly SNELL_CONFIGS="${SNELL_DIR}/configs"
readonly SNELL_BIN="${SNELL_DIR}/snell-server"
readonly SNELL_VERSION_FILE="${SNELL_DIR}/version"
readonly TFO_SYSCTL_CONF="/etc/sysctl.d/local.conf"

download_and_extract_snell() {
    local url="$1"
    local zip_file="$2"
    local version="$3"
    local arch="$4"
    
    mkdir -p "$SNELL_DIR"
    cd "$SNELL_DIR"
    
    echo -e "${YELLOW}下载 Snell（${arch}，${version}）...${PLAIN}"
    if ! wget --no-check-certificate -N "$url" -O "$zip_file"; then
        echo -e "${RED}Snell 下载失败,请检查网络连接!${PLAIN}"
        return 1
    fi
    
    install_unzip_if_missing
    if ! unzip -o "$zip_file"; then
        echo -e "${RED}Snell 解压失败!${PLAIN}"
        return 1
    fi
    
    if [[ ! -e "snell-server" ]]; then
        echo -e "${RED}Snell 解压后未找到可执行文件!${PLAIN}"
        return 1
    fi
    
    rm -f "$zip_file"
    chmod +x snell-server
    mv -f snell-server "${SNELL_BIN}"
    echo "$version" > "${SNELL_VERSION_FILE}"
    
    return 0
}

restart_all_snell_services() {
    echo -e "${YELLOW}正在重启所有 Snell systemd 服务...${PLAIN}"
    systemctl daemon-reload
    
    for svc in /etc/systemd/system/snell@*.service; do
        [ ! -e "$svc" ] && continue
        local svc_name=$(basename "$svc")
        systemctl restart "$svc_name"
        echo -e "${GREEN}已重启服务: $svc_name${PLAIN}"
    done
    
    echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
}

get_snell_version_info() {
    local version_type="$1"
    
    local uname_arch=$(uname -m)
    local arch
    case "$uname_arch" in
        "i686"|"i386") arch="i386" ;;
        *"armv7"*|"armv6l") arch="armv7l" ;;
        *"armv8"*|"aarch64") arch="aarch64" ;;
        *) arch="amd64" ;;
    esac

    local page=$(curl -s "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell")
    local all_links=$(echo "$page" | grep -oE "https://dl.nssurge.com/snell/snell-server-v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*-linux-${arch}\.zip")

    local target_link
    if [[ "$version_type" == "beta" ]]; then
        target_link=$(echo "$all_links" | grep -E 'b[0-9]+|beta' | sort -V | tail -n 1)
    else
        target_link=$(echo "$all_links" | grep -vE 'b[0-9]+|beta' | sort -V | tail -n 1)
    fi

    if [[ -n "$target_link" ]]; then
        local version=$(echo "$target_link" | sed -E "s/.*snell-server-(v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*)-linux-${arch}\.zip/\1/")
        local zip_file=$(basename "$target_link")
        
        echo "$version|$zip_file|$target_link|$arch"
        return 0
    else
        return 1
    fi
}

install_snell() {
    clear
    if snell_installed; then
        echo -e "${YELLOW}Snell 已安装,如需更新请选择【4.更新 Snell】${PLAIN}"
        pause_and_clear
        return
    fi
    
    echo -e "${BLUE}开始安装 Snell...${PLAIN}"
    
    local version_info
    if ! version_info=$(get_snell_version_info "stable"); then
        echo -e "${RED}未获取到 Snell 最新正式版信息，请检查网络或稍后再试！${PLAIN}"
        pause_and_clear
        return 1
    fi
    
    IFS='|' read -r version zip_file url arch <<< "$version_info"
    
    if download_and_extract_snell "$url" "$zip_file" "$version" "$arch"; then
        echo -e "${GREEN}Snell (${arch}) 已下载安装完成${PLAIN}"
        echo -e "${BLUE}请选择【2.配置 Snell】生成并管理配置文件${PLAIN}"
        pause_and_clear
        return 0
    else
        pause_and_clear
        return 1
    fi
}

update_snell_version() {
    local version_type="$1" 
    
    clear
    if ! snell_installed; then
        echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
        pause_and_clear
        return 1
    fi

    echo -e "${BLUE}开始检查并更新 Snell ${version_type} ...${PLAIN}"

    local version_info
    if ! version_info=$(get_snell_version_info "$version_type"); then
        if [[ "$version_type" == "beta" ]]; then
            echo -e "${RED}未检测到任何 Snell 测试版!${PLAIN}"
        else
            echo -e "${RED}未获取到 Snell 最新正式版信息,请检查网络或稍后再试！${PLAIN}"
        fi
        pause_and_clear
        return 1
    fi

    IFS='|' read -r version zip_file url arch <<< "$version_info"

    local current_ver=""
    if [[ -f "$SNELL_VERSION_FILE" ]]; then
        current_ver=$(cat "$SNELL_VERSION_FILE")
    fi

    if [[ "$current_ver" == "$version" && -f "$SNELL_BIN" ]]; then
        echo -e "${GREEN}Snell 已经是${version_type}最新版：${version}${PLAIN}"
        pause_and_clear
        return 0
    fi

    if download_and_extract_snell "$url" "$zip_file" "$version" "$arch"; then
        echo -e "${GREEN}Snell 已更新到${version_type}:${version} (${arch})${PLAIN}"
        restart_all_snell_services
        pause_and_clear
        return 0
    else
        pause_and_clear
        return 1
    fi
}

collect_config_input() {
    local config_name="$1"
    local is_modify="$2"
    local current_values="$3"
    
    local current_port current_psk current_obfs current_obfs_host current_tfo current_dns
    if [[ "$is_modify" == "true" && -n "$current_values" ]]; then
        IFS='|' read -r current_port current_psk current_obfs current_obfs_host current_tfo current_dns <<< "$current_values"
    fi
    
    local port_prompt="${BLUE}请输入监听端口"
    [[ "$is_modify" == "true" ]] && port_prompt+=" ${YELLOW}(当前${current_port})"
    port_prompt+="${BLUE}: ${PLAIN}"
    read -p "$(echo -e "$port_prompt")" port
    port=${port:-${current_port:-5000}}
    
    local psk_prompt="${BLUE}请输入PSK密钥"
    if [[ "$is_modify" == "true" ]]; then
        psk_prompt+=" ${YELLOW}(当前${current_psk} R随机生成)"
    else
        psk_prompt+=" ${YELLOW}(回车随机生成)"
    fi
    psk_prompt+="${BLUE}: ${PLAIN}"
    read -p "$(echo -e "$psk_prompt")" psk
    
    if [[ "$psk" == "r" || "$psk" == "R" ]]; then
        psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    elif [[ -z "$psk" ]]; then
        if [[ "$is_modify" == "true" ]]; then
            psk="$current_psk"
        else
            psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        fi
    fi
    
    local obfs_prompt="${BLUE}是否开启 obfs"
    [[ "$is_modify" == "true" ]] && obfs_prompt+=" ${YELLOW}(当前${current_obfs})"
    obfs_prompt+=" ${YELLOW}(默认不开启 Y/N)${BLUE}: ${PLAIN}"
    read -p "$(echo -e "$obfs_prompt")" enable_obfs
    
    local obfs="off"
    local obfs_host=""
    if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
        obfs="http"
        local host_prompt="${BLUE}请输入 obfs 域名"
        [[ "$is_modify" == "true" ]] && host_prompt+=" ${YELLOW}(当前${current_obfs_host:-icloud.com})"
        host_prompt+="${BLUE}: ${PLAIN}"
        read -p "$(echo -e "$host_prompt")" obfs_host
        obfs_host=${obfs_host:-${current_obfs_host:-icloud.com}}
    fi
    
    local tfo_prompt="${BLUE}是否开启 TFO"
    [[ "$is_modify" == "true" ]] && tfo_prompt+=" ${YELLOW}(当前${current_tfo:-true})"
    tfo_prompt+=" ${YELLOW}(默认开启 Y/N)${BLUE}: ${PLAIN}"
    read -p "$(echo -e "$tfo_prompt")" enable_tfo
    
    local tfo="true"
    if [[ "$enable_tfo" =~ ^[nN]$ ]]; then
        tfo="false"
    elif [[ -z "$enable_tfo" && "$is_modify" == "true" ]]; then
        tfo="${current_tfo:-true}"
    fi
    
    local dns_prompt="${BLUE}是否自定义DNS"
    [[ "$is_modify" == "true" ]] && dns_prompt+=" ${YELLOW}(当前${current_dns:-8.8.8.8, 1.1.1.1})"
    dns_prompt+=" ${YELLOW}(默认8.8.8.8,1.1.1.1 Y/N)${BLUE}: ${PLAIN}"
    read -p "$(echo -e "$dns_prompt")" custom_dns
    
    local dns="8.8.8.8, 1.1.1.1"
    if [[ "$custom_dns" =~ ^[yY]$ ]]; then
        read -p "$(echo -e "${BLUE}请输入 DNS ${YELLOW}(用英文逗号分隔)${BLUE}: ${PLAIN}")" dns
        dns=${dns:-"8.8.8.8, 1.1.1.1"}
    elif [[ "$is_modify" == "true" ]]; then
        dns="${current_dns:-8.8.8.8, 1.1.1.1}"
    fi
    dns=$(echo "$dns" | sed 's/, */, /g')
    
    echo "$port|$psk|$obfs|$obfs_host|$tfo|$dns"
}

generate_config_file() {
    local config_file="$1"
    local config_data="$2"
    
    IFS='|' read -r port psk obfs obfs_host tfo dns <<< "$config_data"
    
    cat > "$config_file" << EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
obfs = ${obfs}
$(if [[ "$obfs" == "http" ]]; then echo "obfs-host = ${obfs_host}"; fi)
ipv6 = false
tfo = ${tfo}
dns = ${dns}
EOF
}

create_systemd_service() {
    local config_name="$1"
    local config_file="$2"
    
    local service_name="snell@${config_name}.service"
    cat > "/etc/systemd/system/$service_name" << EOF
[Unit]
Description=Snell Instance (${config_name})
After=network.target

[Service]
ExecStart=$SNELL_BIN -c $config_file
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now "$service_name"
    echo "$service_name"
}

generate_and_enable_config() {
    clear
    local config_dir="$SNELL_CONFIGS"
    mkdir -p "$config_dir"
    
    echo -e "${BLUE}请输入配置名称:${PLAIN}"
    read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
    [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear && return
    
    local config_file="${config_dir}/${config_name}.conf"
    if [[ -f "$config_file" ]]; then
        echo -e "${RED}配置文件 $config_name 已存在!${PLAIN}"
        pause_and_clear
        return
    fi
    
    local config_data
    config_data=$(collect_config_input "$config_name" "false" "")
    
    generate_config_file "$config_file" "$config_data"
    echo -e "${GREEN}配置文件已生成: $config_file${PLAIN}"
    
    local service_name
    service_name=$(create_systemd_service "$config_name" "$config_file")
    echo -e "${GREEN}配置 $config_name 已启动并设置为开机自启${PLAIN}"
    pause_and_clear
}

get_current_config_values() {
    local config_file="$1"
    
    local current_port=$(grep "^listen = " "$config_file" | cut -d':' -f2)
    local current_psk=$(grep "^psk = " "$config_file" | cut -d' ' -f3)
    local current_obfs=$(grep "^obfs = " "$config_file" | cut -d' ' -f3)
    local current_obfs_host=$(grep "^obfs-host = " "$config_file" | cut -d' ' -f3)
    local current_tfo=$(grep "^tfo = " "$config_file" | cut -d' ' -f3)
    local current_dns=$(grep "^dns = " "$config_file" | cut -d' ' -f3-)
    
    echo "$current_port|$current_psk|$current_obfs|$current_obfs_host|$current_tfo|$current_dns"
}

modify_config() {
    clear
    local config_dir="$SNELL_CONFIGS"
    if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
        pause_and_clear
        return
    fi
    
    echo -e "${BLUE}当前可用配置:${PLAIN}"
    list_configs
    echo -e "${BLUE}请选择要修改的配置名称:${PLAIN}"
    read -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
    [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear && return
    
    local config_file="${config_dir}/${config_name}.conf"
    local service_name="snell@${config_name}.service"
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
        pause_and_clear
        return
    fi
    
    local current_values
    current_values=$(get_current_config_values "$config_file")
    
    display_current_config "$config_file" "$service_name" "$current_values"
    
    read -p "$(echo -e "${YELLOW}是否修改此配置? (Y/N): ${PLAIN}")" confirm_modify
    if [[ "$confirm_modify" =~ ^[nN]$ ]]; then
        return
    fi
    
    echo -e "${YELLOW}开始修改配置(回车不变)...${PLAIN}"
    local new_config_data
    new_config_data=$(collect_config_input "$config_name" "true" "$current_values")
    
    generate_config_file "$config_file" "$new_config_data"
    
    echo -e "${YELLOW}配置已更新,正在重启服务...${PLAIN}"
    systemctl restart "$service_name"
    echo -e "${GREEN}服务已重启,新配置已生效${PLAIN}"
    echo -e "${BLUE}------ 当前服务状态 ------${PLAIN}"
    systemctl status "$service_name" --no-pager
    pause_and_clear
}

display_current_config() {
    local config_file="$1"
    local service_name="$2"
    local current_values="$3"
    
    IFS='|' read -r current_port current_psk current_obfs current_obfs_host current_tfo current_dns <<< "$current_values"
    
    clear
    echo -e "${BLUE}当前配置内容:${PLAIN}"
    echo -e "端口: ${GREEN}${current_port}${PLAIN}"
    echo -e "PSK: ${GREEN}${current_psk}${PLAIN}"
    echo -e "OBFS: ${GREEN}${current_obfs}${PLAIN}"
    [[ "$current_obfs" == "http" ]] && echo -e "OBFS域名: ${GREEN}${current_obfs_host}${PLAIN}"
    echo -e "TFO: ${GREEN}${current_tfo:-true}${PLAIN}"
    echo -e "DNS: ${GREEN}${current_dns:-8.8.8.8, 1.1.1.1}${PLAIN}"

    local status
    status=$(systemctl is-active "$service_name" 2>/dev/null)
    case "$status" in
        "active") echo -e "服务状态: ${GREEN}已启动(active)${PLAIN}" ;;
        "inactive") echo -e "服务状态: ${YELLOW}已停止(inactive)${PLAIN}" ;;
        "failed") echo -e "服务状态: ${RED}启动失败(failed)${PLAIN}" ;;
        *) echo -e "服务状态: ${BLUE}未知或未安装${PLAIN}" ;;
    esac
}


pause_and_clear() {
  read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
  clear
}

snell_installed() {
  [[ -f "$SNELL_BIN" ]] && [[ -x "$SNELL_BIN" ]]
}

snell_config_exists() {
  [[ -d "$SNELL_CONFIGS" ]] && [[ $(ls -A "$SNELL_CONFIGS"/*.conf 2>/dev/null) ]]
}

tfo_enabled() {
  [[ "$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)" == "3" ]] && grep -q "net.ipv4.tcp_fastopen = 3" "$TFO_SYSCTL_CONF" 2>/dev/null
}

install_unzip_if_missing() {
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 unzip，正在自动安装...${PLAIN}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y unzip
        elif command -v dnf &>/dev/null; then
            dnf install -y unzip
        elif command -v yum &>/dev/null; then
            yum install -y unzip
        elif command -v apk &>/dev/null; then
            apk add unzip
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm unzip
        elif command -v zypper &>/dev/null; then
            zypper --non-interactive install unzip
        else
            echo -e "${RED}无法识别的包管理器，unzip 安装失败，请手动安装！${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}unzip 安装完成${PLAIN}"
    fi
}

auto_enable_tcp_fastopen() {
  if tfo_enabled; then
    return
  fi

  kernel=$(uname -r | awk -F . '{print $1}')
  sysctl_conf="$TFO_SYSCTL_CONF"
  if [ "$kernel" -ge 3 ]; then
    echo 3 >/proc/sys/net/ipv4/tcp_fastopen
    [[ ! -e $sysctl_conf ]] && echo "fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control = bbr" >>"$sysctl_conf" && sysctl --system >/dev/null 2>&1
  fi
}

update_snell_stable() {
    update_snell_version "stable"
}

update_snell_beta() {
    update_snell_version "beta"
}

update_snell_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Update ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}更新正式版"
  echo -e "${GREEN}  2.${PLAIN}更新测试版"
  echo -e "${GREEN}  0.${PLAIN}返回主菜单"
  read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" update_choice
  case $update_choice in
    1) update_snell_stable ;;
    2) update_snell_beta ;;
    0) return ;;
    *) echo -e "${RED}无效选项,请重新选择${PLAIN}"; pause_and_clear ;;
  esac
}

delete_all_snell() {
  clear
  if ! snell_installed && ! snell_config_exists; then
    echo -e "${YELLOW}未安装及配置 Snell,请先安装并配置 Snell。${PLAIN}"
    pause_and_clear
    return
  fi

  echo -e "${RED}警告!此操作将彻底删除 /root/snell 目录及相关 systemd 服务${PLAIN}"
  read -p "$(echo -e "${YELLOW}确定继续? [y/N]: ${PLAIN}")" confirm
  [[ ! "$confirm" =~ ^[yY]$ ]] && echo -e "${YELLOW}操作已取消${PLAIN}" && pause_and_clear && return

  for svc in /etc/systemd/system/snell@*.service; do
    [ ! -e "$svc" ] && continue
    svc_name=$(basename "$svc")
    systemctl disable --now "$svc_name" &>/dev/null
    rm -f "$svc"
  done

  systemctl daemon-reload

  if [ -d "/root/snell" ]; then
    rm -rf /root/snell
  fi

  echo -e "${GREEN}已彻底删除 /root/snell 及 systemd 服务${PLAIN}"
  pause_and_clear
}

delete_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${BLUE}请输入要删除的配置名称,输入99删除全部配置:${PLAIN}"
  read -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  if [[ "$config_name" == "99" ]]; then
    delete_all_configs
    return
  fi
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return
  fi
  systemctl disable --now "$service_name" &>/dev/null
  rm -f "/etc/systemd/system/$service_name"
  rm -f "$config_file"
  echo -e "${GREEN}配置 $config_name 及其服务已删除。${PLAIN}"
  pause_and_clear
}

delete_all_configs() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件${PLAIN}"
    pause_and_clear
    return
  fi
  local service_prefix="snell@"
  echo -e "${RED}警告:即将删除所有配置及服务!${PLAIN}"
  read -p "$(echo -e "${YELLOW}确定继续?[y/N]: ${PLAIN}")" choice
  [[ ! "$choice" =~ ^[yY]$ ]] && pause_and_clear && return
  for config_file in "$config_dir"/*.conf; do
    [[ ! -f "$config_file" ]] && continue
    local config_name=$(basename "$config_file" .conf)
    local service_name="${service_prefix}${config_name}.service"
    systemctl disable --now "$service_name" &>/dev/null
    rm -f "/etc/systemd/system/$service_name"
  done
  rm -rf "$config_dir"
  echo -e "${GREEN}所有配置及服务已删除${PLAIN}"
  pause_and_clear
}

stop_or_restart_snell() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${BLUE}请输入要停止的配置名称,输入0重启全部配置:${PLAIN}"
  read -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  if [[ "$config_name" == "0" ]]; then
    for config_file in "$config_dir"/*.conf; do
      [[ ! -f "$config_file" ]] && continue
      local cn=$(basename "$config_file" .conf)
      local service_name="snell@${cn}.service"
      systemctl restart "$service_name"
      echo -e "${GREEN}已重启服务: $service_name${PLAIN}"
    done
    echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
    pause_and_clear
    return
  fi
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return
  fi
  systemctl stop "$service_name"
  echo -e "${YELLOW}已停止服务: $service_name${PLAIN}"
  pause_and_clear
}

list_configs() {
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir")" ]]; then
    echo -e "${YELLOW}没有找到任何配置文件${PLAIN}"
    return
  fi
  for f in "$config_dir"/*.conf; do
    [[ ! -f "$f" ]] && continue
    local name=$(basename "$f" .conf)
    echo -e "  ${YELLOW}${name}${PLAIN}"
  done
}

config_snell_menu() {
  while true; do
    show_sub_menu
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" sub_choice
    case $sub_choice in
      1) generate_and_enable_config ;;
      2) stop_or_restart_snell ;;
      3) modify_config ;;
      4) delete_config ;;
      0) break ;;
      *) echo -e "${RED}无效选项,请重新选择${PLAIN}"; pause_and_clear ;;
    esac
  done
}

show_sub_menu() {
  clear
  echo -e "${BLUE}✦ Confing_Menu ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}生成配置"
  echo -e "${GREEN}  2.${PLAIN}停止服务"
  echo -e "${GREEN}  3.${PLAIN}查看配置"
  echo -e "${GREEN}  4.${PLAIN}删除配置"
  echo -e "${GREEN}  0.${PLAIN}返回上级"
}

show_main_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Ver.1.1 ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}安装Snell"
  echo -e "${GREEN}  2.${PLAIN}配置Snell"
  echo -e "${GREEN}  3.${PLAIN}删除Snell"
  echo -e "${GREEN}  4.${PLAIN}更新Snell"
  echo -e "${GREEN}  0.${PLAIN}退出Kongroo"
}

main() {
  install_unzip_if_missing
  auto_enable_tcp_fastopen
  while true; do
    show_main_menu
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" main_choice
    case $main_choice in
      1) install_snell ;;
      2) config_snell_menu ;;
      3) delete_all_snell ;;
      4) update_snell_menu ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选项,请重新选择${PLAIN}"; pause_and_clear ;;
    esac
  done
}

main
