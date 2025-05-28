#!/bin/bash
set -e

# --- Color codes for pretty logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
VERBOSE=false
DRY_RUN=false

# --- Initialize default values ---
AUTO_DETECT=true
MANUAL_INTERFACE=""
MANUAL_SUBNET=""
EXIT_NODE=false
STRICT_NAT_SUBNET=""
STRICT_NAT_TARGET=""
MANUAL_HOSTNAME=""

# --- Logging Function ---
log() {
  local level="$1"
  local message="$2"

  if [ "$VERBOSE" = true ] || [ "$level" = "WARN" ] || [ "$level" = "ERROR" ]; then
    case "$level" in
      "INFO") color="${GREEN}" ;;
      "DEBUG") color="${GREEN}" ;;
      "WARN") color="${YELLOW}" ;;
      "ERROR") color="${RED}" ;;
      *) color="${NC}" ;;
    esac
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
  fi
}

# --- Dry Run Helper ---
dryrun() {
  if [ "$DRY_RUN" = true ]; then
    log "DEBUG" "[DRY RUN] Would execute: $*"
  else
    log "DEBUG" "Executing: $*"
    "$@"
  fi
}

# --- Usage Help ---
show_help() {
  echo -e "${GREEN}Usage: $0 [OPTIONS]${NC}"
  echo "  -i, --interface        Network interface (e.g., eth0)"
  echo "  -s, --subnet           Subnet to advertise (e.g., 192.168.2.0/24)"
  echo "  --strict-nat           Subnet to NAT (e.g., 192.168.2.0/24)"
  echo "  --strict-nat-target    Target subnet (e.g., 192.168.1.0/24)"
  echo "  --hostname             Override hostname for Tailscale node"
  echo "  -e, --exit-node        Enable exit node"
  echo "  -v, --verbose          Show detailed output"
  echo "  --dry-run              Simulate changes without executing"
  echo "  -h, --help             Show help"
  exit 0
}

# --- Parse CLI arguments ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
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
    --hostname)
      MANUAL_HOSTNAME="$2"
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
      echo -e "${RED}[ERROR] Unknown parameter: $1${NC}"
      show_help
      ;;
  esac
done

# --- Begin Setup ---
log "INFO" "Starting Tailscale setup"

# --- Notify about dry-run mode ---
if [ "$DRY_RUN" = true ]; then
  log "WARN" "DRY RUN MODE - No changes will be made"
fi

# --- Validate Strict NAT Parameters ---
if [ -n "$STRICT_NAT_SUBNET" ] || [ -n "$STRICT_NAT_TARGET" ]; then
  if [ -z "$STRICT_NAT_SUBNET" ] || [ -z "$STRICT_NAT_TARGET" ]; then
    log "ERROR" "Both --strict-nat and --strict-nat-target must be specified"
    exit 1
  fi
  log "INFO" "Strict NAT configured: $STRICT_NAT_SUBNET → $STRICT_NAT_TARGET"
fi

# --- Detect or use provided interface ---
if [ "$AUTO_DETECT" != false ]; then
  INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
  DETECTED_SUBNET=$(ip -o -4 addr show "$INTERFACE" | awk '{print $4}' | head -n1)
  HOSTNAME=$(hostname | cut -d'.' -f1)
  log "INFO" "Auto-detected: Interface=$INTERFACE, Subnet=$DETECTED_SUBNET, Hostname=$HOSTNAME"
else
  if [ -z "$MANUAL_INTERFACE" ]; then
    log "ERROR" "Manual mode requires --interface"
    exit 1
  fi
  INTERFACE="$MANUAL_INTERFACE"
  HOSTNAME=$(hostname | cut -d'.' -f1)
  if ! ip link show "$INTERFACE" &>/dev/null; then
    log "ERROR" "Interface $INTERFACE does not exist"
    exit 1
  fi
  log "INFO" "Using manual interface: $INTERFACE"
fi

# --- Ensure Docker is installed ---
log "INFO" "Checking Docker installation..."
if ! command -v docker &>/dev/null; then
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Would install Docker"
  else
    log "INFO" "Installing Docker..."
    curl -fsSL https://get.docker.com | sh || {
      log "ERROR" "Docker installation failed"
      exit 1
    }
    sudo usermod -aG docker "$USER"
    sudo newgrp docker
    log "WARN" "You must log out and back in for Docker permissions"
    exit 0
  fi
fi

# --- Enable IP forwarding ---
log "INFO" "Configuring IP forwarding..."
dryrun sudo sysctl -w net.ipv4.ip_forward=1
dryrun sudo sysctl -w net.ipv6.conf.all.forwarding=1

# --- Prepare Tailscale Docker directory ---
TAILSCALE_DIR="$HOME/tailscale"
log "INFO" "Creating Tailscale directory at $TAILSCALE_DIR"
dryrun mkdir -p "$TAILSCALE_DIR"

# --- Generate docker-compose file ---
cat <<EOF | dryrun tee "$TAILSCALE_DIR/docker-compose.yml" >/dev/null
version: '3.8'

services:
  tailscale:
    image: tailscale/tailscale
    container_name: tailscale
    restart: unless-stopped
    network_mode: "host"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - ./data:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
      - /etc/machine-id:/etc/machine-id
    command: tailscaled
EOF

# --- Start Docker container ---
log "INFO" "Starting Tailscale container..."
dryrun docker compose -f "$TAILSCALE_DIR/docker-compose.yml" up -d

# --- Wait for container to be running ---
MAX_RETRIES=5
RETRY_DELAY=3
CONTAINER_RUNNING=false
for i in $(seq 1 $MAX_RETRIES); do
  if docker inspect -f '{{.State.Running}}' tailscale 2>/dev/null | grep -q "true"; then
    CONTAINER_RUNNING=true
    break
  fi
  log "WARN" "Container not ready (attempt $i/$MAX_RETRIES)..."
  sleep $RETRY_DELAY
done

if [ "$CONTAINER_RUNNING" != true ]; then
  log "ERROR" "Tailscale container failed to start"
  docker logs tailscale
  exit 1
fi

# --- Configure iptables forwarding rules ---
dryrun sudo iptables -A FORWARD -i "tailscale0" -o $INTERFACE -j ACCEPT
dryrun sudo iptables -A FORWARD -i $INTERFACE -o "tailscale0" -m state --state RELATED,ESTABLISHED -j ACCEPT

# --- Setup Strict NAT if specified ---
if [ -n "$STRICT_NAT_SUBNET" ]; then
  log "INFO" "Configuring iptables for Strict NAT..."
  dryrun sudo iptables -t nat -F
  dryrun sudo iptables -F
  dryrun sudo iptables -X

  dryrun sudo iptables -t nat -A PREROUTING -i "tailscale0" -d "$STRICT_NAT_TARGET" -j NETMAP --to "$STRICT_NAT_SUBNET"
  dryrun sudo iptables -t nat -A POSTROUTING -o "tailscale0" -s "$STRICT_NAT_SUBNET" -j NETMAP --to "$STRICT_NAT_TARGET"

  if [ "$DRY_RUN" = false ]; then
    if ! command -v netfilter-persistent &>/dev/null; then
      log "INFO" "Installing iptables-persistent..."
      sudo apt-get update && sudo apt-get install -y iptables-persistent
    fi
    dryrun sudo netfilter-persistent save
  fi
fi

# --- Construct Tailscale up command ---
TS_UP_ARGS=""
[ -n "$MANUAL_SUBNET" ] && TS_UP_ARGS+=" --advertise-routes=$MANUAL_SUBNET"
[ "$EXIT_NODE" = true ] && TS_UP_ARGS+=" --advertise-exit-node"
[ -n "$MANUAL_HOSTNAME" ] && TS_UP_ARGS+=" --hostname=$MANUAL_HOSTNAME"

# --- Run Tailscale up ---
log "INFO" "Activating Tailscale..."
if [ "$DRY_RUN" = true ]; then
  log "INFO" "Would execute: tailscale up $TS_UP_ARGS"
else
  docker exec tailscale tailscale up $TS_UP_ARGS 2>&1 | tee /tmp/tailscale-login.log
  LOGIN_URL=$(grep -oE 'https://login.tailscale.com/[^ ]+' /tmp/tailscale-login.log | head -n1)

  if [[ -n "$LOGIN_URL" ]]; then
    log "INFO" "\n[🔗 LOGIN REQUIRED] Authenticate here:"
    log "INFO" "   $LOGIN_URL"
  fi
fi

# --- Done ---
log "INFO" "Setup complete"
