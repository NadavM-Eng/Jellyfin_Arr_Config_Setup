#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Prowlarr Public Indexers
# ==============================================================================
# This file is sourced by bootstrap/prowlarr/setup.sh.
#
# Adds:
#   - 1337x
#   - nekoBT
#   - Nyaa.si
#   - The Pirate Bay
#   - Shana Project
#
# Each indexer's current schema is fetched directly from Prowlarr at runtime.
#
# 1337x is linked to TRAWL through the shared "trawl" tag.
# ==============================================================================


# ------------------------------------------------------------------------------
# Requirements
# ------------------------------------------------------------------------------

require_indexer_tools() {
    command -v jq >/dev/null 2>&1 ||
        fatal "jq is required for Prowlarr indexer configuration."
}


# ------------------------------------------------------------------------------
# Generic Prowlarr write helper
# ------------------------------------------------------------------------------

prowlarr_write() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"
    local description="$4"

    local response_file
    local http_code

    response_file="$(mktemp)"

    if ! http_code="$(
        curl -sS \
            -o "$response_file" \
            -w '%{http_code}' \
            -X "$method" \
            -H "X-Api-Key: $PROWLARR_API_KEY" \
            -H 'Content-Type: application/json' \
            --data "$payload" \
            "$PROWLARR_HOST_URL$endpoint"
    )"; then
        rm -f "$response_file"
        warn "$description could not be sent to Prowlarr."
        return 1
    fi

    rm -f "$response_file"

    if [[ "$http_code" =~ ^2 ]]; then
        return 0
    fi

    warn "$description failed (HTTP $http_code)."
    return 1
}


# ------------------------------------------------------------------------------
# App profile
# ------------------------------------------------------------------------------

get_app_profile_id() {
    local id

    id="$(
        prowlarr_get '/api/v1/appprofile' |
            jq -r '
                (.[] | select(.name == "Standard") | .id),
                (.[0].id)
                | select(. != null)
            ' |
            head -n 1
    )"

    [[ -n "$id" ]] ||
        fatal "Could not determine a Prowlarr App Profile ID."

    printf '%s' "$id"
}


# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

get_tag_id() {
    local label="$1"

    prowlarr_get '/api/v1/tag' |
        jq -r --arg label "$label" '
            .[] |
            select(.label == $label) |
            .id
        ' |
        head -n 1
}


ensure_tag() {
    local label="$1"
    local id
    local payload

    id="$(get_tag_id "$label")"

    if [[ -n "$id" ]]; then
        printf '%s' "$id"
        return
    fi

    # This function is used inside $(), so logs must go to stderr.
    info "Creating Prowlarr tag: $label" >&2

    payload="$(
        jq -cn \
            --arg label "$label" \
            '{label: $label}'
    )"

    prowlarr_write \
        POST \
        '/api/v1/tag' \
        "$payload" \
        "Tag '$label'" \
        || fatal "Could not create Prowlarr tag '$label'."

    id="$(get_tag_id "$label")"

    [[ -n "$id" ]] ||
        fatal "Tag '$label' was created but its ID could not be read."

    printf '%s' "$id"
}


# ------------------------------------------------------------------------------
# TRAWL tagging
# ------------------------------------------------------------------------------

ensure_trawl_proxy_tag() {
    local tag_id="$1"

    local proxy
    local proxy_id
    local payload

    proxy="$(
        prowlarr_get '/api/v1/indexerproxy' |
            jq -c '
                .[] |
                select(.name == "TRAWL")
            ' |
            head -n 1
    )"

    [[ -n "$proxy" ]] ||
        fatal "TRAWL proxy was not found in Prowlarr."

    proxy_id="$(
        printf '%s' "$proxy" |
            jq -r '.id'
    )"

    if printf '%s' "$proxy" |
        jq -e \
            --argjson tag_id "$tag_id" '
                (.tags // []) |
                index($tag_id) != null
            ' >/dev/null
    then
        info "TRAWL already has the 'trawl' tag."
        return
    fi

    payload="$(
        printf '%s' "$proxy" |
            jq -c \
                --argjson tag_id "$tag_id" '
                    .tags = (
                        ((.tags // []) + [$tag_id])
                        | unique
                    )
                '
    )"

    prowlarr_write \
        PUT \
        "/api/v1/indexerproxy/$proxy_id" \
        "$payload" \
        "TRAWL proxy tag update" \
        || fatal "Could not attach the 'trawl' tag to TRAWL."

    info "TRAWL linked to tag 'trawl'."
}


# ------------------------------------------------------------------------------
# Existing indexers
# ------------------------------------------------------------------------------

indexer_exists() {
    local definition="$1"

    prowlarr_get '/api/v1/indexer' |
        jq -e \
            --arg definition "$definition" '
                any(.[]; .definitionName == $definition)
            ' >/dev/null
}


# ------------------------------------------------------------------------------
# Read live indexer schema
# ------------------------------------------------------------------------------

get_indexer_schema() {
    local definition="$1"

    prowlarr_get '/api/v1/indexer/schema' |
        jq -c \
            --arg definition "$definition" '
                .[] |
                select(.definitionName == $definition)
            ' |
        head -n 1
}


# ------------------------------------------------------------------------------
# Build indexer from live schema
# ------------------------------------------------------------------------------

build_indexer_payload() {
    local definition="$1"
    local app_profile_id="$2"
    local tag_id="${3:-}"

    local schema

    schema="$(get_indexer_schema "$definition")"

    [[ -n "$schema" ]] ||
        fatal "Prowlarr schema '$definition' was not found."

    if [[ -n "$tag_id" ]]; then

        printf '%s' "$schema" |
            jq -c \
                --argjson profile_id "$app_profile_id" \
                --argjson tag_id "$tag_id" '

                    (.indexerUrls[0] // "") as $base_url

                    | .appProfileId = $profile_id
                    | .tags = [$tag_id]
                    | .enable = true

                    | .fields |= map(
                        if .name == "baseUrl"
                        then .value = $base_url
                        else .
                        end
                    )
                '

    else

        printf '%s' "$schema" |
            jq -c \
                --argjson profile_id "$app_profile_id" '

                    (.indexerUrls[0] // "") as $base_url

                    | .appProfileId = $profile_id
                    | .tags = []
                    | .enable = true

                    | .fields |= map(
                        if .name == "baseUrl"
                        then .value = $base_url
                        else .
                        end
                    )
                '

    fi
}


# ------------------------------------------------------------------------------
# Add one public indexer
# ------------------------------------------------------------------------------

add_public_indexer() {
    local name="$1"
    local definition="$2"
    local app_profile_id="$3"
    local tag_id="${4:-}"

    local payload

    if indexer_exists "$definition"; then
        info "$name already exists. Skipping."
        return
    fi

    info "Adding $name..."

    payload="$(
        build_indexer_payload \
            "$definition" \
            "$app_profile_id" \
            "$tag_id"
    )"

    if prowlarr_write \
        POST \
        '/api/v1/indexer' \
        "$payload" \
        "$name"
    then
        info "$name added."
    else
        warn "$name was skipped. The rest of the bootstrap will continue."
    fi
}

# ------------------------------------------------------------------------------
# Add one credentialed indexer
# ------------------------------------------------------------------------------

add_private_indexer() {
    local name="$1"
    local definition="$2"
    local credential_field="$3"
    local credential_env="$4"
    local credential_value="$5"
    local app_profile_id="$6"

    local payload

    if [[ -z "$credential_value" ]]; then
        warn "$name was not configured."
        warn "Missing value: $credential_env"
        warn "Edit $ENV_FILE and add:"
        warn "    $credential_env=<your credential>"
        warn "Then run the setup again."
        printf '\n'
        return
    fi

    if indexer_exists "$definition"; then
        info "$name already exists. Skipping."
        return
    fi

    info "Adding $name..."

    payload="$(
        build_indexer_payload \
            "$definition" \
            "$app_profile_id" |
        jq -c \
            --arg credential_field "$credential_field" \
            --arg credential_value "$credential_value" '
                .fields |= map(
                    if .name == $credential_field
                    then .value = $credential_value
                    else .
                    end
                )
            '
    )"

    if prowlarr_write \
        POST \
        '/api/v1/indexer' \
        "$payload" \
        "$name"
    then
        info "$name added."
    else
        warn "$name was skipped. The rest of the bootstrap will continue."
    fi
}

# ------------------------------------------------------------------------------
# Configure selected public indexers
# ------------------------------------------------------------------------------

configure_public_indexers() {
    local app_profile_id
    local trawl_tag_id

    printf '\n'
    printf '============================================================\n'
    printf 'PROWLARR PUBLIC INDEXERS\n'
    printf '============================================================\n'

    require_indexer_tools

    app_profile_id="$(get_app_profile_id)"
    trawl_tag_id="$(ensure_tag 'trawl')"

    ensure_trawl_proxy_tag "$trawl_tag_id"


    # 1337x requires the TRAWL proxy.
    add_public_indexer \
        '1337x' \
        '1337x' \
        "$app_profile_id" \
        "$trawl_tag_id"


    add_public_indexer \
        'nekoBT' \
        'nekobt' \
        "$app_profile_id"


    add_public_indexer \
        'Nyaa.si' \
        'nyaasi' \
        "$app_profile_id"


    add_public_indexer \
        'The Pirate Bay' \
        'thepiratebay' \
        "$app_profile_id"


    add_public_indexer \
        'Shana Project' \
        'shanaproject' \
        "$app_profile_id"


    printf '\n'
    info "Public indexer bootstrap finished."
}
# ------------------------------------------------------------------------------
# Configure selected private indexers
# ------------------------------------------------------------------------------

configure_private_indexers() {
    local app_profile_id

    printf '\n'
    printf '============================================================\n'
    printf 'PROWLARR PRIVATE INDEXERS\n'
    printf '============================================================\n'

    require_indexer_tools

    app_profile_id="$(get_app_profile_id)"


    # Anime Tosho
    add_private_indexer \
        'Anime Tosho' \
        'animetosho-xyz' \
        'apikey' \
        'ANIMETOSHO_API_KEY' \
        "${ANIMETOSHO_API_KEY:-}" \
        "$app_profile_id"


    # Fuzer
    add_private_indexer \
        'Fuzer' \
        'fuzer' \
        'cookie' \
        'FUZER_COOKIE' \
        "${FUZER_COOKIE:-}" \
        "$app_profile_id"


    # Hebits
    add_private_indexer \
        'Hebits' \
        'hebits' \
        'cookie' \
        'HEBITS_COOKIE' \
        "${HEBITS_COOKIE:-}" \
        "$app_profile_id"


    printf '\n'
    info "Private indexer bootstrap finished."
}
