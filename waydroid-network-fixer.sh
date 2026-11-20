#!/usr/bin/env bash
# Waydroid Network Fixer for Omarchy / Arch Linux
# Copyright (c) 2026 sepahna
# License: MIT

set -Eeuo pipefail

APP_NAME="Waydroid Network Fixer"
BACKUP_ROOT="/var/backups/waydroid-network-fixer"
DEFAULT_BRIDGE="waydroid0"
DEFAULT_SUBNET="192.168.240.0/24"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'

info(){ printf "${CYAN}[*]${RESET} %s\n" "$*"; }
ok(){ printf "${GREEN}[✓]${RESET} %s\n" "$*"; }
warn(){ printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
err(){ printf "${RED}[x]${RESET} %s\n" "$*" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { err "Run this action with sudo."; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

detect_bridge(){
  if ip link show "$DEFAULT_BRIDGE" >/dev/null 2>&1; then
    BRIDGE="$DEFAULT_BRIDGE"
  else
    BRIDGE="$(ip -o link show | awk -F': ' '$2 ~ /^waydroid/ {sub(/@.*/, "", $2); print $2; exit}')"
  fi
  [[ -n "${BRIDGE:-}" ]] || { err "Waydroid bridge not found. Start Waydroid first."; return 1; }
}

detect_subnet(){
  SUBNET="$(ip -4 route show dev "$BRIDGE" scope link | awk 'NR==1 {print $1}')"
  [[ -n "${SUBNET:-}" ]] || SUBNET="$DEFAULT_SUBNET"
}

detect_uplink(){
  UPLINK="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "${UPLINK:-}" ]] || { err "Could not detect the host internet interface."; return 1; }
  [[ "$UPLINK" != "$BRIDGE" ]] || { err "Detected uplink equals Waydroid bridge; refusing."; return 1; }
}

check_tools(){
  local missing=()
  for c in ip sysctl iptables systemctl; do have "$c" || missing+=("$c"); done
  if (("${#missing[@]}" > 0)); then
    err "Missing commands: ${missing[*]}"
    echo "Install on Arch: sudo pacman -S iproute2 iptables"
    return 1
  fi
}

backup_state(){
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="$BACKUP_ROOT/$stamp"
  mkdir -p "$BACKUP_DIR"
  iptables-save > "$BACKUP_DIR/iptables.rules" 2>/dev/null || true
  if have nft; then nft list ruleset > "$BACKUP_DIR/nftables.rules" 2>/dev/null || true; fi
  ip -4 route show table all > "$BACKUP_DIR/routes.txt" 2>/dev/null || true
  ip -br address > "$BACKUP_DIR/addresses.txt" 2>/dev/null || true
  ip -details link show > "$BACKUP_DIR/links.txt" 2>/dev/null || true
  sysctl net.ipv4.ip_forward > "$BACKUP_DIR/ip_forward.txt" 2>/dev/null || true
  printf '%s\n' "$BRIDGE" > "$BACKUP_DIR/bridge.txt"
  printf '%s\n' "$SUBNET" > "$BACKUP_DIR/subnet.txt"
  printf '%s\n' "$UPLINK" > "$BACKUP_DIR/uplink.txt"
  chmod 700 "$BACKUP_DIR"
  ok "Backup saved to $BACKUP_DIR"
}

diagnose(){
  check_tools
  echo
  printf "${BLUE}=== %s: diagnostics ===${RESET}\n" "$APP_NAME"
  echo
  if systemctl is-active --quiet waydroid-container; then ok "Waydroid container service is active"; else warn "Waydroid container service is not active"; fi
  if ip link show "$DEFAULT_BRIDGE" >/dev/null 2>&1; then
    detect_bridge; detect_subnet; detect_uplink || true
    ok "Bridge: $BRIDGE"
    ok "Waydroid subnet: $SUBNET"
    [[ -n "${UPLINK:-}" ]] && ok "Detected uplink: $UPLINK"
    ip -br address show dev "$BRIDGE" || true
  else
    warn "Bridge $DEFAULT_BRIDGE not found. Start Waydroid and retry."
  fi
  echo
  echo "IPv4 forwarding:"
  sysctl net.ipv4.ip_forward
  echo
  echo "Default IPv4 route:"
  ip -4 route show default
  echo
  echo "NAT postrouting rules:"
  iptables -t nat -S POSTROUTING 2>/dev/null || true
  echo
  echo "Forward rules:"
  iptables -S FORWARD 2>/dev/null || true
  echo
  echo "Recent Waydroid logs:"
  journalctl -u waydroid-container -b --no-pager -n 25 2>/dev/null || true
}

repair(){
  need_root
  check_tools
  detect_bridge
  detect_subnet
  detect_uplink

  echo
  printf "${BLUE}=== Repair plan ===${RESET}\n"
  echo "Waydroid bridge : $BRIDGE"
  echo "Waydroid subnet : $SUBNET"
  echo "Internet uplink : $UPLINK"
  echo
  warn "This will enable IPv4 forwarding and add narrowly scoped iptables rules."
  warn "It will not flush firewall rules or change the FORWARD policy."
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || { info "Cancelled."; return 0; }

  backup_state
  info "Enabling IPv4 forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  install -d -m 755 /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-waydroid-network-fixer.conf
  ok "IPv4 forwarding enabled and persisted"

  info "Checking NAT masquerade rule..."
  if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
    ok "NAT rule added"
  else
    ok "NAT rule already exists"
  fi

  info "Checking forwarding rules..."
  if ! iptables -C FORWARD -i "$BRIDGE" -o "$UPLINK" -s "$SUBNET" -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -i "$BRIDGE" -o "$UPLINK" -s "$SUBNET" -j ACCEPT
    ok "Waydroid outbound forwarding rule added"
  else
    ok "Waydroid outbound forwarding rule already exists"
  fi

  if ! iptables -C FORWARD -i "$UPLINK" -o "$BRIDGE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -i "$UPLINK" -o "$BRIDGE" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ok "Established return-traffic rule added"
  else
    ok "Established return-traffic rule already exists"
  fi

  echo
  warn "Restarting waydroid-container may interrupt Android apps."
  if systemctl is-active --quiet waydroid-container; then
    systemctl restart waydroid-container
    ok "Waydroid container restarted"
  else
    warn "Waydroid container was not active; skipped restart"
  fi
  echo
  ok "Repair completed. Reconnect the VPN inside Android and test connectivity."
}

test_network(){
  echo
  printf "${BLUE}=== Connectivity tests ===${RESET}\n"
  if have curl; then
    for url in https://1.1.1.1 https://google.com; do
      if curl -kIL --connect-timeout 5 --max-time 8 "$url" >/dev/null 2>&1; then
        ok "Host can reach $url"
      else
        warn "Host could not reach $url (this tests host, not Android VPN)"
      fi
    done
  else
    warn "curl not installed; skipping HTTPS tests"
  fi
  echo
  echo "For a real Android/VPN test, connect VPN in Waydroid and open:"
  echo "  https://1.1.1.1"
  echo "  https://google.com"
  echo "  https://ipinfo.io"
  echo
  warn "Host-side tests do not prove that Android traffic is passing through its VPN tunnel."
}

show_logs(){
  echo "Recent Waydroid service logs:"
  journalctl -u waydroid-container -b --no-pager -n 100
}

menu(){
  while true; do
    clear 2>/dev/null || true
    printf "${CYAN}╔══════════════════════════════════════════╗${RESET}\n"
    printf "${CYAN}║       WAYDROID NETWORK FIXER             ║${RESET}\n"
    printf "${CYAN}║          Omarchy / Arch Linux            ║${RESET}\n"
    printf "${CYAN}╚══════════════════════════════════════════╝${RESET}\n\n"
    echo "  1) Repair Waydroid network (requires sudo)"
    echo "  2) Network diagnostics"
    echo "  3) Connectivity tests (host-side)"
    echo "  4) View Waydroid logs"
    echo "  5) Exit"
    echo
    read -r -p "Select an option [1-5]: " choice
    case "$choice" in
      1) repair; read -r -p "Press Enter to continue..." _ ;;
      2) diagnose; read -r -p "Press Enter to continue..." _ ;;
      3) test_network; read -r -p "Press Enter to continue..." _ ;;
      4) show_logs; read -r -p "Press Enter to continue..." _ ;;
      5) exit 0 ;;
      *) warn "Invalid choice"; sleep 1 ;;
    esac
  done
}

usage(){
  cat <<USAGE
$APP_NAME

Usage:
  $0                 Interactive menu
  $0 diagnose        Show host and Waydroid network diagnostics
  $0 repair          Repair common IPv4 NAT/forwarding setup (asks for confirmation)
  $0 test            Run limited host-side connectivity checks
  $0 logs            Show Waydroid container logs

Run repair with sudo:
  sudo $0 repair
USAGE
}

main(){
  case "${1:-menu}" in
    menu) menu ;;
    diagnose) diagnose ;;
    repair) repair ;;
    test) test_network ;;
    logs) show_logs ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
