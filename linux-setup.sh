#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# MasterBuilder - Linux / WSL Installer
# ==============================================================================
# Requirements: Bash + Docker + Docker Compose v2
#
# QUICK SETUP:
#   Reads quick-stack.txt, validates every registered Compose file, prints the
#   exact services/images that Docker will use, pulls them, and starts the stack.
#
# ADDING A CONTAINER LATER:
#   1. Add its YAML file under compose/<module>/
#   2. Add that YAML path to quick-stack.txt
#   3. If it needs a new persistent directory or variable, add it below.
#
# FUTURE:
#   run_quick_configuration() is reserved for automatic Sonarr/Radarr/
#   qBittorrent/Prowlarr/Seerr/Jellyfin API configuration.
# ==============================================================================

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
QUICK_MANIFEST="$PROJECT_ROOT/quick-stack.txt"

# ------------------------------------------------------------------------------
# Persistent directory structure
# ------------------------------------------------------------------------------
CONFIG_DIRS=(
  "npm/data"
  "npm/letsencrypt"
  "jellyfin"
  "sonarr"
  "radarr"
  "bazarr"
  "prowlarr"
  "trawl/proxy-ca"
  "qbittorrent"
  "seerr"
)

DATA_DIRS=(
  "torrents/movies"
  "torrents/tv"
  "usenet/incomplete"
  "usenet/complete/movies"
  "usenet/complete/tv"
  "media/movies"
  "media/tv"
  "media/anime"
)

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
heading() {
  printf '\n========================================================================\n'
  printf '%s\n' "$1"
  printf '========================================================================\n'
}

info()  { printf '[+] %s\n' "$1"; }
warn()  { printf '[!] %s\n' "$1"; }
fatal() { printf '[X] %s\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Docker checks
# ------------------------------------------------------------------------------
check_docker() {
  heading "CHECKING DOCKER"

  command -v docker >/dev/null 2>&1 || fatal "Docker was not found in PATH."
  docker info >/dev/null 2>&1 || fatal "Docker is installed, but the Docker daemon is not available."
  docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 ('docker compose') is not available."

  info "Docker is available."
  info "Docker Compose is available."
}

# ------------------------------------------------------------------------------
# Bootstrap dependencies
# ------------------------------------------------------------------------------

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    info "jq is available."
    return
  fi

  heading "INSTALLING JQ"

  if ! command -v apt-get >/dev/null 2>&1; then
    fatal "jq is required for Prowlarr Quick Configuration.

Automatic jq installation currently supports Debian/Ubuntu/Linux Mint systems.
Install jq manually, then run the installer again."
  fi

  local sudo_cmd=()

  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 ||
      fatal "jq must be installed, but sudo is not available."

    sudo_cmd=(sudo)
  fi

  info "jq was not found. Installing it..."

  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" apt-get install -y jq

  command -v jq >/dev/null 2>&1 ||
    fatal "jq installation completed but jq still cannot be found."

  info "jq installed successfully."
}

# ------------------------------------------------------------------------------
# .env initialization
# ------------------------------------------------------------------------------
env_get() {
  local key="$1"
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s' "$line"
}

initialize_env() {
  heading "INITIALIZING VARIABLES"

  if [[ -f "$ENV_FILE" ]]; then
    info "Existing .env found. Reusing it."
    return
  fi

  local puid pgid default_config default_data config_root data_root
  puid="$(id -u)"
  pgid="$(id -g)"
  default_config="$PROJECT_ROOT/runtime/config"
  default_data="$PROJECT_ROOT/runtime/data"

  printf 'Config root [%s]: ' "$default_config"
  read -r config_root
  config_root="${config_root:-$default_config}"

  printf 'Data root   [%s]: ' "$default_data"
  read -r data_root
  data_root="${data_root:-$default_data}"

  cat > "$ENV_FILE" <<ENVEOF
# MasterBuilder environment

PUID=$puid
PGID=$pgid
TZ=Asia/Jerusalem

CONFIG_ROOT="$config_root"
DATA_ROOT="$data_root"

# Reverse Proxy / DuckDNS
DUCKDNS_SUBDOMAINS=
DUCKDNS_TOKEN=

# qBittorrent
QBITTORRENT_WEBUI_PORT=8080
QBITTORRENT_TORRENTING_PORT=6881

# TRAWL
TRAWL_BROWSER_POOL_SIZE=1
TRAWL_PROXY_URL=
TRAWL_RESIDENTIAL_PROXY_URL=
TRAWL_MITM_ENABLED=false
TRAWL_MITM_MAX_TIER=3
TRAWL_MITM_DEBUG=false

# Prowlarr private indexers
# Optional. Leave blank to skip the corresponding indexer.
ANIMETOSHO_API_KEY=
FUZER_COOKIE=
HEBITS_COOKIE=

# -----------------------------------------------------------------------------
# Future Quick Configuration switches
# These do nothing yet. They reserve the structure for the bootstrap stage.
# -----------------------------------------------------------------------------
QUICK_CONFIG_QBITTORRENT=false
QUICK_CONFIG_SONARR=false
QUICK_CONFIG_RADARR=false
QUICK_CONFIG_PROWLARR=true
QUICK_CONFIG_SEERR=false
QUICK_CONFIG_JELLYFIN=false
QUICK_CONFIG_TRAWL=false
ENVEOF

  info "Created $ENV_FILE"
}

# ------------------------------------------------------------------------------
# Storage initialization
# ------------------------------------------------------------------------------
initialize_directories() {
  heading "INITIALIZING DIRECTORIES"

  [[ -f "$ENV_FILE" ]] || fatal ".env does not exist."

  local config_root data_root dir
  config_root="$(env_get CONFIG_ROOT)"
  data_root="$(env_get DATA_ROOT)"

  [[ -n "$config_root" ]] || fatal "CONFIG_ROOT is missing from .env."
  [[ -n "$data_root" ]] || fatal "DATA_ROOT is missing from .env."

  mkdir -p "$config_root" "$data_root"

  for dir in "${CONFIG_DIRS[@]}"; do
    mkdir -p "$config_root/$dir"
  done

  for dir in "${DATA_DIRS[@]}"; do
    mkdir -p "$data_root/$dir"
  done

  info "Config root: $config_root"
  info "Data root:   $data_root"
}

# ------------------------------------------------------------------------------
# Quick Setup manifest
# ------------------------------------------------------------------------------
load_quick_files() {
  [[ -f "$QUICK_MANIFEST" ]] || fatal "Missing quick-stack.txt."

  QUICK_FILES=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    QUICK_FILES+=("$PROJECT_ROOT/$line")
  done < "$QUICK_MANIFEST"

  ((${#QUICK_FILES[@]} > 0)) || fatal "quick-stack.txt does not contain any Compose files."

  local file
  for file in "${QUICK_FILES[@]}"; do
    [[ -f "$file" ]] || fatal "Missing Compose file: ${file#$PROJECT_ROOT/}"
  done
}

compose_quick() {
  local command=(docker compose --project-directory "$PROJECT_ROOT" --env-file "$ENV_FILE")
  local file

  for file in "${QUICK_FILES[@]}"; do
    command+=( -f "$file" )
  done

  command+=( "$@" )
  "${command[@]}"
}

# ------------------------------------------------------------------------------
# Exact Quick Setup summary
# ------------------------------------------------------------------------------
show_quick_plan() {
  heading "QUICK SETUP - EVERYTHING BELOW WILL BE INSTALLED"

  printf 'Modules:\n'
  printf '  - Reverse Proxy       (NPM, DuckDNS)\n'
  printf '  - Media Management    (Jellyfin, Sonarr, Radarr, Bazarr, Prowlarr)\n'
  printf '  - Bypass              (TRAWL, TRAWL Redis)\n'
  printf '  - Downloads           (qBittorrent)\n'
  printf '  - Request System      (Seerr)\n'

  heading "SERVICES"
  compose_quick config --services | sed 's/^/  - /'

  heading "IMAGES TO DOWNLOAD / USE"
  compose_quick config --images | sort -u | sed 's/^/  - /'
}

validate_quick_stack() {
  heading "VALIDATING COMPOSE"
  compose_quick config --quiet
  info "Compose configuration is valid."
}

# ------------------------------------------------------------------------------
# Future application-level bootstrap
# ------------------------------------------------------------------------------
run_quick_configuration() {
  heading "APPLICATION QUICK CONFIGURATION"

  local prowlarr_bootstrap
  prowlarr_bootstrap="$PROJECT_ROOT/bootstrap/prowlarr/setup.sh"

  # ---------------------------------------------------------------------------
  # Prowlarr
  # ---------------------------------------------------------------------------

  if [[ "$(env_get QUICK_CONFIG_PROWLARR)" == "true" ]]; then
    [[ -f "$prowlarr_bootstrap" ]] ||
      fatal "Missing Prowlarr bootstrap: $prowlarr_bootstrap"

    info "Running Prowlarr Quick Configuration..."

    bash "$prowlarr_bootstrap"

    info "Prowlarr Quick Configuration completed."
  else
    info "Prowlarr Quick Configuration is disabled."
  fi

  # FUTURE:
  # - Configure qBittorrent categories and paths
  # - Connect Sonarr -> qBittorrent
  # - Connect Radarr -> qBittorrent
  # - Connect Seerr -> Sonarr/Radarr
  # - Initialize Jellyfin libraries
}
# ------------------------------------------------------------------------------
# Quick Setup
# ------------------------------------------------------------------------------
quick_setup() {
  check_docker
  ensure_jq
  initialize_env
  initialize_directories
  load_quick_files
  validate_quick_stack
  show_quick_plan

  printf '\nQuick Setup installs the entire registered stack. Continue? [Y/n]: '
  read -r answer
  case "${answer:-Y}" in
    y|Y|yes|YES|Yes) ;;
    *) info "Cancelled."; exit 0 ;;
  esac

  heading "PULLING IMAGES"
  compose_quick pull

  heading "STARTING CONTAINERS"
  compose_quick up -d

  run_quick_configuration

  heading "STACK STATUS"
  compose_quick ps

  heading "QUICK SETUP COMPLETE"
  info "The Docker infrastructure is running."
  info "Application-level Quick Configuration will be added in the bootstrap stage."
}

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------
main() {
  case "${1:-}" in
    quick)
      quick_setup
      ;;
    custom)
      fatal "Custom Setup is reserved for the next stage. Use Quick Setup for now."
      ;;
    "")
      heading "MASTERBUILDER"
      printf '1) Quick Setup  - install everything currently registered\n'
      printf '2) Custom Setup - future\n'
      printf '\nSelect [1]: '
      read -r choice

      case "${choice:-1}" in
        1) quick_setup ;;
        2) fatal "Custom Setup is reserved for the next stage." ;;
        *) fatal "Invalid selection." ;;
      esac
      ;;
    *)
      fatal "Usage: ./setup.sh [quick|custom]"
      ;;
  esac
}

main "$@"
