#!/bin/bash

RED='\033[0;31m'
GREEN="\033[32m\033[01m"
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN="\033[1;36m"
PLAIN='\033[0m'

SNELL_DIR="/root/snell"
SNELL_CONFIGS="${SNELL_DIR}/configs"
SNELL_BIN="${SNELL_DIR}/snell-server"
SNELL_VERSION_FILE="${SNELL_DIR}/version"
TFO_SYSCTL_CONF="/etc/sysctl.d/local.conf"

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

get_latest_snell_version() {
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$latest_version" ]; then
        SNELL_VERSION="v${latest_version}"
    else
        SNELL_VERSION="v4.1.1"
        echo -e "${RED}获取 Snell 最新版本失败,使用默认版本 ${SNELL_VERSION}${PLAIN}"
    fi
}

install_snell() {
  clear
  if snell_installed; then
    echo -e "${YELLOW}Snell 已安装,如需更新请选择【5.更新 Snell】${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${CYAN}开始安装 Snell...${PLAIN}"

  uname_arch=$(uname -m)
  if [[ "$uname_arch" == "i686" ]] || [[ "$uname_arch" == "i386" ]]; then
      arch="i386"
  elif [[ "$uname_arch" == *"armv7"* ]] || [[ "$uname_arch" == "armv6l" ]]; then
      arch="armv7l"
  elif [[ "$uname_arch" == *"armv8"* ]] || [[ "$uname_arch" == "aarch64" ]]; then
      arch="aarch64"
  else
      arch="amd64"
  fi

  snell_latest_ver="4.1.1"
  snell_zip="snell-server-v${snell_latest_ver}-linux-${arch}.zip"
  snell_url_official="https://dl.nssurge.com/snell/${snell_zip}"

  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  echo -e "${YELLOW}下载 Snell（${arch}）...${PLAIN}"
  wget --no-check-certificate -N "$snell_url_official" -O "$snell_zip"
  if [[ ! -e "$snell_zip" ]]; then
      echo -e "${RED}Snell 下载失败,请检查网络连接!${PLAIN}"
      pause_and_clear
      return 1
  else
      unzip -o "$snell_zip"
  fi

  if [[ ! -e "snell-server" ]]; then
      echo -e "${RED}Snell 解压失败!${PLAIN}"
      pause_and_clear
      return 1
  else
      rm -f "$snell_zip"
      chmod +x snell-server
      mv -f snell-server "${SNELL_BIN}"
      echo "v${snell_latest_ver}" > ${SNELL_VERSION_FILE}
      echo -e "${GREEN}Snell (${arch}) 已下载安装完成${PLAIN}"
      echo -e "${CYAN}请选择【2.配置 Snell】生成并管理配置文件${PLAIN}"
      pause_and_clear
      return 0
  fi
}

update_snell() {
  clear

  if ! snell_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    pause_and_clear
    return 1
  fi

  echo -e "${CYAN}开始检查并更新 Snell ...${PLAIN}"

  uname_arch=$(uname -m)
  if [[ "$uname_arch" == "i686" ]] || [[ "$uname_arch" == "i386" ]]; then
      arch="i386"
  elif [[ "$uname_arch" == *"armv7"* ]] || [[ "$uname_arch" == "armv6l" ]]; then
      arch="armv7l"
  elif [[ "$uname_arch" == *"armv8"* ]] || [[ "$uname_arch" == "aarch64" ]]; then
      arch="aarch64"
  else
      arch="amd64"
  fi

  get_latest_snell_version
  latest_ver_num=${SNELL_VERSION#v}
  snell_zip="snell-server-v${latest_ver_num}-linux-${arch}.zip"
  snell_url_official="https://dl.nssurge.com/snell/${snell_zip}"

  current_ver=""
  if [[ -f "$SNELL_VERSION_FILE" ]]; then
    current_ver=$(cat "$SNELL_VERSION_FILE")
  fi

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是最新版：${SNELL_VERSION}${PLAIN}"
    pause_and_clear
    return 0
  fi

  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  echo -e "${YELLOW}下载 Snell 最新版（${arch}, ${SNELL_VERSION}）...${PLAIN}"
  wget --no-check-certificate -N "$snell_url_official" -O "$snell_zip"
  if [[ ! -e "$snell_zip" ]]; then
      echo -e "${RED}Snell 下载失败,请检查网络连接!${PLAIN}"
      pause_and_clear
      return 1
  else
      unzip -o "$snell_zip"
  fi

  if [[ ! -e "snell-server" ]]; then
      echo -e "${RED}Snell 解压失败!${PLAIN}"
      pause_and_clear
      return 1
  else
      rm -f "$snell_zip"
      chmod +x snell-server
      mv -f snell-server "${SNELL_BIN}"
      echo "$SNELL_VERSION" > ${SNELL_VERSION_FILE}
      echo -e "${GREEN}Snell 已更新到最新版:${SNELL_VERSION} (${arch})${PLAIN}"
      pause_and_clear
      return 0
  fi
}

delete_all_snell() {
  clear
  if ! snell_installed && ! snell_config_exists; then
    echo -e "${YELLOW}未安装及配置 Snell,请先安装并配置 Snell。${PLAIN}"
    pause_and_clear
    return
  fi

  echo -e "${RED}警告!此操作将彻底删除 /root/snell 目录及相关 systemd 服务${PLAIN}"
  read -p "确定继续? [y/N]: " confirm
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

enableTCPFastOpen() {
  if tfo_enabled; then
    echo -e "${YELLOW}TCP Fast Open 已经开启,无需重复操作${PLAIN}"
    pause_and_clear
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
    echo -e "${GREEN}TCP Fast Open 及推荐内核优化参数已开启${PLAIN}"
  else
    echo -e "${RED}系统内核版本过低,无法支持 TCP Fast Open!${PLAIN}"
  fi
  pause_and_clear
}

show_sub_menu() {
  clear
  echo -e "${CYAN}✦ Snell 多配置管理 ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}生成 配置"
  echo -e "${GREEN}  2.${PLAIN}启动 配置"
  echo -e "${GREEN}  3.${PLAIN}查看 配置"
  echo -e "${GREEN}  4.${PLAIN}删除 配置"
  echo -e "${GREEN}  5.${PLAIN}修改 配置"
  echo -e "${GREEN}  6.${PLAIN}停止 Snell"
  echo -e "${GREEN}  0.${PLAIN}返回 Psy Kongroo"
}

delete_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${CYAN}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${YELLOW}请输入要删除的配置名称${PLAIN}${CYAN}(如: config1)${PLAIN}${YELLOW}，输入99删除全部配置:${PLAIN}"
  read -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  if [[ "$config_name" == "99" ]]; then
    delete_all_configs
    return
  fi
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear && return
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
    echo -e "${YELLOW}当前没有任何配置文件,无需删除${PLAIN}"
    pause_and_clear
    return
  fi
  local service_prefix="snell@"
  echo -e "${RED}警告: 即将删除所有配置及服务!${PLAIN}"
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

stop_snell() {
  clear
  echo -e "${CYAN}正在停止所有 Snell systemd 服务...${PLAIN}"
  local stopped_any=0
  for svc in $(systemctl list-units --type=service --all | grep -oE 'snell@[^ ]+'); do
    systemctl stop "$svc"
    stopped_any=1
    echo -e "${YELLOW}已停止服务: $svc${PLAIN}"
  done
  pkill -f "$SNELL_BIN" && echo -e "${YELLOW}已尝试终止所有 snell-server 进程${PLAIN}"
  systemctl daemon-reload
  if [[ $stopped_any -eq 1 ]]; then
    echo -e "${GREEN}所有 Snell systemd 服务及进程已停止${PLAIN}"
  else
    echo -e "${YELLOW}未检测到正在运行的 Snell systemd 服务${PLAIN}"
  fi
  pause_and_clear
}

generate_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  mkdir -p "$config_dir"
  echo -e "${CYAN}请输入配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  if [[ -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 已存在!${PLAIN}"
    pause_and_clear
    return
  fi
  read -p "$(echo -e "${CYAN}请输入监听端口 ${YELLOW}(默认5000)${CYAN}: ${PLAIN}")" port
  port=${port:-5000}
  read -p "$(echo -e "${CYAN}请输入PSK密钥 ${YELLOW}(回车随机生成)${CYAN}: ${PLAIN}")" psk
  [[ -z "$psk" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  obfs="off"
  obfs_host=""
  read -p "$(echo -e "${CYAN}是否开启 obfs ${YELLOW}(回车默认不开启, y开启)${CYAN}: ${PLAIN}")" enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "$(echo -e "${CYAN}请输入 obfs 域名 ${YELLOW}(回车默认为 icloud.com)${CYAN}: ${PLAIN}")" obfs_host
    obfs_host=${obfs_host:-icloud.com}
  fi

  cat > "$config_file" << EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
obfs = ${obfs}
$(if [[ "$obfs" == "http" ]]; then echo "obfs-host = ${obfs_host}"; fi)
ipv6 = false
tfo = true
dns = 1.1.1.1, 8.8.8.8
EOF

  echo -e "${GREEN}配置文件已生成: $config_file${PLAIN}"
  pause_and_clear
}

start_and_enable_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
    pause_and_clear
    return
  fi
  local config_bin="$SNELL_BIN"
  echo -e "${CYAN}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${CYAN}请选择要启动的配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return
  fi
  cat > "/etc/systemd/system/$service_name" << EOF
[Unit]
Description=Snell Instance (${config_name})
After=network.target

[Service]
ExecStart=$config_bin -c $config_file
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now $service_name
  echo -e "${GREEN}配置 $config_name 已启动并设置为开机自启${PLAIN}"
  pause_and_clear
}

view_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${CYAN}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${CYAN}请选择要查看的配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${CYAN}------ 配置内容 ------${PLAIN}"
  cat "$config_file"
  echo -e "${CYAN}------ 服务状态 ------${PLAIN}"
  # 只显示服务状态一行
  local status
  status=$(systemctl is-active "$service_name" 2>/dev/null)
  if [[ "$status" == "active" ]]; then
    echo -e "${GREEN}$service_name 状态：已启动 (active)${PLAIN}"
  elif [[ "$status" == "inactive" ]]; then
    echo -e "${YELLOW}$service_name 状态：已停止 (inactive)${PLAIN}"
  elif [[ "$status" == "failed" ]]; then
    echo -e "${RED}$service_name 状态：启动失败 (failed)${PLAIN}"
  else
    echo -e "${PURPLE}$service_name 状态：未知或未安装${PLAIN}"
  fi
  echo -e "${CYAN}---------------------${PLAIN}"
  pause_and_clear
}

modify_config() {
  clear
  local config_dir="$SNELL_CONFIGS"

  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
    pause_and_clear
    return
  fi

  echo -e "${CYAN}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${CYAN}请选择要修改的配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear && return

  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"

  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return
  fi

  local current_port=$(grep "^listen = " "$config_file" | cut -d':' -f2)
  local current_psk=$(grep "^psk = " "$config_file" | cut -d' ' -f3)
  local current_obfs=$(grep "^obfs = " "$config_file" | cut -d' ' -f3)
  local current_obfs_host=$(grep "^obfs-host = " "$config_file" | cut -d' ' -f3)

  echo -e "${CYAN}当前配置内容:${PLAIN}"
  echo -e "端口: ${GREEN}${current_port}${PLAIN}"
  echo -e "PSK: ${GREEN}${current_psk}${PLAIN}"
  echo -e "OBFS: ${GREEN}${current_obfs}${PLAIN}"
  [[ "$current_obfs" == "http" ]] && echo -e "OBFS域名: ${GREEN}${current_obfs_host}${PLAIN}"

  echo -e "${YELLOW}开始修改配置...${PLAIN}"
  read -p "$(echo -e "${CYAN}请输入新端口 ${YELLOW}(当前${current_port},回车不变)${CYAN}: ${PLAIN}")" port
  port=${port:-$current_port}

  read -p "$(echo -e "${CYAN}请输入新PSK密钥 ${YELLOW}(当前${current_psk},r随机,回车不变)${CYAN}: ${PLAIN}")" psk
  if [[ "$psk" == "r" ]]; then
    psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  elif [[ -z "$psk" ]]; then
    psk=$current_psk
  fi

  read -p "$(echo -e "${CYAN}是否开启 obfs ${YELLOW}(当前${current_obfs}, y开启,回车关闭)${CYAN}: ${PLAIN}")" enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "$(echo -e "${CYAN}请输入 obfs 域名 ${YELLOW}(当前${current_obfs_host:-icloud.com},回车不变)${CYAN}: ${PLAIN}")" obfs_host
    obfs_host=${obfs_host:-$current_obfs_host}
    obfs_host=${obfs_host:-icloud.com}
  else
    obfs="off"
    obfs_host=""
  fi

  cat > "$config_file" << EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
obfs = ${obfs}
$(if [[ "$obfs" == "http" ]]; then echo "obfs-host = ${obfs_host}"; fi)
ipv6 = false
tfo = true
dns = 1.1.1.1, 8.8.8.8
EOF

  echo -e "${YELLOW}配置已更新,正在重启服务...${PLAIN}"
  systemctl restart "$service_name"
  echo -e "${GREEN}服务已重启,新配置已生效${PLAIN}"

  echo -e "${CYAN}------ 当前服务状态 ------${PLAIN}"
  systemctl status "$service_name" --no-pager
  pause_and_clear
}

list_configs() {
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir")" ]]; then
    echo -e "${YELLOW}没有找到任何配置文件${PLAIN}"
    return
  fi
  ls "$config_dir" | sed 's/\.conf$//'
}

show_main_menu() {
  clear
  echo -e "${CYAN}✦ Snell_v4 Ver.1.0 ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}安装 Snell"
  echo -e "${GREEN}  2.${PLAIN}配置 Snell"
  echo -e "${GREEN}  3.${PLAIN}删除 Snell"
  echo -e "${GREEN}  4.${PLAIN}开启 TCPFO"
  echo -e "${GREEN}  5.${PLAIN}更新 Snell"
  echo -e "${GREEN}  0.${PLAIN}退出 El Psy Kongroo"
}

main() {
  while true; do
    show_main_menu
    read -p "✦ Steins Gate ✦ : " main_choice
    case $main_choice in
      1) install_snell ;;
      2)
        if ! snell_installed; then
          echo -e "${YELLOW}检测到未安装Snell,请先安装${PLAIN}"
          pause_and_clear
          continue
        fi
        while true; do
          show_sub_menu
          read -p "$(echo -e "${CYAN}请选择操作: ${PLAIN}")" sub_choice
          case $sub_choice in
            1) generate_config ;;
            2) start_and_enable_config ;;
            3) view_config ;;
            4) delete_config ;;
            5) modify_config ;;
            6) stop_snell ;;
            0) break ;;
            *) echo -e "${RED}无效选项,请重新选择${PLAIN}"; pause_and_clear ;;
          esac
        done
        ;;
      3) delete_all_snell ;;
      4) enableTCPFastOpen ;;
      5) update_snell ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选项,请重新选择${PLAIN}"; pause_and_clear ;;
    esac
  done
}

main