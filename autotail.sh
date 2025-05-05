#!/bin/bash
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Usage Help ---
show_help() {
  echo -e "${GREEN}Usage: $0 [OPTIONS]${NC}"
  echo "  -i, --interface        Network interface (e.g., eth0)"
  echo "  -s, --subnet           Subnet to advertise to Tailscale (e.g., 192.168.2.0/24)"
  echo "  --strict-nat           Subnet to NAT (e.g., 192.168.2.0/24)"
  echo "  --strict-nat-target    Target subnet for NAT (e.g., 192.168.1.0/24)"
  echo "  -e, --exit-node        Enable exit node"
  echo "  -h, --help             Show this help"
  echo ""
  echo -e "${YELLOW}Examples:${NC}"
  echo "  # NAT only (no Tailscale advertisement)"
  echo "  $0 --strict-nat 192.168.2.0/24 --strict-nat-target 192.168.1.0/24"
  echo ""
  echo "  # Full deployment (Advertise + NAT + Exit Node)"
  echo "  $0 -s 192.168.2.0/24 --strict-nat 192.168.2.0/24 --strict-nat-target 192.168.1.0/24 -e -i eth0"
  exit 0
}

# --- Initialize Variables ---
AUTO_DETECT=true
MANUAL_INTERFACE=""
MANUAL_SUBNET=""
EXIT_NODE=false
STRICT_NAT_SUBNET=""
STRICT_NAT_TARGET=""

# --- Parse Arguments ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -i|--interface)
      MANUAL_INTERFACE="$2"
      AUTO_DETECT=false
      shift 2
      ;;
    -s|--subnet)
      MANUAL_SUBNET="$2"
      shift 2
      ;;
    --strict-nat)
      STRICT_NAT_SUBNET="$2"
      shift 2
      ;;
    --strict-nat-target)
      STRICT_NAT_TARGET="$2"
      shift 2
      ;;
    -e|--exit-node)
      EXIT_NODE=true
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo -e "${RED}[!] Unknown parameter: $1${NC}"
      show_help
      ;;
  esac
done

# --- Validate Strict NAT ---
if [ -n "$STRICT_NAT_SUBNET" ] || [ -n "$STRICT_NAT_TARGET" ]; then
  if [ -z "$STRICT_NAT_SUBNET" ] || [ -z "$STRICT_NAT_TARGET" ]; then
    echo -e "${RED}[!] Both --strict-nat and --strict-nat-target must be specified${NC}"
    exit 1
  fi
  echo -e "${GREEN}[+] Strict NAT enabled: ${YELLOW}$STRICT_NAT_SUBNET → $STRICT_NAT_TARGET${NC}"
fi

# --- Network Detection ---
if [ "$AUTO_DETECT" != false ]; then
  INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
  DETECTED_SUBNET=$(ip -o -4 addr show "$INTERFACE" | awk '{print $4}' | head -n1)
  echo -e "${GREEN}[+] Auto-detected: Interface=$INTERFACE, Subnet=$DETECTED_SUBNET${NC}"
else
  if [ -z "$MANUAL_INTERFACE" ]; then
    echo -e "${RED}[!] Manual mode requires --interface${NC}"
    exit 1
  fi
  INTERFACE="$MANUAL_INTERFACE"
  if ! ip link show "$INTERFACE" &>/dev/null; then
    echo -e "${RED}[!] Interface $INTERFACE does not exist${NC}"
    exit 1
  fi
  echo -e "${GREEN}[+] Manual interface: $INTERFACE${NC}"
fi

# --- Docker Setup ---
echo -e "${GREEN}[+] Checking Docker...${NC}"
if ! command -v docker &>/dev/null; then
  echo -e "${YELLOW}[!] Installing Docker...${NC}"
  curl -fsSL https://get.docker.com | sh || {
    echo -e "${RED}[!] Docker installation failed${NC}"
    exit 1
  }
  sudo usermod -aG docker "$USER"
  echo -e "${YELLOW}[!] Docker installed. Log out/in or run 'newgrp docker'${NC}"
  exit 0
fi

if ! groups | grep -q docker; then
  echo -e "${RED}[!] User not in 'docker' group. Run 'newgrp docker' and retry${NC}"
  exit 1
fi

# --- IP Forwarding ---
echo -e "${GREEN}[+] Enabling IP forwarding...${NC}"
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf >/dev/null
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.conf >/dev/null

# --- GRO Workaround ---
echo -e "${GREEN}[+] Configuring GRO for $INTERFACE...${NC}"
if sudo ethtool --offload "$INTERFACE" gro off 2>/dev/null; then
  echo -e "${GREEN}[+] GRO disabled${NC}"
else
  echo -e "${YELLOW}[!] Could not disable GRO (may not be supported)${NC}"
fi

# --- Tailscale Docker Setup ---
TAILSCALE_DIR="$HOME/tailscale"
mkdir -p "$TAILSCALE_DIR"
cd "$TAILSCALE_DIR" || exit 1

cat <<EOF > docker-compose.yml
version: '3'
services:
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    network_mode: "host"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - ./tsstate:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    restart: unless-stopped
EOF

echo -e "${GREEN}[+] Starting Tailscale container...${NC}"
docker compose up -d
sleep 5

# --- Strict NAT Rules ---
if [ -n "$STRICT_NAT_SUBNET" ]; then
  echo -e "${GREEN}[+] Configuring iptables for Strict NAT...${NC}"
  sudo iptables -t nat -A PREROUTING -d "$STRICT_NAT_TARGET" -j NETMAP --to "$STRICT_NAT_SUBNET"
  sudo iptables -t nat -A POSTROUTING -s "$STRICT_NAT_SUBNET" -j NETMAP --to "$STRICT_NAT_TARGET"
  
  # Make rules persistent
  if ! command -v netfilter-persistent &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y iptables-persistent
  fi
  sudo netfilter-persistent save
fi

# --- Tailscale Up Command ---
TS_UP_ARGS="--accept-routes"
if [ -n "$MANUAL_SUBNET" ]; then
  TS_UP_ARGS+=" --advertise-routes=$MANUAL_SUBNET"
  echo -e "${GREEN}[+] Advertising subnet: $MANUAL_SUBNET${NC}"
fi
if [ "$EXIT_NODE" = true ]; then
  TS_UP_ARGS+=" --advertise-exit-node"
  echo -e "${GREEN}[✓] Exit node enabled${NC}"
fi

echo -e "${GREEN}[+] Activating Tailscale...${NC}"
LOGIN_OUTPUT=$(docker exec tailscale tailscale up $TS_UP_ARGS 2>&1 | tee /tmp/tailscale-login.log)
LOGIN_URL=$(grep -oE 'https://login.tailscale.com/[^ ]+' /tmp/tailscale-login.log | head -n1)

if [[ -n "$LOGIN_URL" ]]; then
  echo -e "\n${GREEN}[🔗 LOGIN REQUIRED] Authenticate here:${NC}"
  echo -e "   ${YELLOW}$LOGIN_URL${NC}"
  echo -e "\n${GREEN}[!] Enabled features:${NC}"
  [ -n "$MANUAL_SUBNET" ] && echo -e "    - Advertised subnet: ${YELLOW}$MANUAL_SUBNET${NC}"
  [ -n "$STRICT_NAT_SUBNET" ] && echo -e "    - Strict NAT: ${YELLOW}$STRICT_NAT_SUBNET → $STRICT_NAT_TARGET${NC}"
  [ "$EXIT_NODE" = true ] && echo -e "    - ${YELLOW}Exit node${NC}"
else
  echo -e "${GREEN}[✓] Tailscale is already authenticated${NC}"
fi

echo -e "\n${GREEN}[✓] Setup complete!${NC}"
