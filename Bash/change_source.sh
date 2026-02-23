#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
    echo "错误: 请以 root 用户运行此脚本"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME=$VERSION_CODENAME
else
    echo "错误: 无法识别系统版本，未找到 /etc/os-release"
    exit 1
fi

if [ "$ID" != "debian" ]; then
    echo "错误: 此脚本仅适用于 Debian 系统，当前系统为 $ID"
    exit 1
fi

echo "=== 检测到系统版本: Debian $VERSION_ID ($CODENAME) ==="

if [ "$CODENAME" = "bullseye" ]; then
    COMPONENTS="main contrib non-free"
elif [ "$CODENAME" = "bookworm" ] || [ "$CODENAME" = "trixie" ]; then
    COMPONENTS="main contrib non-free non-free-firmware"
else
    echo "错误: 不支持的系统代号 ($CODENAME)。本脚本支持 bullseye(11), bookworm(12), trixie(13)"
    exit 1
fi

if [ -f /etc/apt/sources.list.d/debian.sources ] || [ "$CODENAME" = "trixie" ]; then
    FORMAT="deb822"
    SOURCE_FILE="/etc/apt/sources.list.d/debian.sources"
    rm -f /etc/apt/sources.list
else
    FORMAT="legacy"
    SOURCE_FILE="/etc/apt/sources.list"
    rm -f /etc/apt/sources.list.d/debian.sources
fi

echo "-> 准备使用 $FORMAT 格式写入源配置..."

if [ "$FORMAT" = "deb822" ]; then
    cat > "$SOURCE_FILE" <<EOF
Types: deb
URIs: http://mirrors.mit.edu/debian
Suites: $CODENAME ${CODENAME}-updates ${CODENAME}-backports
Components: $COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://mirrors.ocf.berkeley.edu/debian-security
Suites: ${CODENAME}-security
Components: $COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
else
    cat > "$SOURCE_FILE" <<EOF
deb http://mirrors.mit.edu/debian $CODENAME $COMPONENTS
deb http://mirrors.mit.edu/debian ${CODENAME}-updates $COMPONENTS
deb http://mirrors.mit.edu/debian ${CODENAME}-backports $COMPONENTS
deb http://mirrors.ocf.berkeley.edu/debian-security ${CODENAME}-security $COMPONENTS
EOF
fi

echo "-> 清理原有 APT 缓存..."
rm -rf /var/lib/apt/lists/*
apt clean

echo "-> 正在重新拉取镜像源索引..."
apt update

if [ $? -eq 0 ]; then
    echo "=== 完美！Debian $VERSION_ID ($CODENAME) 所有源均已通过美国教育网连接成功 ==="
else
    echo "=== 错误：源访问失败，请检查网络 ==="
fi
