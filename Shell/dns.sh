#!/usr/bin/env bash
set -euo pipefail

# =========================
# 颜色定义
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# =========================
# 路径定义
# =========================
INSTALL_DIR="/usr/local/bin"
FIX_SCRIPT="$INSTALL_DIR/fix-dns.sh"
SERVICE_FILE="/etc/systemd/system/fix-dns.service"
RESOLV_CONF="/etc/resolv.conf"

[[ $EUID -ne 0 ]] && {
  echo -e "${RED}请使用 root 执行${NC}"
  exit 1
}

# =========================
# 显示当前DNS
# =========================
show_current_dns() {
  echo -e "${YELLOW}当前DNS配置:${NC}\n"

  echo -e "${BLUE}resolv.conf:${NC}"
  if [[ -f "$RESOLV_CONF" ]]; then
    while read -r line; do
      [[ "$line" =~ ^nameserver ]] || continue
      echo -e "  ${GRAY}${line}${NC}"
    done < "$RESOLV_CONF"
  else
    echo -e "  ${GRAY}(不存在)${NC}"
  fi
  echo

  echo -e "${BLUE}systemd-resolved:${NC}"
  if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | while read -r line; do
      echo -e "  ${GRAY}${line}${NC}"
    done
  else
    echo -e "  ${GRAY}(systemd-resolved未运行)${NC}"
  fi
  echo
}

# =========================
# DNS修复脚本
# =========================
write_fix_script() {
  local dns_list=("$@")

  mkdir -p "$INSTALL_DIR"

  cat > "$FIX_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

RESOLV_CONF="$RESOLV_CONF"
DNS_SERVERS=(
$(printf '  "%s"\n' "${dns_list[@]}")
)

[[ \$EUID -ne 0 ]] && exit 0

IMMUTABLE=false
if command -v chattr >/dev/null 2>&1; then
  if lsattr "\$RESOLV_CONF" 2>/dev/null | grep -q 'i'; then
    IMMUTABLE=true
    chattr -i "\$RESOLV_CONF" 2>/dev/null || true
  fi
fi

{
  for dns in "\${DNS_SERVERS[@]}"; do
    echo "nameserver \$dns"
  done
} > "\$RESOLV_CONF" 2>/dev/null || true

if \$IMMUTABLE; then
  chattr +i "\$RESOLV_CONF" 2>/dev/null || true
fi

if command -v resolvectl >/dev/null 2>&1; then
  IFACE=\$(ip route show default 2>/dev/null | awk '{print \$5}' | head -n1)
  if [[ -n "\$IFACE" ]]; then
    resolvectl dns "\$IFACE" "\${DNS_SERVERS[@]}" 2>/dev/null || true
    resolvectl domain "\$IFACE" "~." 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
fi

for svc in nscd dnsmasq named; do
  systemctl is-active "\$svc" >/dev/null 2>&1 && systemctl restart "\$svc" >/dev/null 2>&1 || true
done
EOF

  chmod +x "$FIX_SCRIPT"

  if command -v systemctl >/dev/null 2>&1; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=DHCP-aware DNS auto repair
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FIX_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable fix-dns.service >/dev/null 2>&1 || true
  fi

  "$FIX_SCRIPT"
}

# =========================
# 主菜单
# =========================
while true; do
  clear
  echo -e "${GREEN}======== DNS 配置工具 ========${NC}\n"
  show_current_dns
  echo -e "${YELLOW}请选择操作:${NC}"
  echo -e " ${CYAN}1.${NC}修改DNS为${GREEN}8.8.8.8${NC}和${GREEN}1.1.1.1${NC}"
  echo -e " ${CYAN}2.${NC}自定义修改DNS"
  echo -e " ${CYAN}0.${NC}退出脚本"
  echo -e "${GREEN}==============================${NC}"
  read -rp "$(echo -e "${MAGENTA}请输入选项 [0-2]: ${NC}")" choice

  case "$choice" in
    1)
      write_fix_script "8.8.8.8" "1.1.1.1"
      read -rp "$(echo -e "${BLUE}DNS已修改并立即生效,按回车继续...${NC}")"
      ;;
    2)
      clear
      echo -e "\n${MAGENTA}请输入DNS(每行一个,回车结束):${NC}"
      CUSTOM_DNS=()
      while true; do
        read -rp "> " dns
        [[ -z "$dns" ]] && break
        CUSTOM_DNS+=("$dns")
      done

      if [[ ${#CUSTOM_DNS[@]} -eq 0 ]]; then
        read -rp "$(echo -e "${BLUE}未输入DNS,按回车返回菜单...${NC}")"
      else
        write_fix_script "${CUSTOM_DNS[@]}"
        read -rp "$(echo -e "${BLUE}DNS已修改并立即生效,按回车继续...${NC}")"
      fi
      ;;
    0)
      clear
      exit 0
      ;;
    *)
      read -rp "$(echo -e "${RED}无效选项,按回车重试...${NC}")"
      ;;
  esac
done
