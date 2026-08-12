#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Radarr Download Clients
# ==============================================================================
#
# Stage 4:
#   - Configure qBittorrent as Radarr's torrent download client.
#   - Resolve the qBittorrent schema dynamically from Radarr.
#   - Use Docker service discovery: qbittorrent:8080
#   - Use the qBittorrent "radarr" category.
#   - Test the connection before saving.
#   - Update an existing qBittorrent client instead of duplicating it.
#   - Verify the final configuration.
#
# This file is sourced by bootstrap/radarr/setup.sh.
# ==============================================================================


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

QBITTORRENT_WEBUI_PORT="${QBITTORRENT_WEBUI_PORT:-8080}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-admin}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}"

RADARR_QBIT_NAME="qBittorrent"
RADARR_QBIT_HOST="qbittorrent"
RADARR_QBIT_PORT="$QBITTORRENT_WEBUI_PORT"
RADARR_QBIT_CATEGORY="radarr"


[[ -n "$QBITTORRENT_PASSWORD" ]] ||
    fatal "QBITTORRENT_PASSWORD is missing from .env."


# ------------------------------------------------------------------------------
# Locate qBittorrent schema
# ------------------------------------------------------------------------------

get_qbittorrent_schema() {
    radarr_get '/api/v3/downloadclient/schema' |
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


# ------------------------------------------------------------------------------
# Locate existing qBittorrent download client
# ------------------------------------------------------------------------------

get_existing_qbittorrent_client() {
    radarr_get '/api/v3/downloadclient' |
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


# ------------------------------------------------------------------------------
# Ensure expected schema fields exist
# ------------------------------------------------------------------------------

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
    require_download_client_field "$payload" "movieCategory"
}


# ------------------------------------------------------------------------------
# Build desired qBittorrent client
# ------------------------------------------------------------------------------

build_qbittorrent_payload() {
    local source="$1"

    printf '%s' "$source" |
        jq -c \
            --arg name "$RADARR_QBIT_NAME" \
            --arg host "$RADARR_QBIT_HOST" \
            --argjson port "$RADARR_QBIT_PORT" \
            --arg username "$QBITTORRENT_USERNAME" \
            --arg password "$QBITTORRENT_PASSWORD" \
            --arg category "$RADARR_QBIT_CATEGORY" '

                .name = $name
                | .enable = true

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

                    elif .name == "movieCategory" then
                        .value = $category

                    elif .name == "movieImportedCategory" then
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

                .name == $desired.name

                and

                .enable == true

                and

                field_value("host")
                ==
                (
                    $desired.fields[]
                    | select(.name == "host")
                    | .value
                )

                and

                field_value("port")
                ==
                (
                    $desired.fields[]
                    | select(.name == "port")
                    | .value
                )

                and

                field_value("useSsl")
                ==
                (
                    $desired.fields[]
                    | select(.name == "useSsl")
                    | .value
                )

                and

                field_value("urlBase")
                ==
                (
                    $desired.fields[]
                    | select(.name == "urlBase")
                    | .value
                )

                and

                field_value("username")
                ==
                (
                    $desired.fields[]
                    | select(.name == "username")
                    | .value
                )

                and

                field_value("movieCategory")
                ==
                (
                    $desired.fields[]
                    | select(.name == "movieCategory")
                    | .value
                )
            ' \
        >/dev/null
}


# ------------------------------------------------------------------------------
# Test qBittorrent connection through Radarr
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
            -H "X-Api-Key: $RADARR_API_KEY" \
            -H "Content-Type: application/json" \
            --data "$payload" \
            "$RADARR_HOST_URL/api/v3/downloadclient/test" \
            || true
    )"

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        rm -f "$response_file"

        info "Radarr successfully connected to qBittorrent."
        return 0
    fi

    warn "Radarr could not validate the qBittorrent connection."
    warn "HTTP status: $status"

    if [[ -s "$response_file" ]]; then
        warn "Radarr response:"

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
# Create/update qBittorrent download client
# ------------------------------------------------------------------------------

configure_qbittorrent_download_client() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR QBITTORRENT DOWNLOAD CLIENT\n'
    printf '============================================================\n'

    local schema
    local existing
    local desired
    local client_id

    schema="$(
        get_qbittorrent_schema
    )"

    [[ -n "$schema" ]] ||
        fatal "Could not find the qBittorrent download-client schema in Radarr."

    validate_qbittorrent_schema "$schema"

    existing="$(
        get_existing_qbittorrent_client
    )"


    if [[ -n "$existing" ]]; then

        info "Existing qBittorrent download client found."

        desired="$(
            build_qbittorrent_payload "$existing"
        )"

        if qbittorrent_client_matches \
            "$existing" \
            "$desired"
        then

            info "qBittorrent download client already matches desired configuration."

            if ! test_qbittorrent_client "$desired"; then
                fatal "Existing Radarr qBittorrent configuration could not connect."
            fi

            return
        fi


        info "Testing updated qBittorrent configuration..."

        if ! test_qbittorrent_client "$desired"; then
            fatal "Radarr cannot connect to qBittorrent with the desired settings."
        fi

        client_id="$(
            printf '%s' "$existing" |
                jq -r '.id'
        )"

        [[ "$client_id" =~ ^[0-9]+$ ]] ||
            fatal "Could not determine existing qBittorrent download-client ID."

        info "Updating existing qBittorrent download client..."

        radarr_put \
            "/api/v3/downloadclient/$client_id" \
            "$desired" \
            >/dev/null

        info "qBittorrent download client updated."

        return
    fi


    info "No qBittorrent download client exists in Radarr."

    desired="$(
        build_qbittorrent_payload "$schema"
    )"

    info "Testing qBittorrent connection..."

    if ! test_qbittorrent_client "$desired"; then
        fatal "Radarr cannot connect to qBittorrent."
    fi

    info "Creating qBittorrent download client..."

    radarr_post \
        '/api/v3/downloadclient' \
        "$desired" \
        >/dev/null

    info "qBittorrent download client created."
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_qbittorrent_download_client() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR QBITTORRENT VERIFICATION\n'
    printf '============================================================\n'

    local existing
    local desired

    existing="$(
        get_existing_qbittorrent_client
    )"

    [[ -n "$existing" ]] ||
        fatal "qBittorrent download client is missing from Radarr."

    desired="$(
        build_qbittorrent_payload "$existing"
    )"

    if ! qbittorrent_client_matches \
        "$existing" \
        "$desired"
    then
        fatal "qBittorrent download client does not match desired configuration."
    fi

    if ! test_qbittorrent_client "$desired"; then
        fatal "qBittorrent download client exists but failed its connection test."
    fi

    printf '\n'

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
            "    Category: \(field_value("movieCategory"))"
        '

    printf '\n'

    info "Radarr qBittorrent download client verified."
}
