#!/bin/bash

# 颜色定义
BLUE="\033[1;34m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
PLAIN="\033[0m"

# 基础变量
MIHOMO_DIR="${HOME}/clash"
MIHOMO_PATH="${MIHOMO_DIR}/mihomo"
CONFIG_PATH="${MIHOMO_DIR}/config.yaml"
SERVICE_NAME="mihomo-user"
TIMER_NAME="mihomo-user.timer"

# 检查yq是否安装，否则自动下载安装
check_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] 未检测到 yq，正在自动安装...${PLAIN}"
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        if command -v curl >/dev/null 2>&1; then
            sudo curl -L "$YQ_URL" -o /usr/local/bin/yq
        elif command -v wget >/dev/null 2>&1; then
            sudo wget "$YQ_URL" -O /usr/local/bin/yq
        else
            echo -e "${RED}[!] curl 和 wget 都未安装，无法自动安装 yq，请手动安装。${PLAIN}"
            exit 1
        fi
        sudo chmod +x /usr/local/bin/yq
        hash -r
        if ! command -v yq >/dev/null 2>&1; then
            echo -e "${RED}[!] yq 安装失败，请手动安装。${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}[*] yq 已成功安装。${PLAIN}"
    fi
}
check_yq

# 检查命令执行结果
check_status() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}[!] $1 失败。${PLAIN}"
        exit 1
    fi
}

# 创建 systemd 服务
create_systemd_service() {
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<EOF
[Unit]
Description=User Mihomo Service (Delayed Start)
After=network.target

[Service]
Type=simple
ExecStart=${MIHOMO_PATH} -f ${CONFIG_PATH}
WorkingDirectory=${MIHOMO_DIR}
Restart=on-failure
User=${USER}
EOF
    sudo chmod 644 /etc/systemd/system/${SERVICE_NAME}.service
}

# 创建 systemd timer（开机2分钟后启动）
create_systemd_timer() {
    sudo tee /etc/systemd/system/${TIMER_NAME} > /dev/null <<EOF
[Unit]
Description=Start Mihomo 2 minutes after boot

[Timer]
OnBootSec=2min
AccuracySec=30s
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF
    sudo chmod 644 /etc/systemd/system/${TIMER_NAME}
}

# 获取 Mihomo 最新稳定版
get_latest_mihomo_url() {
    latest_version=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed 's/.*"v\([0-9.]*\)".*/v\1/')
    echo "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-${latest_version}.gz"
}

install_mihomo() {
    echo -e "${CYAN}[*] 开始安装并配置 Mihomo...${PLAIN}"
    mkdir -p "$MIHOMO_DIR" && cd "$MIHOMO_DIR" || exit 1

    download_url=$(get_latest_mihomo_url)
    echo -e "${CYAN}[*] 下载 Mihomo: $download_url ${PLAIN}"
    wget "$download_url" -O "mihomo.gz"
    check_status "下载 Mihomo"

    gunzip -f "mihomo.gz"
    if [ -f "mihomo" ]; then
        chmod +x mihomo
        check_status "设置执行权限"
    else
        echo -e "${RED}[!] 解压后未找到 mihomo 可执行文件，请检查下载或解压是否成功。${PLAIN}"
        exit 1
    fi

    # tun模式交互
    echo -e "${YELLOW}[*] 是否启用 tun 模式？${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 开启"
    echo -e "${GREEN}2.${PLAIN} 关闭"
    read -e -p "$(echo -e "${BLUE}请输入选项 [1/2] (默认1): ${PLAIN}")" tun_choice
    case "$tun_choice" in
        2) tun_enable=false ;;
        *) tun_enable=true ;;
    esac

    # mode参数交互
    echo -e "${YELLOW}[*] 请选择运行模式 mode: ${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} rule"
    echo -e "${GREEN}2.${PLAIN} global"
    echo -e "${GREEN}3.${PLAIN} direct"
    read -e -p "$(echo -e "${BLUE}请输入选项 [1/2/3] (默认1): ${PLAIN}")" mode_choice
    case "$mode_choice" in
        2) mode="global" ;;
        3) mode="direct" ;;
        *) mode="rule" ;;
    esac

    # WireGuard参数交互
    echo -e "${YELLOW}[*] WireGuard配置方式：${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 使用默认配置"
    echo -e "${GREEN}2.${PLAIN} 手动输入配置"
    read -e -p "$(echo -e "${BLUE}请选择 [1/2] (默认1): ${PLAIN}")" wg_choice
    case "$wg_choice" in
        2)
            read -e -p "$(echo -e "${BLUE}  Private-key${PLAIN}: ")" private_key
            read -e -p "$(echo -e "${BLUE}  Endpoint    ${PLAIN}: ")" server
            read -e -p "$(echo -e "${BLUE}  Port        ${PLAIN}: ")" port
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                echo -e "${RED}[!] 无效端口号，请输入 1-65535 之间的数字。${PLAIN}"
                exit 1
            fi
            read -e -p "$(echo -e "${BLUE}  Public-key  ${PLAIN}: ")" public_key
            read -e -p "$(echo -e "${BLUE}  MTU         ${PLAIN}: ")" mtu
            ;;
        *)
            private_key="eMCyIN4iJrc9jeot1L+53I1N7whB3AVlMYCF43yJfnQ="
            server="162.159.193.8"
            port="2408"
            public_key="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
            mtu="1280"
            ;;
    esac

    # socks-port
    echo -e "${YELLOW}[*] 请输入 SOCKS5 代理端口：${PLAIN}"
    read -e -p "$(echo -e "${BLUE}  socks-port  ${PLAIN}${CYAN}[默认: 18443]${PLAIN}: ")" socks_port
    socks_port=${socks_port:-18443}
    echo

    # bind-address
    echo -e "${YELLOW}[*] 请配置 bind-address 监听地址: ${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 127.0.0.1 (仅本地访问)"
    echo -e "${GREEN}2.${PLAIN} 0.0.0.0 (允许公网访问)"
    read -e -p "$(echo -e "${BLUE}请输入选项 [1/2] (默认1): ${PLAIN}")" bind_choice
    case "$bind_choice" in
        2) bind_address="0.0.0.0" ;;
        *) bind_address="127.0.0.1" ;;
    esac

    # socks5认证
    echo -e "${YELLOW}[*] 是否为 SOCKS5 设置用户名密码认证？${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 开启"
    echo -e "${GREEN}2.${PLAIN} 关闭"
    read -e -p "$(echo -e "${BLUE}请输入选项 [1/2] (默认2): ${PLAIN}")" auth_choice
    case "$auth_choice" in
        1)
            read -e -p "$(echo -e "${BLUE}请输入用户名 (默认admin): ${PLAIN}")" auth_user
            read -e -p "$(echo -e "${BLUE}请输入密码 (默认admin): ${PLAIN}")" auth_pass
            auth_user=${auth_user:-admin}
            auth_pass=${auth_pass:-admin}
            authentication_config="authentication:\n  - \"$auth_user:$auth_pass\""
            ;;
        *)
            authentication_config=""
            ;;
    esac

    echo -e "${CYAN}[*] 创建 config.yaml 配置文件...${PLAIN}"
    cat <<EOF > config.yaml
tun:
  enable: $tun_enable
  stack: mixed
  dns-hijack:
    - any:53
  strict_route: true
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true

geodata-mode: false
geox-url:
  mmdb: "https://raw.githubusercontent.com/NobyDa/geoip/release/Private-GeoIP-CN.mmdb"
geo-update-interval: 24
tcp-concurrent: true
find-process-mode: off
allow-lan: true
socks-port: $socks_port
bind-address: "$bind_address"
$(if [ -n "$authentication_config" ]; then echo -e "$authentication_config"; fi)
mode: $mode
log-level: warning
ipv6: false
profile:
  store-fake-ip: true
sniffer:
  enable: false
dns:
  enable: true
  listen: any:53
  ipv6: false
  nameserver:
    - 8.8.8.8
  fallback:
    - 1.1.1.1
  direct-nameserver:
    - system
  enhanced-mode: fake-ip

  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*'
    - '+.lan'
    - '+.local'

proxies:
  - name: "warp"
    type: wireguard
    private-key: $private_key
    server: $server
    port: $port
    ip: 172.16.0.2
    public-key: $public_key
    allowed-ips: ['0.0.0.0/0']
    udp: true
    mtu: $mtu

rule-providers:
  Ai:
    type: http
    behavior: classical
    format: text
    path: ./AI
    url: https://raw.githubusercontent.com/Emokui/Rule/list/Mihomo/AI
    interval: 86400
  YouTube:
    type: http
    behavior: classical
    format: text
    path: ./YouTube
    url: https://raw.githubusercontent.com/Emokui/Rule/list/Mihomo/YouTube
    interval: 86400

rules:
  - RULE-SET,YouTube,warp,no-resolve
  - RULE-SET,Ai,warp,no-resolve
  - MATCH,DIRECT
EOF
    check_status "创建配置文件"

    echo -e "${CYAN}[*] 配置 systemd service 与 timer...${PLAIN}"
    create_systemd_service
    create_systemd_timer

    sudo systemctl daemon-reload
    sudo systemctl enable --now ${TIMER_NAME}
    echo -e "${GREEN}[*] Mihomo 安装完成，将于开机2分钟后自动启动。${PLAIN}"
    echo -e "${CYAN}你也可以用 'sudo systemctl [start|stop|restart|status] ${SERVICE_NAME}' 管理"
    echo "查看定时器状态：sudo systemctl status ${TIMER_NAME}${PLAIN}"

    read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
    clear
}

# 更新Mihomo内核
get_latest_mihomo_url_and_version() {
    latest_version=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed 's/.*"tag_name": *"\(v[0-9.]*\)".*/\1/')
    url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-${latest_version}.gz"
    echo "$url|${latest_version}"
}

update_mihomo() {
    echo -e "${CYAN}[*] 开始更新 Mihomo...${PLAIN}"
    cd "$MIHOMO_DIR" || { echo -e "${RED}[!] 无法进入 $MIHOMO_DIR 目录。${PLAIN}"; exit 1; }
    result=$(get_latest_mihomo_url_and_version)
    download_url="${result%|*}"

    echo -e "${CYAN}[*] 下载 Mihomo: $download_url ${PLAIN}"
    wget "$download_url" -O "mihomo.gz"
    check_status "下载 Mihomo"

    gunzip -f "mihomo.gz"
    if [ -f "mihomo" ]; then
        chmod +x mihomo
        check_status "设置执行权限"
    else
        echo -e "${RED}[!] 解压后未找到 mihomo 可执行文件，请检查下载或解压是否成功。${PLAIN}"
        exit 1
    fi

    echo -e "${CYAN}[*] 重启 Mihomo systemd 服务...${PLAIN}"
    sudo systemctl restart ${SERVICE_NAME}.service
    sleep 2
    sudo systemctl status ${SERVICE_NAME}.service

    read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
    clear
}

# 修改 Mihomo 配置
modify_mihomo_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}[!] 未找到 $CONFIG_PATH 配置文件，请先安装 Mihomo。${PLAIN}"
        read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键返回...${PLAIN}")"
        clear
        return
    fi

    tun_enable=$(yq e '.tun.enable' "$CONFIG_PATH")
    mode_val=$(yq e '.mode' "$CONFIG_PATH")
    socks_port=$(yq e '.socks-port' "$CONFIG_PATH")
    bind_address=$(yq e '.bind-address' "$CONFIG_PATH" | tr -d '"')
    has_auth=$(yq e '.authentication // ""' "$CONFIG_PATH")
    auth_user_pass=$(yq e '.authentication[0]' "$CONFIG_PATH")
    auth_user=$(echo "$auth_user_pass" | cut -d: -f1)
    auth_pass=$(echo "$auth_user_pass" | cut -d: -f2)
    private_key=$(yq e '.proxies[] | select(.name == "warp") | .private-key' "$CONFIG_PATH")
    server=$(yq e '.proxies[] | select(.name == "warp") | .server' "$CONFIG_PATH")
    port=$(yq e '.proxies[] | select(.name == "warp") | .port' "$CONFIG_PATH")
    public_key=$(yq e '.proxies[] | select(.name == "warp") | .public-key' "$CONFIG_PATH")
    mtu=$(yq e '.proxies[] | select(.name == "warp") | .mtu' "$CONFIG_PATH")

    while true; do
        clear
        echo -e "${BLUE}========== Mihomo 配置修改 ==========${PLAIN}"
        echo -e "${CYAN}当前配置:${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} tun.enable:            ${YELLOW}$tun_enable${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} mode:                  ${YELLOW}${mode_val}${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} socks-port:            ${YELLOW}${socks_port:-无}${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} bind-address:          ${YELLOW}${bind_address:-127.0.0.1}${PLAIN}"
        echo -e "${GREEN}5.${PLAIN} SOCKS5认证:             ${YELLOW}${has_auth:-无}${PLAIN}"
        echo -e "${GREEN}6.${PLAIN} WireGuard Private-key: ${YELLOW}$private_key${PLAIN}"
        echo -e "${GREEN}7.${PLAIN} WireGuard Server:      ${YELLOW}$server${PLAIN}"
        echo -e "${GREEN}8.${PLAIN} WireGuard Port:        ${YELLOW}$port${PLAIN}"
        echo -e "${GREEN}9.${PLAIN} WireGuard Public-key:  ${YELLOW}$public_key${PLAIN}"
        echo -e "${GREEN}10.${PLAIN} WireGuard MTU:        ${YELLOW}$mtu${PLAIN}"
        echo -e "${GREEN}0.${PLAIN} 保存并重启 Mihomo 服务${PLAIN}"
        echo -e "${GREEN}q.${PLAIN} 放弃修改并返回${PLAIN}"
        read -e -p "$(echo -e "${YELLOW}请选择要修改的项目 [0-10/q]: ${PLAIN}")" modchoice

        case $modchoice in
            1)
                read -e -p "$(echo -e "${BLUE}tun.enable (true/false) [当前:$tun_enable]: ${PLAIN}")" newval
                newval=${newval:-$tun_enable}
                yq e '.tun.enable = '"$newval"'' -i "$CONFIG_PATH"
                tun_enable="$newval"
                ;;
            2)
                echo -e "${YELLOW}请选择新的 mode 参数:${PLAIN}"
                echo -e "${GREEN}1.${PLAIN} rule (规则模式)"
                echo -e "${GREEN}2.${PLAIN} global (全局模式)"
                echo -e "${GREEN}3.${PLAIN} direct (直连模式)"
                read -e -p "$(echo -e "${BLUE}请输入选项 [1/2/3] (当前:${mode_val:-rule}): ${PLAIN}")" mode_choice
                case "$mode_choice" in
                    2) newmode="global" ;;
                    3) newmode="direct" ;;
                    1|"") newmode="rule" ;;
                    *) echo -e "${RED}无效选项，未更改。${PLAIN}"; read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"; continue ;;
                esac
                yq e '.mode = "'"$newmode"'"' -i "$CONFIG_PATH"
                mode_val="$newmode"
                ;;
            3)
                read -e -p "$(echo -e "${BLUE}socks-port [当前:$socks_port]: ${PLAIN}")" newval
                newval=${newval:-$socks_port}
                yq e '.socks-port = '"$newval"'' -i "$CONFIG_PATH"
                socks_port="$newval"
                ;;
            4)
                echo -e "${YELLOW}请选择 bind-address 监听地址:${PLAIN}"
                echo -e "${GREEN}1.${PLAIN} 127.0.0.1 (仅本地访问，推荐)"
                echo -e "${GREEN}2.${PLAIN} 0.0.0.0 (所有网卡，允许外部访问)"
                read -e -p "$(echo -e "${BLUE}请输入选项 [1/2] (当前:${bind_address:-127.0.0.1}): ${PLAIN}")" bind_choice
                case "$bind_choice" in
                    2) newval="0.0.0.0" ;;
                    *) newval="127.0.0.1" ;;
                esac
                yq e '.bind-address = "'"$newval"'"' -i "$CONFIG_PATH"
                bind_address="$newval"
                ;;
            5)
                echo -e "${YELLOW}是否为 SOCKS5 设置用户名密码认证？${PLAIN}"
                read -e -p "$(echo -e "${BLUE}启用请输入 y，禁用请输入 n [y/n] (当前: ${has_auth:-n}): ${PLAIN}")" auth_enable
                auth_enable=${auth_enable:-n}
                if [[ "$auth_enable" == "y" || "$auth_enable" == "Y" ]]; then
                    read -e -p "$(echo -e "${BLUE}请输入用户名 (默认admin): ${PLAIN}")" newuser
                    read -e -p "$(echo -e "${BLUE}请输入密码 (默认admin): ${PLAIN}")" newpass
                    newuser=${newuser:-admin}
                    newpass=${newpass:-admin}
                    yq e '.authentication = ["'"$newuser:$newpass"'"]' -i "$CONFIG_PATH"
                    has_auth="yes"
                    auth_user="$newuser"
                    auth_pass="$newpass"
                else
                    yq e 'del(.authentication)' -i "$CONFIG_PATH"
                    has_auth=""
                    auth_user=""
                    auth_pass=""
                fi
                ;;
            6)
                read -e -p "$(echo -e "${BLUE}WireGuard Private-key [当前:$private_key]: ${PLAIN}")" newval
                newval=${newval:-$private_key}
                yq e '(.proxies[] | select(.name == "warp") ).private-key = "'"$newval"'"' -i "$CONFIG_PATH"
                private_key="$newval"
                ;;
            7)
                read -e -p "$(echo -e "${BLUE}WireGuard Server [当前:$server]: ${PLAIN}")" newval
                newval=${newval:-$server}
                yq e '(.proxies[] | select(.name == "warp") ).server = "'"$newval"'"' -i "$CONFIG_PATH"
                server="$newval"
                ;;
            8)
                read -e -p "$(echo -e "${BLUE}WireGuard Port [当前:$port]: ${PLAIN}")" newval
                newval=${newval:-$port}
                yq e '(.proxies[] | select(.name == "warp") ).port = '"$newval"'' -i "$CONFIG_PATH"
                port="$newval"
                ;;
            9)
                read -e -p "$(echo -e "${BLUE}WireGuard Public-key [当前:$public_key]: ${PLAIN}")" newval
                newval=${newval:-$public_key}
                yq e '(.proxies[] | select(.name == "warp") ).public-key = "'"$newval"'"' -i "$CONFIG_PATH"
                public_key="$newval"
                ;;
            10)
                read -e -p "$(echo -e "${BLUE}WireGuard MTU [当前:$mtu]: ${PLAIN}")" newval
                newval=${newval:-$mtu}
                yq e '(.proxies[] | select(.name == "warp") ).mtu = '"$newval"'' -i "$CONFIG_PATH"
                mtu="$newval"
                ;;
            0)
                echo -e "${CYAN}[*] 保存并重启 Mihomo 服务...${PLAIN}"
                sudo systemctl restart ${SERVICE_NAME}.service
                sleep 2
                sudo systemctl status ${SERVICE_NAME}.service
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键返回主菜单...${PLAIN}")"
                clear
                break
                ;;
            q|Q)
                echo -e "${CYAN}[*] 放弃修改，返回主菜单...${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键返回主菜单...${PLAIN}")"
                clear
                break
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                ;;
        esac
    done
}

# 删除 Mihomo 及配置
delete_mihomo() {
    echo -e "${RED}[!] 此操作将停止并彻底删除 Mihomo 及其配置，无法恢复！${PLAIN}"
    read -e -p "$(echo -e "${YELLOW}确定要删除 Mihomo 及配置吗？(y/n): ${PLAIN}")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${CYAN}[*] 停止并禁用 Mihomo systemd/timer...${PLAIN}"
        sudo systemctl stop ${SERVICE_NAME}.service
        sudo systemctl disable ${SERVICE_NAME}.service
        sudo systemctl stop ${TIMER_NAME}
        sudo systemctl disable ${TIMER_NAME}
        sudo rm -f /etc/systemd/system/${SERVICE_NAME}.service
        sudo rm -f /etc/systemd/system/${TIMER_NAME}
        sudo systemctl daemon-reload

        if [ -d "$MIHOMO_DIR" ]; then
            rm -rf "$MIHOMO_DIR"
            if [ ! -d "$MIHOMO_DIR" ]; then
                echo -e "${GREEN}[*] 已彻底删除 $MIHOMO_DIR 及其中所有内容。${PLAIN}"
            else
                echo -e "${RED}[!] 删除失败，请检查权限。${PLAIN}"
            fi
        else
            echo -e "${GREEN}[*] 未检测到 $MIHOMO_DIR 目录。${PLAIN}"
        fi
        echo -e "${GREEN}[*] Mihomo 及配置、systemd单元已全部删除。${PLAIN}"

        read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
        clear
    else
        echo -e "${CYAN}[*] 已取消删除操作。${PLAIN}"

        read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
        clear
    fi
}

# 管理 Mihomo systemd 服务
manage_service() {
    while true; do
        echo -e "${BLUE}============== Mihomo 服务管理菜单 ==============${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 停止 Mihomo"
        echo -e "${GREEN}2.${PLAIN} 启动 Mihomo"
        echo -e "${GREEN}3.${PLAIN} 重启 Mihomo"
        echo -e "${GREEN}4.${PLAIN} 查看 Mihomo 状态"
        echo -e "${GREEN}5.${PLAIN} 修改 Mihomo 配置"
        echo -e "${GREEN}6.${PLAIN} 删除 Mihomo"
        echo -e "${GREEN}0.${PLAIN} 返回主菜单"
        read -e -p "$(echo -e "${YELLOW}请输入选项 [0-6]: ${PLAIN}")" subchoice

        case $subchoice in
            1)
                echo -e "${CYAN}[*] systemd 停止 Mihomo...${PLAIN}"
                sudo systemctl stop ${SERVICE_NAME}.service
                echo -e "${GREEN}[*] Mihomo 已停止${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                ;;
            2)
                echo -e "${CYAN}[*] systemd 启动 Mihomo...${PLAIN}"
                sudo systemctl start ${SERVICE_NAME}.service
                echo -e "${GREEN}[*] Mihomo 已启动${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                ;;
            3)
                echo -e "${CYAN}[*] systemd 重启 Mihomo...${PLAIN}"
                sudo systemctl restart ${SERVICE_NAME}.service
                echo -e "${GREEN}[*] Mihomo 已重启${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                ;;
            4)
                echo -e "${CYAN}[*] systemd 查看 Mihomo 状态...${PLAIN}"
                sudo systemctl status ${SERVICE_NAME}.service
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                ;;
            5)
                modify_mihomo_config
                ;;
            6)
                delete_mihomo
                break
                ;;
            0)
                echo -e "${CYAN}[*] 返回主菜单...${PLAIN}"
                clear
                break
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                ;;
        esac
    done
}

# 主菜单
while true; do
    clear
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${BLUE}====      Steins Gate - mihomo Ver.1.0     ====${PLAIN}"
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${CYAN}请选择操作：${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 安装 Mihomo"
    echo -e "${GREEN}2.${PLAIN} 管理 Mihomo"
    echo -e "${GREEN}3.${PLAIN} 更新 Mihomo"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    read -e -p "$(echo -e "${YELLOW}请输入选项 [0-3]: ${PLAIN}")" choice

    case $choice in
        1) install_mihomo ;;
        2)
            if [ ! -f "$MIHOMO_PATH" ]; then
                echo -e "${RED}[!] Mihomo 未安装，请先选择选项 1。${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                continue
            fi
            manage_service
            ;;
        3)
            if [ ! -d "${HOME}/clash" ]; then
                echo -e "${RED}[!] 未找到 ~/clash 目录，请先选择选项 1 安装。${PLAIN}"
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                continue
            fi
            update_mihomo
            ;;
        0)
            echo -e "${GREEN}[*] 退出脚本...${PLAIN}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新选择。${PLAIN}"
            read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
            clear
            ;;
    esac
done
