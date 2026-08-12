#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Sonarr Custom Formats
# ==============================================================================
# This file is sourced by bootstrap/sonarr/setup.sh.
#
# Desired Custom Formats are stored as small JSON definition files.
# The current Sonarr Custom Format schema is fetched at runtime.
#
# Safe to run multiple times:
#   - Missing formats are created.
#   - Existing formats with the same name are updated.
#   - Formats are never duplicated.
# ==============================================================================

CUSTOM_FORMAT_DIR="$PROJECT_ROOT/bootstrap/sonarr/custom-formats"


# ------------------------------------------------------------------------------
# Validate definition files
# ------------------------------------------------------------------------------

validate_custom_format_file() {
    local file="$1"

    [[ -f "$file" ]] ||
        fatal "Missing Custom Format definition: $file"

    jq -e '
        (.name | type == "string" and length > 0)
        and
        (.includeCustomFormatWhenRenaming | type == "boolean")
        and
        (.specifications | type == "array" and length > 0)
        and
        (.specifications[0].implementation | type == "string")
        and
        (.specifications[0].fields.value | type == "string")
    ' "$file" >/dev/null ||
        fatal "Invalid Custom Format definition: $file"
}


# ------------------------------------------------------------------------------
# Existing Custom Format lookup
# ------------------------------------------------------------------------------

get_custom_format_by_name() {
    local name="$1"

    sonarr_get '/api/v3/customformat' |
        jq -c \
            --arg name "$name" '
                .[] |
                select(.name == $name)
            ' |
        head -n 1
}


# ------------------------------------------------------------------------------
# Get current Sonarr specification schema
# ------------------------------------------------------------------------------

get_custom_format_spec_schema() {
    local implementation="$1"

    sonarr_get '/api/v3/customformat/schema' |
        jq -c \
            --arg implementation "$implementation" '
                .[] |
                select(.implementation == $implementation)
            ' |
        head -n 1
}


# ------------------------------------------------------------------------------
# Build API payload from our portable definition
# ------------------------------------------------------------------------------

build_custom_format_payload() {
    local file="$1"

    local name
    local include_when_renaming
    local implementation
    local specification_name
    local negate
    local required
    local value
    local schema
    local specification

    name="$(jq -r '.name' "$file")"

    include_when_renaming="$(
        jq -r '.includeCustomFormatWhenRenaming' "$file"
    )"

    implementation="$(
        jq -r '.specifications[0].implementation' "$file"
    )"

    specification_name="$(
        jq -r '.specifications[0].name' "$file"
    )"

    negate="$(
        jq -r '.specifications[0].negate' "$file"
    )"

    required="$(
        jq -r '.specifications[0].required' "$file"
    )"

    value="$(
        jq -r '.specifications[0].fields.value' "$file"
    )"

    schema="$(get_custom_format_spec_schema "$implementation")"

    [[ -n "$schema" ]] ||
        fatal "Sonarr specification schema '$implementation' was not found."

    specification="$(
        printf '%s' "$schema" |
            jq -c \
                --arg name "$specification_name" \
                --arg value "$value" \
                --argjson negate "$negate" \
                --argjson required "$required" '
                    .name = $name
                    | .negate = $negate
                    | .required = $required

                    | .fields |= map(
                        if .name == "value"
                        then .value = $value
                        else .
                        end
                    )

                    | del(.presets)
                '
    )"

    jq -cn \
        --arg name "$name" \
        --argjson include_when_renaming "$include_when_renaming" \
        --argjson specification "$specification" '
            {
                name: $name,
                includeCustomFormatWhenRenaming: $include_when_renaming,
                specifications: [
                    $specification
                ]
            }
        '
}


# ------------------------------------------------------------------------------
# Determine whether existing format already matches desired state
# ------------------------------------------------------------------------------

custom_format_matches() {
    local existing="$1"
    local desired="$2"

    local desired_name
    local desired_include
    local desired_implementation
    local desired_spec_name
    local desired_negate
    local desired_required
    local desired_value

    desired_name="$(printf '%s' "$desired" | jq -r '.name')"

    desired_include="$(
        printf '%s' "$desired" |
            jq -r '.includeCustomFormatWhenRenaming'
    )"

    desired_implementation="$(
        printf '%s' "$desired" |
            jq -r '.specifications[0].implementation'
    )"

    desired_spec_name="$(
        printf '%s' "$desired" |
            jq -r '.specifications[0].name'
    )"

    desired_negate="$(
        printf '%s' "$desired" |
            jq -r '.specifications[0].negate'
    )"

    desired_required="$(
        printf '%s' "$desired" |
            jq -r '.specifications[0].required'
    )"

    desired_value="$(
        printf '%s' "$desired" |
            jq -r '
                .specifications[0].fields[]
                | select(.name == "value")
                | .value
            '
    )"

    printf '%s' "$existing" |
        jq -e \
            --arg name "$desired_name" \
            --arg implementation "$desired_implementation" \
            --arg spec_name "$desired_spec_name" \
            --arg value "$desired_value" \
            --argjson include "$desired_include" \
            --argjson negate "$desired_negate" \
            --argjson required "$desired_required" '

                .name == $name

                and
                .includeCustomFormatWhenRenaming == $include

                and
                (.specifications | length) == 1

                and
                .specifications[0].implementation == $implementation

                and
                .specifications[0].name == $spec_name

                and
                .specifications[0].negate == $negate

                and
                .specifications[0].required == $required

                and
                (
                    .specifications[0].fields
                    | any(
                        .name == "value"
                        and .value == $value
                    )
                )
            ' >/dev/null
}


# ------------------------------------------------------------------------------
# Create or update one Custom Format
# ------------------------------------------------------------------------------

ensure_custom_format() {
    local file="$1"

    local name
    local existing
    local existing_id
    local payload

    validate_custom_format_file "$file"

    name="$(jq -r '.name' "$file")"

    payload="$(build_custom_format_payload "$file")"

    existing="$(get_custom_format_by_name "$name")"

    if [[ -z "$existing" ]]; then
        info "Adding Custom Format: $name"

        sonarr_post \
            '/api/v3/customformat' \
            "$payload" \
            >/dev/null

        info "$name added."
        return
    fi

    if custom_format_matches "$existing" "$payload"; then
        info "$name already matches desired configuration."
        return
    fi

    existing_id="$(
        printf '%s' "$existing" |
            jq -r '.id'
    )"

    [[ "$existing_id" =~ ^[0-9]+$ ]] ||
        fatal "Could not determine ID for Custom Format '$name'."

    payload="$(
        printf '%s' "$payload" |
            jq -c \
                --argjson id "$existing_id" '
                    .id = $id
                '
    )"

    info "Updating Custom Format: $name"

    sonarr_put \
        "/api/v3/customformat/$existing_id" \
        "$payload" \
        >/dev/null

    info "$name updated."
}


# ------------------------------------------------------------------------------
# Configure all selected Custom Formats
# ------------------------------------------------------------------------------

configure_custom_formats() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR CUSTOM FORMATS\n'
    printf '============================================================\n'

    local file
    local found=false

    shopt -s nullglob

    for file in "$CUSTOM_FORMAT_DIR"/*.json; do
        found=true
        ensure_custom_format "$file"
    done

    shopt -u nullglob

    if [[ "$found" == false ]]; then
        warn "No Sonarr Custom Format JSON files were found in:"
        warn "    $CUSTOM_FORMAT_DIR"
    fi

    info "Custom Format configuration finished."
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_custom_formats() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR CUSTOM FORMAT VERIFICATION\n'
    printf '============================================================\n'

    local file
    local name
    local existing
    local desired
    local found=false

    shopt -s nullglob

    for file in "$CUSTOM_FORMAT_DIR"/*.json; do
        found=true

        name="$(jq -r '.name' "$file")"
        existing="$(get_custom_format_by_name "$name")"

        if [[ -z "$existing" ]]; then
            warn "$name is missing from Sonarr."
            continue
        fi

        desired="$(build_custom_format_payload "$file")"

        if custom_format_matches "$existing" "$desired"; then
            info "$name verified."
        else
            warn "$name exists but does not match the desired configuration."
        fi
    done

    shopt -u nullglob

    if [[ "$found" == false ]]; then
        warn "No Sonarr Custom Format JSON files were found in:"
        warn "    $CUSTOM_FORMAT_DIR"
    fi
}
