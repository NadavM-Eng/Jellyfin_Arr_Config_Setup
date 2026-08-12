#!/usr/bin/env bash

PROFILE_DIR="$PROJECT_ROOT/bootstrap/radarr/profiles"


validate_profile_file() {
    local file="$1"

    [[ -f "$file" ]] ||
        fatal "Missing Quality Profile definition: $file"

    jq -e '
        (.name | type == "string" and length > 0)

        and

        ((.baseProfile // "Any") | type == "string")

        and

        ((.upgradeAllowed // true) | type == "boolean")

        and

        ((.upgradeUntilQuality // "") | type == "string")

        and

        ((.enableQualities // []) | type == "array")

        and

        ((.manageQualitiesExactly // false) | type == "boolean")

        and

        (.language | type == "string" and length > 0)

        and

        ((.minFormatScore // 0) | type == "number")

        and

        ((.cutoffFormatScore // 0) | type == "number")

        and

        ((.minUpgradeFormatScore // 1) | type == "number")

        and

        (.customFormatScores | type == "object")
    ' "$file" >/dev/null ||
        fatal "Invalid Quality Profile definition: $file"
}


get_quality_profile_by_name() {
    local name="$1"

    radarr_get '/api/v3/qualityprofile' |
        jq -c \
            --arg name "$name" '
                .[]
                | select(.name == $name)
            ' |
        head -n 1
}


get_language_by_name() {
    local name="$1"

    radarr_get '/api/v3/language' |
        jq -c \
            --arg name "$name" '
                .[]
                | select(.name == $name)
            ' |
        head -n 1
}


validate_profile_custom_formats() {
    local file="$1"

    local profile_name
    local scores
    local custom_formats
    local missing

    profile_name="$(jq -r '.name' "$file")"
    scores="$(jq -c '.customFormatScores' "$file")"

    custom_formats="$(
        radarr_get '/api/v3/customformat'
    )"

    missing="$(
        jq -nr \
            --argjson scores "$scores" \
            --argjson custom_formats "$custom_formats" '

                ($custom_formats | map(.name)) as $existing

                | ($scores | keys[])

                | select(
                    . as $name
                    | $existing
                    | index($name) == null
                )
            '
    )"

    if [[ -n "$missing" ]]; then
        warn "Profile '$profile_name' references missing Custom Formats:"

        while IFS= read -r name; do
            warn "    $name"
        done <<< "$missing"

        fatal "Create the missing Custom Formats before configuring profiles."
    fi
}


build_profile_format_items() {
    local file="$1"

    local scores
    local custom_formats

    scores="$(jq -c '.customFormatScores' "$file")"

    custom_formats="$(
        radarr_get '/api/v3/customformat'
    )"

    printf '%s' "$custom_formats" |
        jq -c \
            --argjson scores "$scores" '
                map({
                    format: .id,
                    name: .name,
                    score: ($scores[.name] // 0)
                })
            '
}


apply_profile_policy() {
    local profile="$1"
    local file="$2"
    local format_items="$3"
    local language="$4"

    local upgrade_allowed
    local upgrade_until_quality
    local enable_qualities
    local manage_exact

    local min_format_score
    local cutoff_format_score
    local min_upgrade_format_score

    upgrade_allowed="$(
        jq -r '.upgradeAllowed // true' "$file"
    )"

    upgrade_until_quality="$(
        jq -r '.upgradeUntilQuality // ""' "$file"
    )"

    enable_qualities="$(
        jq -c '.enableQualities // []' "$file"
    )"

    manage_exact="$(
        jq -r '.manageQualitiesExactly // false' "$file"
    )"

    min_format_score="$(
        jq -r '.minFormatScore // 0' "$file"
    )"

    cutoff_format_score="$(
        jq -r '.cutoffFormatScore // 0' "$file"
    )"

    min_upgrade_format_score="$(
        jq -r '.minUpgradeFormatScore // 1' "$file"
    )"

    printf '%s' "$profile" |
        jq -c \
            --arg upgrade_until_quality "$upgrade_until_quality" \
            --argjson enable_qualities "$enable_qualities" \
            --argjson manage_exact "$manage_exact" \
            --argjson format_items "$format_items" \
            --argjson language "$language" \
            --argjson upgrade_allowed "$upgrade_allowed" \
            --argjson min_format_score "$min_format_score" \
            --argjson cutoff_format_score "$cutoff_format_score" \
            --argjson min_upgrade_format_score "$min_upgrade_format_score" '

                def item_name:
                    if .quality != null
                    then .quality.name
                    else .name
                    end;

                def item_cutoff_id:
                    if .quality != null
                    then .quality.id
                    else .id
                    end;


                .formatItems = $format_items

                | .language = $language

                | .upgradeAllowed = $upgrade_allowed

                | .minFormatScore = $min_format_score

                | .cutoffFormatScore = $cutoff_format_score

                | .minUpgradeFormatScore =
                    $min_upgrade_format_score


                | .items |= map(

                    . as $item

                    | ($item | item_name) as $name

                    | if ($enable_qualities | index($name)) != null
                      then

                          .allowed = true

                          | if ((.items // []) | length) > 0
                            then
                                .items |= map(.allowed = true)
                            else
                                .
                            end

                      elif $manage_exact
                      then

                          .allowed = false

                          | if ((.items // []) | length) > 0
                            then
                                .items |= map(.allowed = false)
                            else
                                .
                            end

                      else
                          .
                      end
                )


                | if $upgrade_until_quality != ""
                  then

                      (
                          [
                              .items[]

                              | select(
                                  item_name ==
                                  $upgrade_until_quality
                              )

                              | item_cutoff_id
                          ]

                          | first
                      ) as $cutoff_id

                      | if $cutoff_id == null
                        then
                            error(
                                "Quality not found for Upgrade Until: "
                                + $upgrade_until_quality
                            )
                        else
                            .cutoff = $cutoff_id
                        end

                  else
                      .
                  end
            '
}


profile_matches() {
    local existing="$1"
    local file="$2"
    local desired_items="$3"
    local language="$4"

    local desired

    desired="$(
        apply_profile_policy \
            "$existing" \
            "$file" \
            "$desired_items" \
            "$language"
    )"

    printf '%s' "$existing" |
        jq -e \
            --argjson desired "$desired" '

                .upgradeAllowed ==
                    $desired.upgradeAllowed

                and

                .cutoff ==
                    $desired.cutoff

                and

                .language.id ==
                    $desired.language.id

                and

                .minFormatScore ==
                    $desired.minFormatScore

                and

                .cutoffFormatScore ==
                    $desired.cutoffFormatScore

                and

                .minUpgradeFormatScore ==
                    $desired.minUpgradeFormatScore

                and

                .items ==
                    $desired.items

                and

                (
                    (
                        (.formatItems // [])
                        | map({
                            format: .format,
                            score: .score
                        })
                        | sort_by(.format)
                    )

                    ==

                    (
                        ($desired.formatItems // [])
                        | map({
                            format: .format,
                            score: .score
                        })
                        | sort_by(.format)
                    )
                )
            ' >/dev/null
}


ensure_quality_profile() {
    local file="$1"

    local name
    local base_profile_name
    local language_name

    local existing
    local base_profile
    local language

    local profile_id
    local format_items
    local new_profile
    local payload

    validate_profile_file "$file"
    validate_profile_custom_formats "$file"

    name="$(jq -r '.name' "$file")"

    base_profile_name="$(
        jq -r '.baseProfile // "Any"' "$file"
    )"

    language_name="$(
        jq -r '.language' "$file"
    )"

    language="$(
        get_language_by_name "$language_name"
    )"

    [[ -n "$language" ]] ||
        fatal "Radarr language '$language_name' was not found."

    format_items="$(
        build_profile_format_items "$file"
    )"

    existing="$(
        get_quality_profile_by_name "$name"
    )"


    if [[ -n "$existing" ]]; then

        if profile_matches \
            "$existing" \
            "$file" \
            "$format_items" \
            "$language"
        then
            info "$name profile already matches desired configuration."
            return
        fi

        profile_id="$(
            printf '%s' "$existing" |
                jq -r '.id'
        )"

        [[ "$profile_id" =~ ^[0-9]+$ ]] ||
            fatal "Could not determine Quality Profile ID for '$name'."

        payload="$(
            apply_profile_policy \
                "$existing" \
                "$file" \
                "$format_items" \
                "$language"
        )"

        info "Updating Quality Profile: $name"

        radarr_put \
            "/api/v3/qualityprofile/$profile_id" \
            "$payload" \
            >/dev/null

        info "$name profile updated."
        return
    fi


    info "Quality Profile '$name' does not exist."
    info "Creating it from base profile: $base_profile_name"

    base_profile="$(
        get_quality_profile_by_name "$base_profile_name"
    )"

    [[ -n "$base_profile" ]] ||
        fatal "Base Quality Profile '$base_profile_name' was not found."

    new_profile="$(
        printf '%s' "$base_profile" |
            jq -c \
                --arg name "$name" '
                    del(.id)
                    | .name = $name
                '
    )"

    payload="$(
        apply_profile_policy \
            "$new_profile" \
            "$file" \
            "$format_items" \
            "$language"
    )"

    radarr_post \
        '/api/v3/qualityprofile' \
        "$payload" \
        >/dev/null

    info "$name profile created."
}


configure_quality_profiles() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR QUALITY PROFILES\n'
    printf '============================================================\n'

    local file
    local found=false

    shopt -s nullglob

    for file in "$PROFILE_DIR"/*.json; do
        found=true
        ensure_quality_profile "$file"
    done

    shopt -u nullglob

    if [[ "$found" == false ]]; then
        warn "No Radarr Quality Profile JSON files were found."
        return
    fi

    info "Quality Profile configuration finished."
}


get_profile_cutoff_name() {
    local profile="$1"

    printf '%s' "$profile" |
        jq -r '

            def flatten_items:
                .[]
                | .,
                  (
                      (.items // [])
                      | flatten_items
                  );

            .cutoff as $cutoff

            |

            [
                .items
                | flatten_items

                | select(
                    (
                        if .quality != null
                        then .quality.id
                        else .id
                        end
                    )
                    == $cutoff
                )

                |
                (
                    if .quality != null
                    then .quality.name
                    else .name
                    end
                )
            ]

            | first // "Unknown"
        '
}


verify_quality_profiles() {
    printf '\n'
    printf '============================================================\n'
    printf 'RADARR QUALITY PROFILE VERIFICATION\n'
    printf '============================================================\n'

    local file
    local name
    local language_name
    local existing
    local language
    local desired_items
    local cutoff_name

    shopt -s nullglob

    for file in "$PROFILE_DIR"/*.json; do

        name="$(jq -r '.name' "$file")"
        language_name="$(jq -r '.language' "$file")"

        existing="$(
            get_quality_profile_by_name "$name"
        )"

        [[ -n "$existing" ]] || {
            warn "$name profile is missing from Radarr."
            continue
        }

        language="$(
            get_language_by_name "$language_name"
        )"

        desired_items="$(
            build_profile_format_items "$file"
        )"

        if ! profile_matches \
            "$existing" \
            "$file" \
            "$desired_items" \
            "$language"
        then
            warn "$name profile does not match desired configuration."
            continue
        fi

        info "$name profile verified."

        cutoff_name="$(
            get_profile_cutoff_name "$existing"
        )"

        printf '\n'
        printf '    Language:                    %s\n' \
            "$(printf '%s' "$existing" | jq -r '.language.name')"

        printf '    Upgrade Allowed:             %s\n' \
            "$(printf '%s' "$existing" | jq -r '.upgradeAllowed')"

        printf '    Upgrade Until Quality:       %s\n' \
            "$cutoff_name"

        printf '    Minimum CF Score:            %s\n' \
            "$(printf '%s' "$existing" | jq -r '.minFormatScore')"

        printf '    Upgrade Until CF Score:      %s\n' \
            "$(printf '%s' "$existing" | jq -r '.cutoffFormatScore')"

        printf '    Minimum Upgrade Increment:   %s\n' \
            "$(printf '%s' "$existing" | jq -r '.minUpgradeFormatScore')"

        printf '\n    Custom Format scores:\n'

        printf '%s' "$existing" |
            jq -r '
                .formatItems
                | sort_by(.name)
                | .[]
                | "    \(.name): \(.score)"
            '

        printf '\n'
    done

    shopt -u nullglob
}
