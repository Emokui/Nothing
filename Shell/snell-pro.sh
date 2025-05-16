#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 目录定义
SNELL_V3_DIR="/root/snell/v3"
SNELL_V4_DIR="/root/snell/v4"
SNELL_V3_CONFIGS="${SNELL_V3_DIR}/configs"
SNELL_V4_CONFIGS="${SNELL_V4_DIR}/configs"
SNELL_V3_ZIP="snell-v3.zip"
SNELL_V4_ZIP="snell-v4.zip"

# 初始化目录
mkdir -p "$SNELL_V3_CONFIGS" "$SNELL_V4_CONFIGS"

pause_and_clear() {
  read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
  clear
}

# 下载并自动解压 Snell v3/v4
install_snell() {
  clear
  echo -e "${CYAN}开始安装 Snell Server...${PLAIN}"

  # v3
  mkdir -p "$SNELL_V3_DIR"
  cd "$SNELL_V3_DIR"
  echo -e "${YELLOW}下载 Snell v3...${PLAIN}"
  wget -q --show-progress https://raw.githubusercontent.com/xOS/Others/master/snell/v3.0.1/snell-server-v3.0.1-linux-amd64.zip -O "$SNELL_V3_ZIP"
  unzip -o "$SNELL_V3_ZIP"
  chmod +x snell-server
  rm -f "$SNELL_V3_ZIP"

  # v4
  mkdir -p "$SNELL_V4_DIR"
  cd "$SNELL_V4_DIR"
  echo -e "${YELLOW}下载 Snell v4...${PLAIN}"
  wget -q --show-progress https://dl.nssurge.com/snell/snell-server-v4.1.1-linux-amd64.zip -O "$SNELL_V4_ZIP"
  unzip -o "$SNELL_V4_ZIP"
  chmod +x snell-server
  rm -f "$SNELL_V4_ZIP"

  echo -e "${GREEN}Snell v3/v4 已自动下载并解压完成。${PLAIN}"
  echo -e "${CYAN}请用[选项2]生成并管理配置文件。${PLAIN}"
  pause_and_clear
}

# 一键删除 /root/snell 及所有相关 systemd 服务
delete_all_snell() {
  clear
  echo -e "${RED}警告！此操作将彻底删除 /root/snell 目录及所有相关 systemd 服务。${PLAIN}"
  read -p "确定继续? [y/N]: " confirm
  [[ ! "$confirm" =~ ^[yY]$ ]] && echo -e "${YELLOW}操作已取消。${PLAIN}" && pause_and_clear && return

  # 删除所有 systemd snell服务
  for svc in $(systemctl list-unit-files | grep -oE 'snell-(v3|v4)@[^ ]+.service'); do
    systemctl disable --now "$svc" &>/dev/null
    rm -f "/etc/systemd/system/$svc"
  done
  systemctl daemon-reload

  # 删除目录
  rm -rf /root/snell
  echo -e "${GREEN}已彻底删除 /root/snell 及 systemd 服务。${PLAIN}"
  pause_and_clear
}

# 修改指定配置
modify_config() {
  clear
  local version=$1
  local config_dir
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS";;
    v4) config_dir="$SNELL_V4_CONFIGS";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; pause_and_clear; return;;
  esac

  echo -e "${CYAN}当前可用配置：${PLAIN}"
  list_configs $version
  echo "请选择要修改的配置名称："
  read -p "(如: config1): " config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空！${PLAIN}" && pause_and_clear && return

  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell-${version}@${config_name}.service"

  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在！${PLAIN}"
    pause_and_clear
    return
  fi

  # 读取当前配置
  local current_port=$(grep "^listen = " "$config_file" | cut -d':' -f2)
  local current_psk=$(grep "^psk = " "$config_file" | cut -d' ' -f3)
  local current_obfs=$(grep "^obfs = " "$config_file" | cut -d' ' -f3)
  local current_obfs_host=$(grep "^obfs-host = " "$config_file" | cut -d' ' -f3)

  echo -e "${CYAN}当前配置内容：${PLAIN}"
  echo -e "端口: ${GREEN}${current_port}${PLAIN}"
  echo -e "PSK: ${GREEN}${current_psk}${PLAIN}"
  echo -e "OBFS: ${GREEN}${current_obfs}${PLAIN}"
  [[ "$current_obfs" == "http" ]] && echo -e "OBFS域名: ${GREEN}${current_obfs_host}${PLAIN}"

  echo -e "${YELLOW}开始修改配置...${PLAIN}"
  read -p "请输入新端口 (当前${current_port}, 保持不变请直接回车): " port
  port=${port:-$current_port}

  read -p "请输入新PSK密钥 (当前${current_psk}, 随机生成请输入r, 保持不变请直接回车): " psk
  if [[ "$psk" == "r" ]]; then
    psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  elif [[ -z "$psk" ]]; then
    psk=$current_psk
  fi

  read -p "是否开启 obfs (当前${current_obfs}, y:开启http/N:关闭): " enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "请输入 obfs 域名 (当前${current_obfs_host:-example.com}, 保持不变请直接回车): " obfs_host
    obfs_host=${obfs_host:-$current_obfs_host}
    obfs_host=${obfs_host:-example.com}
  else
    obfs="off"
    obfs_host=""
  fi

  # 根据版本生成不同的配置内容
  if [[ "$version" == "v3" ]]; then
    cat > "$config_file" << EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
obfs = ${obfs}
$(if [[ "$obfs" == "http" ]]; then echo "obfs-host = ${obfs_host}"; fi)
ipv6 = false
tfo = true
EOF
  else  # v4
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
  fi

  echo -e "${YELLOW}配置已更新，正在重启服务...${PLAIN}"
  systemctl restart "$service_name"
  echo -e "${GREEN}服务已重启，新配置已生效。${PLAIN}"

  echo -e "${CYAN}------ 当前服务状态 ------${PLAIN}"
  systemctl status "$service_name" --no-pager
  pause_and_clear
}

# 生成配置文件
generate_config() {
  clear
  local version=$1
  local config_dir
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS";;
    v4) config_dir="$SNELL_V4_CONFIGS";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; pause_and_clear; return;;
  esac
  mkdir -p "$config_dir"
  echo "请输入配置名称："
  read -p "(如: config1): " config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空！${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  if [[ -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 已存在！${PLAIN}"
    pause_and_clear
    return
  fi
  read -p "请输入监听端口 (默认5000): " port
  port=${port:-5000}
  read -p "请输入PSK密钥 (随机生成留空): " psk
  [[ -z "$psk" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  obfs="off"
  read -p "是否开启 obfs (开启为http) [y/N]: " enable_obfs
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    obfs="http"
    read -p "请输入 obfs 域名 (默认: example.com): " obfs_host
    obfs_host=${obfs_host:-example.com}
  fi

  # 根据版本生成不同的配置内容
  if [[ "$version" == "v3" ]]; then
    cat > "$config_file" << EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
obfs = ${obfs}
$(if [[ "$obfs" == "http" ]]; then echo "obfs-host = ${obfs_host}"; fi)
ipv6 = false
tfo = true
EOF
  else  # v4
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
  fi

  echo -e "${GREEN}配置文件已生成: $config_file${PLAIN}"
  pause_and_clear
}

# 启动配置并设置开机自启
start_and_enable_config() {
  clear
  local version=$1 config_dir config_bin
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS"; config_bin="$SNELL_V3_DIR/snell-server";;
    v4) config_dir="$SNELL_V4_CONFIGS"; config_bin="$SNELL_V4_DIR/snell-server";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; pause_and_clear; return;;
  esac
  echo -e "${CYAN}当前可用配置：${PLAIN}"
  list_configs $version
  echo "请选择要启动的配置名称："
  read -p "(如: config1): " config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空！${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell-${version}@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在！${PLAIN}"
    pause_and_clear
    return
  fi
  cat > "/etc/systemd/system/$service_name" << EOF
[Unit]
Description=Snell $version Instance (${config_name})
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
  echo -e "${GREEN}配置 $config_name 已启动并设置为开机自启。${PLAIN}"
  pause_and_clear
}

# 查看配置内容与状态
view_config() {
  clear
  local version=$1 config_dir
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS";;
    v4) config_dir="$SNELL_V4_CONFIGS";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; pause_and_clear; return;;
  esac
  echo -e "${CYAN}当前可用配置：${PLAIN}"
  list_configs $version
  echo "请选择要查看的配置名称："
  read -p "(如: config1): " config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空！${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell-${version}@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在！${PLAIN}"
    pause_and_clear
    return
  fi
  echo -e "${CYAN}------ 配置内容 ------${PLAIN}"
  cat "$config_file"
  echo -e "${CYAN}------ 服务状态 ------${PLAIN}"
  systemctl status $service_name --no-pager
  pause_and_clear
}

# 删除指定配置及服务
delete_config() {
  clear
  local version=$1 config_dir
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS";;
    v4) config_dir="$SNELL_V4_CONFIGS";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; pause_and_clear; return;;
  esac
  echo -e "${CYAN}当前可用配置：${PLAIN}"
  list_configs $version
  echo "请选择要删除的配置名称："
  read -p "(如: config1): " config_name
  [[ -z "$config_name" ]] && echo -e "${RED}配置名称不能为空！${PLAIN}" && pause_and_clear && return
  local config_file="${config_dir}/${config_name}.conf"
  local service_name="snell-${version}@${config_name}.service"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}配置文件 $config_name 不存在！${PLAIN}"
    pause_and_clear
    return
  fi
  systemctl disable --now "$service_name" &>/dev/null
  rm -f "/etc/systemd/system/$service_name"
  rm -f "$config_file"
  echo -e "${GREEN}配置 $config_name 及其服务已删除。${PLAIN}"
  pause_and_clear
}

# 删除所有配置及服务（单一版本）
delete_all_configs() {
  clear
  local version=$1
  local config_dir service_prefix
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS"; service_prefix="snell-v3@";;
    v4) config_dir="$SNELL_V4_CONFIGS"; service_prefix="snell-v4@";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; pause_and_clear; return;;
  esac
  echo -e "${RED}警告：即将删除 $version 的所有配置及服务！${PLAIN}"
  read -p "确定继续？[y/N]: " choice
  [[ ! "$choice" =~ ^[yY]$ ]] && pause_and_clear && return
  for config_file in "$config_dir"/*.conf; do
    [[ ! -f "$config_file" ]] && continue
    local config_name=$(basename "$config_file" .conf)
    local service_name="${service_prefix}${config_name}.service"
    systemctl disable --now "$service_name" &>/dev/null
    rm -f "/etc/systemd/system/$service_name"
  done
  rm -rf "$config_dir"
  mkdir -p "$config_dir"
  echo -e "${GREEN}$version 的所有配置及服务已删除。${PLAIN}"
  pause_and_clear
}

# 列出当前所有配置
list_configs() {
  local version=$1 config_dir
  case $version in
    v3) config_dir="$SNELL_V3_CONFIGS";;
    v4) config_dir="$SNELL_V4_CONFIGS";;
    *) echo -e "${RED}未知版本：$version${PLAIN}"; return;;
  esac
  if [[ ! -d "$config_dir" || -z "$(ls -A "$config_dir")" ]]; then
    echo -e "${YELLOW}没有找到任何配置文件。${PLAIN}"
    return
  fi
  ls "$config_dir" | sed 's/\.conf$//'
}

# 主菜单
show_main_menu() {
  clear
  echo -e "${BLUE}=======================${PLAIN}"
  echo -e "${CYAN}      Snell 管理工具${PLAIN}"
  echo -e "${BLUE}=======================${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} 安装 Snell v3/v4"
  echo -e "${GREEN}2.${PLAIN} 多配置管理"
  echo -e "${GREEN}3.${PLAIN} 一键删除snell所有内容"
  echo -e "${GREEN}0.${PLAIN} 退出"
}

# 子菜单
show_sub_menu() {
  clear
  echo -e "${BLUE}=======================${PLAIN}"
  echo -e "${CYAN}    Snell $1 配置管理${PLAIN}"
  echo -e "${BLUE}=======================${PLAIN}"
  echo -e "${GREEN}1.${PLAIN} 生成配置"
  echo -e "${GREEN}2.${PLAIN} 启动配置"
  echo -e "${GREEN}3.${PLAIN} 查看配置"
  echo -e "${GREEN}4.${PLAIN} 删除指定配置"
  echo -e "${GREEN}5.${PLAIN} 删除所有配置"
  echo -e "${GREEN}6.${PLAIN} 修改指定配置"
  echo -e "${GREEN}0.${PLAIN} 返回主菜单"
}

# 主流程
main() {
  while true; do
    show_main_menu
    read -p "请选择操作：" main_choice
    case $main_choice in
      1) install_snell ;;
      2)
        clear
        echo -e "${CYAN}请选择版本：${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} v3 配置管理"
        echo -e "${GREEN}2.${PLAIN} v4 配置管理"
        read -p "(默认: 1): " version_choice
        [[ -z "$version_choice" ]] && version_choice="1"
        case $version_choice in
          1) version="v3" ;;
          2) version="v4" ;;
          *) echo -e "${RED}无效选项${PLAIN}"; pause_and_clear; continue ;;
        esac
        while true; do
          show_sub_menu "$version"
          read -p "请选择操作：" sub_choice
          case $sub_choice in
            1) generate_config "$version" ;;
            2) start_and_enable_config "$version" ;;
            3) view_config "$version" ;;
            4) delete_config "$version" ;;
            5) delete_all_configs "$version" ;;
            6) modify_config "$version" ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${PLAIN}"; pause_and_clear ;;
          esac
        done
        ;;
      3) delete_all_snell ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选项，请重新选择。${PLAIN}"; pause_and_clear ;;
    esac
  done
}

main
