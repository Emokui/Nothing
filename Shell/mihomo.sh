#!/bin/bash

# 定义颜色
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

# 检查命令执行结果
check_status() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}[!] $1 失败。${PLAIN}"
        exit 1
    fi
}

# systemd service
create_systemd_service() {
    cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null
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

# systemd timer (2min after boot)
create_systemd_timer() {
    cat <<EOF | sudo tee /etc/systemd/system/${TIMER_NAME} > /dev/null
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
get_latest_stable_version() {
    local raw_version
    echo -e "${CYAN}[*] 检查最新稳定 Mihomo 版本...${PLAIN}" >&2
    raw_version=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases | \
                  grep -oP '(?<=tag_name": "v)\d+\.\d+\.\d+(?=")' | \
                  grep -v "Prerelease" | head -n 1)
    if [ -z "$raw_version" ]; then
        echo -e "${RED}[!] 无法获取最新稳定版本，请检查网络或 GitHub API。${PLAIN}" >&2
        exit 1
    fi
    local latest_version="v${raw_version}"
    echo -e "${GREEN}[*] 最新稳定版本: $latest_version${PLAIN}" >&2
    echo "$latest_version"
}

# 修改 Mihomo 配置交互式子菜单
modify_mihomo_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}[!] 未找到 $CONFIG_PATH 配置文件，请先安装 Mihomo。${PLAIN}"
        read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键返回...${PLAIN}")"
        clear
        return
    fi

    # 读取配置
    tun_enable=$(awk '/^tun:/ {f=1} f && /enable:/ {print $2;f=0}' "$CONFIG_PATH")
    socks_port=$(awk '/^socks-port:/ {print $2}' "$CONFIG_PATH")
    private_key=$(awk '/- name: "warp"/, /mtu:/ {if($1=="private-key:")print $2}' "$CONFIG_PATH")
    server=$(awk '/- name: "warp"/, /mtu:/ {if($1=="server:")print $2}' "$CONFIG_PATH")
    port=$(awk '/- name: "warp"/, /mtu:/ {if($1=="port:")print $2}' "$CONFIG_PATH")
    public_key=$(awk '/- name: "warp"/, /mtu:/ {if($1=="public-key:")print $2}' "$CONFIG_PATH")
    reserved=$(awk '/- name: "warp"/, /mtu:/ {if($1=="reserved:")print $2}' "$CONFIG_PATH")
    mtu=$(awk '/- name: "warp"/, /mtu:/ {if($1=="mtu:")print $2}' "$CONFIG_PATH")

    while true; do
        clear
        echo -e "${BLUE}========== Mihomo 配置修改 ==========${PLAIN}"
        echo -e "${CYAN}当前配置:${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} tun.enable:      ${YELLOW}$tun_enable${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} socks-port:      ${YELLOW}${socks_port:-无}${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} WireGuard Private-key: ${YELLOW}$private_key${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} WireGuard Server:      ${YELLOW}$server${PLAIN}"
        echo -e "${GREEN}5.${PLAIN} WireGuard Port:        ${YELLOW}$port${PLAIN}"
        echo -e "${GREEN}6.${PLAIN} WireGuard Public-key:  ${YELLOW}$public_key${PLAIN}"
        echo -e "${GREEN}7.${PLAIN} WireGuard Reserved:    ${YELLOW}$reserved${PLAIN}"
        echo -e "${GREEN}8.${PLAIN} WireGuard MTU:         ${YELLOW}$mtu${PLAIN}"
        echo -e "${GREEN}0.${PLAIN} 保存并重启 Mihomo 服务${PLAIN}"
        echo -e "${GREEN}q.${PLAIN} 放弃修改并返回${PLAIN}"
        read -e -p "$(echo -e "${YELLOW}请选择要修改的项目 [0-8/q]: ${PLAIN}")" modchoice

        case $modchoice in
            1)
                read -e -p "$(echo -e "${BLUE}tun.enable (true/false) [当前:$tun_enable]: ${PLAIN}")" newval
                newval=${newval:-$tun_enable}
                awk -v val="$newval" '
                  BEGIN{f=0}
                  /^tun:/ {f=1}
                  f && /enable:/ {sub(/enable: .*/, "enable: "val); f=0}
                  {print}
                ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                tun_enable="$newval"
                ;;
            2)
                read -e -p "$(echo -e "${BLUE}socks-port [当前:$socks_port]: ${PLAIN}")" newval
                newval=${newval:-$socks_port}
                if grep -q "^socks-port:" "$CONFIG_PATH"; then
                    sed -i "s/^socks-port:.*/socks-port: $newval/" "$CONFIG_PATH"
                else
                    sed -i "/^allow-lan:/a socks-port: $newval" "$CONFIG_PATH"
                fi
                socks_port="$newval"
                ;;
            3)
                read -e -p "$(echo -e "${BLUE}WireGuard Private-key [当前:$private_key]: ${PLAIN}")" newval
                newval=${newval:-$private_key}
                awk '
                  /- name: "warp"/{f=1}
                  f && /private-key:/{$2=": "newval; $0="    private-key: "newval; f=0}
                  {print}
                ' newval="$newval" "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                private_key="$newval"
                ;;
            4)
                read -e -p "$(echo -e "${BLUE}WireGuard Server [当前:$server]: ${PLAIN}")" newval
                newval=${newval:-$server}
                awk '
                  /- name: "warp"/{f=1}
                  f && /server:/{$2=": "newval; $0="    server: "newval; f=0}
                  {print}
                ' newval="$newval" "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                server="$newval"
                ;;
            5)
                read -e -p "$(echo -e "${BLUE}WireGuard Port [当前:$port]: ${PLAIN}")" newval
                newval=${newval:-$port}
                awk '
                  /- name: "warp"/{f=1}
                  f && /port:/{$2=": "newval; $0="    port: "newval; f=0}
                  {print}
                ' newval="$newval" "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                port="$newval"
                ;;
            6)
                read -e -p "$(echo -e "${BLUE}WireGuard Public-key [当前:$public_key]: ${PLAIN}")" newval
                newval=${newval:-$public_key}
                awk '
                  /- name: "warp"/{f=1}
                  f && /public-key:/{$2=": "newval; $0="    public-key: "newval; f=0}
                  {print}
                ' newval="$newval" "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                public_key="$newval"
                ;;
            7)
                read -e -p "$(echo -e "${BLUE}WireGuard Reserved [当前:$reserved]: ${PLAIN}")" newval
                newval=${newval:-$reserved}
                awk '
                  /- name: "warp"/{f=1}
                  f && /reserved:/{$2=": "newval; $0="    reserved: "newval; f=0}
                  {print}
                ' newval="$newval" "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
                reserved="$newval"
                ;;
            8)
                read -e -p "$(echo -e "${BLUE}WireGuard MTU [当前:$mtu]: ${PLAIN}")" newval
                newval=${newval:-$mtu}
                awk '
                  /- name: "warp"/{f=1}
                  f && /mtu:/{$2=": "newval; $0="    mtu: "newval; f=0}
                  {print}
                ' newval="$newval" "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
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

# 安装并配置 Mihomo
install_mihomo() {
    echo -e "${CYAN}[*] 开始安装并配置 Mihomo...${PLAIN}"
    mkdir -p "$MIHOMO_DIR" && cd "$MIHOMO_DIR" || exit 1

    latest_version=$(get_latest_stable_version)
    download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-compatible-${latest_version}.gz"

    echo -e "${CYAN}[*] 下载 Mihomo $latest_version...${PLAIN}"
    wget "$download_url" -O "mihomo-linux-amd64-compatible-${latest_version}.gz"
    check_status "下载 Mihomo"

    echo -e "${CYAN}[*] 解压并赋予执行权限...${PLAIN}"
    gunzip "mihomo-linux-amd64-compatible-${latest_version}.gz"
    check_status "解压文件"
    mv "mihomo-linux-amd64-compatible-${latest_version}" mihomo
    chmod +x mihomo
    check_status "设置执行权限"

    # tun 模式选择
    echo -e "${YELLOW}[*] 是否启用 tun 模式？${PLAIN}"
    read -e -p "$(echo -e "${BLUE}启用请输入 y，禁用请输入 n [y/n]: ${PLAIN}")" enable_tun
    enable_tun=${enable_tun:-y}
    if [[ "$enable_tun" == "y" || "$enable_tun" == "Y" ]]; then
        tun_enable=true
    else
        tun_enable=false
    fi
    echo

    # WireGuard 配置交互
    echo -e "${YELLOW}[*] 请输入 WireGuard 配置信息（直接回车为默认值）：${PLAIN}"

    read -e -p "$(echo -e "${BLUE}  Private-key${PLAIN} ${CYAN}[默认: 2Nk08dzxAkzubjt19fO2VKEgdBjpHxEluNvTJKDHW1w=]${PLAIN}: ")" private_key
    private_key=${private_key:-2Nk08dzxAkzubjt19fO2VKEgdBjpHxEluNvTJKDHW1w=}

    read -e -p "$(echo -e "${BLUE}  Endpoint    ${PLAIN}${CYAN}[默认: 162.159.193.10]${PLAIN}: ")" server
    server=${server:-162.159.193.10}

    read -e -p "$(echo -e "${BLUE}  Port        ${PLAIN}${CYAN}[默认: 2408]${PLAIN}: ")" port
    port=${port:-2408}
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}[!] 无效端口号，请输入 1-65535 之间的数字。${PLAIN}"
        exit 1
    fi

    read -e -p "$(echo -e "${BLUE}  Public-key  ${PLAIN}${CYAN}[默认: bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=]${PLAIN}: ")" public_key
    public_key=${public_key:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}

    read -e -p "$(echo -e "${BLUE}  Reserved    ${PLAIN}${CYAN}[默认: [154,242,221]]${PLAIN}: ")" reserved
    reserved=${reserved:-[154,242,221]}

    read -e -p "$(echo -e "${BLUE}  MTU         ${PLAIN}${CYAN}[默认: 1280]${PLAIN}: ")" mtu
    mtu=${mtu:-1280}
    echo

    # socks-port 配置
    echo -e "${YELLOW}[*] 请输入本地 SOCKS 代理端口（直接回车为默认18443）：${PLAIN}"
    read -e -p "$(echo -e "${BLUE}  socks-port  ${PLAIN}${CYAN}[默认: 18443]${PLAIN}: ")" socks_port
    socks_port=${socks_port:-18443}
    echo

    # 写入 config.yaml
    echo -e "${CYAN}[*] 创建 config.yaml 配置文件...${PLAIN}"
    cat <<EOF > config.yaml
tun:
  enable: $tun_enable
  stack: system
  dns-hijack:
    - '0.0.0.0:53'
  strict_route: true
  auto-route: true
  auto-detect-interface: true

geodata-mode: false
geox-url:
  mmdb: "https://raw.githubusercontent.com/NobyDa/geoip/release/Private-GeoIP-CN.mmdb"
geo-update-interval: 24
tcp-concurrent: true
find-process-mode: off
allow-lan: true
socks-port: $socks_port
bind-address: "127.0.0.1"
mode: rule
log-level: warning
ipv6: false
profile:
  store-fake-ip: true
sniffer:
  enable: false
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  default-nameserver:
    - 8.8.8.8
    - 1.1.1.1
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
  direct-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  enhanced-mode: fake-ip # or redir-host

  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*'
    - '+.lan'
    - '+.local'
 # use-hosts: true

proxies:
  - name: "warp"
    type: wireguard
    private-key: $private_key
    server: $server
    port: $port
    ip: 172.16.0.2
    public-key: $public_key
    allowed-ips: ['0.0.0.0/0']
    reserved: $reserved
    udp: true
    mtu: $mtu

rule-providers:
  Ai:
    type: http
    behavior: classical
    format: text
    path: ./𝗔𝗜
    url: https://raw.githubusercontent.com/Emokui/Rule/𝗟𝗶𝘀𝘁/𝗔𝗜
    interval: 86400
  YouTube:
    type: http
    behavior: classical
    format: text
    path: ./𝗬𝗼𝘂𝗧𝘂𝗯𝗲
    url: https://raw.githubusercontent.com/Emokui/Rule/𝗟𝗶𝘀𝘁/𝗬𝗼𝘂𝗧𝘂𝗯𝗲
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

# 更新 Mihomo
update_mihomo() {
    echo -e "${CYAN}[*] 开始更新 Mihomo...${PLAIN}"
    cd "$MIHOMO_DIR" || { echo -e "${RED}[!] 无法进入 $MIHOMO_DIR 目录。${PLAIN}"; exit 1; }
    latest_version=$(get_latest_stable_version)
    download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-compatible-${latest_version}.gz"

    echo -e "${CYAN}[*] 下载 Mihomo $latest_version...${PLAIN}"
    wget "$download_url" -O "mihomo-linux-amd64-compatible-${latest_version}.gz"
    check_status "下载 Mihomo"

    echo -e "${CYAN}[*] 解压并替换文件...${PLAIN}"
    gunzip "mihomo-linux-amd64-compatible-${latest_version}.gz"
    check_status "解压文件"
    if [ -f "$MIHOMO_PATH" ]; then
        mv "$MIHOMO_PATH" "$MIHOMO_PATH.old"
        echo -e "${YELLOW}[*] 已备份旧内核到 $MIHOMO_PATH.old${PLAIN}"
    fi
    mv "mihomo-linux-amd64-compatible-${latest_version}" mihomo
    chmod +x mihomo
    check_status "设置执行权限"
    rm -f "$MIHOMO_PATH.old"

    echo -e "${CYAN}[*] 重启 Mihomo systemd 服务...${PLAIN}"
    sudo systemctl restart ${SERVICE_NAME}.service
    sleep 2
    sudo systemctl status ${SERVICE_NAME}.service

    read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
    clear
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
        echo -e "${BLUE}选择属于你的命运之门${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 停止 Mihomo${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 启动 Mihomo${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} 重启 Mihomo${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} 查看 Mihomo 状态${PLAIN}"
        echo -e "${GREEN}5.${PLAIN} 查看 Timer 状态${PLAIN}"
        echo -e "${GREEN}6.${PLAIN} 删除 Mihomo 及配置${PLAIN}"
        echo -e "${GREEN}7.${PLAIN} 修改 Mihomo 配置并自动重启${PLAIN}"
        echo -e "${GREEN}0.${PLAIN} 返回世界线${PLAIN}"
        read -e -p "$(echo -e "${YELLOW}请输入选项 [0-7]: ${PLAIN}")" subchoice

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
                echo -e "${CYAN}[*] 查看 Timer 状态...${PLAIN}"
                sudo systemctl status ${TIMER_NAME}
                read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
                clear
                ;;
            6)
                delete_mihomo
                break
                ;;
            7)
                modify_mihomo_config
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
    echo -e "${CYAN}选择属于你的命运之门：${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 安装并配置 Mihomo (systemd/timer 2分钟后自启)${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 管理 Mihomo 服务 (systemd)${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 更新 Mihomo${PLAIN}"
    echo -e "${GREEN}0.${PLAIN} 再见 El Psy Kongroo${PLAIN}"
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
        0) echo -e "${GREEN}[*] 退出脚本...${PLAIN}"; exit 0 ;;
        *) 
            echo -e "${RED}无效选项，请重新选择。${PLAIN}" 
            read -n 1 -s -r -p "$(echo -e "${YELLOW}按任意键继续...${PLAIN}")"
            clear
            ;;
    esac
done
