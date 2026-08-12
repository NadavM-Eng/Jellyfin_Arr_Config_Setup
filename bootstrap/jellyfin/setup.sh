#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# MasterBuilder - Jellyfin Quick Configuration
# ==============================================================================

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

info()  { printf '[+] %s\n' "$1"; }
warn()  { printf '[!] %s\n' "$1"; }
fatal() { printf '[X] %s\n' "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 ||
    fatal "curl is required."

command -v jq >/dev/null 2>&1 ||
    fatal "jq is required."

[[ -f "$ENV_FILE" ]] ||
    fatal "Missing .env file."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

JELLYFIN_PORT="${JELLYFIN_PORT:-8096}"
JELLYFIN_HOST_URL="http://localhost:${JELLYFIN_PORT}"

JELLYFIN_ADMIN_USERNAME="${JELLYFIN_ADMIN_USERNAME:-admin}"
JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-}"

JELLYFIN_SERVER_NAME="${JELLYFIN_SERVER_NAME:-Jellyfin}"
JELLYFIN_ENABLE_REMOTE_ACCESS="${JELLYFIN_ENABLE_REMOTE_ACCESS:-true}"

JELLYFIN_TOKEN=""
JELLYFIN_USER_ID=""

[[ -n "$JELLYFIN_ADMIN_PASSWORD" ]] ||
    fatal "JELLYFIN_ADMIN_PASSWORD is missing from .env."


# ------------------------------------------------------------------------------
# HTTP helpers
# ------------------------------------------------------------------------------

jellyfin_status_request() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    local auth="${4:-false}"

    local args=(
        -sS
        -X "$method"
        -H "Content-Type: application/json"
    )

    if [[ "$auth" == "true" && -n "$JELLYFIN_TOKEN" ]]; then
        args+=(
            -H "X-Emby-Token: $JELLYFIN_TOKEN"
        )
    fi

    if [[ -n "$body" ]]; then
        args+=(
            --data "$body"
        )
    fi

    curl \
        "${args[@]}" \
        -w $'\n%{http_code}' \
        "$JELLYFIN_HOST_URL$endpoint"
}


split_response() {
    local response="$1"

    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
}


require_success() {
    local status="$1"
    local action="$2"
    local body="${3:-}"

    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        warn "$action failed."
        warn "HTTP status: $status"

        if [[ -n "$body" ]]; then
            printf '%s\n' "$body" |
                sed 's/^/    /' >&2
        fi

        fatal "$action failed."
    fi
}


# ------------------------------------------------------------------------------
# Wait for server
# ------------------------------------------------------------------------------

wait_for_jellyfin() {
    local waited=0
    local status

    info "Waiting for Jellyfin API..."

    while (( waited < 180 )); do

        status="$(
            curl \
                -s \
                -o /dev/null \
                -w '%{http_code}' \
                "$JELLYFIN_HOST_URL/System/Info/Public" \
                2>/dev/null ||
                true
        )"

        if [[ "$status" == "200" ]]; then
            info "Jellyfin API is ready."
            return
        fi

        sleep 2
        ((waited += 2))
    done

    fatal "Jellyfin API did not become ready."
}


# ------------------------------------------------------------------------------
# Authentication
# ------------------------------------------------------------------------------

authenticate_admin() {
    local payload
    local response

    payload="$(
        jq -cn \
            --arg username "$JELLYFIN_ADMIN_USERNAME" \
            --arg password "$JELLYFIN_ADMIN_PASSWORD" '
                {
                    Username: $username,
                    Pw: $password
                }
            '
    )"

    response="$(
        curl \
            -sS \
            -X POST \
            -H "Content-Type: application/json" \
            -H 'Authorization: MediaBrowser Client="MasterBuilder", Device="Installer", DeviceId="masterbuilder-installer", Version="1.0"' \
            --data "$payload" \
            -w $'\n%{http_code}' \
            "$JELLYFIN_HOST_URL/Users/AuthenticateByName"
    )"

    split_response "$response"

    if [[ "$HTTP_STATUS" != "200" ]]; then
        return 1
    fi

    JELLYFIN_TOKEN="$(
        printf '%s' "$HTTP_BODY" |
            jq -r '.AccessToken // empty'
    )"

    JELLYFIN_USER_ID="$(
        printf '%s' "$HTTP_BODY" |
            jq -r '.User.Id // empty'
    )"

    [[ -n "$JELLYFIN_TOKEN" ]] || return 1
    [[ -n "$JELLYFIN_USER_ID" ]] || return 1

    return 0
}

# ------------------------------------------------------------------------------
# Detect setup state
# ------------------------------------------------------------------------------

startup_wizard_available() {
    local response

    response="$(
        jellyfin_status_request \
            GET \
            "/Startup/Configuration"
    )"

    split_response "$response"

    [[ "$HTTP_STATUS" == "200" ]]
}


# ------------------------------------------------------------------------------
# Initial server configuration
# ------------------------------------------------------------------------------

configure_initial_server() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN INITIAL SERVER CONFIGURATION\n'
    printf '============================================================\n'

    local response
    local startup_config
    local desired_config

    response="$(
        jellyfin_status_request \
            GET \
            "/Startup/Configuration"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Jellyfin startup configuration" \
        "$HTTP_BODY"

    startup_config="$HTTP_BODY"

    desired_config="$(
        printf '%s' "$startup_config" |
            jq \
                --arg server_name "$JELLYFIN_SERVER_NAME" '
                    .ServerName = $server_name
                '
    )"

    response="$(
        jellyfin_status_request \
            POST \
            "/Startup/Configuration" \
            "$desired_config"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Updating Jellyfin startup configuration" \
        "$HTTP_BODY"

    info "Server name configured: $JELLYFIN_SERVER_NAME"
}

# ------------------------------------------------------------------------------
# Initial administrator
# ------------------------------------------------------------------------------

configure_admin() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN ADMINISTRATOR\n'
    printf '============================================================\n'

    local payload
    local response
    local initial_username

    # Jellyfin does not create/initialize the first user until this
    # endpoint has been called at least once during startup.
    response="$(
        jellyfin_status_request \
            GET \
            "/Startup/User"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Initializing Jellyfin first user" \
        "$HTTP_BODY"

    initial_username="$(
        printf '%s' "$HTTP_BODY" |
            jq -r '.Name // empty'
    )"

    [[ -n "$initial_username" ]] ||
        fatal "Jellyfin initialized the first user, but returned no username."

    info "Initial Jellyfin user initialized: $initial_username"

    payload="$(
        jq -cn \
            --arg username "$JELLYFIN_ADMIN_USERNAME" \
            --arg password "$JELLYFIN_ADMIN_PASSWORD" '
                {
                    Name: $username,
                    Password: $password
                }
            '
    )"

    response="$(
        jellyfin_status_request \
            POST \
            "/Startup/User" \
            "$payload"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Configuring Jellyfin administrator" \
        "$HTTP_BODY"

    info "Administrator configured: $JELLYFIN_ADMIN_USERNAME"
}

# ------------------------------------------------------------------------------
# Remote access
# ------------------------------------------------------------------------------

configure_remote_access() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN REMOTE ACCESS\n'
    printf '============================================================\n'

    local enabled
    local payload
    local response

    case "${JELLYFIN_ENABLE_REMOTE_ACCESS,,}" in
        true|1|yes)
            enabled=true
            ;;
        false|0|no)
            enabled=false
            ;;
        *)
            fatal "Invalid JELLYFIN_ENABLE_REMOTE_ACCESS value."
            ;;
    esac

    payload="$(
        jq -cn \
            --argjson enabled "$enabled" '
                {
                    EnableRemoteAccess: $enabled
                }
            '
    )"

    response="$(
        jellyfin_status_request \
            POST \
            "/Startup/RemoteAccess" \
            "$payload"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Configuring Jellyfin remote access" \
        "$HTTP_BODY"

    info "Remote access configured: $enabled"
}

# ------------------------------------------------------------------------------
# Complete startup
# ------------------------------------------------------------------------------

complete_startup() {
    printf '\n'
    printf '============================================================\n'
    printf 'COMPLETING JELLYFIN STARTUP\n'
    printf '============================================================\n'

    local response

    response="$(
        jellyfin_status_request \
            POST \
            "/Startup/Complete"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Completing Jellyfin startup wizard" \
        "$HTTP_BODY"

    info "Startup wizard completed."
}

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_admin() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN STAGE 1 VERIFICATION\n'
    printf '============================================================\n'

    local response

    if ! authenticate_admin; then
        fatal "Jellyfin administrator authentication failed."
    fi

    response="$(
        jellyfin_status_request \
            GET \
            "/Users/$JELLYFIN_USER_ID" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Jellyfin administrator" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY" |
        jq -e \
            --arg username "$JELLYFIN_ADMIN_USERNAME" '
                .Name == $username
                and
                .Policy.IsAdministrator == true
            ' \
        >/dev/null ||
        fatal "Jellyfin administrator verification failed."

    info "Administrator login verified."
    info "Administrator privileges verified."
}

# ------------------------------------------------------------------------------
# Stage 2 - Media libraries
# ------------------------------------------------------------------------------

urlencode() {
    jq -rn \
        --arg value "$1" \
        '$value | @uri'
}


get_virtual_folders() {
    local response

    response="$(
        jellyfin_status_request \
            GET \
            "/Library/VirtualFolders" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Jellyfin libraries" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


ensure_library() {
    local name="$1"
    local path="$2"
    local collection_type="$3"
    local collection_type_id="$4"

    local folders
    local existing
    local conflict
    local endpoint
    local response

    folders="$(get_virtual_folders)"

    existing="$(
        printf '%s' "$folders" |
            jq -c \
                --arg name "$name" '
                    [
                        .[]
                        | select(.Name == $name)
                    ]
                    | first // empty
                '
    )"

    if [[ -n "$existing" ]]; then

        if printf '%s' "$existing" |
            jq -e \
                --arg path "$path" \
                --arg type "$collection_type" \
                --arg type_id "$collection_type_id" '

                    (
                        (.Locations // [])
                        | index($path)
                    ) != null

                    and

                    (
                        (
                            (.CollectionType // "")
                            | tostring
                            | ascii_downcase
                        ) == $type

                        or

                        (
                            (.CollectionType // "")
                            | tostring
                        ) == $type_id
                    )
                ' \
                >/dev/null
        then
            info "$name library already configured."
            return
        fi

        fatal "Jellyfin library '$name' already exists but does not match the expected path/type."
    fi


    # Protect against the same path already belonging to another library.
    conflict="$(
        printf '%s' "$folders" |
            jq -r \
                --arg path "$path" '
                    [
                        .[]
                        | select(
                            (
                                (.Locations // [])
                                | index($path)
                            ) != null
                        )
                        | .Name
                    ]
                    | first // empty
                '
    )"

    if [[ -n "$conflict" ]]; then
        fatal "Path '$path' is already used by Jellyfin library '$conflict'."
    fi


    endpoint="/Library/VirtualFolders"
    endpoint+="?name=$(urlencode "$name")"
    endpoint+="&collectionType=$(urlencode "$collection_type")"
    endpoint+="&paths=$(urlencode "$path")"
    endpoint+="&refreshLibrary=false"

    response="$(
        jellyfin_status_request \
            POST \
            "$endpoint" \
            "{}" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Creating Jellyfin library '$name'" \
        "$HTTP_BODY"

    info "$name library created."
}


configure_libraries() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN MEDIA LIBRARIES\n'
    printf '============================================================\n'

    ensure_library \
        "Movies" \
        "/data/media/movies" \
        "movies" \
        "0"

    ensure_library \
        "TV Shows" \
        "/data/media/tv" \
        "tvshows" \
        "1"

    ensure_library \
        "Anime" \
        "/data/media/anime" \
        "tvshows" \
        "1"
}

# ------------------------------------------------------------------------------
# Stage 3 - Administrator permissions
# ------------------------------------------------------------------------------

configure_admin_permissions() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN ADMINISTRATOR PERMISSIONS\n'
    printf '============================================================\n'

    local response
    local user
    local current_policy
    local desired_policy

    response="$(
        jellyfin_status_request \
            GET \
            "/Users/$JELLYFIN_USER_ID" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Jellyfin administrator policy" \
        "$HTTP_BODY"

    user="$HTTP_BODY"

    printf '%s' "$user" |
        jq -e '.Policy.IsAdministrator == true' \
        >/dev/null ||
        fatal "Configured Jellyfin user is not an administrator."

    current_policy="$(
        printf '%s' "$user" |
            jq -c '.Policy'
    )"

    if printf '%s' "$current_policy" |
        jq -e '.EnableContentDeletion == true' \
        >/dev/null
    then
        info "Administrator media deletion permission already enabled."
        return
    fi

    desired_policy="$(
        printf '%s' "$current_policy" |
            jq '
                .EnableContentDeletion = true
            '
    )"

    response="$(
        jellyfin_status_request \
            POST \
            "/Users/$JELLYFIN_USER_ID/Policy" \
            "$desired_policy" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Enabling Jellyfin administrator media deletion" \
        "$HTTP_BODY"

    info "Administrator media deletion permission enabled."
}

verify_library() {
    local name="$1"
    local path="$2"
    local collection_type="$3"
    local collection_type_id="$4"

    local folders

    folders="$(get_virtual_folders)"

    printf '%s' "$folders" |
        jq -e \
            --arg name "$name" \
            --arg path "$path" \
            --arg type "$collection_type" \
            --arg type_id "$collection_type_id" '

                any(
                    .[];

                    .Name == $name

                    and

                    (
                        (.Locations // [])
                        | index($path)
                    ) != null

                    and

                    (
                        (
                            (.CollectionType // "")
                            | tostring
                            | ascii_downcase
                        ) == $type

                        or

                        (
                            (.CollectionType // "")
                            | tostring
                        ) == $type_id
                    )
                )
            ' \
        >/dev/null ||
        fatal "Jellyfin library '$name' verification failed."

    info "$name verified: $path"
}


verify_libraries() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN STAGE 2 VERIFICATION\n'
    printf '============================================================\n'

    verify_library \
        "Movies" \
        "/data/media/movies" \
        "movies" \
        "0"

    verify_library \
        "TV Shows" \
        "/data/media/tv" \
        "tvshows" \
        "1"

    verify_library \
        "Anime" \
        "/data/media/anime" \
        "tvshows" \
        "1"

    info "All Jellyfin media libraries verified."
}

verify_admin_permissions() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN STAGE 3 VERIFICATION\n'
    printf '============================================================\n'

    local response

    response="$(
        jellyfin_status_request \
            GET \
            "/Users/$JELLYFIN_USER_ID" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Verifying Jellyfin administrator policy" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY" |
        jq -e '
            .Policy.IsAdministrator == true
            and
            .Policy.EnableContentDeletion == true
        ' \
        >/dev/null ||
        fatal "Jellyfin administrator permission verification failed."

    info "Administrator privileges verified."
    info "Media deletion permission verified."
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'JELLYFIN QUICK CONFIGURATION\n'
printf '============================================================\n'

wait_for_jellyfin


# ------------------------------------------------------------------------------
# Stage 1
# ------------------------------------------------------------------------------

if authenticate_admin; then

    info "Existing configured Jellyfin instance detected."
    info "Administrator authentication succeeded."

    verify_admin

else

    if ! startup_wizard_available; then
        fatal "Jellyfin is already configured, but the administrator credentials in .env do not work."
    fi

    info "Fresh Jellyfin instance detected."

    configure_initial_server
    configure_admin
    configure_remote_access
    complete_startup

    # Give Jellyfin time to transition out of startup mode.
    sleep 2

    verify_admin
fi


printf '\n'
printf '============================================================\n'
printf 'JELLYFIN STAGE 1 COMPLETE\n'
printf '============================================================\n'


# ------------------------------------------------------------------------------
# Stage 2
# ------------------------------------------------------------------------------

configure_libraries
verify_libraries

# ------------------------------------------------------------------------------
# Stage 3
# ------------------------------------------------------------------------------

configure_admin_permissions
verify_admin_permissions


printf '\n'
printf '============================================================\n'
printf 'JELLYFIN QUICK CONFIGURATION COMPLETE\n'
printf '============================================================\n'

info "Administrator configured."
info "Movies library configured."
info "TV Shows library configured."
info "Anime library configured."
info "Media deletion permission enabled."
