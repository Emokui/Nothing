#!/bin/sh

# 依赖检测与自动安装
DEPS="curl jq awk printf cat base64 wg"
ONEOF="xxd hexdump od"
NEED_INSTALL=""
HEX_INSTALLED=0

for cmd in $DEPS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        NEED_INSTALL="$NEED_INSTALL $cmd"
    fi
done

for cmd in $ONEOF; do
    if command -v "$cmd" >/dev/null 2>&1; then
        HEX_INSTALLED=1
        break
    fi
done
if [ "$HEX_INSTALLED" -eq 0 ]; then
    NEED_INSTALL="$NEED_INSTALL xxd"
fi

if [ -n "$NEED_INSTALL" ]; then
    echo "缺少依赖: $NEED_INSTALL"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=""
    fi
    case "$OS" in
        ubuntu|debian)
            PKGMGR="apt-get"
            UPDATE_CMD="apt-get update"
            INSTALL_CMD="apt-get install -y"
            ;;
        centos|rhel|almalinux|rocky)
            PKGMGR="yum"
            UPDATE_CMD="yum makecache"
            INSTALL_CMD="yum install -y"
            ;;
        arch)
            PKGMGR="pacman"
            UPDATE_CMD="pacman -Sy"
            INSTALL_CMD="pacman -S --noconfirm"
            ;;
        *)
            echo "未知系统，请手动安装: $NEED_INSTALL"
            exit 1
            ;;
    esac
    # wg工具包名兼容
    case "$OS" in
        ubuntu|debian|centos|rhel|almalinux|rocky|arch)
            NEED_INSTALL=$(echo "$NEED_INSTALL" | sed 's/\bwg\b/wireguard-tools/g')
            ;;
    esac
    echo "使用 $PKGMGR 自动安装: $NEED_INSTALL"
    sudo $UPDATE_CMD
    sudo $INSTALL_CMD $NEED_INSTALL
    if [ $? -ne 0 ]; then
        echo "依赖自动安装失败，请手动安装: $NEED_INSTALL"
        exit 1
    fi
fi

BASE_URL='https://api.cloudflareclient.com/v0a2483'
REFRESH_TOKEN_FILE="refresh_token.txt"

echo "请选择模式："
echo "0. 退出脚本"
echo "1. 免费账号（新注册）"
echo "2. 团队账号（需输入token）"
echo "3. 刷IP（自动读取现有参数刷新）"
read -p "输入选项（0/1/2/3）: " mode

case "$mode" in
0)
    echo "已退出脚本。"
    exit 0
    ;;
1)
    echo "正在注册免费账号..."
    wg_private_key="$(wg genkey)"
    wg_public_key="$(printf %s "${wg_private_key}" | wg pubkey)"
    reg="$(curl -s --header 'Content-Type: application/json' --header 'User-Agent: 1.1.1.1/6.81' \
        --data '{"key":"'"${wg_public_key}"'","install_id":"","fcm_token":"","model":"warp-menu","serial_number":"","name":"","locale":"en_US"}' \
        "${BASE_URL}/reg")"
    ;;
2)
    read -p "请输入Teams Token: " teams_token
    [ -z "$teams_token" ] && { echo "Token 不能为空"; exit 1; }
    echo "正在注册团队账号..."
    wg_private_key="$(wg genkey)"
    wg_public_key="$(printf %s "${wg_private_key}" | wg pubkey)"
    reg="$(curl -s --header 'Content-Type: application/json' --header 'User-Agent: 1.1.1.1/6.81' \
        --header "CF-Access-Jwt-Assertion: $teams_token" \
        --data '{"key":"'"${wg_public_key}"'","install_id":"","fcm_token":"","model":"warp-menu","serial_number":"","name":"","locale":"en_US"}' \
        "${BASE_URL}/reg")"
    ;;
3)
    if [ ! -f "$REFRESH_TOKEN_FILE" ]; then
        echo "未找到 $REFRESH_TOKEN_FILE，请先注册获取。"
        exit 1
    fi
    refresh_token="$(cat $REFRESH_TOKEN_FILE)"
    token=$(printf %s "$refresh_token" | awk -F, '{print $1}')
    device_id=$(printf %s "$refresh_token" | awk -F, '{print $2}')
    wg_private_key=$(printf %s "$refresh_token" | awk -F, '{print $3}')
    reg="$(curl -s --header 'Content-Type: application/json' --header 'User-Agent: 1.1.1.1/6.81' \
        -H "Authorization: Bearer ${token}" \
        "${BASE_URL}/reg/${device_id}")"
    ;;
*)
    echo "无效选项。"
    exit 1
    ;;
esac

if [ -z "$reg" ] || [ "$reg" = "null" ]; then
    echo "注册失败，请检查网络或参数。"
    exit 1
fi

wg_config=$(printf %s "${reg}" | jq -r '.config|.peers[0].public_key+"\n"+.peers[0].endpoint.host+"\n"+.peers[0].endpoint.v4+"\n"+.peers[0].endpoint.v6+"\n"+.interface.addresses.v4+"\n"+.interface.addresses.v6+"\n"+.client_id')
peer_public_key=$(printf %s "${wg_config}" | awk 'NR==1')
endpoint_host=$(printf %s "${wg_config}" | awk 'NR==2')
endpoint_ipv4=$(printf %s "${wg_config}" | awk 'NR==3')
endpoint_ipv6=$(printf %s "${wg_config}" | awk 'NR==4')
address_ipv4=$(printf %s "${wg_config}" | awk 'NR==5')
address_ipv6=$(printf %s "${wg_config}" | awk 'NR==6')

# 输出 WireGuard 配置到终端
cat <<-EOF
[Interface]
PrivateKey = ${wg_private_key}
Address = ${address_ipv4}, ${address_ipv6}
DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
MTU = 1280

[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
Endpoint = ${endpoint_ipv4}:2408
EOF

token=$(printf %s "$reg" | jq -r '.token')
device_id=$(printf %s "$reg" | jq -r '.id')
echo "${token},${device_id},${wg_private_key}" > $REFRESH_TOKEN_FILE
echo "刷新参数已保存到 $REFRESH_TOKEN_FILE"
