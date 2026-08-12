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
  "torrents/anime"
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

generate_secret() {
  od -An -N16 -tx1 /dev/urandom |
    tr -d ' \n'
}

env_get() {
  local key="$1"
  local line
  local value

  line="$(
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null |
      tail -n 1 ||
      true
  )"

  value="${line#*=}"

  # Trim leading whitespace
  value="${value#"${value%%[![:space:]]*}"}"

  # Trim trailing whitespace
  value="${value%"${value##*[![:space:]]}"}"

  # Remove surrounding quotes
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

initialize_env() {
  heading "INITIALIZING VARIABLES"

  if [[ -f "$ENV_FILE" ]]; then
    info "Existing .env found. Reusing it."
    return
  fi

  local puid pgid default_config default_data config_root data_root
  local jellyfin_password

  puid="$(id -u)"
  pgid="$(id -g)"
  jellyfin_password="$(generate_secret)"

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

# Jellyfin
JELLYFIN_PORT=8096
JELLYFIN_ADMIN_USERNAME=admin
JELLYFIN_ADMIN_PASSWORD=$jellyfin_password
JELLYFIN_SERVER_NAME=Jellyfin
JELLYFIN_ENABLE_REMOTE_ACCESS=true

# qBittorrent
QBITTORRENT_WEBUI_PORT=8080
QBITTORRENT_TORRENTING_PORT=6881
QBITTORRENT_USERNAME=admin
QBITTORRENT_PASSWORD=adminadmin

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

# Quick Configs 
QUICK_CONFIG_QBITTORRENT=true
QUICK_CONFIG_SONARR=true
QUICK_CONFIG_RADARR=true
QUICK_CONFIG_PROWLARR=true
QUICK_CONFIG_SEERR=true
QUICK_CONFIG_JELLYFIN=true
QUICK_CONFIG_TRAWL=false
QUICK_CONFIG_BAZARR=true
ENVEOF

  info "Created $ENV_FILE"
  info "Jellyfin administrator username: admin"
  info "Jellyfin administrator password was generated and stored in .env."
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
# Stack integrity checks
# ------------------------------------------------------------------------------

check_config_mount() {
  local service="$1"
  local host_dir="$2"
  local container_dir="$3"

  local container_id
  local probe
  local host_probe

  container_id="$(compose_quick ps -q "$service" 2>/dev/null || true)"

  [[ -n "$container_id" ]] || {
    warn "$service container does not exist."
    return 1
  }

  if [[ ! -d "$host_dir" ]]; then
    warn "$service config directory is missing."
    warn "Expected: $host_dir"
    return 1
  fi

  if [[ ! -w "$host_dir" ]]; then
    warn "$service config directory is not writable."
    warn "Path: $host_dir"
    return 1
  fi

  probe=".masterbuilder-mount-probe-$$-$RANDOM"
  host_probe="$host_dir/$probe"

  printf 'MasterBuilder mount test\n' > "$host_probe"

  if ! docker exec "$container_id" \
      test -f "$container_dir/$probe" \
      >/dev/null 2>&1
  then
    rm -f "$host_probe"

    warn "$service config mount is not connected to the current host directory."
    warn "Host:      $host_dir"
    warn "Container: $container_dir"

    return 1
  fi

  rm -f "$host_probe"

  info "$service config mount verified."
}


check_container_health() {
  local service="$1"
  local container_id
  local state
  local restarts
  local health

  container_id="$(compose_quick ps -q "$service" 2>/dev/null || true)"

  if [[ -z "$container_id" ]]; then
    warn "$service container was not found."
    return 1
  fi

  state="$(
    docker inspect \
      --format '{{.State.Status}}' \
      "$container_id"
  )"

  restarts="$(
    docker inspect \
      --format '{{.RestartCount}}' \
      "$container_id"
  )"

  health="$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$container_id"
  )"

  if [[ "$state" != "running" ]]; then
    warn "$service is not running. State: $state"
    return 1
  fi

  if [[ "$health" == "unhealthy" ]]; then
    warn "$service reports Docker health status: unhealthy"
    return 1
  fi

  if (( restarts >= 5 )); then
    warn "$service has restarted $restarts times."
    warn "Possible crash/restart loop."
    return 1
  fi

  info "$service container state verified."
}


verify_stack_integrity() {
  heading "VERIFYING STACK INTEGRITY"

  local config_root
  local failures=0
  local host_dir
  local container_dir

  config_root="$(env_get CONFIG_ROOT)"

  [[ -n "$config_root" ]] ||
    fatal "CONFIG_ROOT is missing from .env."

  # Give newly-created containers a few seconds to settle.
  sleep 3

  local services=(
    prowlarr
    qbittorrent
    sonarr
    radarr
    bazarr
    jellyfin
    seerr
  )

  # Most applications use /config.
  # Only exceptions need to be declared here.
  local -A config_mount_overrides=(
    [seerr]="/app/config"
  )

  local service

  for service in "${services[@]}"; do

    if ! check_container_health "$service"; then
      ((failures += 1))
      continue
    fi

    host_dir="$config_root/$service"

    container_dir="${config_mount_overrides[$service]:-/config}"

    check_config_mount \
      "$service" \
      "$host_dir" \
      "$container_dir" ||
      ((failures += 1))

  done

  if (( failures > 0 )); then
    printf '\n'

    warn "Stack integrity check found $failures problem(s)."

    fatal "Quick Configuration stopped to avoid modifying a potentially broken installation."
  fi

  printf '\n'
  info "Stack integrity check passed."
}

verify_installation() {
  check_docker

  [[ -f "$ENV_FILE" ]] ||
    fatal "Cannot verify installation: .env does not exist."

  load_quick_files
  verify_stack_integrity

  heading "INSTALLATION VERIFICATION COMPLETE"
  info "No infrastructure integrity problems were detected."
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

show_service_links() {
  heading "SERVICE LINKS"

  local host_ip

  local sonarr_port
  local radarr_port
  local prowlarr_port
  local bazarr_port
  local qbittorrent_port
  local jellyfin_port
  local seerr_port
  local npm_port

  host_ip="$(
    hostname -I 2>/dev/null |
      awk '{print $1}'
  )"

  [[ -n "$host_ip" ]] || host_ip="localhost"

  sonarr_port="$(env_get SONARR_PORT)"
  radarr_port="$(env_get RADARR_PORT)"
  prowlarr_port="$(env_get PROWLARR_PORT)"
  bazarr_port="$(env_get BAZARR_PORT)"
  qbittorrent_port="$(env_get QBITTORRENT_WEBUI_PORT)"
  jellyfin_port="$(env_get JELLYFIN_PORT)"
  seerr_port="$(env_get SEERR_PORT)"
  npm_port="$(env_get NPM_ADMIN_PORT)"

  sonarr_port="${sonarr_port:-8989}"
  radarr_port="${radarr_port:-7878}"
  prowlarr_port="${prowlarr_port:-9696}"
  bazarr_port="${bazarr_port:-6767}"
  qbittorrent_port="${qbittorrent_port:-8080}"
  jellyfin_port="${jellyfin_port:-8096}"
  seerr_port="${seerr_port:-5055}"
  npm_port="${npm_port:-81}"

  printf '\n'
  printf '  %-22s %s\n' "Sonarr:"       "http://$host_ip:$sonarr_port"
  printf '  %-22s %s\n' "Radarr:"       "http://$host_ip:$radarr_port"
  printf '  %-22s %s\n' "Prowlarr:"     "http://$host_ip:$prowlarr_port"
  printf '  %-22s %s\n' "Bazarr:"       "http://$host_ip:$bazarr_port"
  printf '  %-22s %s\n' "qBittorrent:"  "http://$host_ip:$qbittorrent_port"
  printf '  %-22s %s\n' "Jellyfin:"     "http://$host_ip:$jellyfin_port"
  printf '  %-22s %s\n' "Seerr:"        "http://$host_ip:$seerr_port"
  printf '  %-22s %s\n' "NPM Admin:"    "http://$host_ip:$npm_port"

  printf '\n'
  info "Use the addresses above from another device on the same network."
  info "On this machine, you can also replace $host_ip with localhost."
}

# ------------------------------------------------------------------------------
# Future application-level bootstrap
# ------------------------------------------------------------------------------
run_quick_configuration() {
  heading "APPLICATION QUICK CONFIGURATION"

  # add main setup.sh of an appliction
  local prowlarr_bootstrap="$PROJECT_ROOT/bootstrap/prowlarr/setup.sh"
  local qbittorrent_bootstrap="$PROJECT_ROOT/bootstrap/qbittorrent/setup.sh"
  local sonarr_bootstrap="$PROJECT_ROOT/bootstrap/sonarr/setup.sh"
  local radarr_bootstrap="$PROJECT_ROOT/bootstrap/radarr/setup.sh"
  local bazarr_bootstrap="$PROJECT_ROOT/bootstrap/bazarr/setup.sh"
  local jellyfin_bootstrap="$PROJECT_ROOT/bootstrap/jellyfin/setup.sh"
  local seerr_bootstrap="$PROJECT_ROOT/bootstrap/seerr/setup.sh"

  # checks for if they config enable them in .env, add based on added setups. 
  if [[ "$(env_get QUICK_CONFIG_PROWLARR)" == "true" ]]; then
    [[ -f "$prowlarr_bootstrap" ]] ||
      fatal "Missing Prowlarr bootstrap: $prowlarr_bootstrap"

    info "Running Prowlarr Quick Configuration..."
    bash "$prowlarr_bootstrap"
    info "Prowlarr Quick Configuration completed."
  fi

  if [[ "$(env_get QUICK_CONFIG_QBITTORRENT)" == "true" ]]; then
    [[ -f "$qbittorrent_bootstrap" ]] ||
      fatal "Missing qBittorrent bootstrap: $qbittorrent_bootstrap"

    info "Running qBittorrent Quick Configuration..."
    bash "$qbittorrent_bootstrap"
    info "qBittorrent Quick Configuration completed."
  fi

  if [[ "$(env_get QUICK_CONFIG_SONARR)" == "true" ]]; then
    [[ -f "$sonarr_bootstrap" ]] ||
      fatal "Missing Sonarr bootstrap: $sonarr_bootstrap"

    info "Running Sonarr Quick Configuration..."
    bash "$sonarr_bootstrap"
    info "Sonarr Quick Configuration completed."
  fi

  if [[ "$(env_get QUICK_CONFIG_RADARR)" == "true" ]]; then
    [[ -f "$radarr_bootstrap" ]] ||
      fatal "Missing Radarr bootstrap: $radarr_bootstrap"

    info "Running Radarr Quick Configuration..."
    bash "$radarr_bootstrap"
    info "Radarr Quick Configuration completed."
  fi

  if [[ "$(env_get QUICK_CONFIG_BAZARR)" == "true" ]]; then
    [[ -f "$bazarr_bootstrap" ]] ||
      fatal "Missing Bazarr bootstrap: $bazarr_bootstrap"

    info "Running Bazarr Quick Configuration..."
    bash "$bazarr_bootstrap"
    info "Bazarr Quick Configuration completed."
  fi

  if [[ "$(env_get QUICK_CONFIG_JELLYFIN)" == "true" ]]; then
    [[ -f "$jellyfin_bootstrap" ]] ||
      fatal "Missing Jellyfin bootstrap: $jellyfin_bootstrap"

    info "Running Jellyfin Quick Configuration..."
    bash "$jellyfin_bootstrap"
    info "Jellyfin Quick Configuration completed."
  fi

  if [[ "$(env_get QUICK_CONFIG_SEERR)" == "true" ]]; then
   [[ -f "$seerr_bootstrap" ]] ||
    fatal "Missing Seerr bootstrap: $seerr_bootstrap"

    info "Running Seerr Quick Configuration..."
    bash "$seerr_bootstrap"
    info "Seerr Quick Configuration completed."
  fi

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

  verify_stack_integrity

  run_quick_configuration

  heading "STACK STATUS"
  compose_quick ps
  
  show_service_links

  heading "QUICK SETUP COMPLETE"
  info "The Docker infrastructure is running."
  info "Application Quick Configuration completed successfully."
}

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------
main() {
  case "${1:-}" in
    quick)
      quick_setup
      ;;
    verify)
      verify_installation
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
      fatal "Usage: ./setup.sh [quick|verify|custom]"
      ;;
  esac
}

main "$@"
