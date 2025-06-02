#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[1;35m'
PLAIN='\033[0m'

SUBSTORE_COMPOSE_PATH="/root/substore/docker-compose.yml"
SUBSTORE_DATA_PATH="/root/substore/data"
SUBSTORE_INFO_PATH="/root/substore/info.txt"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}运行脚本需要 root 权限${PLAIN}" >&2
        exit 1
    fi
}

install_packages() {
    hash -r
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker 和 Docker Compose...${PLAIN}"
        (
            if ! curl -fsSL https://get.docker.com | bash; then
                exit 10
            fi
            if ! apt-get update && apt-get install -y docker-compose; then
                exit 11
            fi
        ) &
        install_pid=$!
        spin='-\|/'
        i=0
        while kill -0 $install_pid 2>/dev/null; do
            i=$(( (i+1) %4 ))
            printf "\r${CYAN}安装中，请稍候... ${spin:$i:1}${PLAIN}"
            sleep 0.3
        done
        wait $install_pid
        install_status=$?
        echo -ne "\r"
        if [[ $install_status -eq 0 ]]; then
            echo -e "${GREEN}Docker 和 Docker Compose 安装完成。${PLAIN}"
        elif [[ $install_status -eq 10 ]]; then
            echo -e "${RED}Docker 安装失败${PLAIN}" >&2
            exit 1
        elif [[ $install_status -eq 11 ]]; then
            echo -e "${RED}Docker Compose 安装失败${PLAIN}" >&2
            exit 1
        else
            echo -e "${RED}未知错误，安装失败${PLAIN}" >&2
            exit 1
        fi
    else
        echo -e "${GREEN}Docker 和 Docker Compose 已安装。${PLAIN}"
    fi
}

get_public_ip() {
    local ip_services=("ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "ipecho.net/plain" "ident.me")
    local public_ip

    for service in "${ip_services[@]}"; do
        if public_ip=$(curl -sS --connect-timeout 5 "$service"); then
            if [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$public_ip"
                return 0
            fi
        fi
        sleep 1
    done

    echo -e "${RED}无法获取公共 IP 地址。${PLAIN}" >&2
    exit 1
}

install_substore() {
    # 新增：检测是否已安装并配置过
    if [[ -f "$SUBSTORE_COMPOSE_PATH" && -f "$SUBSTORE_INFO_PATH" ]]; then
        echo -e "${GREEN}Sub-Store 已经安装并配置过。${PLAIN}"
        echo -e "${YELLOW}如需修改配置，请选择 2. 管理 Sub-Store。${PLAIN}"
        read -p "按回车键返回主菜单..." 
        return 0
    fi

    install_packages
    local public_ip
    public_ip=$(get_public_ip)
    local secret_key
    secret_key=$(openssl rand -hex 16)

    echo -e "${CYAN}生成的密钥: $secret_key${PLAIN}"

    local default_port=3001
    read -p "请输入你想使用的端口号（默认: $default_port）: " custom_port
    custom_port="${custom_port:-$default_port}"

    if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || [ "$custom_port" -lt 1 ] || [ "$custom_port" -gt 65535 ]; then
        echo -e "${YELLOW}无效端口号，使用默认端口 $default_port${PLAIN}"
        custom_port=$default_port
    fi

    echo -e "${YELLOW}请选择访问方式：${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 公网访问（所有设备可访问）"
    echo -e "${GREEN}2.${PLAIN} 仅本机访问（127.0.0.1，仅本机可访问）"
    read -p "请输入选项 [1/2]，默认1: " access_choice
    access_choice="${access_choice:-1}"

    if [[ "$access_choice" == "2" ]]; then
        port_mapping="127.0.0.1:${custom_port}:3001"
        panel_host="127.0.0.1"
    else
        port_mapping="${custom_port}:3001"
        panel_host="$public_ip"
    fi

    mkdir -p /root/substore "$SUBSTORE_DATA_PATH"

    echo -e "${YELLOW}清理旧容器和配置...${PLAIN}"
    if command -v docker &>/dev/null; then
        docker rm -f sub-store >/dev/null 2>&1 || true
        docker compose -p sub-store down >/dev/null 2>&1 || true
    fi

    cat <<EOF > "$SUBSTORE_COMPOSE_PATH"
name: sub-store-app
services:
  sub-store:
    image: xream/sub-store
    container_name: sub-store
    restart: always
    environment:
      - SUB_STORE_BACKEND_UPLOAD_CRON=55 23 * * *
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$secret_key
    ports:
      - "$port_mapping"
    volumes:
      - $SUBSTORE_DATA_PATH:/opt/app/data
EOF

    cd /root/substore

    echo -e "${CYAN}拉取最新镜像...${PLAIN}"
    docker compose -f "$SUBSTORE_COMPOSE_PATH" -p sub-store pull

    echo -e "${CYAN}启动容器...${PLAIN}"
    docker compose -f "$SUBSTORE_COMPOSE_PATH" -p sub-store up -d

    if ! command -v cron &>/dev/null; then
        echo -e "${YELLOW}安装 cron...${PLAIN}"
        apt-get update >/dev/null 2>&1
        apt-get install -y cron >/dev/null 2>&1
    fi
    systemctl enable cron >/dev/null 2>&1
    systemctl start cron

    local cron_job="0 * * * * cd /root/substore && docker stop sub-store && docker rm sub-store && docker compose -f $SUBSTORE_COMPOSE_PATH -p sub-store pull sub-store && docker compose -f $SUBSTORE_COMPOSE_PATH -p sub-store up -d"
    (crontab -l 2>/dev/null || true; echo "$cron_job") | sort -u | crontab -

    echo -e "${CYAN}等待服务启动...${PLAIN}"
    for i in {1..30}; do
        if curl -s "http://127.0.0.1:$custom_port" >/dev/null; then
            echo -e "\n${GREEN}部署成功！您的 Sub-Store 信息如下：${PLAIN}"
            echo -e "${YELLOW}Sub-Store 面板：http://$panel_host:$custom_port${PLAIN}"
            echo -e "${YELLOW}后端地址：http://$panel_host:$custom_port/$secret_key${PLAIN}\n"
            echo "PORT=$custom_port" > "$SUBSTORE_INFO_PATH"
            echo "SECRET=$secret_key" >> "$SUBSTORE_INFO_PATH"
            echo "IP=$panel_host" >> "$SUBSTORE_INFO_PATH"
            return 0
        fi
        sleep 1
    done

    echo -e "${YELLOW}警告: 服务似乎未能在预期时间内启动，但可能仍在进行中。${PLAIN}"
    echo "PORT=$custom_port" > "$SUBSTORE_INFO_PATH"
    echo "SECRET=$secret_key" >> "$SUBSTORE_INFO_PATH"
    echo "IP=$panel_host" >> "$SUBSTORE_INFO_PATH"
    echo -e "${YELLOW}Sub-Store 面板：http://$panel_host:$custom_port${PLAIN}"
    echo -e "${YELLOW}后端地址：http://$panel_host:$custom_port/$secret_key${PLAIN}\n"
}

show_substore_info() {
    if [[ -f "$SUBSTORE_INFO_PATH" ]]; then
        source "$SUBSTORE_INFO_PATH"
        echo -e "${GREEN}Sub-Store 面板: ${CYAN}http://$IP:$PORT${PLAIN}"
        echo -e "${GREEN}后端地址: ${CYAN}http://$IP:$PORT/$SECRET${PLAIN}"
    else
        echo -e "${RED}Sub-Store 信息不存在，请先安装。${PLAIN}"
    fi
}

restart_substore() {
    if [[ ! -f "$SUBSTORE_COMPOSE_PATH" ]]; then
        echo -e "${RED}未检测到 Sub-Store 配置，无法重启。${PLAIN}"
        return 1
    fi
    if command -v docker &>/dev/null; then
        cd /root/substore
        docker compose -f "$SUBSTORE_COMPOSE_PATH" -p sub-store restart
        echo -e "${GREEN}Sub-Store 已重启。${PLAIN}"
    else
        echo -e "${RED}Docker 未安装，无法重启 Sub-Store。${PLAIN}"
    fi
}

update_substore() {
    if [[ ! -f "$SUBSTORE_COMPOSE_PATH" ]]; then
        echo -e "${RED}未检测到 Sub-Store 配置，无法更新。${PLAIN}"
        return 1
    fi
    if command -v docker &>/dev/null; then
        cd /root/substore
        echo -e "${CYAN}拉取最新 Sub-Store 镜像...${PLAIN}"
        docker compose -f "$SUBSTORE_COMPOSE_PATH" -p sub-store pull
        echo -e "${CYAN}重启 Sub-Store...${PLAIN}"
        docker compose -f "$SUBSTORE_COMPOSE_PATH" -p sub-store up -d
        echo -e "${GREEN}Sub-Store 已更新并重启。${PLAIN}"
    else
        echo -e "${RED}Docker 未安装，无法更新 Sub-Store。${PLAIN}"
    fi
}

delete_substore() {
    echo -e "${RED}即将彻底删除 Sub-Store、Docker 及其所有数据，是否继续? [y/N]${PLAIN}"
    read -r confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        if command -v docker &>/dev/null; then
            echo -e "${YELLOW}1. 停止并删除所有 Docker 容器...${PLAIN}"
            docker rm -f $(docker ps -aq) 2>/dev/null || true

            echo -e "${YELLOW}2. 删除所有 Docker 镜像...${PLAIN}"
            docker rmi -f $(docker images -q) 2>/dev/null || true

            echo -e "${YELLOW}3. 清理所有未使用的 Docker 网络...${PLAIN}"
            docker network prune -f || true
        fi

        echo -e "${YELLOW}4. 卸载 Docker 及 Docker Compose...${PLAIN}"
        if command -v apt &>/dev/null; then
            apt-get remove -y docker docker-ce docker-ce-cli docker-compose
            apt-get purge -y docker-ce docker-ce-cli docker-compose
        elif command -v yum &>/dev/null; then
            yum remove -y docker docker-ce docker-ce-cli docker-compose
        elif command -v dnf &>/dev/null; then
            dnf remove -y docker docker-ce docker-ce-cli docker-compose
        elif command -v apk &>/dev/null; then
            apk del docker docker-compose
        fi

        echo -e "${YELLOW}5. 删除 Docker 数据与配置目录...${PLAIN}"
        rm -rf /var/lib/docker /etc/docker

        echo -e "${YELLOW}6. 删除 Sub-Store 相关目录和数据...${PLAIN}"
        rm -rf /root/substore
        rm -rf /root/substore/data
        rm -rf /root/substore/info.txt

        echo -e "${YELLOW}7. 删除残留 docker-compose 配置文件（如有）...${PLAIN}"
        rm -rf /root/docker-compose.yml

        echo -e "${YELLOW}8. 删除其他自定义目录（如有/home/nginx、/root/sub-store-data）...${PLAIN}"
        rm -rf /home/nginx
        rm -rf /root/sub-store-data

        echo -e "${GREEN}Sub-Store、Docker 及相关数据已全部删除。${PLAIN}"
        hash -r
    else
        echo -e "${YELLOW}已取消删除。${PLAIN}"
    fi
}

substore_manage_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}============== Sub-Store 管理 ==============${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 查看当前 Sub-Store 地址及后端"
        echo -e "${GREEN}2.${PLAIN} 重启 Sub-Store"
        echo -e "${GREEN}3.${PLAIN} 更新 Sub-Store"
        echo -e "${GREEN}4.${PLAIN} 删除 Sub-Store 及相关"
        echo -e "${GREEN}0.${PLAIN} 返回主菜单"
        read -p "请选择操作：" sub_choice
        case $sub_choice in
            1) show_substore_info; read -p "按回车键返回管理菜单..." ;;
            2) restart_substore; read -p "按回车键返回管理菜单..." ;;
            3) update_substore; read -p "按回车键返回管理菜单..." ;;
            4) delete_substore; read -p "按回车键返回管理菜单..." ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${PLAIN}"; read -p "按回车键返回管理菜单..." ;;
        esac
        clear
    done
}

substore_manage_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}============== Sub-Store 管理 ==============${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 查看当前 Sub-Store 地址及后端"
        echo -e "${GREEN}2.${PLAIN} 重启 Sub-Store"
        echo -e "${GREEN}3.${PLAIN} 更新 Sub-Store"
        echo -e "${GREEN}4.${PLAIN} 修改 Sub-Store 配置"
        echo -e "${GREEN}5.${PLAIN} 删除 Sub-Store 及相关"        
        echo -e "${GREEN}0.${PLAIN} 返回主菜单"
        read -p "请选择操作：" sub_choice
        case $sub_choice in
            1) show_substore_info; read -p "按回车键返回管理菜单..." ;;
            2) restart_substore; read -p "按回车键返回管理菜单..." ;;
            3) update_substore; read -p "按回车键返回管理菜单..." ;;
            4) modify_substore_config; read -p "按回车键返回管理菜单..." ;;
            5) delete_substore; read -p "按回车键返回管理菜单..." ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${PLAIN}"; read -p "按回车键返回管理菜单..." ;;
        esac
        clear
    done
}

modify_substore_config() {
    if [[ ! -f "$SUBSTORE_COMPOSE_PATH" || ! -f "$SUBSTORE_INFO_PATH" ]]; then
        echo -e "${RED}未检测到 Sub-Store 配置，请先安装。${PLAIN}"
        return 1
    fi

    source "$SUBSTORE_INFO_PATH"
    echo -e "${CYAN}当前配置:${PLAIN}"
    echo -e "1. 端口号: ${YELLOW}${PORT}${PLAIN}"
    echo -e "2. 密钥:   ${YELLOW}${SECRET}${PLAIN}"
    echo -e "3. 访问IP: ${YELLOW}${IP}${PLAIN}"
    echo -e "${YELLOW}如需修改端口或密钥，将重新生成 docker-compose 配置，并重启服务。${PLAIN}"

    read -p "请输入新端口号（回车保留当前: $PORT）: " new_port
    new_port="${new_port:-$PORT}"
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}无效端口号，保留当前端口。${PLAIN}"
        new_port=$PORT
    fi

    read -p "请输入新的后台密钥（回车保留当前: $SECRET）: " new_secret
    new_secret="${new_secret:-$SECRET}"

    echo -e "${YELLOW}请选择访问方式：${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 公网访问（所有设备可访问）"
    echo -e "${GREEN}2.${PLAIN} 仅本机访问（127.0.0.1，仅本机可访问）"
    read -p "请输入选项 [1/2]，默认与当前一致: " access_choice
    access_choice="${access_choice:-1}"
    if [[ "$access_choice" == "2" ]]; then
        port_mapping="127.0.0.1:${new_port}:3001"
        new_ip="127.0.0.1"
    else
        port_mapping="${new_port}:3001"
        new_ip=$(get_public_ip)
    fi

    cat <<EOF > "$SUBSTORE_COMPOSE_PATH"
name: sub-store-app
services:
  sub-store:
    image: xream/sub-store
    container_name: sub-store
    restart: always
    environment:
      - SUB_STORE_BACKEND_UPLOAD_CRON=55 23 * * *
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$new_secret
    ports:
      - "$port_mapping"
    volumes:
      - $SUBSTORE_DATA_PATH:/opt/app/data
EOF

    echo "PORT=$new_port" > "$SUBSTORE_INFO_PATH"
    echo "SECRET=$new_secret" >> "$SUBSTORE_INFO_PATH"
    echo "IP=$new_ip" >> "$SUBSTORE_INFO_PATH"

    cd /root/substore
    echo -e "${CYAN}重启 Sub-Store 服务以应用新配置...${PLAIN}"
    docker compose -f "$SUBSTORE_COMPOSE_PATH" -p sub-store up -d

    echo -e "${GREEN}配置已更新！新面板地址: ${CYAN}http://$new_ip:$new_port${PLAIN}"
    echo -e "${GREEN}新后端路径: ${CYAN}http://$new_ip:$new_port/$new_secret${PLAIN}"
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=======================${PLAIN}"
        echo -e "${CYAN}      Sub-Store 脚本${PLAIN}"
        echo -e "${BLUE}=======================${PLAIN}"
        echo -e "${YELLOW}1.${PLAIN} 安装 Sub-Store"
        echo -e "${YELLOW}2.${PLAIN} 管理 Sub-Store"
        echo -e "${YELLOW}0.${PLAIN} 退出"
        read -p "请选择操作：" main_choice
        case $main_choice in
            1) install_substore ;;  # 修改：去掉多余的 read，install_substore 里已处理
            2) substore_manage_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项，请重新选择。${PLAIN}"; read -p "按回车键返回菜单..." ;;
        esac
        clear
    done
}

trap 'echo -e "${RED}错误发生在第 $LINENO 行${PLAIN}"; exit 1' ERR

check_root
main_menu
