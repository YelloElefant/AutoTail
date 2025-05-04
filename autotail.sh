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
  echo "  -s, --subnet      Subnet to advertise (e.g., 192.168.1.0/24)"
  echo "  -i, --interface   Network interface (e.g., eth0)"
  echo "  -e, --exit-node   Enable exit node functionality"
  echo "  --strict-nat      Enable strict NAT handling (placeholder)"
  echo "  -h, --help        Show this help"
  echo ""
  echo -e "${YELLOW}Examples:${NC}"
  echo "  $0                          # Auto-detect everything"
  echo "  $0 -s 192.168.2.0/24 -e    # Advertise subnet + exit node"
  echo "  $0 -e -i eth1              # Exit node via specific interface"
  exit 0
}

# --- Initialize Variables ---
AUTO_DETECT=true
MANUAL_SUBNET=""
MANUAL_INTERFACE=""
EXIT_NODE=false
STRICT_NAT=false

# --- Parse Arguments ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -s|--subnet)
      MANUAL_SUBNET="$2"
      AUTO_DETECT=false
      shift 2
      ;;
    -i|--interface)
      MANUAL_INTERFACE="$2"
      AUTO_DETECT=false
      shift 2
      ;;
    -e|--exit-node)
      EXIT_NODE=true
      shift
      ;;
    --strict-nat)
      STRICT_NAT=true
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

# --- Network Detection ---
if [ "$AUTO_DETECT" != false ]; then
  INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
  ROUTE_SUBNET=$(ip -o -4 addr show "$INTERFACE" | awk '{print $4}' | head -n1)
  echo -e "${GREEN}[+] Auto-detected: Interface=$INTERFACE, Subnet=$ROUTE_SUBNET${NC}"
else
  # Validate manual inputs
  if [ -n "$MANUAL_SUBNET" ]; then
    if ! ip route | grep -q "$MANUAL_SUBNET"; then
      echo -e "${RED}[!] Subnet $MANUAL_SUBNET not found in routing table${NC}"
      exit 1
    fi
    ROUTE_SUBNET="$MANUAL_SUBNET"
  fi

  if [ -n "$MANUAL_INTERFACE" ]; then
    if ! ip link show "$MANUAL_INTERFACE" &>/dev/null; then
      echo -e "${RED}[!] Interface $MANUAL_INTERFACE does not exist${NC}"
      exit 1
    fi
    INTERFACE="$MANUAL_INTERFACE"
  else
    # Auto-find interface for manual subnet
    INTERFACE=$(ip route | grep "$MANUAL_SUBNET" | awk '{print $3}' | head -n1)
    if [ -z "$INTERFACE" ]; then
      echo -e "${RED}[!] Could not determine interface for subnet $MANUAL_SUBNET${NC}"
      exit 1
    fi
  fi
  echo -e "${GREEN}[+] Manual config: Interface=$INTERFACE, Subnet=$ROUTE_SUBNET${NC}"
fi

# --- Docker Check ---
echo -e "${GREEN}[+] Checking Docker installation...${NC}"
if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}[!] Docker not found. Installing...${NC}"
    curl -fsSL https://get.docker.com | sh || {
        echo -e "${RED}[!] Docker installation failed${NC}"
        exit 1
    }
    sudo usermod -aG docker "$USER"
    echo -e "${YELLOW}[!] Docker installed. You must LOG OUT and back in.${NC}"
    exit 0
fi

if ! groups | grep -q docker; then
    echo -e "${RED}[!] User not in 'docker' group.${NC}"
    echo -e "${YELLOW}    Run: newgrp docker and re-execute this script${NC}"
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
echo -e "${GREEN}[+] Creating Tailscale directory at $TAILSCALE_DIR${NC}"
mkdir -p "$TAILSCALE_DIR"
cd "$TAILSCALE_DIR" || exit 1

echo -e "${GREEN}[+] Generating docker-compose.yml${NC}"
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

# --- Start Container ---
echo -e "${GREEN}[+] Starting Tailscale container...${NC}"
docker compose up -d
sleep 5  # Wait for initialization

# --- iptables Rules ---
echo -e "${GREEN}[+] Configuring iptables for $INTERFACE...${NC}"
sudo iptables -A FORWARD -i tailscale0 -o "$INTERFACE" -j ACCEPT
sudo iptables -A FORWARD -i "$INTERFACE" -o tailscale0 -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE

# Make rules persistent
if ! command -v netfilter-persistent &>/dev/null; then
    echo -e "${GREEN}[+] Installing iptables-persistent...${NC}"
    sudo apt-get update && sudo apt-get install -y iptables-persistent
fi
sudo netfilter-persistent save

# --- Tailscale Login ---
TS_UP_ARGS="--advertise-routes=$ROUTE_SUBNET --accept-routes"
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
    echo -e "\n${GREEN}[!] After login, your Pi will provide:${NC}"
    [ -n "$ROUTE_SUBNET" ] && echo -e "    - Subnet route: ${YELLOW}$ROUTE_SUBNET${NC}"
    [ "$EXIT_NODE" = true ] && echo -e "    - ${YELLOW}Exit node${NC} (all internet traffic)"
else
    echo -e "${GREEN}[✓] Tailscale is already authenticated${NC}"
fi

echo -e "\n${GREEN}[✓] Setup complete!${NC}"
