#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# MasterBuilder - Sonarr Quick Configuration
# ==============================================================================
# Stage 1:
#   - Add TV root folder
#   - Add Anime root folder
#   - Enable episode renaming
#   - Configure Standard, Daily and Anime naming formats
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
# Load project environment
# ------------------------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
    fatal "Missing .env file.

Create it from the provided example:

    cp .env.example .env

Then edit .env and fill in the required configuration values before running
the setup again."
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${CONFIG_ROOT:?CONFIG_ROOT is missing from .env}"

SONARR_PORT="${SONARR_PORT:-8989}"
SONARR_HOST_URL="http://localhost:${SONARR_PORT}"


# ------------------------------------------------------------------------------
# Read Sonarr API key
# ------------------------------------------------------------------------------

SONARR_CONFIG="$CONFIG_ROOT/sonarr/config.xml"


wait_for_config() {
    local waited=0

    info "Waiting for Sonarr configuration..." >&2

    until [[ -s "$SONARR_CONFIG" ]]; do
        if (( waited >= 120 )); then
            fatal "Sonarr config.xml did not appear: $SONARR_CONFIG"
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
            "$SONARR_CONFIG" |
            head -n 1
    )"

    [[ -n "$key" ]] ||
        fatal "Could not read Sonarr API key."

    printf '%s' "$key"
}


SONARR_API_KEY="$(read_api_key)"


# ------------------------------------------------------------------------------
# Wait for Sonarr API
# ------------------------------------------------------------------------------

wait_for_sonarr() {
    local waited=0

    info "Waiting for Sonarr API..."

    until curl -fsS \
        -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_HOST_URL/api/v3/system/status" \
        >/dev/null 2>&1
    do
        if (( waited >= 120 )); then
            fatal "Sonarr API did not become ready."
        fi

        sleep 2
        ((waited += 2))
    done

    info "Sonarr API is ready."
}


# ------------------------------------------------------------------------------
# Sonarr API helpers
# ------------------------------------------------------------------------------

sonarr_get() {
    local endpoint="$1"

    curl -fsS \
        -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_HOST_URL$endpoint"
}


sonarr_post() {
    local endpoint="$1"
    local payload="$2"

    curl -fsS \
        -X POST \
        -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$SONARR_HOST_URL$endpoint"
}


sonarr_put() {
    local endpoint="$1"
    local payload="$2"

    curl -fsS \
        -X PUT \
        -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$SONARR_HOST_URL$endpoint"
}


# ------------------------------------------------------------------------------
# Root folders
# ------------------------------------------------------------------------------

root_folder_exists() {
    local path="$1"

    sonarr_get '/api/v3/rootfolder' |
        jq -e \
            --arg path "$path" \
            'any(.[]; .path == $path)' \
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
            --arg path "$path" \
            '{path: $path}'
    )"

    sonarr_post \
        '/api/v3/rootfolder' \
        "$payload" \
        >/dev/null

    info "$name root folder added."
}


configure_root_folders() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR ROOT FOLDERS\n'
    printf '============================================================\n'

    ensure_root_folder \
        "TV Shows" \
        "/data/media/tv"

    ensure_root_folder \
        "Anime" \
        "/data/media/anime"
}


# ------------------------------------------------------------------------------
# Naming
# ------------------------------------------------------------------------------

configure_naming() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR MEDIA NAMING\n'
    printf '============================================================\n'

    local current
    local naming_id
    local payload

    current="$(sonarr_get '/api/v3/config/naming')"

    naming_id="$(
        printf '%s' "$current" |
            jq -r '.id'
    )"

    [[ "$naming_id" =~ ^[0-9]+$ ]] ||
        fatal "Could not determine Sonarr naming configuration ID."

    payload="$(
        printf '%s' "$current" |
            jq -c '
                .renameEpisodes = true

                | .standardEpisodeFormat =
                    "{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}"

                | .dailyEpisodeFormat =
                    "{Series Title} - {Air-Date} - {Episode Title} {Quality Full}"

                | .animeEpisodeFormat =
                    "{Release Group} {Series Title} - S{season:00}E{episode:00} - {absolute:000} - {Episode Title} {Quality Full}"
            '
    )"

    sonarr_put \
        "/api/v3/config/naming/$naming_id" \
        "$payload" \
        >/dev/null

    info "Episode renaming enabled."
    info "Standard episode naming configured."
    info "Daily episode naming configured."
    info "Anime episode naming configured."
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_configuration() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR STAGE 1 VERIFICATION\n'
    printf '============================================================\n'

    local naming

    naming="$(sonarr_get '/api/v3/config/naming')"

    printf '\nRoot folders:\n'

    sonarr_get '/api/v3/rootfolder' |
        jq -r '.[] | "  - \(.path)"'

    printf '\nNaming:\n'

    printf '%s' "$naming" |
        jq -r '
            "  Rename Episodes: \(.renameEpisodes)",
            "  Standard:        \(.standardEpisodeFormat)",
            "  Daily:           \(.dailyEpisodeFormat)",
            "  Anime:           \(.animeEpisodeFormat)"
        '
}


# ------------------------------------------------------------------------------
# Run Stage 1
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'SONARR QUICK CONFIGURATION - STAGE 1\n'
printf '============================================================\n'

wait_for_sonarr

configure_root_folders
configure_naming
verify_configuration

printf '\n'
printf '============================================================\n'
printf 'SONARR STAGE 1 COMPLETE\n'
printf '============================================================\n'
