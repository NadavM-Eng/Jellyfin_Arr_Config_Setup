#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Sonarr Download Clients
# ==============================================================================
#
# Responsibilities:
#   - Configure qBittorrent download clients in Sonarr.
#   - Route normal TV downloads through the "sonarr" qBittorrent category.
#   - Route Anime downloads through the "anime" qBittorrent category.
#   - Resolve Sonarr's qBittorrent schema dynamically.
#   - Test every client before saving it.
#   - Update existing managed clients instead of duplicating them.
#
# This file is sourced by bootstrap/sonarr/setup.sh.
# ==============================================================================


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

QBITTORRENT_WEBUI_PORT="${QBITTORRENT_WEBUI_PORT:-8080}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-admin}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}"

SONARR_QBIT_HOST="qbittorrent"
SONARR_QBIT_PORT="$QBITTORRENT_WEBUI_PORT"

SONARR_QBIT_TV_NAME="qBittorrent"
SONARR_QBIT_TV_CATEGORY="sonarr"

SONARR_QBIT_ANIME_NAME="qBittorrent Anime"
SONARR_QBIT_ANIME_CATEGORY="anime"


[[ -n "$QBITTORRENT_PASSWORD" ]] ||
    fatal "QBITTORRENT_PASSWORD is missing from .env."


# ------------------------------------------------------------------------------
# Schema
# ------------------------------------------------------------------------------

get_qbittorrent_schema() {
    sonarr_get '/api/v3/downloadclient/schema' |
        jq -c '
            .[]
            | select(
                .implementation == "QBittorrent"
                or
                .implementationName == "qBittorrent"
            )
        ' |
        head -n 1
}


require_download_client_field() {
    local payload="$1"
    local field="$2"

    printf '%s' "$payload" |
        jq -e \
            --arg field "$field" '
                any(.fields[]; .name == $field)
            ' \
        >/dev/null ||
        fatal "qBittorrent download-client schema is missing expected field: $field"
}


validate_qbittorrent_schema() {
    local payload="$1"

    require_download_client_field "$payload" "host"
    require_download_client_field "$payload" "port"
    require_download_client_field "$payload" "useSsl"
    require_download_client_field "$payload" "urlBase"
    require_download_client_field "$payload" "apiKey"
    require_download_client_field "$payload" "username"
    require_download_client_field "$payload" "password"
    require_download_client_field "$payload" "tvCategory"
}


# ------------------------------------------------------------------------------
# Locate managed download clients
# ------------------------------------------------------------------------------

get_qbittorrent_client_by_name() {
    local name="$1"

    sonarr_get '/api/v3/downloadclient' |
        jq -c \
            --arg name "$name" '
                .[]
                | select(
                    (
                        .implementation == "QBittorrent"
                        or
                        .implementationName == "qBittorrent"
                    )
                    and
                    .name == $name
                )
            ' |
        head -n 1
}


# ------------------------------------------------------------------------------
# Build desired configuration
# ------------------------------------------------------------------------------

build_qbittorrent_payload() {
    local source="$1"
    local name="$2"
    local category="$3"
    local tags="$4"

    printf '%s' "$source" |
        jq -c \
            --arg name "$name" \
            --arg host "$SONARR_QBIT_HOST" \
            --argjson port "$SONARR_QBIT_PORT" \
            --arg username "$QBITTORRENT_USERNAME" \
            --arg password "$QBITTORRENT_PASSWORD" \
            --arg category "$category" \
            --argjson tags "$tags" '

                .name = $name
                | .enable = true
                | .tags = $tags

                | .fields |= map(

                    if .name == "host" then
                        .value = $host

                    elif .name == "port" then
                        .value = $port

                    elif .name == "useSsl" then
                        .value = false

                    elif .name == "urlBase" then
                        .value = ""

                    elif .name == "apiKey" then
                        .value = ""

                    elif .name == "username" then
                        .value = $username

                    elif .name == "password" then
                        .value = $password

                    elif .name == "tvCategory" then
                        .value = $category

                    elif .name == "tvImportedCategory" then
                        .value = ""

                    else
                        .
                    end
                )
            '
}


# ------------------------------------------------------------------------------
# Compare managed settings
# ------------------------------------------------------------------------------

qbittorrent_client_matches() {
    local existing="$1"
    local desired="$2"

    printf '%s' "$existing" |
        jq -e \
            --argjson desired "$desired" '

                def field_value($name):
                    (
                        .fields[]
                        | select(.name == $name)
                        | .value
                    );

                def managed:
                    {
                        name: .name,
                        enable: .enable,

                        tags:
                            (
                                (.tags // [])
                                | sort
                            ),

                        host:
                            field_value("host"),

                        port:
                            field_value("port"),

                        useSsl:
                            field_value("useSsl"),

                        urlBase:
                            field_value("urlBase"),

                        username:
                            field_value("username"),

                        tvCategory:
                            field_value("tvCategory")
                    };

                managed
                ==
                ($desired | managed)
            ' \
        >/dev/null
}


# ------------------------------------------------------------------------------
# Test connection
# ------------------------------------------------------------------------------

test_qbittorrent_client() {
    local payload="$1"

    local response_file
    local status

    response_file="$(mktemp)"

    status="$(
        curl -sS \
            -o "$response_file" \
            -w '%{http_code}' \
            -X POST \
            -H "X-Api-Key: $SONARR_API_KEY" \
            -H "Content-Type: application/json" \
            --data "$payload" \
            "$SONARR_HOST_URL/api/v3/downloadclient/test" \
            || true
    )"

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        rm -f "$response_file"

        return 0
    fi

    warn "Sonarr could not validate the qBittorrent connection."
    warn "HTTP status: $status"

    if [[ -s "$response_file" ]]; then
        warn "Sonarr response:"

        jq -r '
            if type == "array" then

                .[]
                | "    \(.propertyName // "unknown"): \(.errorMessage // .message // tostring)"

            else

                tostring

            end
        ' "$response_file" 2>/dev/null ||
            cat "$response_file" >&2
    fi

    rm -f "$response_file"

    return 1
}


# ------------------------------------------------------------------------------
# Ensure one managed qBittorrent client
# ------------------------------------------------------------------------------

ensure_qbittorrent_client() {
    local schema="$1"
    local name="$2"
    local category="$3"
    local tags="$4"

    local existing
    local desired
    local client_id

    existing="$(
        get_qbittorrent_client_by_name "$name"
    )"

    # --------------------------------------------------------------------------
    # Existing client
    # --------------------------------------------------------------------------

    if [[ -n "$existing" ]]; then

        desired="$(
            build_qbittorrent_payload \
                "$existing" \
                "$name" \
                "$category" \
                "$tags"
        )"

        if qbittorrent_client_matches \
            "$existing" \
            "$desired"
        then
            info "$name already matches desired configuration."

            if ! test_qbittorrent_client "$desired"; then
                fatal "$name exists but failed its connection test."
            fi

            return
        fi

        info "Testing updated configuration for $name..."

        if ! test_qbittorrent_client "$desired"; then
            fatal "$name could not connect using the desired settings."
        fi

        client_id="$(
            printf '%s' "$existing" |
                jq -r '.id'
        )"

        [[ "$client_id" =~ ^[0-9]+$ ]] ||
            fatal "Could not determine download-client ID for $name."

        info "Updating $name..."

        sonarr_put \
            "/api/v3/downloadclient/$client_id" \
            "$desired" \
            >/dev/null

        info "$name updated."

        return
    fi

    # --------------------------------------------------------------------------
    # New client
    # --------------------------------------------------------------------------

    desired="$(
        build_qbittorrent_payload \
            "$schema" \
            "$name" \
            "$category" \
            "$tags"
    )"

    info "Testing new configuration for $name..."

    if ! test_qbittorrent_client "$desired"; then
        fatal "$name could not connect to qBittorrent."
    fi

    info "Creating $name..."

    sonarr_post \
        '/api/v3/downloadclient' \
        "$desired" \
        >/dev/null

    info "$name created."
}


# ------------------------------------------------------------------------------
# Configure qBittorrent clients
# ------------------------------------------------------------------------------

configure_qbittorrent_download_clients() {
    local anime_tag_id="$1"

    local schema
    local anime_tags

    [[ "$anime_tag_id" =~ ^[0-9]+$ ]] ||
        fatal "Anime routing tag ID was not provided to download-client configuration."

    printf '\n'
    printf '============================================================\n'
    printf 'SONARR QBITTORRENT DOWNLOAD CLIENTS\n'
    printf '============================================================\n'

    schema="$(get_qbittorrent_schema)"

    [[ -n "$schema" ]] ||
        fatal "Could not find the qBittorrent download-client schema in Sonarr."

    validate_qbittorrent_schema "$schema"

    anime_tags="$(
        jq -cn \
            --argjson tag_id "$anime_tag_id" '
                [$tag_id]
            '
    )"

    ensure_qbittorrent_client \
        "$schema" \
        "$SONARR_QBIT_TV_NAME" \
        "$SONARR_QBIT_TV_CATEGORY" \
        '[]'

    ensure_qbittorrent_client \
        "$schema" \
        "$SONARR_QBIT_ANIME_NAME" \
        "$SONARR_QBIT_ANIME_CATEGORY" \
        "$anime_tags"
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_qbittorrent_client() {
    local name="$1"
    local category="$2"
    local tags="$3"

    local existing
    local desired

    existing="$(
        get_qbittorrent_client_by_name "$name"
    )"

    [[ -n "$existing" ]] ||
        fatal "$name is missing from Sonarr."

    desired="$(
        build_qbittorrent_payload \
            "$existing" \
            "$name" \
            "$category" \
            "$tags"
    )"

    if ! qbittorrent_client_matches \
        "$existing" \
        "$desired"
    then
        fatal "$name does not match desired configuration."
    fi

    if ! test_qbittorrent_client "$desired"; then
        fatal "$name exists but failed its connection test."
    fi

    printf '%s' "$existing" |
        jq -r '

            def field_value($name):
                (
                    .fields[]
                    | select(.name == $name)
                    | .value
                );

            "    Name:     \(.name)",
            "    Enabled:  \(.enable)",
            "    Host:     \(field_value("host"))",
            "    Port:     \(field_value("port"))",
            "    Category: \(field_value("tvCategory"))",
            "    Tags:     \((.tags // []) | join(", "))"
        '

    printf '\n'
}


verify_qbittorrent_download_clients() {
    local anime_tag_id="$1"

    local anime_tags

    [[ "$anime_tag_id" =~ ^[0-9]+$ ]] ||
        fatal "Anime routing tag ID was not provided to verification."

    anime_tags="$(
        jq -cn \
            --argjson tag_id "$anime_tag_id" '
                [$tag_id]
            '
    )"

    printf '\n'
    printf '============================================================\n'
    printf 'SONARR QBITTORRENT VERIFICATION\n'
    printf '============================================================\n'
    printf '\n'

    verify_qbittorrent_client \
        "$SONARR_QBIT_TV_NAME" \
        "$SONARR_QBIT_TV_CATEGORY" \
        '[]'

    verify_qbittorrent_client \
        "$SONARR_QBIT_ANIME_NAME" \
        "$SONARR_QBIT_ANIME_CATEGORY" \
        "$anime_tags"

    info "Sonarr qBittorrent download clients verified."
}
