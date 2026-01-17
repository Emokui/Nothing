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

# ======== 检测IPv4 ========
check_ipv4() {
    curl -s -4 --max-time 2 https://www.google.com > /dev/null 2>&1
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
    
    if [[ "$arch" == "amd64" ]]; then
        asset_name="mihomo-linux-${arch}-v3-go123-${latest_version}.gz"
    else
        asset_name="mihomo-linux-${arch}-${latest_version}.gz"
    fi
    download_url="${base_url}/MetaCubeX/mihomo/releases/download/${latest_version}/${asset_name}"
    echo "${download_url}|${latest_version}"
}

# ======== 证书配置 ========
select_cert() {
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
        
        read -p "$(echo -e "${BLUE}输入选项: ${PLAIN}")" opt
        
        if [[ "$opt" == "0" ]]; then
            read -p "$(echo -e "${BLUE}证书路径: ${PLAIN}")" cert_path
            read -p "$(echo -e "${BLUE}私钥路径: ${PLAIN}")" key_path
            if [[ -f "$cert_path" && -f "$key_path" ]]; then
                return 0
            else
                echo -e "${RED}路径无效${PLAIN}"
                sleep 1
            fi
        elif [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#cert_files[@]} )); then
            cert_path="${cert_files[$((opt-1))]}"
            key_path="${cert_path%.crt}.key"
            if [[ -f "$key_path" ]]; then
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

# ======== 生成配置文件 ========
generate_config() {
    cat > "$CONFIG_PATH" <<EOF
tcp-concurrent: true
find-process-mode: off
allow-lan: false
mode: rule
log-level: silent
ipv6: true
dns:
  enable: true
  listen: ::1:1053
  ipv6: true
  nameserver:
    - 1.1.1.1
    - 2606:4700:4700::1111
  enhanced-mode: fake-ip
profile:
  store-selected: false
  store-fake-ip: false
listeners:
EOF

    if [[ "$enable_anytls" == "y" ]]; then
        cat >> "$CONFIG_PATH" <<EOF
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
        cat >> "$CONFIG_PATH" <<EOF
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
    
    if [[ "$enable_hy2" == "y" ]]; then
        cat >> "$CONFIG_PATH" <<EOF
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

    if [[ "$enable_tuic" == "y" ]]; then
        cat >> "$CONFIG_PATH" <<EOF
- name: tuicv5-in
  type: tuic
  port: ${tuic_port}
  listen: ::0
  users:
    ${tuic_uuid}: ${tuic_pass}
  certificate: ${tuic_cert}
  private-key: ${tuic_key}
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 3000
  alpn:
    - h3
  max-udp-relay-packet-size: 1408

EOF
    fi

    cat >> "$CONFIG_PATH" <<EOF
rules:
  - MATCH,DIRECT
EOF
}

# ======== 安装Mihomo ========
install_mihomo() {
    clear
    if [[ -f "$EXEC_PATH" && -f "$CONFIG_PATH" ]]; then
        echo -e "${YELLOW}已安装,请使用管理服务功能${PLAIN}"
        pause_and_return
        return
    fi

    echo -e "${BLUE}[*] 下载 Mihomo...${PLAIN}"
    mkdir -p "$CONFIG_DIR"
    
    ARCH=$(get_arch)
    result=$(get_latest_download_url "$ARCH")
    download_url="${result%|*}"
    
    if ! wget -O "/tmp/mihomo.gz" "$download_url"; then
        echo -e "${RED}下载失败${PLAIN}"
        rm -f "/tmp/mihomo.gz"
        pause_and_return
        return
    fi
    
    gunzip -f "/tmp/mihomo.gz"
    mv "/tmp/mihomo" "$EXEC_PATH"
    chmod +x "$EXEC_PATH"
    echo -e "${GREEN}内核安装完成${PLAIN}"

    clear
    echo -e "${BLUE}选择要启用的监听器:${PLAIN}"
    read -p "$(echo -e "${BLUE}启用 Anytls?   [y/N]: ${PLAIN}")" enable_anytls
    read -p "$(echo -e "${BLUE}启用 Trojan?   [y/N]: ${PLAIN}")" enable_trojan
    read -p "$(echo -e "${BLUE}启用 Tuicv5?   [y/N]: ${PLAIN}")" enable_tuic
    read -p "$(echo -e "${BLUE}启用 Hysteria? [y/N]: ${PLAIN}")" enable_hy2
    

    if [[ "$enable_anytls" == "y" || "$enable_anytls" == "Y" ]]; then
        enable_anytls="y"
        clear
        echo -e "${BLUE}===== AnyTLS 配置 =====${PLAIN}"
        read -p "$(echo -e "${BLUE}端口(默认:8443): ${PLAIN}")" anytls_port
        anytls_port=${anytls_port:-8443}
        read -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" anytls_pass
        if [[ -z "$anytls_pass" ]]; then
            anytls_pass=$(random_pass)
            echo -e "${GREEN}密码: $anytls_pass${PLAIN}"
        fi
        select_cert
        anytls_cert="$cert_path"
        anytls_key="$key_path"
    fi
    
    if [[ "$enable_trojan" == "y" || "$enable_trojan" == "Y" ]]; then
        enable_trojan="y"
        clear
        echo -e "${BLUE}===== Trojan 配置 =====${PLAIN}"
        read -p "$(echo -e "${BLUE}端口(默认:10819): ${PLAIN}")" trojan_port
        trojan_port=${trojan_port:-10819}
        read -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" trojan_pass
        if [[ -z "$trojan_pass" ]]; then
            trojan_pass=$(random_pass)
            echo -e "${GREEN}密码: $trojan_pass${PLAIN}"
        fi
        select_cert
        trojan_cert="$cert_path"
        trojan_key="$key_path"
    fi

    if [[ "$enable_hy2" == "y" || "$enable_hy2" == "Y" ]]; then
        enable_hy2="y"
        clear
        echo -e "${BLUE}===== Hysteria2 配置 =====${PLAIN}"
        read -p "$(echo -e "${BLUE}端口(默认:18443): ${PLAIN}")" hy2_port
        hy2_port=${hy2_port:-18443}
        read -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" hy2_pass
        if [[ -z "$hy2_pass" ]]; then
            hy2_pass=$(random_pass)
            echo -e "${GREEN}密码: $hy2_pass${PLAIN}"
        fi
        select_cert
        hy2_cert="$cert_path"
        hy2_key="$key_path"
    fi

    if [[ "$enable_tuic" == "y" || "$enable_tuic" == "Y" ]]; then
        enable_tuic="y"
        clear
        echo -e "${BLUE}===== TUIC 配置 =====${PLAIN}"
        read -p "$(echo -e "${BLUE}端口(默认:28443): ${PLAIN}")" tuic_port
        tuic_port=${tuic_port:-28443}
        read -p "$(echo -e "${BLUE}UUID(回车随机): ${PLAIN}")" tuic_uuid
        if [[ -z "$tuic_uuid" ]]; then
            tuic_uuid=$(cat /proc/sys/kernel/random/uuid)
            echo -e "${GREEN}UUID: $tuic_uuid${PLAIN}"
        fi
        read -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" tuic_pass
        if [[ -z "$tuic_pass" ]]; then
            tuic_pass=$(random_pass)
            echo -e "${GREEN}密码: $tuic_pass${PLAIN}"
        fi
        select_cert
        tuic_cert="$cert_path"
        tuic_key="$key_path"
    fi

    generate_config
    create_systemd_service
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

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
    while true; do
        local anytls_status="未启用"
        local trojan_status="未启用"
        local hy2_status="未启用"
        local tuic_status="未启用"
        grep -q "name: anytls-in" "$CONFIG_PATH" && anytls_status="已启用"
        grep -q "name: trojan-in" "$CONFIG_PATH" && trojan_status="已启用"
        grep -q "name: tuicv5-in" "$CONFIG_PATH" && tuic_status="已启用"
        grep -q "name: hysteria2-in" "$CONFIG_PATH" && hy2_status="已启用"
        
        clear
        echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}Anytls  [${YELLOW}${anytls_status}${PLAIN}]"
        echo -e "${GREEN}  2.${PLAIN}Trojan  [${YELLOW}${trojan_status}${PLAIN}]"
        echo -e "${GREEN}  3.${PLAIN}Tuicv5  [${YELLOW}${tuic_status}${PLAIN}]"
        echo -e "${GREEN}  4.${PLAIN}Hysteria[${YELLOW}${hy2_status}${PLAIN}]"
        echo -e "${GREEN}  0.${PLAIN}Return"
        read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt
        
        case "$opt" in
            1) toggle_or_modify_listener "anytls-in" "AnyTLS" "8443" ;;
            2) toggle_or_modify_listener "trojan-in" "Trojan" "10819" ;;
            3) toggle_or_modify_listener "tuicv5-in" "TUIC" "28443" ;;
            4) toggle_or_modify_listener "hysteria2-in" "Hysteria2" "18443" ;;
            0) break ;;
        esac
    done
}

# ======== 启用/禁用/修改监听器 ========
toggle_or_modify_listener() {
    local name="$1"
    local display_name="$2"
    local default_port="$3"
    
    while true; do
        local is_enabled="n"
        grep -q "name: $name" "$CONFIG_PATH" && is_enabled="y"
        
        clear
        echo -e "${BLUE}✦ ${display_name}_Conf ✦${PLAIN}"
        if [[ "$is_enabled" == "y" ]]; then
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}修改密码"
            echo -e "${GREEN}  3.${PLAIN}修改证书"
            echo -e "${GREEN}  4.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            read -p "$(echo -e "${BLUE}✦ Steins Gate ✦ : ${PLAIN}")" opt
            
            case "$opt" in
                1) modify_listener_port "$name" ;;
                2) modify_listener_pass "$name" ;;
                3) modify_listener_cert "$name" ;;
                4) disable_listener "$name" "$display_name"; break ;;
                0) break ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            read -p "$(echo -e "${BLUE}是否启用? [y/N]: ${PLAIN}")" enable
            if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
                add_listener "$name" "$display_name" "$default_port"
            else
                break
            fi
        fi
    done
}

# ======== 添加监听器 ========
add_listener() {
    local name="$1"
    local display_name="$2"
    local default_port="$3"
    
    clear
    echo -e "${BLUE}===== 添加 ${display_name} =====${PLAIN}"
    read -p "$(echo -e "${BLUE}端口(默认:${default_port}): ${PLAIN}")" port
    port=${port:-$default_port}
    
    local uuid=""
    if [[ "$name" == "tuicv5-in" ]]; then
        read -p "$(echo -e "${BLUE}UUID(回车随机): ${PLAIN}")" uuid
        if [[ -z "$uuid" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid)
            echo -e "${GREEN}UUID: $uuid${PLAIN}"
        fi
    fi
    
    read -p "$(echo -e "${BLUE}密码(回车随机): ${PLAIN}")" pass
    if [[ -z "$pass" ]]; then
        pass=$(random_pass)
        echo -e "${GREEN}密码: $pass${PLAIN}"
    fi
    
    select_cert
    
    local tmp_config=$(mktemp)
    case "$name" in
        anytls-in)
            cat > "$tmp_config" <<LISTENER
- name: anytls-in
  type: anytls
  port: ${port}
  listen: ::0
  users:
    username1: ${pass}
  certificate: ${cert_path}
  private-key: ${key_path}
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
  certificate: ${cert_path}
  private-key: ${key_path}

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
  certificate: ${cert_path}
  private-key: ${key_path}

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
  certificate: ${cert_path}
  private-key: ${key_path}
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 3000
  alpn:
    - h3
  max-udp-relay-packet-size: 1408

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
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    rm -f "$tmp_config"
    
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}${display_name} 已启用${PLAIN}"
    sleep 1
}

# ======== 禁用监听器 ========
disable_listener() {
    local name="$1"
    local display_name="$2"
    
    read -p "$(echo -e "${RED}确定禁用 ${display_name}? [y/N]: ${PLAIN}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
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
        ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}${display_name} 已禁用${PLAIN}"
    fi
    sleep 1
}

# ======== 修改监听器端口 ========
modify_listener_port() {
    local name="$1"
    read -p "$(echo -e "${BLUE}新端口: ${PLAIN}")" new_port
    if [[ -n "$new_port" && "$new_port" =~ ^[0-9]+$ ]]; then
        awk -v name="$name" -v port="$new_port" '
            /^- name: /{found=($0 ~ name)}
            found && /^  port:/{$0="  port: "port; found=0}
            {print}
        ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}已更新${PLAIN}"
    fi
    sleep 1
}

# ======== 修改监听器密码 ========
modify_listener_pass() {
    local name="$1"
    read -p "$(echo -e "${BLUE}新密码: ${PLAIN}")" new_pass
    if [[ -n "$new_pass" ]]; then
        case "$name" in
            anytls-in)
                awk -v pass="$new_pass" '
                    /^- name: anytls-in/{found=1}
                    found && /username1:/{$0="    username1: "pass; found=0}
                    {print}
                ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                ;;
            trojan-in)
                awk -v pass="$new_pass" '
                    /^- name: trojan-in/{found=1}
                    found && /password:/{$0="      password: "pass; found=0}
                    {print}
                ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                ;;
            hysteria2-in)
                awk -v pass="$new_pass" '
                    /^- name: hysteria2-in/{found=1}
                    found && /user1:/{$0="    user1: "pass; found=0}
                    {print}
                ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
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
                ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                ;;
        esac
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}已更新${PLAIN}"
    fi
    sleep 1
}

# ======== 修改监听器证书 ========
modify_listener_cert() {
    local name="$1"
    select_cert
    awk -v name="$name" -v cert="$cert_path" -v key="$key_path" '
        /^- name: /{block=($0 ~ name)}
        block && /certificate:/{$0="  certificate: "cert}
        block && /private-key:/{$0="  private-key: "key; block=0}
        {print}
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    systemctl restart "$SERVICE_NAME"
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

    current_version=$($EXEC_PATH -v 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
    
    ARCH=$(get_arch)
    result=$(get_latest_download_url "$ARCH")
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
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    echo -e "${BLUE}[*] 更新中...${PLAIN}"
    systemctl stop "$SERVICE_NAME"

    if wget -O "/tmp/mihomo.gz" "$download_url"; then
        gunzip -f "/tmp/mihomo.gz"
        mv "/tmp/mihomo" "$EXEC_PATH"
        chmod +x "$EXEC_PATH"
        echo -e "${GREEN}已更新到 ${latest_version}${PLAIN}"
    else
        echo -e "${RED}下载失败${PLAIN}"
        rm -f "/tmp/mihomo.gz"
    fi
    
    systemctl start "$SERVICE_NAME"
    pause_and_return
}

# ======== 删除服务 ========
delete_mihomo() {
    clear
    read -p "$(echo -e "${RED}确定删除? [y/N]: ${PLAIN}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
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
