#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# MasterBuilder - qBittorrent Quick Configuration
# ==============================================================================
#
# Stage 4A:
#   - Authenticate using configured credentials when already initialized.
#   - Otherwise obtain the LinuxServer temporary password from container logs.
#   - Replace the temporary credentials with permanent credentials.
#   - Configure the default torrent path.
#   - Enable Automatic Torrent Management.
#   - Create/update Sonarr and Radarr categories.
#   - Verify the final configuration.
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

command -v docker >/dev/null 2>&1 ||
    fatal "Docker is required."


# ------------------------------------------------------------------------------
# Load environment
# ------------------------------------------------------------------------------

[[ -f "$ENV_FILE" ]] ||
    fatal "Missing .env file: $ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a


QBITTORRENT_WEBUI_PORT="${QBITTORRENT_WEBUI_PORT:-8080}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-admin}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}"

QBIT_URL="http://localhost:${QBITTORRENT_WEBUI_PORT}"

QBIT_DEFAULT_PATH="/data/torrents"
QBIT_SONARR_CATEGORY="sonarr"
QBIT_SONARR_PATH="/data/torrents/tv"
QBIT_RADARR_CATEGORY="radarr"
QBIT_RADARR_PATH="/data/torrents/movies"
QBIT_ANIME_CATEGORY="anime"
QBIT_ANIME_PATH="/data/torrents/anime"

COOKIE_JAR=""


[[ -n "$QBITTORRENT_PASSWORD" ]] ||
    fatal "QBITTORRENT_PASSWORD is missing from .env."


# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

cleanup() {
    if [[ -n "${COOKIE_JAR:-}" && -f "$COOKIE_JAR" ]]; then
        rm -f "$COOKIE_JAR"
    fi
}

trap cleanup EXIT


# ------------------------------------------------------------------------------
# Wait for qBittorrent
# ------------------------------------------------------------------------------

wait_for_qbittorrent() {
    local waited=0
    local status

    info "Waiting for qBittorrent WebUI..."

    while true; do

        status="$(
            curl -sS \
                --connect-timeout 2 \
                --max-time 5 \
                -o /dev/null \
                -w '%{http_code}' \
                "$QBIT_URL/api/v2/app/version" \
                2>/dev/null \
                || true
        )"

        case "$status" in
            200|204|401|403)
                info "qBittorrent WebUI is reachable (HTTP $status)."
                return
                ;;
        esac

        if (( waited >= 60 )); then
            fatal "qBittorrent did not become reachable after 60 seconds."
        fi

        sleep 2
        ((waited += 2))
    done
}

# ------------------------------------------------------------------------------
# Login
# ------------------------------------------------------------------------------

qbit_login() {
    local username="$1"
    local password="$2"

    local status
    local cookie

    cookie="$(mktemp)"

    status="$(
        curl -sS \
            -o /dev/null \
            -w '%{http_code}' \
            -c "$cookie" \
            -H "Referer: $QBIT_URL" \
            --data-urlencode "username=$username" \
            --data-urlencode "password=$password" \
            "$QBIT_URL/api/v2/auth/login"
    )"

    if [[ "$status" =~ ^2[0-9][0-9]$ ]] &&
       grep -q 'SID' "$cookie"
    then
        if [[ -n "$COOKIE_JAR" && -f "$COOKIE_JAR" ]]; then
            rm -f "$COOKIE_JAR"
        fi

        COOKIE_JAR="$cookie"
        return 0
    fi

    rm -f "$cookie"
    return 1
}


# ------------------------------------------------------------------------------
# Authenticated API helpers
# ------------------------------------------------------------------------------

qbit_get() {
    local endpoint="$1"

    curl -fsS \
        -b "$COOKIE_JAR" \
        -H "Referer: $QBIT_URL" \
        "$QBIT_URL$endpoint"
}


qbit_post() {
    local endpoint="$1"
    shift

    curl -fsS \
        -b "$COOKIE_JAR" \
        -H "Referer: $QBIT_URL" \
        -X POST \
        "$@" \
        "$QBIT_URL$endpoint"
}


# ------------------------------------------------------------------------------
# Temporary password
# ------------------------------------------------------------------------------

get_temporary_password() {
    docker logs qbittorrent 2>&1 |
        sed -n \
            's/.*A temporary password is provided for this session: \(.*\)$/\1/p' |
        tail -n 1
}


# ------------------------------------------------------------------------------
# Authentication bootstrap
# ------------------------------------------------------------------------------

authenticate_qbittorrent() {
    local temporary_password

    printf '\n'
    printf '============================================================\n'
    printf 'QBITTORRENT AUTHENTICATION\n'
    printf '============================================================\n'

    info "Trying configured qBittorrent credentials..."

    if qbit_login \
        "$QBITTORRENT_USERNAME" \
        "$QBITTORRENT_PASSWORD"
    then
        info "Configured qBittorrent credentials are already valid."
        return
    fi


    warn "Configured credentials did not authenticate."
    info "Checking container logs for a temporary password..."

    temporary_password="$(get_temporary_password)"

    [[ -n "$temporary_password" ]] ||
        fatal "No usable qBittorrent temporary password was found."


    if ! qbit_login "admin" "$temporary_password"; then
        fatal "Temporary qBittorrent credentials also failed.

The qBittorrent instance appears to already have different permanent
credentials configured."
    fi


    info "Temporary qBittorrent credentials accepted."
    info "Setting permanent WebUI credentials..."

    local preferences

    preferences="$(
        jq -cn \
            --arg username "$QBITTORRENT_USERNAME" \
            --arg password "$QBITTORRENT_PASSWORD" '
                {
                    web_ui_username: $username,
                    web_ui_password: $password
                }
            '
    )"

    qbit_post \
        '/api/v2/app/setPreferences' \
        --data-urlencode "json=$preferences" \
        >/dev/null


    # Credentials changed. Start a fresh authenticated session.
    rm -f "$COOKIE_JAR"
    COOKIE_JAR=""


    info "Verifying permanent qBittorrent credentials..."

    if ! qbit_login \
        "$QBITTORRENT_USERNAME" \
        "$QBITTORRENT_PASSWORD"
    then
        fatal "Permanent qBittorrent credentials were set but verification failed."
    fi

    info "Permanent qBittorrent credentials verified."
}


# ------------------------------------------------------------------------------
# Application preferences
# ------------------------------------------------------------------------------

configure_preferences() {
    printf '\n'
    printf '============================================================\n'
    printf 'QBITTORRENT DOWNLOAD SETTINGS\n'
    printf '============================================================\n'

    local current
    local current_save_path
    local current_auto_tmm
    local desired

    current="$(
        qbit_get '/api/v2/app/preferences'
    )"

    current_save_path="$(
        printf '%s' "$current" |
            jq -r '.save_path'
    )"

    current_auto_tmm="$(
        printf '%s' "$current" |
            jq -r '.auto_tmm_enabled'
    )"


    if [[ "$current_save_path" == "$QBIT_DEFAULT_PATH" &&
          "$current_auto_tmm" == "true" ]]
    then
        info "Default torrent settings already match desired configuration."
        return
    fi


    desired="$(
        jq -cn \
            --arg save_path "$QBIT_DEFAULT_PATH" '
                {
                    save_path: $save_path,
                    auto_tmm_enabled: true
                }
            '
    )"


    info "Configuring default torrent path: $QBIT_DEFAULT_PATH"
    info "Enabling Automatic Torrent Management."

    qbit_post \
        '/api/v2/app/setPreferences' \
        --data-urlencode "json=$desired" \
        >/dev/null

    info "qBittorrent download settings updated."
}

# ------------------------------------------------------------------------------
# Categories
# ------------------------------------------------------------------------------

ensure_category() {
    local category="$1"
    local save_path="$2"

    local categories
    local current_path

    categories="$(
        qbit_get '/api/v2/torrents/categories'
    )"

    current_path="$(
        printf '%s' "$categories" |
            jq -r \
                --arg category "$category" '
                    .[$category].savePath // empty
                '
    )"


    # --------------------------------------------------------------------------
    # Category does not exist
    # --------------------------------------------------------------------------

    if [[ -z "$current_path" ]]; then
        info "Creating category '$category' -> $save_path"

        qbit_post \
            '/api/v2/torrents/createCategory' \
            --data-urlencode "category=$category" \
            --data-urlencode "savePath=$save_path" \
            >/dev/null

        info "Category '$category' created."
        return
    fi


    # --------------------------------------------------------------------------
    # Category already correct
    # --------------------------------------------------------------------------

    if [[ "$current_path" == "$save_path" ]]; then
        info "Category '$category' already matches: $save_path"
        return
    fi


    # --------------------------------------------------------------------------
    # Category exists but has wrong path
    # --------------------------------------------------------------------------

    info "Updating category '$category':"
    info "    $current_path"
    info " -> $save_path"

    qbit_post \
        '/api/v2/torrents/editCategory' \
        --data-urlencode "category=$category" \
        --data-urlencode "savePath=$save_path" \
        >/dev/null

    info "Category '$category' updated."
}


configure_categories() {
    printf '\n'
    printf '============================================================\n'
    printf 'QBITTORRENT CATEGORIES\n'
    printf '============================================================\n'

    ensure_category \
        "$QBIT_SONARR_CATEGORY" \
        "$QBIT_SONARR_PATH"

    ensure_category \
        "$QBIT_ANIME_CATEGORY" \
        "$QBIT_ANIME_PATH"

    ensure_category \
        "$QBIT_RADARR_CATEGORY" \
        "$QBIT_RADARR_PATH"

}

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_qbittorrent() {
    printf '\n'
    printf '============================================================\n'
    printf 'QBITTORRENT VERIFICATION\n'
    printf '============================================================\n'

    local version
    local preferences
    local categories

    version="$(
        qbit_get '/api/v2/app/version'
    )"

    preferences="$(
        qbit_get '/api/v2/app/preferences'
    )"

    categories="$(
        qbit_get '/api/v2/torrents/categories'
    )"


    printf '\n'
    printf 'Version:\n'
    printf '    %s\n' "$version"


    printf '\n'
    printf 'Download settings:\n'

    printf '%s' "$preferences" |
        jq -r '
            "    Default path:                 \(.save_path)",
            "    Automatic Torrent Management: \(.auto_tmm_enabled)"
        '


    printf '\n'
    printf 'Categories:\n'

    printf '%s' "$categories" |
    jq -r \
        --arg sonarr "$QBIT_SONARR_CATEGORY" \
        --arg radarr "$QBIT_RADARR_CATEGORY" \
        --arg anime "$QBIT_ANIME_CATEGORY" '
            .[$sonarr],
            .[$radarr],
            .[$anime]

            | select(. != null)

            | "    \(.name) -> \(.savePath)"
        '

    printf '\n'
}

# ------------------------------------------------------------------------------
# Run Stage 4A
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'QBITTORRENT QUICK CONFIGURATION - STAGE 4A\n'
printf '============================================================\n'

wait_for_qbittorrent
authenticate_qbittorrent
configure_preferences
configure_categories
verify_qbittorrent

printf '\n'
printf '============================================================\n'
printf 'QBITTORRENT STAGE 4A COMPLETE\n'
printf '============================================================\n'
