#!/bin/bash

RED='\033[0;31m'
GREEN="\033[1;32m"
YELLOW='\033[1;33m'
BLUE="\033[1;34m"
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

    page=$(curl -s "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell")

    all_links=$(echo "$page" | grep -oE "https://dl.nssurge.com/snell/snell-server-v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*-linux-${arch}\.zip")

    latest_stable=$(echo "$all_links" | grep -vE 'b[0-9]+|beta' | sort -V | tail -n 1)
    latest_beta=$(echo "$all_links" | grep -E 'b[0-9]+|beta' | sort -V | tail -n 1)

    if [[ -n "$latest_stable" ]]; then
        SNELL_VERSION=$(echo "$latest_stable" | sed -E "s/.*snell-server-(v[0-9]+\.[0-9]+\.[0-9]+)-linux-${arch}\.zip/\1/")
        SNELL_ZIP=$(basename "$latest_stable")
        SNELL_URL="$latest_stable"
        SNELL_ARCH="$arch"
    else
        SNELL_VERSION=""
        SNELL_ZIP=""
        SNELL_URL=""
        SNELL_ARCH="$arch"
    fi

    if [[ -n "$latest_beta" ]]; then
        SNELL_BETA_VERSION=$(echo "$latest_beta" | sed -E "s/.*snell-server-(v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*)-linux-${arch}\.zip/\1/")
        SNELL_BETA_ZIP=$(basename "$latest_beta")
        SNELL_BETA_URL="$latest_beta"
        SNELL_BETA_ARCH="$arch"
    else
        SNELL_BETA_VERSION=""
        SNELL_BETA_ZIP=""
        SNELL_BETA_URL=""
        SNELL_BETA_ARCH="$arch"
    fi
}

get_latest_snell_beta_version() {
    get_latest_snell_version
    SNELL_VERSION="$SNELL_BETA_VERSION"
    SNELL_ZIP="$SNELL_BETA_ZIP"
    SNELL_URL="$SNELL_BETA_URL"
    SNELL_ARCH="$SNELL_BETA_ARCH"
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

install_snell() {
  clear
  if snell_installed; then
    echo -e "${YELLOW}Snell 已安装,如需更新请选择【4.更新 Snell】${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${BLUE}开始安装 Snell...${PLAIN}"

  get_latest_snell_version

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
      echo -e "${RED}未获取到 Snell 最新正式版信息，请检查网络或稍后再试！${PLAIN}"
      pause_and_clear
      return 1
  fi

  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  echo -e "${YELLOW}下载 Snell（${SNELL_ARCH}，${SNELL_VERSION}）...${PLAIN}"
  wget --no-check-certificate -N "$SNELL_URL" -O "$SNELL_ZIP"
  if [[ ! -e "$SNELL_ZIP" ]]; then
      echo -e "${RED}Snell 下载失败,请检查网络连接!${PLAIN}"
      pause_and_clear
      return 1
  else
      install_unzip_if_missing
      unzip -o "$SNELL_ZIP"
  fi

  if [[ ! -e "snell-server" ]]; then
      echo -e "${RED}Snell 解压失败!${PLAIN}"
      pause_and_clear
      return 1
  else
      rm -f "$SNELL_ZIP"
      chmod +x snell-server
      mv -f snell-server "${SNELL_BIN}"
      echo "$SNELL_VERSION" > ${SNELL_VERSION_FILE}
      echo -e "${GREEN}Snell (${SNELL_ARCH}) 已下载安装完成${PLAIN}"
      echo -e "${BLUE}请选择【2.配置 Snell】生成并管理配置文件${PLAIN}"
      pause_and_clear
      return 0
  fi
}

update_snell_stable() {
  clear
  if ! snell_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    pause_and_clear
    return 1
  fi

  echo -e "${BLUE}开始检查并更新 Snell 正式版 ...${PLAIN}"

  get_latest_snell_version

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
      echo -e "${RED}未获取到 Snell 最新正式版信息，请检查网络或稍后再试！${PLAIN}"
      pause_and_clear
      return 1
  fi

  current_ver=""
  if [[ -f "$SNELL_VERSION_FILE" ]]; then
    current_ver=$(cat "$SNELL_VERSION_FILE")
  fi

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是正式版最新版：${SNELL_VERSION}${PLAIN}"
    pause_and_clear
    return 0
  fi

  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  echo -e "${YELLOW}下载 Snell 正式版（${SNELL_ARCH}, ${SNELL_VERSION}）...${PLAIN}"
  wget --no-check-certificate -N "$SNELL_URL" -O "$SNELL_ZIP"
  if [[ ! -e "$SNELL_ZIP" ]]; then
      echo -e "${RED}Snell 正式版下载失败,请检查网络连接!${PLAIN}"
      pause_and_clear
      return 1
  else
      install_unzip_if_missing
      unzip -o "$SNELL_ZIP"
  fi

  if [[ ! -e "snell-server" ]]; then
      echo -e "${RED}Snell 正式版解压失败!${PLAIN}"
      pause_and_clear
      return 1
else
    rm -f "$SNELL_ZIP"
    chmod +x snell-server
    mv -f snell-server "${SNELL_BIN}"
    echo "$SNELL_VERSION" > ${SNELL_VERSION_FILE}
    echo -e "${GREEN}Snell 已更新到正式版:${SNELL_VERSION} (${SNELL_ARCH})${PLAIN}"
    echo -e "${YELLOW}正在重启所有 Snell systemd 服务...${PLAIN}"
    systemctl daemon-reload
    for svc in /etc/systemd/system/snell@*.service; do
      [ ! -e "$svc" ] && continue
      svc_name=$(basename "$svc")
      systemctl restart "$svc_name"
      echo -e "${GREEN}已重启服务: $svc_name${PLAIN}"
    done
    echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
    pause_and_clear
    return 0
  fi
}

update_snell_beta() {
  clear
  if ! snell_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    pause_and_clear
    return 1
  fi
  echo -e "${BLUE}开始检查并更新 Snell 测试版 ...${PLAIN}"

  get_latest_snell_beta_version

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
    echo -e "${RED}未检测到任何 Snell 测试版！${PLAIN}"
    pause_and_clear
    return 1
  fi

  current_ver=""
  if [[ -f "$SNELL_VERSION_FILE" ]]; then
    current_ver=$(cat "$SNELL_VERSION_FILE")
  fi

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是测试版最新版：${SNELL_VERSION}${PLAIN}"
    pause_and_clear
    return 0
  fi

  mkdir -p "$SNELL_DIR"
  cd "$SNELL_DIR"

  echo -e "${YELLOW}下载 Snell 测试版（${SNELL_ARCH}, ${SNELL_VERSION}）...${PLAIN}"
  wget --no-check-certificate -N "$SNELL_URL" -O "$SNELL_ZIP"
  if [[ ! -e "$SNELL_ZIP" ]]; then
      echo -e "${RED}Snell 测试版下载失败,请检查网络连接!${PLAIN}"
      pause_and_clear
      return 1
  else
      install_unzip_if_missing
      unzip -o "$SNELL_ZIP"
  fi

  if [[ ! -e "snell-server" ]]; then
      echo -e "${RED}Snell 测试版解压失败!${PLAIN}"
      pause_and_clear
      return 1
else
    rm -f "$SNELL_ZIP"
    chmod +x snell-server
    mv -f snell-server "${SNELL_BIN}"
    echo "$SNELL_VERSION" > ${SNELL_VERSION_FILE}
    echo -e "${GREEN}Snell 已更新到测试版:${SNELL_VERSION} (${SNELL_ARCH})${PLAIN}"
    echo -e "${YELLOW}正在重启所有 Snell systemd 服务...${PLAIN}"
    systemctl daemon-reload
    for svc in /etc/systemd/system/snell@*.service; do
      [ ! -e "$svc" ] && continue
      svc_name=$(basename "$svc")
      systemctl restart "$svc_name"
      echo -e "${GREEN}已重启服务: $svc_name${PLAIN}"
    done
    echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
    pause_and_clear
    return 0
  fi
}

update_snell_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Update ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}更新正式版"
  echo -e "${GREEN}  2.${PLAIN}更新测试版"
  echo -e "${GREEN}  0.${PLAIN}返回Kongroo"
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

generate_config() {
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
  read -p "$(echo -e "${BLUE}请输入监听端口 ${YELLOW}(默认5000)${BLUE}: ${PLAIN}")" port
  port=${port:-5000}
  read -p "$(echo -e "${BLUE}请输入PSK密钥 ${YELLOW}(回车随机生成)${BLUE}: ${PLAIN}")" psk
  [[ -z "$psk" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  obfs="off"
  obfs_host=""
  read -p "$(echo -e "${BLUE}是否开启 obfs ${YELLOW}(回车默认不开启, y开启)${BLUE}: ${PLAIN}")" enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "$(echo -e "${BLUE}请输入 obfs 域名 ${YELLOW}(回车默认为 icloud.com)${BLUE}: ${PLAIN}")" obfs_host
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
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${BLUE}请选择要启动的配置名称:${PLAIN}"
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
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${BLUE}请选择要查看的配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空!${PLAIN}" && pause_and_clear
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${BLUE}------ 配置内容 ------${PLAIN}"
  cat "$config_file"
  echo -e "${BLUE}------ 服务状态 ------${PLAIN}"
  local status
  status=$(systemctl is-active "$service_name" 2>/dev/null)
  if [[ "$status" == "active" ]]; then
    echo -e "${GREEN}$service_name 状态：已启动 (active)${PLAIN}"
  elif [[ "$status" == "inactive" ]]; then
    echo -e "${YELLOW}$service_name 状态：已停止 (inactive)${PLAIN}"
  elif [[ "$status" == "failed" ]]; then
    echo -e "${RED}$service_name 状态：启动失败 (failed)${PLAIN}"
  else
    echo -e "${BLUE}$service_name 状态：未知或未安装${PLAIN}"
  fi
  echo -e "${BLUE}---------------------${PLAIN}"
  pause_and_clear
}

delete_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir" 2>/dev/null)" ]]; then
    echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${YELLOW}请输入要删除的配置名称${PLAIN}${BLUE}(如: config1)${PLAIN}${YELLOW}，输入99删除全部配置:${PLAIN}"
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
  echo -e "${BLUE}当前配置内容:${PLAIN}"
  echo -e "端口: ${GREEN}${current_port}${PLAIN}"
  echo -e "PSK: ${GREEN}${current_psk}${PLAIN}"
  echo -e "OBFS: ${GREEN}${current_obfs}${PLAIN}"
  [[ "$current_obfs" == "http" ]] && echo -e "OBFS域名: ${GREEN}${current_obfs_host}${PLAIN}"
  echo -e "${YELLOW}开始修改配置...${PLAIN}"
  read -p "$(echo -e "${BLUE}请输入新端口 ${YELLOW}(当前${current_port},回车不变)${BLUE}: ${PLAIN}")" port
  port=${port:-$current_port}
  read -p "$(echo -e "${BLUE}请输入新PSK密钥 ${YELLOW}(当前${current_psk},r随机,回车不变)${BLUE}: ${PLAIN}")" psk
  if [[ "$psk" == "r" ]]; then
    psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  elif [[ -z "$psk" ]]; then
    psk=$current_psk
  fi
  read -p "$(echo -e "${BLUE}是否开启 obfs ${YELLOW}(当前${current_obfs}, y开启,回车关闭)${BLUE}: ${PLAIN}")" enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "$(echo -e "${BLUE}请输入 obfs 域名 ${YELLOW}(当前${current_obfs_host:-icloud.com},回车不变)${BLUE}: ${PLAIN}")" obfs_host
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
  echo -e "${BLUE}------ 当前服务状态 ------${PLAIN}"
  systemctl status "$service_name" --no-pager
  pause_and_clear
}

stop_snell() {
  clear
  echo -e "${BLUE}正在停止所有 Snell systemd 服务...${PLAIN}"
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

list_configs() {
  local config_dir="$SNELL_CONFIGS"
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir")" ]]; then
    echo -e "${YELLOW}没有找到任何配置文件${PLAIN}"
    return
  fi
  ls "$config_dir" | sed 's/\.conf$//'
}

config_snell_menu() {
  while true; do
    show_sub_menu
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" sub_choice
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
}

show_sub_menu() {
  clear
  echo -e "${BLUE}✦ Confing_Menu ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}生成配置"
  echo -e "${GREEN}  2.${PLAIN}启动配置"
  echo -e "${GREEN}  3.${PLAIN}查看配置"
  echo -e "${GREEN}  4.${PLAIN}删除配置"
  echo -e "${GREEN}  5.${PLAIN}修改配置"
  echo -e "${GREEN}  6.${PLAIN}停止Snell"
  echo -e "${GREEN}  0.${PLAIN}返回Kongroo"
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
