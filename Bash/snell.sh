#!/bin/bash
# ========== 颜色定义 ==========
RED="\033[0;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

# ========== 路径常量 ==========
readonly SNELL_BIN="/usr/local/bin/snell-server"
readonly SNELL_ETC="/etc/snell"
readonly SNELL_CONFIGS="${SNELL_ETC}/configs"
readonly SNELL_VERSION_FILE="${SNELL_ETC}/version"
readonly TFO_SYSCTL_CONF="/etc/sysctl.d/local.conf"

# ========== 配置默认值 ==========
readonly DEFAULT_PORT=5000
readonly DEFAULT_DNS="8.8.8.8, 1.1.1.1"
readonly DEFAULT_OBFS_HOST="icloud.com"
readonly SNELL_RELEASE_PAGE="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
readonly SNELL_DOWNLOAD_BASE="https://dl.nssurge.com/snell"
readonly SNELL_CDN_BASE="https://snell-cdn.pages.dev/snell"

# ========== 工具函数 ==========
pause_and_clear() {
  read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
  clear
}

get_arch() {
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

has_ipv4() {
  curl -4 -s --connect-timeout 3 --max-time 5 https://ipv4.icanhazip.com >/dev/null 2>&1 && return 0
  ip -4 addr show scope global 2>/dev/null | grep -q inet && return 0
  return 1
}

cleanup_tmp() {
  rm -f /tmp/snell-server /tmp/snell-server-*.zip 2>/dev/null
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535))
}

validate_config_name() {
  local n="$1"
  [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# ========== 状态检查函数 ==========
snell_installed() {
  [[ -f "$SNELL_BIN" ]] && [[ -x "$SNELL_BIN" ]]
}

snell_config_exists() {
  shopt -s nullglob
  local files=("$SNELL_CONFIGS"/*.conf)
  shopt -u nullglob
  [[ -d "$SNELL_CONFIGS" && ${#files[@]} -gt 0 ]]
}

tfo_enabled() {
  [[ "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)" == "3" ]] \
    && grep -Eq '^\s*net\.ipv4\.tcp_fastopen\s*=\s*3\s*$' "$TFO_SYSCTL_CONF" 2>/dev/null
}

# ========== 版本获取函数 ==========
get_latest_snell_version() {
    local arch
    arch=$(get_arch)

    local page
    page=$(curl -s --connect-timeout 10 --max-time 30 "$SNELL_RELEASE_PAGE")
    
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

    if ! has_ipv4; then
      latest_stable=$(echo "$latest_stable" | sed "s|dl.nssurge.com|snell-cdn.pages.dev|")
      latest_beta=$(echo "$latest_beta" | sed "s|dl.nssurge.com|snell-cdn.pages.dev|")
    fi

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
    get_latest_snell_version || return 1
    SNELL_VERSION="$SNELL_BETA_VERSION"
    SNELL_ZIP="$SNELL_BETA_ZIP"
    SNELL_URL="$SNELL_BETA_URL"
    SNELL_ARCH="$SNELL_BETA_ARCH"
}

# ========== 核心安装函数 ==========
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
            echo -e "${RED}无法识别的包管理器,unzip 安装失败,请手动安装！${PLAIN}"
            return 1
        fi
        echo -e "${GREEN}unzip 安装完成${PLAIN}"
    fi
}

download_and_install_snell() {
  local url="$1"
  local version="$2"
  local zip_file
  zip_file=$(basename "$url")
  
  cd /tmp || { echo -e "${RED}无法进入 /tmp 目录${PLAIN}"; return 1; }
  cleanup_tmp
  
  echo -e "${YELLOW}下载 Snell（$(get_arch)，${version}）...${PLAIN}"
  if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$zip_file" "$url"; then
    echo -e "${RED}下载失败，请检查网络连接${PLAIN}"
    cleanup_tmp
    return 1
  fi
  
  install_unzip_if_missing || return 1
  
  if ! unzip -o "$zip_file"; then
    echo -e "${RED}解压失败${PLAIN}"
    cleanup_tmp
    return 1
  fi
  
  if [[ ! -e "snell-server" ]]; then
    echo -e "${RED}未找到 snell-server 可执行文件${PLAIN}"
    cleanup_tmp
    return 1
  fi
  
  chmod +x snell-server
  mv -f snell-server "${SNELL_BIN}"
  mkdir -p "$SNELL_ETC"
  echo "$version" > "${SNELL_VERSION_FILE}"
  cleanup_tmp
  
  echo -e "${GREEN}Snell ${version} 安装成功${PLAIN}"
  return 0
}

restart_all_snell_services() {
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

# ========== sysctl 优化 ==========
auto_enable_tcp_fastopen() {
  local sysctl_conf="$TFO_SYSCTL_CONF"
  mkdir -p "$(dirname "$sysctl_conf")"
  
  declare -A sysctl_params=(
    ["net.core.netdev_max_backlog"]="4096"
    ["net.core.somaxconn"]="4096"
    ["net.ipv4.tcp_max_syn_backlog"]="4096"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_fin_timeout"]="30"
    ["net.ipv4.ip_local_port_range"]="10000 65000"
    ["net.ipv4.tcp_fastopen"]="3"
    ["net.ipv4.tcp_mtu_probing"]="1"
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"
    ["net.core.rmem_max"]="8388608"
    ["net.core.wmem_max"]="8388608"
    ["net.core.optmem_max"]="4194304"
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
  )
  
  [[ ! -f "$sysctl_conf" ]] && touch "$sysctl_conf"
  
  for key in "${!sysctl_params[@]}"; do
    local value="${sysctl_params[$key]}"
    if grep -Eq "^\s*${key}\s*=" "$sysctl_conf" 2>/dev/null; then
      sed -i "s|^\s*${key}\s*=.*|${key} = ${value}|" "$sysctl_conf"
    else
      echo "${key} = ${value}" >> "$sysctl_conf"
    fi
  done
  
  sysctl --system >/dev/null 2>&1
  [ -w /proc/sys/net/ipv4/tcp_fastopen ] && echo 3 > /proc/sys/net/ipv4/tcp_fastopen
}

# ========== 安装/更新/回滚函数 ==========
install_snell() {
  clear
  if snell_installed; then
    echo -e "${YELLOW}Snell 已安装,如需更新请选择【4.更新 Snell】${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${BLUE}开始安装 Snell...${PLAIN}"

  if ! get_latest_snell_version; then
    pause_and_clear
    return 1
  fi

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
      echo -e "${RED}未获取到 Snell 最新正式版信息,请检查网络或稍后再试！${PLAIN}"
      pause_and_clear
      return 1
  fi

  mkdir -p "$SNELL_ETC"
  mkdir -p "$SNELL_CONFIGS"

  if download_and_install_snell "$SNELL_URL" "$SNELL_VERSION"; then
    echo -e "${BLUE}请选择【2.配置 Snell】生成并管理配置文件${PLAIN}"
  fi
  
  pause_and_clear
}

update_snell_stable() {
  clear
  if ! snell_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    pause_and_clear
    return 1
  fi

  echo -e "${BLUE}开始检查并更新 Snell 正式版 ...${PLAIN}"

  if ! get_latest_snell_version; then
    pause_and_clear
    return 1
  fi

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
      echo -e "${RED}未获取到 Snell 最新正式版信息,请检查网络或稍后再试！${PLAIN}"
      pause_and_clear
      return 1
  fi

  local current_ver=""
  if [[ -f "$SNELL_VERSION_FILE" ]]; then
    current_ver=$(cat "$SNELL_VERSION_FILE")
  fi

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是正式版最新版:${SNELL_VERSION}${PLAIN}"
    pause_and_clear
    return 0
  fi

  if download_and_install_snell "$SNELL_URL" "$SNELL_VERSION"; then
    restart_all_snell_services
  fi
  
  pause_and_clear
}

update_snell_beta() {
  clear
  if ! snell_installed; then
    echo -e "${YELLOW}检测到未安装Snell,请先安装并配置${PLAIN}"
    pause_and_clear
    return 1
  fi
  echo -e "${BLUE}开始检查并更新 Snell 测试版 ...${PLAIN}"

  if ! get_latest_snell_beta_version; then
    pause_and_clear
    return 1
  fi

  if [[ -z "$SNELL_VERSION" || -z "$SNELL_URL" ]]; then
    echo -e "${RED}未检测到任何 Snell 测试版!${PLAIN}"
    pause_and_clear
    return 1
  fi

  local current_ver=""
  if [[ -f "$SNELL_VERSION_FILE" ]]; then
    current_ver=$(cat "$SNELL_VERSION_FILE")
  fi

  if [[ "$current_ver" == "$SNELL_VERSION" && -f "$SNELL_BIN" ]]; then
    echo -e "${GREEN}Snell 已经是测试版最新版：${SNELL_VERSION}${PLAIN}"
    pause_and_clear
    return 0
  fi

  if download_and_install_snell "$SNELL_URL" "$SNELL_VERSION"; then
    restart_all_snell_services
  fi
  
  pause_and_clear
}

rollback_snell_v4() {
  clear
  local target_version="v4.1.1"
  local arch
  arch=$(get_arch)
  
  if [[ -f "$SNELL_VERSION_FILE" ]]; then
      local current_ver
      current_ver=$(cat "$SNELL_VERSION_FILE")
      if [[ "$current_ver" == "$target_version" ]] && [[ -f "$SNELL_BIN" ]]; then
          echo -e "${GREEN}Snell 当前已是 ${target_version} 版本 ${PLAIN}"
          pause_and_clear
          return 0
      fi
  fi

  local url
  if has_ipv4; then
    url="${SNELL_DOWNLOAD_BASE}/snell-server-${target_version}-linux-${arch}.zip"
  else
    url="${SNELL_CDN_BASE}/snell-server-${target_version}-linux-${arch}.zip"
  fi

  echo -e "${YELLOW}回退到 Snell ${target_version}...${PLAIN}"
  if download_and_install_snell "$url" "$target_version"; then
    restart_all_snell_services
  fi
  
  pause_and_clear
}

# ========== 配置管理函数 ==========
generate_config_file() {
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

create_systemd_service() {
  local config_name="$1"
  local config_file="$2"
  local service_name="snell@${config_name}.service"
  
  cat > "/etc/systemd/system/$service_name" << EOF
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

generate_and_enable_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  mkdir -p "$config_dir"
  
  echo -e "${BLUE}请输入配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}(如: config1): ${PLAIN}")" config_name
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空!${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  if ! validate_config_name "$config_name"; then
    echo -e "${RED}配置名称只能包含字母、数字、下划线和连字符${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  if [[ -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 已存在!${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  read -p "$(echo -e "${BLUE}请输入监听端口 ${YELLOW}(默认${DEFAULT_PORT})${BLUE}: ${PLAIN}")" port
  port=${port:-$DEFAULT_PORT}
  if ! validate_port "$port"; then
    echo -e "${RED}端口必须是 1-65535 之间的数字${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  read -p "$(echo -e "${BLUE}请输入PSK密钥 ${YELLOW}(回车随机生成)${BLUE}: ${PLAIN}")" psk
  [[ -z "$psk" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  
  local obfs="off"
  local obfs_host=""
  read -p "$(echo -e "${BLUE}是否开启 obfs ${YELLOW}(默认不开启 Y/N)${BLUE}: ${PLAIN}")" enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "$(echo -e "${BLUE}请输入 obfs 域名 ${YELLOW}(默认 ${DEFAULT_OBFS_HOST})${BLUE}: ${PLAIN}")" obfs_host
    obfs_host=${obfs_host:-$DEFAULT_OBFS_HOST}
  fi

  local ipv6="false"
  read -p "$(echo -e "${BLUE}是否开启 IPv6 ${YELLOW}(默认不开启 Y/N)${BLUE}: ${PLAIN}")" enable_ipv6
  if [[ "$enable_ipv6" =~ ^[yY]$ ]]; then
    ipv6="true"
  fi

  local tfo="true"
  read -p "$(echo -e "${BLUE}是否开启 TFO ${YELLOW}(默认开启 Y/N)${BLUE}: ${PLAIN}")" enable_tfo
  if [[ "$enable_tfo" =~ ^[nN]$ ]]; then
    tfo="false"
  fi

  local dns="$DEFAULT_DNS"
  read -p "$(echo -e "${BLUE}是否自定义DNS ${YELLOW}(默认${DEFAULT_DNS} Y/N)${BLUE}: ${PLAIN}")" custom_dns
  if [[ "$custom_dns" =~ ^[yY]$ ]]; then
    read -p "$(echo -e "${BLUE}请输入 DNS ${YELLOW}(用英文逗号分隔)${BLUE}: ${PLAIN}")" dns
    dns=${dns:-$DEFAULT_DNS}
    dns=$(echo "$dns" | sed 's/, */, /g')
  fi

  generate_config_file "$config_file" "$port" "$psk" "$obfs" "$obfs_host" "$ipv6" "$tfo" "$dns"
  echo -e "${GREEN}配置文件已生成: $config_file${PLAIN}"

  create_systemd_service "$config_name" "$config_file"
  echo -e "${GREEN}配置 $config_name 已启动并设置为开机自启${PLAIN}"
  pause_and_clear
}

modify_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  
  shopt -s nullglob
  local files=("$config_dir"/*.conf)
  shopt -u nullglob
  
  if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}当前没有任何配置文件,请先生成配置${PLAIN}"
    pause_and_clear
    return
  fi
  
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${BLUE}请选择要修改的配置名称:${PLAIN}"
  read -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空!${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return 1
  fi

  local current_port current_psk current_obfs current_obfs_host current_ipv6 current_tfo current_dns
  current_port=$(grep "^listen[[:space:]]*=" "$config_file" | awk -F: '{print $NF}' | tr -d ' ')
  current_psk=$(grep "^psk[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | tr -d ' ')
  current_obfs=$(grep "^obfs[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | tr -d ' ')
  current_obfs_host=$(grep "^obfs-host[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | tr -d ' ')
  current_ipv6=$(grep "^ipv6[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | tr -d ' ')
  current_tfo=$(grep "^tfo[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | tr -d ' ')
  current_dns=$(grep "^dns[[:space:]]*=" "$config_file" | awk -F'=' '{print $2}' | sed 's/^ *//;s/ *$//')

  clear
  echo -e "${BLUE}当前配置内容:${PLAIN}"
  echo -e "端口: ${GREEN}${current_port}${PLAIN}"
  echo -e "PSK: ${GREEN}${current_psk}${PLAIN}"
  echo -e "OBFS: ${GREEN}${current_obfs}${PLAIN}"
  [[ "$current_obfs" == "http" ]] && echo -e "OBFS域名: ${GREEN}${current_obfs_host}${PLAIN}"
  echo -e "IPv6: ${GREEN}${current_ipv6:-false}${PLAIN}"
  echo -e "TFO: ${GREEN}${current_tfo:-true}${PLAIN}"
  echo -e "DNS: ${GREEN}${current_dns:-$DEFAULT_DNS}${PLAIN}"

  local status
  status=$(systemctl is-active "$service_name" 2>/dev/null)
  case "$status" in
    active)   echo -e "服务状态: ${GREEN}已启动(active)${PLAIN}" ;;
    inactive) echo -e "服务状态: ${YELLOW}已停止(inactive)${PLAIN}" ;;
    failed)   echo -e "服务状态: ${RED}启动失败(failed)${PLAIN}" ;;
    *)        echo -e "服务状态: ${BLUE}未知或未安装${PLAIN}" ;;
  esac

  read -p "$(echo -e "${YELLOW}是否修改此配置? (Y/N): ${PLAIN}")" confirm_modify
  if [[ ! "$confirm_modify" =~ ^[yY]$ ]]; then
    return
  fi

  echo -e "${YELLOW}开始修改配置(回车保持原值)...${PLAIN}"
  
  read -p "$(echo -e "${BLUE}请输入新端口 ${YELLOW}(当前${current_port})${BLUE}: ${PLAIN}")" port
  port=${port:-$current_port}
  if ! validate_port "$port"; then
    echo -e "${RED}端口必须是 1-65535 之间的数字${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  read -p "$(echo -e "${BLUE}请输入新PSK密钥 ${YELLOW}(当前${current_psk} R随机生成)${BLUE}: ${PLAIN}")" psk
  if [[ "$psk" =~ ^[rR]$ ]]; then
    psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  elif [[ -z "$psk" ]]; then
    psk=$current_psk
  fi
  
  local obfs obfs_host
  read -p "$(echo -e "${BLUE}是否开启 obfs ${YELLOW}(当前${current_obfs} Y/N)${BLUE}: ${PLAIN}")" enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "$(echo -e "${BLUE}请输入 obfs 域名 ${YELLOW}(当前${current_obfs_host:-$DEFAULT_OBFS_HOST})${BLUE}: ${PLAIN}")" obfs_host
    obfs_host=${obfs_host:-${current_obfs_host:-$DEFAULT_OBFS_HOST}}
  elif [[ "$enable_obfs" =~ ^[nN]$ ]]; then
    obfs="off"
    obfs_host=""
  else
    obfs=${current_obfs:-off}
    obfs_host=${current_obfs_host:-}
  fi

  # IPv6
  local ipv6
  read -p "$(echo -e "${BLUE}是否开启 IPv6 ${YELLOW}(当前${current_ipv6:-false} Y/N)${BLUE}: ${PLAIN}")" enable_ipv6
  if [[ "$enable_ipv6" =~ ^[yY]$ ]]; then
    ipv6="true"
  elif [[ "$enable_ipv6" =~ ^[nN]$ ]]; then
    ipv6="false"
  else
    ipv6=${current_ipv6:-false}
  fi

  local tfo
  read -p "$(echo -e "${BLUE}是否开启 TFO ${YELLOW}(当前${current_tfo:-true} Y/N)${BLUE}: ${PLAIN}")" enable_tfo
  if [[ "$enable_tfo" =~ ^[yY]$ ]]; then
    tfo="true"
  elif [[ "$enable_tfo" =~ ^[nN]$ ]]; then
    tfo="false"
  else
    tfo=${current_tfo:-true}
  fi

  local dns
  read -p "$(echo -e "${BLUE}是否自定义DNS ${YELLOW}(当前${current_dns:-$DEFAULT_DNS}, Y/N)${BLUE}: ${PLAIN}")" custom_dns
  if [[ "$custom_dns" =~ ^[yY]$ ]]; then
    read -p "$(echo -e "${BLUE}请输入 DNS ${YELLOW}(用英文逗号分隔)${BLUE}: ${PLAIN}")" dns
    dns=${dns:-$DEFAULT_DNS}
    dns=$(echo "$dns" | sed 's/, */, /g')
  else
    dns=${current_dns:-$DEFAULT_DNS}
    dns=$(echo "$dns" | sed 's/, */, /g')
  fi

  generate_config_file "$config_file" "$port" "$psk" "$obfs" "$obfs_host" "$ipv6" "$tfo" "$dns"

  echo -e "${YELLOW}配置已更新,正在重启服务...${PLAIN}"
  systemctl restart "$service_name"
  echo -e "${GREEN}服务已重启,新配置已生效${PLAIN}"
  echo -e "${BLUE}------ 当前服务状态 ------${PLAIN}"
  systemctl status "$service_name" --no-pager
  pause_and_clear
}

delete_config() {
  clear
  local config_dir="$SNELL_CONFIGS"
  
  shopt -s nullglob
  local files=("$config_dir"/*.conf)
  shopt -u nullglob
  
  if [[ ${#files[@]} -eq 0 ]]; then
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
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  systemctl disable --now "$service_name" &>/dev/null
  rm -f "/etc/systemd/system/$service_name"
  rm -f "$config_file"
  systemctl daemon-reload
  echo -e "${GREEN}配置 $config_name 及其服务已删除${PLAIN}"
  pause_and_clear
}

delete_all_configs() {
  clear
  local config_dir="$SNELL_CONFIGS"
  
  shopt -s nullglob
  local files=("$config_dir"/*.conf)
  shopt -u nullglob
  
  if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}当前没有任何配置文件${PLAIN}"
    pause_and_clear
    return
  fi
  
  echo -e "${RED}警告:即将删除所有配置及服务!${PLAIN}"
  read -p "$(echo -e "${YELLOW}确定继续?[y/N]: ${PLAIN}")" choice
  [[ ! "$choice" =~ ^[yY]$ ]] && pause_and_clear && return
  
  for config_file in "${files[@]}"; do
    local config_name
    config_name=$(basename "$config_file" .conf)
    local service_name="snell@${config_name}.service"
    systemctl disable --now "$service_name" &>/dev/null
    rm -f "/etc/systemd/system/$service_name"
  done
  
  rm -rf "$config_dir"
  systemctl daemon-reload
  echo -e "${GREEN}所有配置及服务已删除${PLAIN}"
  pause_and_clear
}

delete_all_snell() {
  clear
  if ! snell_installed && ! snell_config_exists; then
    echo -e "${YELLOW}未安装及配置 Snell,请先安装并配置 Snell。${PLAIN}"
    pause_and_clear
    return
  fi

  echo -e "${RED}警告!此操作将彻底删除snell-server及其相关内容、服务${PLAIN}"
  read -p "$(echo -e "${YELLOW}确定继续? [y/N]: ${PLAIN}")" confirm
  [[ ! "$confirm" =~ ^[yY]$ ]] && echo -e "${YELLOW}操作已取消${PLAIN}" && pause_and_clear && return

  shopt -s nullglob
  local services=(/etc/systemd/system/snell@*.service)
  shopt -u nullglob
  
  for svc in "${services[@]}"; do
    local svc_name
    svc_name=$(basename "$svc")
    systemctl disable --now "$svc_name" &>/dev/null
    rm -f "$svc"
  done

  systemctl daemon-reload

  [[ -d "$SNELL_ETC" ]] && rm -rf "$SNELL_ETC"
  [[ -f "$SNELL_BIN" ]] && rm -f "$SNELL_BIN"

  echo -e "${GREEN}已彻底删除snell服务${PLAIN}"
  pause_and_clear
}

stop_or_restart_snell() {
  clear
  local config_dir="$SNELL_CONFIGS"
  
  shopt -s nullglob
  local files=("$config_dir"/*.conf)
  shopt -u nullglob
  
  if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}当前没有任何配置文件${PLAIN}"
    pause_and_clear
    return
  fi
  
  echo -e "${BLUE}当前可用配置:${PLAIN}"
  list_configs
  echo -e "${BLUE}请输入要停止的配置名称,输入0重启全部配置:${PLAIN}"
  read -p "$(echo -e "${GREEN}配置名称: ${PLAIN}")" config_name
  
  if [[ "$config_name" == "0" ]]; then
    for config_file in "${files[@]}"; do
      local cn
      cn=$(basename "$config_file" .conf)
      local service_name="snell@${cn}.service"
      systemctl restart "$service_name"
      echo -e "${GREEN}已重启服务: $service_name${PLAIN}"
    done
    echo -e "${GREEN}所有 Snell 服务已重启${PLAIN}"
    pause_and_clear
    return
  fi
  
  if [[ -z "$config_name" ]]; then
    echo -e "${RED}配置名称不能为空${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell@${config_name}.service"
  
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在!${PLAIN}"
    pause_and_clear
    return 1
  fi
  
  systemctl stop "$service_name"
  echo -e "${YELLOW}已停止服务: $service_name${PLAIN}"
  pause_and_clear
}

list_configs() {
  local config_dir="$SNELL_CONFIGS"
  
  shopt -s nullglob
  local files=("$config_dir"/*.conf)
  shopt -u nullglob
  
  if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}没有找到任何配置文件${PLAIN}"
    return 1
  fi
  
  for f in "${files[@]}"; do
    local name
    name=$(basename "$f" .conf)
    echo -e "  ${YELLOW}${name}${PLAIN}"
  done
}

# ========== 菜单函数 ==========
show_sub_menu() {
  clear
  echo -e "${BLUE}✦ Confing_Menu ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}生成配置"
  echo -e "${GREEN}  2.${PLAIN}停止服务"
  echo -e "${GREEN}  3.${PLAIN}查看配置"
  echo -e "${GREEN}  4.${PLAIN}删除配置"
  echo -e "${GREEN}  0.${PLAIN}返回主页"
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

update_snell_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Update ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}正式版"
  echo -e "${GREEN}  2.${PLAIN}测试版"
  echo -e "${GREEN}  3.${PLAIN}回退v4版"
  echo -e "${GREEN}  0.${PLAIN}返回主页"
  read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" update_choice
  case $update_choice in
    1) update_snell_stable ;;
    2) update_snell_beta ;;
    3) rollback_snell_v4 ;;
    0) return ;;
    *) echo -e "${RED}无效选项,请重新选择${PLAIN}"; pause_and_clear ;;
  esac
}

show_main_menu() {
  clear
  echo -e "${BLUE}✦ Snell_Ver.1.3 ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}安装Snell"
  echo -e "${GREEN}  2.${PLAIN}配置Snell"
  echo -e "${GREEN}  3.${PLAIN}删除Snell"
  echo -e "${GREEN}  4.${PLAIN}更新Snell"
  echo -e "${GREEN}  0.${PLAIN}离开Snell"
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
