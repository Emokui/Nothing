#!/bin/bash

# ======== 全局变量 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PLAIN="\033[0m"

EXEC_PATH="/usr/local/bin/mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_PATH="${CONFIG_DIR}/config.yaml"
ENV_PATH="${CONFIG_DIR}/mihomo.env"

SERVICE_NAME="mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# ======== Root检查 ========
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}错误: 请使用 root 用户运行此脚本${PLAIN}"
  exit 1
fi

# ======== 通用函数 ========
pause_and_return() {
  read -p "$(echo -e "${BLUE}按回车返回...${PLAIN}")" temp
  clear
}

get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *) echo "$arch" ;;
  esac
}

random_pass() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_yes() {
  [[ "$1" =~ ^[yY]$ ]]
}

require_cmds() {
  local missing=()
  local c
  for c in "$@"; do
    if ! need_cmd "$c"; then
      missing+=("$c")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo -e "${RED}缺少依赖命令: ${missing[*]}${PLAIN}"
    pause_and_return
    return 1
  fi
  return 0
}

yaml_quote() {
  local s="$1"
  s=${s//\'/\'\'}
  printf "'%s'" "$s"
}

validate_port_expr() {
  local s="$1"
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    (( s >= 1 && s <= 65535 ))
    return $?
  fi
  if [[ "$s" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local a="${BASH_REMATCH[1]}"
    local b="${BASH_REMATCH[2]}"
    (( a >= 1 && b <= 65535 && a < b ))
    return $?
  fi
  return 1
}

# ======== 监听器配置交互 ========
prompt_listener_config() {
  local title="$1"
  local default_port="$2"

  clear
  echo -e "${BLUE}===== ${title} =====${PLAIN}"

  while true; do
    read -p "$(echo -e "${BLUE}端口(默认:${default_port}，支持 1000-2000): ${PLAIN}")" listener_port
    listener_port=${listener_port:-$default_port}
    if validate_port_expr "$listener_port"; then
      break
    fi
    echo -e "${YELLOW}端口格式无效：请输入 1-65535 的端口，或 1000-2000 这样的范围${PLAIN}"
    sleep 1
  done

  read -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" listener_pass
  if [[ -z "$listener_pass" ]]; then
    listener_pass=$(random_pass)
    echo -e "${GREEN}密码: $listener_pass${PLAIN}"
  fi

  select_cert
  listener_cert="$cert_path"
  listener_key="$key_path"
}

# ======== 检测IPv4 ========
check_ipv4() {
  curl -fsS -4 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1 \
    || curl -fsS -4 --max-time 3 https://api.ipify.org >/dev/null 2>&1
}

get_latest_download_url() {
  local arch="$1"
  local latest_version asset_name download_url base_url api_url

  if check_ipv4; then
    base_url="https://github.com"
    api_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  else
    base_url="https://mihomo.nicycc.workers.dev"
    api_url="https://api.nicycc.workers.dev/repos/MetaCubeX/mihomo/releases/latest"
  fi

  latest_version=$(curl -s "$api_url" | grep '"tag_name":' | sed 's/.*"tag_name": *"\(v[0-9.]*\)".*/\1/')

  if [[ -z "$latest_version" ]]; then
    echo "ERROR|"
    return 1
  fi

  asset_name="mihomo-linux-${arch}-${latest_version}.gz"
  download_url="${base_url}/MetaCubeX/mihomo/releases/download/${latest_version}/${asset_name}"
  echo "${download_url}|${latest_version}"
}

# ======== 证书配置 ========
select_cert() {
  while true; do
    clear
    echo -e "${BLUE}证书配置${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}扫描/etc/cert"
    echo -e "${GREEN}2.${PLAIN}自定义路径"
    read -p "$(echo -e "${BLUE}输入选项: ${PLAIN}")" opt

    case "$opt" in
      1)
        cert_files=()
        if compgen -G "/etc/cert/*.crt" > /dev/null 2>&1; then
          mapfile -t cert_files < <(ls /etc/cert/*.crt 2>/dev/null | sort)
        fi
        if (( ${#cert_files[@]} == 0 )); then
          echo -e "${YELLOW}未检测到证书${PLAIN}"
          sleep 1
          continue
        fi
        clear
        echo -e "${BLUE}选择证书:${PLAIN}"
        for ((i=0; i<${#cert_files[@]}; i++)); do
          echo -e "${GREEN}$((i+1)).${PLAIN} $(basename "${cert_files[$i]}")"
        done
        read -p "$(echo -e "${BLUE}输入编号: ${PLAIN}")" idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#cert_files[@]} )); then
          cert_path="${cert_files[$((idx-1))]}"
          key_path="${cert_path%.crt}.key"
          if [[ -f "$key_path" ]]; then
            return 0
          else
            echo -e "${RED}未找到私钥${PLAIN}"
            sleep 1
          fi
        fi
        ;;
      2)
        read -p "$(echo -e "${BLUE}证书路径: ${PLAIN}")" cert_path
        read -p "$(echo -e "${BLUE}私钥路径: ${PLAIN}")" key_path
        if [[ -f "$cert_path" && -f "$key_path" ]]; then
          return 0
        else
          echo -e "${RED}路径无效${PLAIN}"
          sleep 1
        fi
        ;;
      *)
        echo -e "${YELLOW}请输入 1 或 2${PLAIN}"
        sleep 0.5
        ;;
    esac
  done
}

# ======== ENV ========
load_env() {
  [[ -f "$ENV_PATH" ]] && source "$ENV_PATH"

  : "${ANYTLS_ENABLE:=0}"
  : "${ANYTLS_PORT:=8443}"
  : "${ANYTLS_PASS:=}"
  : "${ANYTLS_CERT:=}"
  : "${ANYTLS_KEY:=}"

  : "${TROJAN_ENABLE:=0}"
  : "${TROJAN_PORT:=10819}"
  : "${TROJAN_PASS:=}"
  : "${TROJAN_CERT:=}"
  : "${TROJAN_KEY:=}"

  : "${HY2_ENABLE:=0}"
  : "${HY2_PORT:=18443}"
  : "${HY2_PASS:=}"
  : "${HY2_CERT:=}"
  : "${HY2_KEY:=}"
}

upsert_env() {
  local key="$1"
  local val="$2"
  mkdir -p "$CONFIG_DIR"
  touch "$ENV_PATH"

  local tmp
  tmp=$(mktemp)
  local found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      printf "%s=%q\n" "$key" "$val" >> "$tmp"
      found=1
    else
      printf "%s\n" "$line" >> "$tmp"
    fi
  done < "$ENV_PATH"

  if [[ $found -eq 0 ]]; then
    printf "%s=%q\n" "$key" "$val" >> "$tmp"
  fi

  mv "$tmp" "$ENV_PATH"
  chmod 600 "$ENV_PATH" 2>/dev/null || true
}

ensure_env_exists() {
  if [[ -f "$ENV_PATH" ]]; then
    return 0
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    migrate_config_to_env
    return 0
  fi

  mkdir -p "$CONFIG_DIR"
  cat > "$ENV_PATH" <<'EOF'
ANYTLS_ENABLE=0
ANYTLS_PORT=8443
ANYTLS_PASS=
ANYTLS_CERT=
ANYTLS_KEY=

TROJAN_ENABLE=0
TROJAN_PORT=10819
TROJAN_PASS=
TROJAN_CERT=
TROJAN_KEY=

HY2_ENABLE=0
HY2_PORT=18443
HY2_PASS=
HY2_CERT=
HY2_KEY=
EOF
  chmod 600 "$ENV_PATH" 2>/dev/null || true
}

yaml_unquote() {
  local s="$1"
  if [[ "$s" =~ ^\'(.*)\'$ ]]; then
    s="${BASH_REMATCH[1]}"
    s="${s//\'\'/\'}"
    printf "%s" "$s"
    return 0
  fi
  if [[ "$s" =~ ^\"(.*)\"$ ]]; then
    s="${BASH_REMATCH[1]}"
    printf "%s" "$s"
    return 0
  fi
  printf "%s" "$s"
}

extract_listener_value() {
  local lname="$1"
  local pat="$2"
  awk -v lname="$lname" -v pat="$pat" '
    BEGIN{b=0}
    $0 ~ "^- name: " lname "$" {b=1; next}
    b && $0 ~ "^- name:" {exit}
    b && $0 ~ pat {
      line=$0
      sub(/^[^:]+:[[:space:]]*/, "", line)
      print line
      exit
    }
  ' "$CONFIG_PATH"
}


migrate_config_to_env() {
  mkdir -p "$CONFIG_DIR"
  touch "$ENV_PATH"

  if grep -q "name: anytls-in" "$CONFIG_PATH"; then
    local p pass cert key
    p=$(extract_listener_value "anytls-in" "^  port:")
    pass=$(extract_listener_value "anytls-in" "username1:")
    cert=$(extract_listener_value "anytls-in" "^  certificate:")
    key=$(extract_listener_value "anytls-in" "^  private-key:")
    pass=$(yaml_unquote "$pass")
    cert=$(yaml_unquote "$cert")
    key=$(yaml_unquote "$key")

    upsert_env ANYTLS_ENABLE 1
    [[ -n "$p" ]] && upsert_env ANYTLS_PORT "$p"
    [[ -n "$pass" ]] && upsert_env ANYTLS_PASS "$pass"
    [[ -n "$cert" ]] && upsert_env ANYTLS_CERT "$cert"
    [[ -n "$key" ]] && upsert_env ANYTLS_KEY "$key"
  else
    upsert_env ANYTLS_ENABLE 0
  fi

  if grep -q "name: trojan-in" "$CONFIG_PATH"; then
    local p pass cert key
    p=$(extract_listener_value "trojan-in" "^  port:")
    pass=$(extract_listener_value "trojan-in" "password:")
    cert=$(extract_listener_value "trojan-in" "^  certificate:")
    key=$(extract_listener_value "trojan-in" "^  private-key:")
    pass=$(yaml_unquote "$pass")
    cert=$(yaml_unquote "$cert")
    key=$(yaml_unquote "$key")

    upsert_env TROJAN_ENABLE 1
    [[ -n "$p" ]] && upsert_env TROJAN_PORT "$p"
    [[ -n "$pass" ]] && upsert_env TROJAN_PASS "$pass"
    [[ -n "$cert" ]] && upsert_env TROJAN_CERT "$cert"
    [[ -n "$key" ]] && upsert_env TROJAN_KEY "$key"
  else
    upsert_env TROJAN_ENABLE 0
  fi

  if grep -q "name: hysteria2-in" "$CONFIG_PATH"; then
    local p pass cert key
    p=$(extract_listener_value "hysteria2-in" "^  port:")
    pass=$(extract_listener_value "hysteria2-in" "user1:")
    cert=$(extract_listener_value "hysteria2-in" "^  certificate:")
    key=$(extract_listener_value "hysteria2-in" "^  private-key:")
    pass=$(yaml_unquote "$pass")
    cert=$(yaml_unquote "$cert")
    key=$(yaml_unquote "$key")

    upsert_env HY2_ENABLE 1
    [[ -n "$p" ]] && upsert_env HY2_PORT "$p"
    [[ -n "$pass" ]] && upsert_env HY2_PASS "$pass"
    [[ -n "$cert" ]] && upsert_env HY2_CERT "$cert"
    [[ -n "$key" ]] && upsert_env HY2_KEY "$key"
  else
    upsert_env HY2_ENABLE 0
  fi

  chmod 600 "$ENV_PATH" 2>/dev/null || true
}


# ======== 生成配置文件 ========
render_config() {
  load_env

  cat <<EOF
tcp-concurrent: true
find-process-mode: off
allow-lan: false
mode: rule
log-level: silent
ipv6: true
sniffer:
  enable: false
dns:
  enable: false
listeners:
EOF

  if [[ "$ANYTLS_ENABLE" == "1" ]]; then
    cat <<EOF
- name: anytls-in
  type: anytls
  port: ${ANYTLS_PORT}
  listen: ::0
  users:
    username1: $(yaml_quote "$ANYTLS_PASS")
  certificate: $(yaml_quote "$ANYTLS_CERT")
  private-key: $(yaml_quote "$ANYTLS_KEY")
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

  if [[ "$TROJAN_ENABLE" == "1" ]]; then
    cat <<EOF
- name: trojan-in
  type: trojan
  port: ${TROJAN_PORT}
  listen: ::0
  users:
    - username: 1
      password: $(yaml_quote "$TROJAN_PASS")
  ws-path: "/"
  certificate: $(yaml_quote "$TROJAN_CERT")
  private-key: $(yaml_quote "$TROJAN_KEY")

EOF
  fi

  if [[ "$HY2_ENABLE" == "1" ]]; then
    cat <<EOF
- name: hysteria2-in
  type: hysteria2
  port: ${HY2_PORT}
  listen: ::0
  users:
    user1: $(yaml_quote "$HY2_PASS")
  masquerade: ""
  alpn:
  - h3
  certificate: $(yaml_quote "$HY2_CERT")
  private-key: $(yaml_quote "$HY2_KEY")

EOF
  fi

  cat <<'EOF'
rules:
  - MATCH,DIRECT
EOF
}

# ======== 应用配置并重启 ========
apply_and_restart() {
  if ! render_config > "$CONFIG_PATH"; then
    echo -e "${RED}生成配置失败：请检查 env 文件内容与 YAML 字段是否正确${PLAIN}"
    return 1
  fi

  if ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
    echo -e "${RED}重启 ${SERVICE_NAME} 失败：请查看日志定位原因${PLAIN}"
    echo -e "${YELLOW}你也可以手动运行：systemctl status ${SERVICE_NAME} --no-pager${PLAIN}"
    echo -e "${YELLOW}最近日志（最后 30 行）：${PLAIN}"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    return 1
  fi
  return 0
}

# ======== 创建systemd ========
create_systemd_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon, A rule-based tunnel in Go.
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=SKIP_SAFE_PATH_CHECK=1
ExecStart=${EXEC_PATH} -d ${CONFIG_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
}

# ======== 安装Mihomo ========
install_mihomo() {
  clear
  if [[ -f "$EXEC_PATH" && -f "$CONFIG_PATH" ]]; then
    echo -e "${YELLOW}已安装,请使用管理服务功能${PLAIN}"
    pause_and_return
    return
  fi

  require_cmds curl wget gunzip systemctl || return

  echo -e "${BLUE}[*] 下载 Mihomo...${PLAIN}"
  mkdir -p "$CONFIG_DIR"

  ARCH=$(get_arch)
  result=$(get_latest_download_url "$ARCH") || {
    echo -e "${RED}获取 Mihomo 最新版本失败（可能是 GitHub API 被限流/网络问题）${PLAIN}"
    pause_and_return
    return
  }
  download_url="${result%|*}"

  if ! wget -O "/tmp/mihomo.gz" "$download_url"; then
    echo -e "${RED}下载失败${PLAIN}"
    rm -f "/tmp/mihomo.gz"
    pause_and_return
    return
  fi

  if ! gunzip -f "/tmp/mihomo.gz"; then
    echo -e "${RED}解压失败${PLAIN}"
    rm -f "/tmp/mihomo.gz" "/tmp/mihomo"
    pause_and_return
    return
  fi

  mv "/tmp/mihomo" "$EXEC_PATH"
  chmod +x "$EXEC_PATH"
  echo -e "${GREEN}内核安装完成${PLAIN}"

  clear
  echo -e "${BLUE}选择要启用的监听器:${PLAIN}"
  read -p "$(echo -e "${BLUE}启用 AnyTLS?   [y/N]: ${PLAIN}")" enable_anytls
  read -p "$(echo -e "${BLUE}启用 Trojan?   [y/N]: ${PLAIN}")" enable_trojan
  read -p "$(echo -e "${BLUE}启用 Hysteria? [y/N]: ${PLAIN}")" enable_hy2

  ensure_env_exists

  if is_yes "$enable_anytls"; then
    prompt_listener_config "AnyTLS 配置" 8443
    upsert_env ANYTLS_ENABLE 1
    upsert_env ANYTLS_PORT "$listener_port"
    upsert_env ANYTLS_PASS "$listener_pass"
    upsert_env ANYTLS_CERT "$listener_cert"
    upsert_env ANYTLS_KEY "$listener_key"
  else
    upsert_env ANYTLS_ENABLE 0
  fi

  if is_yes "$enable_trojan"; then
    prompt_listener_config "Trojan 配置" 10819
    upsert_env TROJAN_ENABLE 1
    upsert_env TROJAN_PORT "$listener_port"
    upsert_env TROJAN_PASS "$listener_pass"
    upsert_env TROJAN_CERT "$listener_cert"
    upsert_env TROJAN_KEY "$listener_key"
  else
    upsert_env TROJAN_ENABLE 0
  fi

  if is_yes "$enable_hy2"; then
    prompt_listener_config "Hysteria2 配置" 18443
    upsert_env HY2_ENABLE 1
    upsert_env HY2_PORT "$listener_port"
    upsert_env HY2_PASS "$listener_pass"
    upsert_env HY2_CERT "$listener_cert"
    upsert_env HY2_KEY "$listener_key"
  else
    upsert_env HY2_ENABLE 0
  fi

  render_config > "$CONFIG_PATH"
  create_systemd_service

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${RED}服务启动失败，请查看日志：journalctl -u ${SERVICE_NAME} -e --no-pager${PLAIN}"
    pause_and_return
    return
  fi

  echo -e "${GREEN}安装完成!${PLAIN}"
  systemctl status --no-pager "$SERVICE_NAME"
  pause_and_return
}

# ======== 管理服务 ========
manage_service() {
  while true; do
    clear
    echo -e "${BLUE}✦ Mihomo_Menu ✦${PLAIN}"
    echo -e "${GREEN}  1.${PLAIN}查看服务"
    echo -e "${GREEN}  2.${PLAIN}修改配置"
    echo -e "${GREEN}  3.${PLAIN}停止服务"
    echo -e "${GREEN}  4.${PLAIN}重启服务"
    echo -e "${GREEN}  0.${PLAIN}返回主页"
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

    case "$opt" in
      1)
        clear
        echo -e "${BLUE}Mihomo 服务状态:${PLAIN}"
        systemctl status --no-pager "$SERVICE_NAME"
        read -p "$(echo -e "${BLUE}按回车查看配置...${PLAIN}")"
        clear
        echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
        cat "$CONFIG_PATH"
        echo -e "${BLUE}------------------------------------------------------${PLAIN}"
        pause_and_return
        ;;
      2)
        modify_config
        ;;
      3)
        systemctl stop "$SERVICE_NAME"
        echo -e "${GREEN}已停止${PLAIN}"
        pause_and_return
        ;;
      4)
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}已重启${PLAIN}"
        pause_and_return
        ;;
      0) break ;;
    esac
  done
}

# ======== 修改配置 ========
modify_config() {
  ensure_env_exists

  while true; do
    load_env

    local anytls_status="未启用"
    local trojan_status="未启用"
    local hy2_status="未启用"
    [[ "$ANYTLS_ENABLE" == "1" ]] && anytls_status="已启用"
    [[ "$TROJAN_ENABLE" == "1" ]] && trojan_status="已启用"
    [[ "$HY2_ENABLE" == "1" ]] && hy2_status="已启用"

    clear
    echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
    echo -e "${GREEN}  1.${PLAIN}AnyTLS   [${YELLOW}${anytls_status}${PLAIN}]"
    echo -e "${GREEN}  2.${PLAIN}Trojan   [${YELLOW}${trojan_status}${PLAIN}]"
    echo -e "${GREEN}  3.${PLAIN}Hysteria [${YELLOW}${hy2_status}${PLAIN}]"
    echo -e "${GREEN}  0.${PLAIN}返回上级"
    read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

    case "$opt" in
      1) toggle_or_modify_listener "ANYTLS" "AnyTLS" "8443" ;;
      2) toggle_or_modify_listener "TROJAN" "Trojan" "10819" ;;
      3) toggle_or_modify_listener "HY2" "Hysteria2" "18443" ;;
      0) break ;;
    esac
  done
}

# ======== 启用/禁用/修改监听器 ========
toggle_or_modify_listener() {
  local prefix="$1"
  local display_name="$2"
  local default_port="$3"

  while true; do
    load_env

    local enable_var="${prefix}_ENABLE"
    local is_enabled="${!enable_var}"
    [[ -z "$is_enabled" ]] && is_enabled=0

    clear
    echo -e "${BLUE}✦ ${display_name}_Conf ✦${PLAIN}"

    if [[ "$is_enabled" == "1" ]]; then
      echo -e "${GREEN}  1.${PLAIN}修改端口"
      echo -e "${GREEN}  2.${PLAIN}修改密码"
      echo -e "${GREEN}  3.${PLAIN}修改证书"
      echo -e "${GREEN}  4.${PLAIN}禁用服务"
      echo -e "${GREEN}  0.${PLAIN}返回上级"
      read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt

      case "$opt" in
        1) modify_listener_port "$prefix" ;;
        2) modify_listener_pass "$prefix" ;;
        3) modify_listener_cert "$prefix" ;;
        4) disable_listener "$prefix" "$display_name"; break ;;
        0) break ;;
      esac
    else
      echo -e "${YELLOW}当前未启用${PLAIN}"
      read -p "$(echo -e "${BLUE}是否启用? [y/N]: ${PLAIN}")" enable
      if is_yes "$enable"; then
        add_listener "$prefix" "$display_name" "$default_port"
      else
        break
      fi
    fi
  done
}

# ======== 添加监听器 ========
add_listener() {
  local prefix="$1"
  local display_name="$2"
  local default_port="$3"

  prompt_listener_config "添加 ${display_name}" "$default_port"

  upsert_env "${prefix}_ENABLE" 1
  upsert_env "${prefix}_PORT" "$listener_port"
  upsert_env "${prefix}_PASS" "$listener_pass"
  upsert_env "${prefix}_CERT" "$listener_cert"
  upsert_env "${prefix}_KEY" "$listener_key"

  apply_and_restart
  echo -e "${GREEN}${display_name} 已启用${PLAIN}"
  sleep 1
}


# ======== 禁用监听器 ========
disable_listener() {
  local prefix="$1"
  local display_name="$2"

  read -p "$(echo -e "${RED}确定禁用 ${display_name}? [y/N]: ${PLAIN}")" confirm
  if is_yes "$confirm"; then
    upsert_env "${prefix}_ENABLE" 0
    apply_and_restart
    echo -e "${GREEN}${display_name} 已禁用${PLAIN}"
  fi
  sleep 1
}

# ======== 修改监听器端口 ========
modify_listener_port() {
  local prefix="$1"
  read -p "$(echo -e "${BLUE}新端口(支持 1000-2000): ${PLAIN}")" new_port

  if [[ -z "$new_port" ]]; then
    sleep 1
    return
  fi

  if validate_port_expr "$new_port"; then
    upsert_env "${prefix}_PORT" "$new_port"
    apply_and_restart
    echo -e "${GREEN}已更新${PLAIN}"
  else
    echo -e "${YELLOW}端口格式无效：请输入 1-65535 的端口，或 1000-2000 这样的范围${PLAIN}"
  fi
  sleep 1
}


# ======== 修改监听器密码 ========
modify_listener_pass() {
  local prefix="$1"
  read -p "$(echo -e "${BLUE}新密码: ${PLAIN}")" new_pass

  if [[ -n "$new_pass" ]]; then
    upsert_env "${prefix}_PASS" "$new_pass"
    apply_and_restart
    echo -e "${GREEN}已更新${PLAIN}"
  fi
  sleep 1
}

# ======== 修改监听器证书 ========
modify_listener_cert() {
  local prefix="$1"

  select_cert
  upsert_env "${prefix}_CERT" "$cert_path"
  upsert_env "${prefix}_KEY" "$key_path"

  apply_and_restart
  echo -e "${GREEN}已更新${PLAIN}"
  sleep 1
}

# ======== 更新内核 ========
update_mihomo() {
  clear
  if [ ! -f "$EXEC_PATH" ]; then
    echo -e "${RED}未安装${PLAIN}"
    pause_and_return
    return
  fi


  require_cmds curl wget gunzip systemctl || return
  current_version=$($EXEC_PATH -v 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")

  ARCH=$(get_arch)
  result=$(get_latest_download_url "$ARCH") || {
    echo -e "${RED}获取 Mihomo 最新版本失败（可能是 GitHub API 被限流/网络问题）${PLAIN}"
    pause_and_return
    return
  }
  download_url="${result%|*}"
  latest_version="${result#*|}"

  echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
  echo -e "${BLUE}最新版本: ${YELLOW}${latest_version}${PLAIN}"

  if [[ "$current_version" == "$latest_version" ]]; then
    echo -e "${GREEN}已是最新版本${PLAIN}"
    pause_and_return
    return
  fi

  read -p "$(echo -e "${BLUE}是否更新? [y/N]: ${PLAIN}")" confirm
  if ! is_yes "$confirm"; then
    return
  fi

  echo -e "${BLUE}[*] 更新中...${PLAIN}"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  if wget -O "/tmp/mihomo.gz" "$download_url"; then
    if gunzip -f "/tmp/mihomo.gz"; then
      mv "/tmp/mihomo" "$EXEC_PATH"
      chmod +x "$EXEC_PATH"
      echo -e "${GREEN}已更新到 ${latest_version}${PLAIN}"
    else
      echo -e "${RED}解压失败${PLAIN}"
      rm -f "/tmp/mihomo.gz" "/tmp/mihomo"
    fi
  else
    echo -e "${RED}下载失败${PLAIN}"
    rm -f "/tmp/mihomo.gz"
  fi

  systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  pause_and_return
}

# ======== 删除服务 ========
delete_mihomo() {
  clear
  read -p "$(echo -e "${RED}确定删除? [y/N]: ${PLAIN}")" confirm
  if is_yes "$confirm"; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$EXEC_PATH"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}已删除${PLAIN}"
  fi
  pause_and_return
}

# ======== 主菜单 ========
while true; do
  clear
  echo -e "${BLUE}✦ Mihomo_Ver.1.3 ✦${PLAIN}"
  echo -e "${GREEN}  1.${PLAIN}安装服务"
  echo -e "${GREEN}  2.${PLAIN}管理服务"
  echo -e "${GREEN}  3.${PLAIN}更新内核"
  echo -e "${GREEN}  4.${PLAIN}删除服务"
  echo -e "${GREEN}  0.${PLAIN}退出脚本"
  read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" option

  case "$option" in
    1) install_mihomo ;;
    2)
      if [[ ! -f "$EXEC_PATH" ]]; then
        echo -e "${RED}未安装${PLAIN}"
        pause_and_return
        continue
      fi
      manage_service
      ;;
    3) update_mihomo ;;
    4) delete_mihomo ;;
    0) exit 0 ;;
  esac
done
