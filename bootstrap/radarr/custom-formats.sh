#!/usr/bin/env bash

CUSTOM_FORMAT_DIR="$PROJECT_ROOT/bootstrap/radarr/custom-formats"


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
        all(
            .specifications[];
            (.name | type == "string" and length > 0)
            and
            (.implementation | type == "string" and length > 0)
            and
            (.negate | type == "boolean")
            and
            (.required | type == "boolean")
            and
            (.fields | type == "object")
        )
    ' "$file" >/dev/null ||
        fatal "Invalid Custom Format definition: $file"
}


get_custom_format_by_name() {
    local name="$1"

    radarr_get '/api/v3/customformat' |
        jq -c \
            --arg name "$name" '
                .[]
                | select(.name == $name)
            ' |
        head -n 1
}


get_custom_format_spec_schema() {
    local implementation="$1"

    radarr_get '/api/v3/customformat/schema' |
        jq -c \
            --arg implementation "$implementation" '
                .[]
                | select(.implementation == $implementation)
            ' |
        head -n 1
}


build_custom_format_payload() {
    local file="$1"

    local name
    local include_when_renaming
    local specifications
    local definition
    local implementation
    local specification_name
    local negate
    local required
    local fields
    local schema
    local specification

    name="$(jq -r '.name' "$file")"

    include_when_renaming="$(
        jq -r '.includeCustomFormatWhenRenaming' "$file"
    )"

    specifications='[]'

    while IFS= read -r definition; do

        implementation="$(
            printf '%s' "$definition" |
                jq -r '.implementation'
        )"

        specification_name="$(
            printf '%s' "$definition" |
                jq -r '.name'
        )"

        negate="$(
            printf '%s' "$definition" |
                jq -r '.negate'
        )"

        required="$(
            printf '%s' "$definition" |
                jq -r '.required'
        )"

        fields="$(
            printf '%s' "$definition" |
                jq -c '.fields'
        )"

        schema="$(
            get_custom_format_spec_schema "$implementation"
        )"

        [[ -n "$schema" ]] ||
            fatal "Radarr specification schema '$implementation' was not found."

        specification="$(
            printf '%s' "$schema" |
                jq -c \
                    --arg name "$specification_name" \
                    --argjson fields "$fields" \
                    --argjson negate "$negate" \
                    --argjson required "$required" '

                        .name = $name
                        | .negate = $negate
                        | .required = $required

                        | .fields |= map(
                            .name as $field_name

                            | if ($fields | has($field_name))
                              then
                                  .value = $fields[$field_name]
                              else
                                  .
                              end
                        )

                        | del(.presets)
                    '
        )"

        specifications="$(
            printf '%s' "$specifications" |
                jq -c \
                    --argjson specification "$specification" '
                        . + [$specification]
                    '
        )"

    done < <(
        jq -c '.specifications[]' "$file"
    )

    jq -cn \
        --arg name "$name" \
        --argjson include "$include_when_renaming" \
        --argjson specifications "$specifications" '
            {
                name: $name,
                includeCustomFormatWhenRenaming: $include,
                specifications: $specifications
            }
        '
}


custom_format_matches() {
    local existing="$1"
    local desired="$2"

    jq -n -e \
        --argjson existing "$existing" \
        --argjson desired "$desired" '

            def normalize_spec:
                {
                    name,
                    implementation,
                    negate,
                    required,

                    fields:
                        (
                            (.fields // [])
                            | map({
                                name: .name,
                                value: .value
                            })
                            | sort_by(.name)
                        )
                };

            (
                {
                    name:
                        $existing.name,

                    include:
                        $existing.includeCustomFormatWhenRenaming,

                    specifications:
                        (
                            $existing.specifications
                            | map(normalize_spec)
                            | sort_by(.implementation, .name)
                        )
                }
            )

            ==

            (
                {
                    name:
                        $desired.name,

                    include:
                        $desired.includeCustomFormatWhenRenaming,

                    specifications:
                        (
                            $desired.specifications
                            | map(normalize_spec)
                            | sort_by(.implementation, .name)
                        )
                }
            )
        ' >/dev/null
}


ensure_custom_format() {
    local file="$1"

    local name
    local existing
    local existing_id
    local payload

    validate_custom_format_file "$file"

    name="$(jq -r '.name' "$file")"

    payload="$(
        build_custom_format_payload "$file"
    )"

    existing="$(
        get_custom_format_by_name "$name"
    )"

    if [[ -z "$existing" ]]; then
        info "Adding Custom Format: $name"

        radarr_post \
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

    radarr_put \
        "/api/v3/customformat/$existing_id" \
        "$payload" \
        >/dev/null

    info "$name updated."
}


configure_custom_formats() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR CUSTOM FORMATS\n'
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
        warn "No Radarr Custom Format JSON files were found in:"
        warn "    $CUSTOM_FORMAT_DIR"
        return
    fi

    info "Custom Format configuration finished."
}


verify_custom_formats() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR CUSTOM FORMAT VERIFICATION\n'
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

        existing="$(
            get_custom_format_by_name "$name"
        )"

        if [[ -z "$existing" ]]; then
            warn "$name is missing from Radarr."
            continue
        fi

        desired="$(
            build_custom_format_payload "$file"
        )"

        if custom_format_matches "$existing" "$desired"; then
            info "$name verified."
        else
            warn "$name exists but does not match the desired configuration."
        fi
    done

    shopt -u nullglob

    if [[ "$found" == false ]]; then
        warn "No Radarr Custom Format JSON files were found."
    fi
}
