#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Sonarr Media Routing
# ==============================================================================
#
# Responsibilities:
#   - Ensure the "anime" Sonarr tag exists.
#   - Ensure Anime series automatically receive that tag.
#   - Apply the tag immediately to existing Anime series.
#
# Download-client routing is handled separately by download-clients.sh.
#
# This file is sourced by bootstrap/sonarr/setup.sh.
# ==============================================================================


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

SONARR_ANIME_TAG_LABEL="anime"
SONARR_ANIME_AUTOTAG_NAME="MasterBuilder Anime Routing"

SONARR_ANIME_TAG_ID=""


# ------------------------------------------------------------------------------
# Tag helpers
# ------------------------------------------------------------------------------

get_tag_by_label() {
    local label="$1"

    sonarr_get '/api/v3/tag' |
        jq -c \
            --arg label "$label" '
                .[]
                | select(
                    (.label | ascii_downcase)
                    ==
                    ($label | ascii_downcase)
                )
            ' |
        head -n 1
}


ensure_anime_tag() {
    local existing
    local payload

    existing="$(get_tag_by_label "$SONARR_ANIME_TAG_LABEL")"

    if [[ -z "$existing" ]]; then
        info "Creating Sonarr tag: $SONARR_ANIME_TAG_LABEL"

        payload="$(
            jq -cn \
                --arg label "$SONARR_ANIME_TAG_LABEL" '
                    {
                        label: $label
                    }
                '
        )"

        sonarr_post \
            '/api/v3/tag' \
            "$payload" \
            >/dev/null

        existing="$(get_tag_by_label "$SONARR_ANIME_TAG_LABEL")"
    else
        info "Sonarr tag already exists: $SONARR_ANIME_TAG_LABEL"
    fi

    SONARR_ANIME_TAG_ID="$(
        printf '%s' "$existing" |
            jq -r '.id'
    )"

    [[ "$SONARR_ANIME_TAG_ID" =~ ^[0-9]+$ ]] ||
        fatal "Could not determine Sonarr Anime tag ID."

    info "Anime tag ID: $SONARR_ANIME_TAG_ID"
}


# ------------------------------------------------------------------------------
# Auto-tagging schema
# ------------------------------------------------------------------------------

get_series_type_schema() {
    sonarr_get '/api/v3/autotagging/schema' |
        jq -c '
            .[]
            | select(
                .implementation
                ==
                "SeriesTypeSpecification"
            )
        ' |
        head -n 1
}


get_anime_series_type_value() {
    local schema="$1"

    printf '%s' "$schema" |
        jq -r '
            .fields[]
            | select(.name == "value")
            | .selectOptions[]
            | select(
                (.name | ascii_downcase)
                ==
                "anime"
            )
            | .value
        ' |
        head -n 1
}


# ------------------------------------------------------------------------------
# Desired Auto Tagging rule
# ------------------------------------------------------------------------------

build_anime_autotag_payload() {
    local schema
    local anime_value

    schema="$(get_series_type_schema)"

    [[ -n "$schema" ]] ||
        fatal "Sonarr does not expose the Series Type Auto Tagging schema."

    anime_value="$(get_anime_series_type_value "$schema")"

    [[ "$anime_value" =~ ^[0-9]+$ ]] ||
        fatal "Could not resolve the Anime Series Type value from Sonarr."

    printf '%s' "$schema" |
        jq -c \
            --arg rule_name "$SONARR_ANIME_AUTOTAG_NAME" \
            --arg condition_name "Series Type is Anime" \
            --argjson tag_id "$SONARR_ANIME_TAG_ID" \
            --argjson anime_value "$anime_value" '

                .name = $condition_name
                | .negate = false
                | .required = false

                | .fields |= map(
                    if .name == "value" then
                        .value = $anime_value
                    else
                        .
                    end
                )

                | {
                    name: $rule_name,
                    removeTagsAutomatically: true,
                    tags: [$tag_id],
                    specifications: [.]
                }
            '
}


get_existing_anime_autotag() {
    sonarr_get '/api/v3/autotagging' |
        jq -c \
            --arg name "$SONARR_ANIME_AUTOTAG_NAME" '
                .[]
                | select(.name == $name)
            ' |
        head -n 1
}


anime_autotag_matches() {
    local existing="$1"
    local desired="$2"

    printf '%s' "$existing" |
        jq -e \
            --argjson desired "$desired" '

                def normalized:
                    {
                        name: .name,

                        removeTagsAutomatically:
                            .removeTagsAutomatically,

                        tags:
                            (
                                (.tags // [])
                                | sort
                            ),

                        specifications:
                            [
                                (.specifications // [])[]
                                |
                                {
                                    implementation:
                                        .implementation,

                                    negate:
                                        .negate,

                                    required:
                                        .required,

                                    value:
                                        (
                                            [
                                                .fields[]
                                                | select(.name == "value")
                                                | .value
                                            ][0]
                                        )
                                }
                            ]
                    };

                normalized
                ==
                ($desired | normalized)
            ' \
        >/dev/null
}


ensure_anime_autotag() {
    local existing
    local desired
    local rule_id

    desired="$(build_anime_autotag_payload)"
    existing="$(get_existing_anime_autotag)"

    if [[ -z "$existing" ]]; then
        info "Creating Sonarr Anime Auto Tagging rule."

        sonarr_post \
            '/api/v3/autotagging' \
            "$desired" \
            >/dev/null

        info "Anime Auto Tagging rule created."
        return
    fi

    if anime_autotag_matches "$existing" "$desired"; then
        info "Anime Auto Tagging rule already matches."
        return
    fi

    rule_id="$(
        printf '%s' "$existing" |
            jq -r '.id'
    )"

    [[ "$rule_id" =~ ^[0-9]+$ ]] ||
        fatal "Could not determine Anime Auto Tagging rule ID."

    desired="$(
        printf '%s' "$desired" |
            jq -c \
                --argjson id "$rule_id" '
                    .id = $id
                '
    )"

    info "Updating Sonarr Anime Auto Tagging rule."

    sonarr_put \
        "/api/v3/autotagging/$rule_id" \
        "$desired" \
        >/dev/null

    info "Anime Auto Tagging rule updated."
}


# ------------------------------------------------------------------------------
# Existing Anime series
# ------------------------------------------------------------------------------

apply_anime_tag_to_existing_series() {
    local series
    local series_id
    local updated_series
    local updated_count=0

    info "Checking existing Anime series for routing tag."

    while IFS= read -r series; do

        [[ -n "$series" ]] || continue

        if printf '%s' "$series" |
            jq -e \
                --argjson tag_id "$SONARR_ANIME_TAG_ID" '
                    (.tags // [])
                    | index($tag_id) != null
                ' \
                >/dev/null
        then
            continue
        fi

        series_id="$(
            printf '%s' "$series" |
                jq -r '.id'
        )"

        [[ "$series_id" =~ ^[0-9]+$ ]] ||
            fatal "Could not determine Anime series ID."

        updated_series="$(
            printf '%s' "$series" |
                jq -c \
                    --argjson tag_id "$SONARR_ANIME_TAG_ID" '
                        .tags =
                            (
                                (.tags // [])
                                + [$tag_id]
                                | unique
                            )
                    '
        )"

        sonarr_put \
            "/api/v3/series/$series_id" \
            "$updated_series" \
            >/dev/null

        ((updated_count += 1))

    done < <(
        sonarr_get '/api/v3/series' |
            jq -c '
                .[]
                | select(
                    (.seriesType | ascii_downcase)
                    ==
                    "anime"
                )
            '
    )

    if (( updated_count == 0 )); then
        info "Existing Anime series already have the routing tag."
    else
        info "Applied Anime routing tag to $updated_count existing series."
    fi
}


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

configure_anime_routing() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR ANIME ROUTING\n'
    printf '============================================================\n'

    ensure_anime_tag
    ensure_anime_autotag
    apply_anime_tag_to_existing_series
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_anime_routing() {
    local desired
    local existing
    local anime_count
    local missing_count

    printf '\n'
    printf '============================================================\n'
    printf 'SONARR ANIME ROUTING VERIFICATION\n'
    printf '============================================================\n'

    [[ "$SONARR_ANIME_TAG_ID" =~ ^[0-9]+$ ]] ||
        fatal "Anime routing tag is not configured."

    desired="$(build_anime_autotag_payload)"
    existing="$(get_existing_anime_autotag)"

    [[ -n "$existing" ]] ||
        fatal "Anime Auto Tagging rule is missing."

    anime_autotag_matches "$existing" "$desired" ||
        fatal "Anime Auto Tagging rule does not match desired configuration."

    anime_count="$(
        sonarr_get '/api/v3/series' |
            jq '
                [
                    .[]
                    | select(
                        (.seriesType | ascii_downcase)
                        ==
                        "anime"
                    )
                ]
                | length
            '
    )"

    missing_count="$(
        sonarr_get '/api/v3/series' |
            jq \
                --argjson tag_id "$SONARR_ANIME_TAG_ID" '
                    [
                        .[]
                        | select(
                            (.seriesType | ascii_downcase)
                            ==
                            "anime"
                        )
                        | select(
                            (
                                (.tags // [])
                                | index($tag_id)
                            )
                            ==
                            null
                        )
                    ]
                    | length
                '
    )"

    (( missing_count == 0 )) ||
        fatal "$missing_count Anime series are missing the routing tag."

    printf '\n'
    printf '    Tag:          %s\n' "$SONARR_ANIME_TAG_LABEL"
    printf '    Tag ID:       %s\n' "$SONARR_ANIME_TAG_ID"
    printf '    Anime series: %s\n' "$anime_count"
    printf '\n'

    info "Sonarr Anime routing verified."
}
