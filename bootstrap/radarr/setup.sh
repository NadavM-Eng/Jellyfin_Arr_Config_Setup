#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# MasterBuilder - Radarr Quick Configuration
# ==============================================================================
#
# Stage 1:
#   - Add Movies root folder
#   - Enable movie renaming
#
# Stage 2:
#   - Custom Formats
#
# Stage 3:
#   - Quality Profiles
#
# Stage 4:
#   - qBittorrent download client
#
# Safe to run multiple times.
# ==============================================================================

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

info()  { printf '[+] %s\n' "$1"; }
warn()  { printf '[!] %s\n' "$1"; }
fatal() { printf '[X] %s\n' "$1" >&2; exit 1; }


# ------------------------------------------------------------------------------
# Requirements
# ------------------------------------------------------------------------------

command -v curl >/dev/null 2>&1 ||
    fatal "curl is required."

command -v jq >/dev/null 2>&1 ||
    fatal "jq is required."


# ------------------------------------------------------------------------------
# Load environment
# ------------------------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
    fatal "Missing .env file.

Create it from the provided example:

    cp .env.example .env

Then edit .env and fill in the required configuration values."
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${CONFIG_ROOT:?CONFIG_ROOT is missing from .env}"

RADARR_PORT="${RADARR_PORT:-7878}"
RADARR_HOST_URL="http://localhost:${RADARR_PORT}"


# ------------------------------------------------------------------------------
# Read Radarr API key
# ------------------------------------------------------------------------------

RADARR_CONFIG="$CONFIG_ROOT/radarr/config.xml"


wait_for_config() {
    local waited=0

    info "Waiting for Radarr configuration..." >&2

    until [[ -s "$RADARR_CONFIG" ]]; do

        if (( waited >= 120 )); then
            fatal "Radarr config.xml did not appear: $RADARR_CONFIG"
        fi

        sleep 2
        ((waited += 2))
    done
}


read_api_key() {
    local key

    wait_for_config

    key="$(
        sed -n \
            's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
            "$RADARR_CONFIG" |
            head -n 1
    )"

    [[ -n "$key" ]] ||
        fatal "Could not read Radarr API key."

    printf '%s' "$key"
}


RADARR_API_KEY="$(read_api_key)"


# ------------------------------------------------------------------------------
# Wait for Radarr
# ------------------------------------------------------------------------------

wait_for_radarr() {
    local waited=0

    info "Waiting for Radarr API..."

    until curl -fsS \
        -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_HOST_URL/api/v3/system/status" \
        >/dev/null 2>&1
    do

        if (( waited >= 120 )); then
            fatal "Radarr API did not become ready."
        fi

        sleep 2
        ((waited += 2))
    done

    info "Radarr API is ready."
}


# ------------------------------------------------------------------------------
# Radarr API helpers
# ------------------------------------------------------------------------------

radarr_get() {
    local endpoint="$1"

    curl -fsS \
        -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_HOST_URL$endpoint"
}


radarr_post() {
    local endpoint="$1"
    local payload="$2"

    curl -fsS \
        -X POST \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$RADARR_HOST_URL$endpoint"
}


radarr_put() {
    local endpoint="$1"
    local payload="$2"

    curl -fsS \
        -X PUT \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$RADARR_HOST_URL$endpoint"
}


# ------------------------------------------------------------------------------
# Root folder
# ------------------------------------------------------------------------------

root_folder_exists() {
    local path="$1"

    radarr_get '/api/v3/rootfolder' |
        jq -e \
            --arg path "$path" '
                any(.[]; .path == $path)
            ' \
        >/dev/null
}


ensure_root_folder() {
    local name="$1"
    local path="$2"

    if root_folder_exists "$path"; then
        info "$name root folder already exists: $path"
        return
    fi

    info "Adding $name root folder: $path"

    local payload

    payload="$(
        jq -cn \
            --arg path "$path" '
                {
                    path: $path
                }
            '
    )"

    radarr_post \
        '/api/v3/rootfolder' \
        "$payload" \
        >/dev/null

    info "$name root folder added."
}


configure_root_folders() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR ROOT FOLDERS\n'
    printf '============================================================\n'

    ensure_root_folder \
        "Movies" \
        "/data/media/movies"
}


# ------------------------------------------------------------------------------
# Naming
# ------------------------------------------------------------------------------

configure_naming() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR MEDIA NAMING\n'
    printf '============================================================\n'

    local current
    local naming_id
    local payload

    current="$(
        radarr_get '/api/v3/config/naming'
    )"

    naming_id="$(
        printf '%s' "$current" |
            jq -r '.id'
    )"

    [[ "$naming_id" =~ ^[0-9]+$ ]] ||
        fatal "Could not determine Radarr naming configuration ID."

    payload="$(
        printf '%s' "$current" |
            jq -c '
                .renameMovies = true
            '
    )"

    radarr_put \
        "/api/v3/config/naming/$naming_id" \
        "$payload" \
        >/dev/null

    info "Movie renaming enabled."
}


# ------------------------------------------------------------------------------
# Stage 1 verification
# ------------------------------------------------------------------------------

verify_base_configuration() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR STAGE 1 VERIFICATION\n'
    printf '============================================================\n'

    local naming

    naming="$(
        radarr_get '/api/v3/config/naming'
    )"

    printf '\nRoot folders:\n'

    radarr_get '/api/v3/rootfolder' |
        jq -r '
            .[]
            | "  - \(.path)"
        '

    printf '\nNaming:\n'

    printf '%s' "$naming" |
        jq -r '
            "  Rename Movies: \(.renameMovies)",
            "  Movie Format:  \(.standardMovieFormat)",
            "  Folder Format: \(.movieFolderFormat)"
        '
}


# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'RADARR QUICK CONFIGURATION - STAGE 1\n'
printf '============================================================\n'

wait_for_radarr

configure_root_folders
configure_naming
verify_base_configuration


# ------------------------------------------------------------------------------
# Stage 2
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'RADARR QUICK CONFIGURATION - STAGE 2\n'
printf '============================================================\n'

CUSTOM_FORMAT_BOOTSTRAP="$PROJECT_ROOT/bootstrap/radarr/custom-formats.sh"

[[ -f "$CUSTOM_FORMAT_BOOTSTRAP" ]] ||
    fatal "Missing Radarr Custom Format bootstrap: $CUSTOM_FORMAT_BOOTSTRAP"

# shellcheck disable=SC1090
source "$CUSTOM_FORMAT_BOOTSTRAP"

configure_custom_formats
verify_custom_formats


# ------------------------------------------------------------------------------
# Stage 3
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'RADARR QUICK CONFIGURATION - STAGE 3\n'
printf '============================================================\n'

PROFILE_BOOTSTRAP="$PROJECT_ROOT/bootstrap/radarr/profiles.sh"

[[ -f "$PROFILE_BOOTSTRAP" ]] ||
    fatal "Missing Radarr Quality Profile bootstrap: $PROFILE_BOOTSTRAP"

# shellcheck disable=SC1090
source "$PROFILE_BOOTSTRAP"

configure_quality_profiles
verify_quality_profiles


# ------------------------------------------------------------------------------
# Stage 4
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'RADARR QUICK CONFIGURATION - STAGE 4\n'
printf '============================================================\n'

DOWNLOAD_CLIENT_BOOTSTRAP="$PROJECT_ROOT/bootstrap/radarr/download-clients.sh"

[[ -f "$DOWNLOAD_CLIENT_BOOTSTRAP" ]] ||
    fatal "Missing Radarr Download Client bootstrap: $DOWNLOAD_CLIENT_BOOTSTRAP"

# shellcheck disable=SC1090
source "$DOWNLOAD_CLIENT_BOOTSTRAP"

configure_qbittorrent_download_client
verify_qbittorrent_download_client


printf '\n'
printf '============================================================\n'
printf 'RADARR STAGE 1 + 2 + 3 + 4 COMPLETE\n'
printf '============================================================\n'
