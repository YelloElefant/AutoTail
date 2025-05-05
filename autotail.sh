#!/bin/bash
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
VERBOSE=false
DRY_RUN=false

# --- Logging Function ---
log() {
  local level="$1"
  local message="$2"
  
  # Always show errors/warnings, verbose shows info/debug
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
  echo "  -e, --exit-node        Enable exit node"
  echo "  -v, --verbose          Show detailed output"
  echo "  --dry-run              Simulate changes without executing"
  echo "  -h, --help             Show help"
  echo ""
  echo -e "${YELLOW}Examples:${NC}"
  echo "  # Dry run with verbose output"
  echo "  $0 -s 192.168.2.0/24 --strict-nat 192.168.2.0/24 -v --dry-run"
  echo ""
  echo "  # Real run with minimal output"
  echo "  $0 -s 192.168.2.0/24 --exit-node"
  exit 0
}

# --- Argument Parsing ---
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
    # [Previous argument cases here...]
    -h|--help)
      show_help
      ;;
    *)
      echo -e "${RED}[ERROR] Unknown parameter: $1${NC}"
      show_help
      ;;
  esac
done

log "INFO" "Starting Tailscale setup"

# --- Dry Run Header ---
if [ "$DRY_RUN" = true ]; then
  log "WARN" "DRY RUN MODE - No changes will be made"
fi

# --- System Checks ---
log "DEBUG" "Checking system dependencies..."
if ! command -v docker &>/dev/null; then
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Would install Docker"
  else
    log "INFO" "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
  fi
fi

# --- Strict NAT Simulation ---
if [ -n "$STRICT_NAT_SUBNET" ]; then
  log "INFO" "Configuring NAT: $STRICT_NAT_SUBNET → $STRICT_NAT_TARGET"
  dryrun sudo iptables -t nat -A PREROUTING -d "$STRICT_NAT_TARGET" -j NETMAP --to "$STRICT_NAT_SUBNET"
  dryrun sudo iptables -t nat -A POSTROUTING -s "$STRICT_NAT_SUBNET" -j NETMAP --to "$STRICT_NAT_TARGET"
fi

# --- Tailscale Up Command ---
TS_UP_ARGS="--accept-routes"
[ -n "$MANUAL_SUBNET" ] && TS_UP_ARGS+=" --advertise-routes=$MANUAL_SUBNET"
[ "$EXIT_NODE" = true ] && TS_UP_ARGS+=" --advertise-exit-node"

if [ "$DRY_RUN" = true ]; then
  log "INFO" "Would execute: tailscale up $TS_UP_ARGS"
else
  log "INFO" "Activating Tailscale..."
  docker exec tailscale tailscale up $TS_UP_ARGS
fi

log "INFO" "Setup complete"
