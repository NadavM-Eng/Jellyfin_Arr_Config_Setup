#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Sonarr Quality Profiles
# ==============================================================================
#
# Profiles are defined by JSON files inside:
#
#   bootstrap/sonarr/profiles/
#
# The loader:
#   - Scans every *.json file automatically.
#   - Creates missing profiles from their configured base profile.
#   - Preserves existing Quality configuration unless explicitly managed.
#   - Can enable additional qualities by name.
#   - Can configure the normal Quality "Upgrade Until" cutoff by name.
#   - Resolves Custom Formats dynamically by name.
#   - Includes EVERY Sonarr Custom Format in each managed profile.
#   - Unspecified Custom Formats receive score 0.
#   - Configures Custom Format upgrade behavior.
#   - Updates existing profiles without duplicating them.
#
# No Sonarr Quality IDs or Custom Format IDs are hardcoded.
# ==============================================================================

PROFILE_DIR="$PROJECT_ROOT/bootstrap/sonarr/profiles"


# ------------------------------------------------------------------------------
# Validate profile definition
# ------------------------------------------------------------------------------

validate_profile_file() {
    local file="$1"

    [[ -f "$file" ]] ||
        fatal "Missing Quality Profile definition: $file"

    jq -e '
        (.name | type == "string" and length > 0)

        and

        (
            (.baseProfile // "Any")
            | type == "string" and length > 0
        )

        and

        (
            (.upgradeAllowed // true)
            | type == "boolean"
        )

        and

        (
            (.upgradeUntilQuality // "")
            | type == "string"
        )

        and

        (
            (.enableQualities // [])
            | type == "array"
        )

        and

        all(
            (.enableQualities // [])[];
            type == "string" and length > 0
        )

        and

        (
            (.minFormatScore // 0)
            | type == "number"
              and floor == .
        )

        and

        (
            (.cutoffFormatScore // 0)
            | type == "number"
              and floor == .
        )

        and

        (
            (.minUpgradeFormatScore // 1)
            | type == "number"
              and floor == .
              and . >= 1
        )

        and

        (.customFormatScores | type == "object")

        and

        all(
            .customFormatScores[];
            type == "number"
            and floor == .
        )
    ' "$file" >/dev/null ||
        fatal "Invalid Quality Profile definition: $file"
}


# ------------------------------------------------------------------------------
# Quality Profile lookup
# ------------------------------------------------------------------------------

get_quality_profile_by_name() {
    local name="$1"

    sonarr_get '/api/v3/qualityprofile' |
        jq -c \
            --arg name "$name" '
                .[]
                | select(.name == $name)
            ' |
        head -n 1
}


# ------------------------------------------------------------------------------
# Validate referenced Custom Formats
# ------------------------------------------------------------------------------

validate_profile_custom_formats() {
    local file="$1"

    local profile_name
    local scores
    local custom_formats
    local missing

    profile_name="$(jq -r '.name' "$file")"
    scores="$(jq -c '.customFormatScores' "$file")"

    custom_formats="$(
        sonarr_get '/api/v3/customformat'
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
        warn "Profile '$profile_name' references Custom Formats that do not exist:"

        while IFS= read -r name; do
            warn "    $name"
        done <<< "$missing"

        fatal "Create the missing Custom Formats before configuring Quality Profiles."
    fi
}


# ------------------------------------------------------------------------------
# Build complete formatItems dynamically
# ------------------------------------------------------------------------------

build_profile_format_items() {
    local file="$1"

    local scores
    local custom_formats

    scores="$(
        jq -c '.customFormatScores' "$file"
    )"

    custom_formats="$(
        sonarr_get '/api/v3/customformat'
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


# ------------------------------------------------------------------------------
# Apply Quality + Custom Format profile policy
# ------------------------------------------------------------------------------

apply_profile_policy() {
    local profile="$1"
    local file="$2"
    local format_items="$3"

    local upgrade_allowed
    local upgrade_until_quality
    local enable_qualities

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
            --argjson format_items "$format_items" \
            --argjson upgrade_allowed "$upgrade_allowed" \
            --argjson min_format_score "$min_format_score" \
            --argjson cutoff_format_score "$cutoff_format_score" \
            --argjson min_upgrade_format_score "$min_upgrade_format_score" '

                # --------------------------------------------------------------
                # Helpers
                # --------------------------------------------------------------

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


                # --------------------------------------------------------------
                # Custom Format policy
                # --------------------------------------------------------------

                .formatItems = $format_items

                | .upgradeAllowed =
                    $upgrade_allowed

                | .minFormatScore =
                    $min_format_score

                | .cutoffFormatScore =
                    $cutoff_format_score

                | .minUpgradeFormatScore =
                    $min_upgrade_format_score


                # --------------------------------------------------------------
                # Enable requested qualities.
                #
                # This is ADDITIVE.
                #
                # Existing enabled qualities are preserved.
                # --------------------------------------------------------------

                | .items |= map(

                    . as $item

                    | ($item | item_name) as $name

                    | if ($enable_qualities | index($name)) != null
                      then

                          .allowed = true

                          |

                          if (
                              (.items // [])
                              | length
                          ) > 0
                          then
                              .items |= map(
                                  .allowed = true
                              )
                          else
                              .
                          end

                      else
                          .
                      end
                )


                # --------------------------------------------------------------
                # Configure normal Quality "Upgrade Until"
                # --------------------------------------------------------------

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

                      |

                      if $cutoff_id == null
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


# ------------------------------------------------------------------------------
# Compare managed profile state
# ------------------------------------------------------------------------------

profile_matches() {
    local existing="$1"
    local file="$2"
    local desired_items="$3"

    local desired

    desired="$(
        apply_profile_policy \
            "$existing" \
            "$file" \
            "$desired_items"
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

                .minFormatScore ==
                    $desired.minFormatScore

                and

                .cutoffFormatScore ==
                    $desired.cutoffFormatScore

                and

                .minUpgradeFormatScore ==
                    $desired.minUpgradeFormatScore

                and

                (
                    .items ==
                    $desired.items
                )

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


# ------------------------------------------------------------------------------
# Create or update one Quality Profile
# ------------------------------------------------------------------------------

ensure_quality_profile() {
    local file="$1"

    local name
    local base_profile_name

    local existing
    local base_profile

    local profile_id
    local format_items

    local new_profile
    local payload

    validate_profile_file "$file"
    validate_profile_custom_formats "$file"

    name="$(
        jq -r '.name' "$file"
    )"

    base_profile_name="$(
        jq -r '.baseProfile // "Any"' "$file"
    )"

    format_items="$(
        build_profile_format_items "$file"
    )"

    existing="$(
        get_quality_profile_by_name "$name"
    )"


    # --------------------------------------------------------------------------
    # Existing profile
    # --------------------------------------------------------------------------

    if [[ -n "$existing" ]]; then

        if profile_matches \
            "$existing" \
            "$file" \
            "$format_items"
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
                "$format_items"
        )"

        info "Updating Quality Profile: $name"

        sonarr_put \
            "/api/v3/qualityprofile/$profile_id" \
            "$payload" \
            >/dev/null

        info "$name profile updated."
        return
    fi


    # --------------------------------------------------------------------------
    # New profile
    #
    # Clone configured base profile first.
    # --------------------------------------------------------------------------

    info "Quality Profile '$name' does not exist."
    info "Creating it from base profile: $base_profile_name"

    base_profile="$(
        get_quality_profile_by_name "$base_profile_name"
    )"

    if [[ -z "$base_profile" ]]; then
        warn "Base Quality Profile '$base_profile_name' was not found."
        warn "Available Quality Profiles:"

        sonarr_get '/api/v3/qualityprofile' |
            jq -r '.[] | "    \(.name)"' >&2

        fatal "Cannot create Quality Profile '$name'."
    fi


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
            "$format_items"
    )"


    sonarr_post \
        '/api/v3/qualityprofile' \
        "$payload" \
        >/dev/null

    info "$name profile created."
}


# ------------------------------------------------------------------------------
# Configure every profile JSON file
# ------------------------------------------------------------------------------

configure_quality_profiles() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR QUALITY PROFILES\n'
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
        warn "No Sonarr Quality Profile JSON files were found in:"
        warn "    $PROFILE_DIR"
        return
    fi


    info "Quality Profile configuration finished."
}


# ------------------------------------------------------------------------------
# Print configured Upgrade Until Quality
# ------------------------------------------------------------------------------

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


# ------------------------------------------------------------------------------
# Verify every managed profile
# ------------------------------------------------------------------------------

verify_quality_profiles() {
    printf '\n'
    printf '============================================================\n'
    printf 'SONARR QUALITY PROFILE VERIFICATION\n'
    printf '============================================================\n'

    local file
    local name

    local existing
    local desired_items

    local cutoff_name
    local found=false

    shopt -s nullglob


    for file in "$PROFILE_DIR"/*.json; do
        found=true

        name="$(
            jq -r '.name' "$file"
        )"

        existing="$(
            get_quality_profile_by_name "$name"
        )"

        if [[ -z "$existing" ]]; then
            warn "$name profile is missing from Sonarr."
            continue
        fi


        desired_items="$(
            build_profile_format_items "$file"
        )"


        if profile_matches \
            "$existing" \
            "$file" \
            "$desired_items"
        then
            info "$name profile verified."
        else
            warn "$name profile exists but does not match desired configuration."
            continue
        fi


        cutoff_name="$(
            get_profile_cutoff_name "$existing"
        )"


        printf '\n'

        printf '    Quality policy:\n'
        printf '    Upgrade Allowed:             %s\n' \
            "$(printf '%s' "$existing" | jq -r '.upgradeAllowed')"

        printf '    Upgrade Until Quality:       %s\n' \
            "$cutoff_name"


        printf '\n'

        printf '    Custom Format policy:\n'

        printf '    Minimum Score:               %s\n' \
            "$(printf '%s' "$existing" | jq -r '.minFormatScore')"

        printf '    Upgrade Until CF Score:      %s\n' \
            "$(printf '%s' "$existing" | jq -r '.cutoffFormatScore')"

        printf '    Minimum Upgrade Increment:   %s\n' \
            "$(printf '%s' "$existing" | jq -r '.minUpgradeFormatScore')"


        printf '\n'

        printf '    Enabled requested qualities:\n'

        jq -r \
            '.enableQualities[]? | "    - \(.)"' \
            "$file"


        printf '\n'

        printf '    Custom Format scores:\n'

        printf '%s' "$existing" |
            jq -r '
                .formatItems
                | sort_by(.name)[]
                | "    \(.name): \(.score)"
            '

        printf '\n'
    done


    shopt -u nullglob


    if [[ "$found" == false ]]; then
        warn "No Sonarr Quality Profile JSON files were found in:"
        warn "    $PROFILE_DIR"
    fi
}
