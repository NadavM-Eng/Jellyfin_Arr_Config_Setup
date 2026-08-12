#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# MasterBuilder - Bazarr Quick Configuration
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

: "${CONFIG_ROOT:?CONFIG_ROOT is missing from .env}"

BAZARR_PORT="${BAZARR_PORT:-6767}"
BAZARR_HOST_URL="http://localhost:${BAZARR_PORT}"

BAZARR_PROFILE_NAME="English + Hebrew"

BAZARR_OPENSUBTITLES_USERNAME="${BAZARR_OPENSUBTITLES_USERNAME:-}"
BAZARR_OPENSUBTITLES_PASSWORD="${BAZARR_OPENSUBTITLES_PASSWORD:-}"


# ------------------------------------------------------------------------------
# Configuration discovery
# ------------------------------------------------------------------------------

find_bazarr_config() {
    local config

    config="$(
        find "$CONFIG_ROOT/bazarr" \
            -maxdepth 3 \
            -type f \
            -name 'config.yaml' \
            -print \
            -quit \
            2>/dev/null \
            || true
    )"

    printf '%s' "$config"
}


wait_for_bazarr_config() {
    local waited=0
    local config=""

    info "Waiting for Bazarr configuration..." >&2

    while (( waited < 120 )); do

        config="$(find_bazarr_config)"

        if [[ -n "$config" && -s "$config" ]]; then
            printf '%s' "$config"
            return
        fi

        sleep 2
        ((waited += 2))
    done

    fatal "Bazarr config.yaml did not appear."
}


read_bazarr_api_key() {
    local config="$1"
    local key

    key="$(
        awk '
            /^[[:space:]]*auth:[[:space:]]*$/ {
                in_auth = 1
                next
            }

            in_auth && /^[^[:space:]]/ {
                in_auth = 0
            }

            in_auth && /^[[:space:]]+apikey:[[:space:]]*/ {
                sub(/^[[:space:]]+apikey:[[:space:]]*/, "")
                gsub(/^["'\'']|["'\'']$/, "")
                print
                exit
            }
        ' "$config"
    )"

    [[ -n "$key" ]] ||
        fatal "Could not read Bazarr API key."

    printf '%s' "$key"
}


BAZARR_CONFIG="$(wait_for_bazarr_config)"
BAZARR_API_KEY="$(read_bazarr_api_key "$BAZARR_CONFIG")"


# ------------------------------------------------------------------------------
# Sonarr / Radarr API keys
# ------------------------------------------------------------------------------

read_arr_api_key() {
    local app="$1"
    local config="$CONFIG_ROOT/$app/config.xml"
    local waited=0
    local key

    while [[ ! -s "$config" ]]; do

        if (( waited >= 120 )); then
            fatal "$app config.xml did not appear: $config"
        fi

        sleep 2
        ((waited += 2))
    done

    key="$(
        sed -n \
            's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
            "$config" |
            head -n 1
    )"

    [[ -n "$key" ]] ||
        fatal "Could not read $app API key."

    printf '%s' "$key"
}


SONARR_API_KEY="$(read_arr_api_key sonarr)"
RADARR_API_KEY="$(read_arr_api_key radarr)"


# ------------------------------------------------------------------------------
# Bazarr API
# ------------------------------------------------------------------------------

bazarr_get() {
    local endpoint="$1"

    curl -fsS \
        -H "X-API-KEY: $BAZARR_API_KEY" \
        "$BAZARR_HOST_URL/api$endpoint"
}


bazarr_settings_post() {
    curl -fsS \
        -X POST \
        -H "X-API-KEY: $BAZARR_API_KEY" \
        "$BAZARR_HOST_URL/api/system/settings" \
        "$@"
}


wait_for_bazarr() {
    local waited=0

    info "Waiting for Bazarr API..."

    until bazarr_get '/system/status' >/dev/null 2>&1; do

        if (( waited >= 120 )); then
            fatal "Bazarr API did not become ready."
        fi

        sleep 2
        ((waited += 2))
    done

    info "Bazarr API is ready."
}


# ------------------------------------------------------------------------------
# Stage 1 - Languages + profile
# ------------------------------------------------------------------------------

build_language_profiles() {
    local existing_profiles
    local existing_id
    local profile_id
    local desired_profile

    existing_profiles="$(
        bazarr_get '/system/languages/profiles'
    )"

    existing_id="$(
        printf '%s' "$existing_profiles" |
            jq -r \
                --arg name "$BAZARR_PROFILE_NAME" '
                    [
                        .[]
                        | select(.name == $name)
                        | .profileId
                    ]
                    | first // empty
                '
    )"

    if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
        profile_id="$existing_id"
    else
        profile_id="$(
            printf '%s' "$existing_profiles" |
                jq -r '
                    (
                        [
                            .[].profileId
                        ]
                        | max // 0
                    ) + 1
                '
        )"
    fi

    desired_profile="$(
        jq -cn \
            --arg name "$BAZARR_PROFILE_NAME" \
            --argjson profile_id "$profile_id" '
                {
                    profileId: $profile_id,
                    name: $name,
                    tag: null,

                    items: [
                        {
                            id: 1,
                            language: "en",
                            audio_exclude: "False",
                            audio_only_include: "False",
                            hi: "False",
                            forced: "False"
                        },
                        {
                            id: 2,
                            language: "he",
                            audio_exclude: "False",
                            audio_only_include: "False",
                            hi: "False",
                            forced: "False"
                        }
                    ],

                    cutoff: null,
                    mustContain: [],
                    mustNotContain: [],
                    originalFormat: false
                }
            '
    )"

    BAZARR_PROFILE_ID="$profile_id"

    BAZARR_LANGUAGE_PROFILES="$(
        printf '%s' "$existing_profiles" |
            jq -c \
                --arg name "$BAZARR_PROFILE_NAME" \
                --argjson desired "$desired_profile" '

                    [
                        .[]
                        | select(.name != $name)
                    ]
                    + [$desired]
                '
    )"
}


configure_languages() {
    printf '\n'
    printf '============================================================\n'
    printf 'BAZARR LANGUAGE PROFILE\n'
    printf '============================================================\n'

    local languages
    local enabled_languages=()

    build_language_profiles

    mapfile -t enabled_languages < <(
        bazarr_get '/system/languages' |
            jq -r '
                .[]
                | select(
                    .enabled == true
                    or
                    .code2 == "en"
                    or
                    .code2 == "he"
                )
                | .code2
            ' |
            sort -u
    )

    local args=()

    local language

    for language in "${enabled_languages[@]}"; do
        args+=(
            --data-urlencode
            "languages-enabled=$language"
        )
    done

    args+=(
        --data-urlencode
        "languages-profiles=$BAZARR_LANGUAGE_PROFILES"

        --data-urlencode
        "settings-general-serie_default_enabled=true"

        --data-urlencode
        "settings-general-serie_default_profile=$BAZARR_PROFILE_ID"

        --data-urlencode
        "settings-general-movie_default_enabled=true"

        --data-urlencode
        "settings-general-movie_default_profile=$BAZARR_PROFILE_ID"
    )

    bazarr_settings_post "${args[@]}" >/dev/null

    info "English enabled."
    info "Hebrew enabled."
    info "'$BAZARR_PROFILE_NAME' profile configured."
    info "Profile set as default for new Series."
    info "Profile set as default for new Movies."
}


# ------------------------------------------------------------------------------
# Stage 2 - OpenSubtitles.com
# ------------------------------------------------------------------------------

configure_provider() {
    printf '\n'
    printf '============================================================\n'
    printf 'BAZARR PROVIDERS\n'
    printf '============================================================\n'

    if [[ -z "$BAZARR_OPENSUBTITLES_USERNAME" ||
          -z "$BAZARR_OPENSUBTITLES_PASSWORD" ]]
    then
        warn "OpenSubtitles.com credentials are missing."
        warn "OpenSubtitles.com provider will not be enabled."
        return
    fi

    local settings
    local providers=()

    settings="$(
        bazarr_get '/system/settings'
    )"

    mapfile -t providers < <(
        printf '%s' "$settings" |
            jq -r '
                (
                    .general.enabled_providers // []
                )
                + ["opensubtitlescom"]
                | unique[]
            '
    )

    local args=()
    local provider

    for provider in "${providers[@]}"; do
        args+=(
            --data-urlencode
            "settings-general-enabled_providers=$provider"
        )
    done

    args+=(
        --data-urlencode
        "settings-opensubtitlescom-username=$BAZARR_OPENSUBTITLES_USERNAME"

        --data-urlencode
        "settings-opensubtitlescom-password=$BAZARR_OPENSUBTITLES_PASSWORD"

        --data-urlencode
        "settings-opensubtitlescom-use_hash=true"

        --data-urlencode
        "settings-opensubtitlescom-include_ai_translated=false"

        --data-urlencode
        "settings-opensubtitlescom-include_machine_translated=false"
    )

    bazarr_settings_post "${args[@]}" >/dev/null

    info "OpenSubtitles.com configured."
}


# ------------------------------------------------------------------------------
# Stage 3 - Subtitle behavior
# ------------------------------------------------------------------------------

configure_subtitles() {
    printf '\n'
    printf '============================================================\n'
    printf 'BAZARR SUBTITLE SETTINGS\n'
    printf '============================================================\n'

    bazarr_settings_post \
        --data-urlencode \
        "settings-general-use_embedded_subs=true" \
        --data-urlencode \
        "subzero-remove_HI=true" \
        >/dev/null

    info "Embedded subtitles are treated as downloaded."
    info "Hearing-impaired subtitle cleanup enabled."
}


# ------------------------------------------------------------------------------
# Stage 4 - Sonarr / Radarr
# ------------------------------------------------------------------------------

configure_arr_connections() {
    printf '\n'
    printf '============================================================\n'
    printf 'BAZARR SONARR / RADARR CONNECTIONS\n'
    printf '============================================================\n'

    bazarr_settings_post \
        --data-urlencode \
        "settings-general-use_sonarr=true" \
        --data-urlencode \
        "settings-sonarr-ip=sonarr" \
        --data-urlencode \
        "settings-sonarr-port=8989" \
        --data-urlencode \
        "settings-sonarr-base_url=/" \
        --data-urlencode \
        "settings-sonarr-ssl=false" \
        --data-urlencode \
        "settings-sonarr-apikey=$SONARR_API_KEY" \
        --data-urlencode \
        "settings-general-use_radarr=true" \
        --data-urlencode \
        "settings-radarr-ip=radarr" \
        --data-urlencode \
        "settings-radarr-port=7878" \
        --data-urlencode \
        "settings-radarr-base_url=/" \
        --data-urlencode \
        "settings-radarr-ssl=false" \
        --data-urlencode \
        "settings-radarr-apikey=$RADARR_API_KEY" \
        >/dev/null

    info "Sonarr connection configured."
    info "Radarr connection configured."
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_bazarr() {
    printf '\n'
    printf '============================================================\n'
    printf 'BAZARR VERIFICATION\n'
    printf '============================================================\n'

    local settings
    local profiles

    settings="$(
        bazarr_get '/system/settings'
    )"

    profiles="$(
        bazarr_get '/system/languages/profiles'
    )"

    printf '%s' "$profiles" |
        jq -e \
            --arg name "$BAZARR_PROFILE_NAME" '

                any(
                    .[];
                    .name == $name

                    and

                    (
                        [.items[].language]
                        | sort
                    )
                    ==
                    ["en", "he"]
                )
            ' \
        >/dev/null ||
        fatal "English + Hebrew language profile verification failed."

    printf '%s' "$settings" |
        jq -e '

            .general.use_embedded_subs == true

            and

            (
                .general.subzero_mods
                | index("remove_HI")
            ) != null

            and

            .general.use_sonarr == true

            and

            .sonarr.ip == "sonarr"

            and

            .sonarr.port == 8989

            and

            .general.use_radarr == true

            and

            .radarr.ip == "radarr"

            and

            .radarr.port == 7878
        ' \
        >/dev/null ||
        fatal "Bazarr settings verification failed."

    info "Language profile verified."
    info "Embedded subtitle handling verified."
    info "Hearing-impaired cleanup verified."
    info "Sonarr connection settings verified."
    info "Radarr connection settings verified."

    if [[ -n "$BAZARR_OPENSUBTITLES_USERNAME" &&
          -n "$BAZARR_OPENSUBTITLES_PASSWORD" ]]
    then

        printf '%s' "$settings" |
            jq -e '

                (
                    .general.enabled_providers
                    | index("opensubtitlescom")
                ) != null

                and

                .opensubtitlescom.username != ""
            ' \
            >/dev/null ||
            fatal "OpenSubtitles.com verification failed."

        info "OpenSubtitles.com verified."
    fi
}


# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'BAZARR QUICK CONFIGURATION\n'
printf '============================================================\n'

wait_for_bazarr

configure_languages
configure_provider
configure_subtitles
configure_arr_connections
verify_bazarr

printf '\n'
printf '============================================================\n'
printf 'BAZARR QUICK CONFIGURATION COMPLETE\n'
printf '============================================================\n'
