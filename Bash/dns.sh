#!/usr/bin/env bash
set -euo pipefail

#====== 颜色定义 ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

#====== 路径定义 ======
RESOLV_CONF="/etc/resolv.conf"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="$RESOLVED_DROPIN_DIR/99-custom-dns.conf"

[[ $EUID -ne 0 ]] && {
  echo -e "${RED}请使用 root 执行${NC}"
  exit 1
}

#====== 显示当前DNS ======
get_default_iface() {
  local iface

  iface="$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)"

  if [[ -z "$iface" ]]; then
    iface="$(ip -6 route show default 2>/dev/null | awk '{print $5}' | head -n1)"
  fi

  echo "$iface"
}

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

  if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    IFACE="$(get_default_iface)"

    if [[ -n "$IFACE" ]]; then
      echo -e "  ${CYAN}默认网卡:${NC} ${GRAY}${IFACE}${NC}"

      DNS_LIST="$(resolvectl status "$IFACE" 2>/dev/null \
        | awk '/DNS Servers:/ {for (i=3; i<=NF; i++) print $i}')"

      if [[ -n "$DNS_LIST" ]]; then
        echo -e "  ${CYAN}DNS Servers:${NC}"
        while read -r dns; do
          echo -e "    ${GRAY}- ${dns}${NC}"
        done <<< "$DNS_LIST"
      else
        echo -e "  ${GRAY}(systemd-resolved 未接管 DNS)${NC}"
      fi
    else
      echo -e "  ${GRAY}(未检测到默认网卡)${NC}"
    fi
  else
    echo -e "  ${GRAY}(systemd-resolved 未运行)${NC}"
  fi

  echo
}

#====== DNS输入校验 ======
is_valid_ipv4() {
  local ip="$1" IFS=.
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] 2>/dev/null || return 1
  done
  return 0
}

is_valid_ipv6_like() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9A-Fa-f:%.]+$ ]] || return 1
  [[ "$ip" == *:* ]] || return 1
  [[ ${#ip} -le 80 ]] || return 1
  return 0
}

is_valid_dns_ip() {
  local ip="$1"
  [[ "$ip" =~ [[:space:]] ]] && return 1
  [[ "$ip" == *\"* ]] && return 1
  [[ "$ip" == *\'* ]] && return 1
  [[ "$ip" == *\\* ]] && return 1
  is_valid_ipv4 "$ip" && return 0
  is_valid_ipv6_like "$ip" && return 0
  return 1
}

#====== 应用DNS配置 ======
unlock_resolv_conf() {
  if command -v chattr >/dev/null 2>&1 && [[ -f "$RESOLV_CONF" ]]; then
    chattr -i "$RESOLV_CONF" 2>/dev/null || true
  fi
}

apply_dns() {
  local dns_list=("$@")

  local ok=() bad=()
  for dns in "${dns_list[@]}"; do
    if is_valid_dns_ip "$dns"; then
      ok+=("$dns")
    else
      bad+=("$dns")
    fi
  done
  dns_list=("${ok[@]}")

  if [[ ${#dns_list[@]} -eq 0 ]]; then
    echo -e "${RED}未检测到有效的 DNS IP（请输入 IPv4/IPv6 地址）${NC}"
    return 1
  fi
  if [[ ${#bad[@]} -gt 0 ]]; then
    echo -e "${YELLOW}已忽略无效 DNS：${bad[*]}${NC}"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
    mkdir -p "$RESOLVED_DROPIN_DIR"
    {
      echo "[Resolve]"
      echo "DNS=${dns_list[*]}"
      echo "Domains=~."
    } > "$RESOLVED_DROPIN_FILE"

    systemctl restart systemd-resolved 2>/dev/null || true

    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl flush-caches 2>/dev/null || true
    fi

    if command -v resolvectl >/dev/null 2>&1; then
      local iface
      iface="$(get_default_iface)"
      if [[ -n "$iface" ]]; then
        resolvectl dns "$iface" "${dns_list[@]}" 2>/dev/null || true
        resolvectl domain "$iface" "~." 2>/dev/null || true
        resolvectl flush-caches 2>/dev/null || true
      fi
    fi

    if [[ ! -L "$RESOLV_CONF" ]]; then
      unlock_resolv_conf
      {
        for dns in "${dns_list[@]}"; do
          echo "nameserver $dns"
        done
      } > "$RESOLV_CONF" 2>/dev/null || true
    fi
  else
    if [[ -L "$RESOLV_CONF" ]]; then
      rm -f "$RESOLV_CONF" 2>/dev/null || true
    fi

    unlock_resolv_conf
    {
      for dns in "${dns_list[@]}"; do
        echo "nameserver $dns"
      done
    } > "$RESOLV_CONF" 2>/dev/null || true
  fi

  for svc in nscd dnsmasq named; do
    systemctl is-active "$svc" >/dev/null 2>&1 && systemctl restart "$svc" >/dev/null 2>&1 || true
  done

  return 0
}

#====== 主菜单 ======
while true; do
  clear
  echo -e "${GREEN}======== DNS 配置工具 ========${NC}\n"
  show_current_dns
  echo -e "${YELLOW}请选择操作:${NC}"
  echo -e " ${CYAN}1.${NC}修改DNS为 ${GREEN}8.8.8.8${NC} 和 ${GREEN}1.1.1.1${NC}"
  echo -e " ${CYAN}2.${NC}自定义修改DNS"
  echo -e " ${CYAN}0.${NC}退出脚本"
  echo -e "${GREEN}==============================${NC}"
  read -rp "$(echo -e "${MAGENTA}请输入选项 [0-2]: ${NC}")" choice

  case "$choice" in
    1)
      if apply_dns "8.8.8.8" "1.1.1.1"; then
        read -rp "$(echo -e "${BLUE}DNS已修改并立即生效,按回车继续...${NC}")"
      else
        read -rp "$(echo -e "${RED}DNS修改失败,按回车返回菜单...${NC}")"
      fi
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
        if apply_dns "${CUSTOM_DNS[@]}"; then
          read -rp "$(echo -e "${BLUE}DNS已修改并立即生效,按回车继续...${NC}")"
        else
          read -rp "$(echo -e "${RED}DNS修改失败,按回车返回菜单...${NC}")"
        fi
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
