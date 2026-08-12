#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

info()  { printf '[+] %s\n' "$1"; }
warn()  { printf '[!] %s\n' "$1"; }
fatal() { printf '[X] %s\n' "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fatal "curl is required."
command -v jq >/dev/null 2>&1 || fatal "jq is required."

[[ -f "$ENV_FILE" ]] || fatal "Missing .env file."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

SEERR_PORT="${SEERR_PORT:-5055}"
SEERR_HOST_URL="http://localhost:${SEERR_PORT}"

SEERR_ADMIN_EMAIL="${SEERR_ADMIN_EMAIL:-admin@localhost}"

# Seerr reaches Jellyfin through the Docker network.
SEERR_JELLYFIN_HOST="${SEERR_JELLYFIN_HOST:-jellyfin}"
SEERR_JELLYFIN_PORT="${SEERR_JELLYFIN_PORT:-8096}"

JELLYFIN_ADMIN_USERNAME="${JELLYFIN_ADMIN_USERNAME:-admin}"
JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-}"

: "${CONFIG_ROOT:?CONFIG_ROOT is missing from .env.}"

SONARR_CONFIG="$CONFIG_ROOT/sonarr/config.xml"
RADARR_CONFIG="$CONFIG_ROOT/radarr/config.xml"

SEERR_SONARR_HOST="${SEERR_SONARR_HOST:-sonarr}"
SEERR_SONARR_PORT="${SEERR_SONARR_PORT:-8989}"

SEERR_RADARR_HOST="${SEERR_RADARR_HOST:-radarr}"
SEERR_RADARR_PORT="${SEERR_RADARR_PORT:-7878}"

SONARR_STANDARD_PROFILE_NAME="${SEERR_SONARR_STANDARD_PROFILE:-Any}"

SONARR_ANIME_PROFILE_FILE="$PROJECT_ROOT/bootstrap/sonarr/profiles/anime.json"
RADARR_DEFAULT_PROFILE_FILE="$PROJECT_ROOT/bootstrap/radarr/profiles/smart-downloader.json"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

[[ -n "$JELLYFIN_ADMIN_PASSWORD" ]] ||
    fatal "JELLYFIN_ADMIN_PASSWORD is missing from .env."


# ------------------------------------------------------------------------------
# Generic HTTP helpers
# ------------------------------------------------------------------------------

seerr_request() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    local authenticated="${4:-false}"

    local args=(
        -sS
        -X "$method"
        -H "Content-Type: application/json"
    )

    if [[ "$authenticated" == "true" ]]; then
        args+=(
            -b "$COOKIE_JAR"
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
        "$SEERR_HOST_URL$endpoint"
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


urlencode() {
    jq -rn \
        --arg value "$1" \
        '$value | @uri'
}


# ------------------------------------------------------------------------------
# Wait for Seerr
# ------------------------------------------------------------------------------

wait_for_seerr() {
    printf '\n'
    info "Waiting for Seerr API..."

    local attempts=60
    local response
    local status

    for ((i = 1; i <= attempts; i++)); do
        response="$(
            curl \
                -sS \
                -o /dev/null \
                -w '%{http_code}' \
                "$SEERR_HOST_URL/api/v1/status" \
                2>/dev/null ||
                true
        )"

        status="$response"

        if [[ "$status" == "200" ]]; then
            info "Seerr API is ready."
            return
        fi

        sleep 2
    done

    fatal "Seerr API did not become ready."
}


# ------------------------------------------------------------------------------
# Public settings
# ------------------------------------------------------------------------------

get_public_settings() {
    local response

    response="$(
        seerr_request \
            GET \
            "/api/v1/settings/public"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Seerr public settings" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


# ------------------------------------------------------------------------------
# Stage 1 - Jellyfin connection / administrator
# ------------------------------------------------------------------------------

setup_jellyfin_admin() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR JELLYFIN CONNECTION\n'
    printf '============================================================\n'

    local payload
    local response

    payload="$(
        jq -cn \
            --arg username "$JELLYFIN_ADMIN_USERNAME" \
            --arg password "$JELLYFIN_ADMIN_PASSWORD" \
            --arg hostname "$SEERR_JELLYFIN_HOST" \
            --arg email "$SEERR_ADMIN_EMAIL" \
            --argjson port "$SEERR_JELLYFIN_PORT" '
                {
                    username: $username,
                    password: $password,
                    hostname: $hostname,
                    port: $port,
                    useSsl: false,
                    urlBase: "",
                    email: $email,
                    serverType: 2
                }
            '
    )"

    response="$(
        curl \
            -sS \
            -X POST \
            -H "Content-Type: application/json" \
            -c "$COOKIE_JAR" \
            -b "$COOKIE_JAR" \
            --data "$payload" \
            -w $'\n%{http_code}' \
            "$SEERR_HOST_URL/api/v1/auth/jellyfin"
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Connecting Seerr to Jellyfin" \
        "$HTTP_BODY"

    info "Seerr connected to Jellyfin."
    info "Seerr administrator created from Jellyfin administrator."
}


login_existing_admin() {
    local payload
    local response

    payload="$(
        jq -cn \
            --arg username "$JELLYFIN_ADMIN_USERNAME" \
            --arg password "$JELLYFIN_ADMIN_PASSWORD" '
                {
                    username: $username,
                    password: $password
                }
            '
    )"

    response="$(
        curl \
            -sS \
            -X POST \
            -H "Content-Type: application/json" \
            -c "$COOKIE_JAR" \
            -b "$COOKIE_JAR" \
            --data "$payload" \
            -w $'\n%{http_code}' \
            "$SEERR_HOST_URL/api/v1/auth/jellyfin"
    )"

    split_response "$response"

    if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
        info "Existing Seerr administrator authenticated."
        return 0
    fi

    return 1
}


verify_admin_session() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR STAGE 1 VERIFICATION\n'
    printf '============================================================\n'

    local response

    response="$(
        seerr_request \
            GET \
            "/api/v1/settings/main" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Verifying Seerr administrator access" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY" |
        jq -e '
            .mediaServerType == 2
        ' \
        >/dev/null ||
        fatal "Seerr is not configured to use Jellyfin."

    info "Administrator session verified."
    info "Jellyfin media server type verified."
}


# ------------------------------------------------------------------------------
# Stage 2 - Jellyfin libraries
# ------------------------------------------------------------------------------

get_jellyfin_settings() {
    local response

    response="$(
        seerr_request \
            GET \
            "/api/v1/settings/jellyfin" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Seerr Jellyfin settings" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


sync_jellyfin_libraries() {
    local settings
    local enabled_ids
    local endpoint
    local response

    settings="$(get_jellyfin_settings)"

    enabled_ids="$(
        printf '%s' "$settings" |
            jq -r '
                [
                    .libraries[]?
                    | select(.enabled == true)
                    | .id
                ]
                | join(",")
            '
    )"

    endpoint="/api/v1/settings/jellyfin/library?sync=true"

    if [[ -n "$enabled_ids" ]]; then
        endpoint+="&enable=$(urlencode "$enabled_ids")"
    fi

    response="$(
        seerr_request \
            GET \
            "$endpoint" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Syncing Jellyfin libraries into Seerr" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


configure_jellyfin_libraries() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR JELLYFIN LIBRARIES\n'
    printf '============================================================\n'

    local libraries
    local current_enabled
    local target_ids
    local desired_ids
    local desired_csv
    local missing
    local response
    local endpoint

    libraries="$(sync_jellyfin_libraries)"

    missing="$(
        printf '%s' "$libraries" |
            jq -r '
                ["Movies", "TV Shows", "Anime"]
                -
                [
                    .[]?
                    | .name
                ]
                | join(", ")
            '
    )"

    if [[ -n "$missing" ]]; then
        fatal "Required Jellyfin libraries were not found in Seerr: $missing"
    fi

    current_enabled="$(
        printf '%s' "$libraries" |
            jq -c '
                [
                    .[]?
                    | select(.enabled == true)
                    | .id
                ]
            '
    )"

    target_ids="$(
        printf '%s' "$libraries" |
            jq -c '
                [
                    .[]?
                    | select(
                        .name == "Movies"
                        or
                        .name == "TV Shows"
                        or
                        .name == "Anime"
                    )
                    | .id
                ]
            '
    )"

    desired_ids="$(
        jq -cn \
            --argjson current "$current_enabled" \
            --argjson targets "$target_ids" '
                ($current + $targets)
                | unique
            '
    )"

    desired_csv="$(
        printf '%s' "$desired_ids" |
            jq -r 'join(",")'
    )"

    [[ -n "$desired_csv" ]] ||
        fatal "No Jellyfin libraries were selected for Seerr."

    endpoint="/api/v1/settings/jellyfin/library"
    endpoint+="?enable=$(urlencode "$desired_csv")"

    response="$(
        seerr_request \
            GET \
            "$endpoint" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Enabling Jellyfin libraries in Seerr" \
        "$HTTP_BODY"

    info "Movies library enabled."
    info "TV Shows library enabled."
    info "Anime library enabled."
}


verify_jellyfin_libraries() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR STAGE 2 VERIFICATION\n'
    printf '============================================================\n'

    local settings

    settings="$(get_jellyfin_settings)"

    printf '%s' "$settings" |
        jq -e '
            any(
                .libraries[];
                .name == "Movies"
                and
                .enabled == true
            )

            and

            any(
                .libraries[];
                .name == "TV Shows"
                and
                .enabled == true
            )

            and

            any(
                .libraries[];
                .name == "Anime"
                and
                .enabled == true
            )
        ' \
        >/dev/null ||
        fatal "Seerr Jellyfin library verification failed."

    info "Movies library verified."
    info "TV Shows library verified."
    info "Anime library verified."
}


# ------------------------------------------------------------------------------
# Stage 3 - Sonarr / Radarr services
# ------------------------------------------------------------------------------

read_arr_api_key() {
    local service="$1"
    local config_file="$2"
    local key

    [[ -s "$config_file" ]] ||
        fatal "$service config.xml was not found: $config_file"

    key="$(
        sed -n \
            's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' \
            "$config_file" |
            head -n 1
    )"

    [[ -n "$key" ]] ||
        fatal "Could not read $service API key."

    printf '%s' "$key"
}


read_profile_name() {
    local file="$1"

    [[ -f "$file" ]] ||
        fatal "Profile definition was not found: $file"

    local name

    name="$(
        jq -r '.name // empty' "$file"
    )"

    [[ -n "$name" ]] ||
        fatal "Profile definition has no name: $file"

    printf '%s' "$name"
}


test_arr_connection() {
    local service="$1"
    local hostname="$2"
    local port="$3"
    local api_key="$4"

    local payload
    local response

    payload="$(
        jq -cn \
            --arg hostname "$hostname" \
            --arg api_key "$api_key" \
            --argjson port "$port" '
                {
                    hostname: $hostname,
                    port: $port,
                    apiKey: $api_key,
                    useSsl: false,
                    baseUrl: ""
                }
            '
    )"

    response="$(
        seerr_request \
            POST \
            "/api/v1/settings/$service/test" \
            "$payload" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Testing Seerr connection to $service" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


get_arr_settings() {
    local service="$1"
    local response

    response="$(
        seerr_request \
            GET \
            "/api/v1/settings/$service" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Seerr $service settings" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


save_arr_instance() {
    local service="$1"
    local hostname="$2"
    local port="$3"
    local desired="$4"

    local settings
    local existing
    local existing_id
    local payload
    local response

    settings="$(
        get_arr_settings "$service"
    )"

    existing="$(
        printf '%s' "$settings" |
            jq -c \
                --arg hostname "$hostname" \
                --argjson port "$port" '
                    [
                        .[]
                        | select(
                            .hostname == $hostname
                            and
                            .port == $port
                            and
                            (.is4k // false) == false
                        )
                    ]
                    | first // empty
                '
    )"

    if [[ -n "$existing" ]]; then
        existing_id="$(
            printf '%s' "$existing" |
                jq -r '.id'
        )"

        [[ "$existing_id" =~ ^[0-9]+$ ]] ||
            fatal "Could not determine existing Seerr $service instance ID."

        payload="$(
            jq -cn \
                --argjson existing "$existing" \
                --argjson desired "$desired" '
                    ($existing + $desired)
                    | del(.id)
                '
        )"

        response="$(
            seerr_request \
                PUT \
                "/api/v1/settings/$service/$existing_id" \
                "$payload" \
                true
        )"

        split_response "$response"

        require_success \
            "$HTTP_STATUS" \
            "Updating Seerr $service service" \
            "$HTTP_BODY"

        info "$service service already existed and was updated."
        return
    fi

    response="$(
        seerr_request \
            POST \
            "/api/v1/settings/$service" \
            "$desired" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Adding $service to Seerr" \
        "$HTTP_BODY"

    info "$service service added."
}


configure_radarr() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR RADARR CONFIGURATION\n'
    printf '============================================================\n'

    local api_key
    local profile_name
    local test_result
    local profile_id
    local base_url
    local desired

    api_key="$(
        read_arr_api_key \
            "Radarr" \
            "$RADARR_CONFIG"
    )"

    profile_name="$(
        read_profile_name \
            "$RADARR_DEFAULT_PROFILE_FILE"
    )"

    test_result="$(
        test_arr_connection \
            "radarr" \
            "$SEERR_RADARR_HOST" \
            "$SEERR_RADARR_PORT" \
            "$api_key"
    )"

    info "Seerr successfully connected to Radarr."

    profile_id="$(
        printf '%s' "$test_result" |
            jq -r \
                --arg name "$profile_name" '
                    [
                        .profiles[]
                        | select(.name == $name)
                        | .id
                    ]
                    | first // empty
                '
    )"

    [[ "$profile_id" =~ ^[0-9]+$ ]] ||
        fatal "Required Radarr quality profile '$profile_name' was not found."

    printf '%s' "$test_result" |
        jq -e '
            any(
                .rootFolders[];
                .path == "/data/media/movies"
            )
        ' \
        >/dev/null ||
        fatal "Radarr root folder '/data/media/movies' was not found."

    base_url="$(
        printf '%s' "$test_result" |
            jq -r '.urlBase // ""'
    )"

    desired="$(
        jq -cn \
            --arg hostname "$SEERR_RADARR_HOST" \
            --arg api_key "$api_key" \
            --arg base_url "$base_url" \
            --arg profile_name "$profile_name" \
            --argjson port "$SEERR_RADARR_PORT" \
            --argjson profile_id "$profile_id" '
                {
                    name: "Radarr",
                    hostname: $hostname,
                    port: $port,
                    apiKey: $api_key,
                    useSsl: false,
                    baseUrl: $base_url,

                    activeProfileId: $profile_id,
                    activeProfileName: $profile_name,
                    activeDirectory: "/data/media/movies",

                    is4k: false,
                    minimumAvailability: "released",

                    tags: [],
                    isDefault: true,

                    syncEnabled: true,
                    preventSearch: false,
                    tagRequests: false
                }
            '
    )"

    save_arr_instance \
        "radarr" \
        "$SEERR_RADARR_HOST" \
        "$SEERR_RADARR_PORT" \
        "$desired"

    info "Radarr root folder configured."
    info "Radarr quality profile configured: $profile_name"
    info "Radarr automatic search enabled."
    info "Radarr scan enabled."
}


configure_sonarr() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR SONARR CONFIGURATION\n'
    printf '============================================================\n'

    local api_key
    local anime_profile_name
    local test_result
    local standard_profile_id
    local anime_profile_id
    local base_url
    local desired

    api_key="$(
        read_arr_api_key \
            "Sonarr" \
            "$SONARR_CONFIG"
    )"

    anime_profile_name="$(
        read_profile_name \
            "$SONARR_ANIME_PROFILE_FILE"
    )"

    test_result="$(
        test_arr_connection \
            "sonarr" \
            "$SEERR_SONARR_HOST" \
            "$SEERR_SONARR_PORT" \
            "$api_key"
    )"

    info "Seerr successfully connected to Sonarr."

    standard_profile_id="$(
        printf '%s' "$test_result" |
            jq -r \
                --arg name "$SONARR_STANDARD_PROFILE_NAME" '
                    [
                        .profiles[]
                        | select(.name == $name)
                        | .id
                    ]
                    | first // empty
                '
    )"

    [[ "$standard_profile_id" =~ ^[0-9]+$ ]] ||
        fatal "Required standard Sonarr quality profile '$SONARR_STANDARD_PROFILE_NAME' was not found."

    anime_profile_id="$(
        printf '%s' "$test_result" |
            jq -r \
                --arg name "$anime_profile_name" '
                    [
                        .profiles[]
                        | select(.name == $name)
                        | .id
                    ]
                    | first // empty
                '
    )"

    [[ "$anime_profile_id" =~ ^[0-9]+$ ]] ||
        fatal "Required Anime Sonarr quality profile '$anime_profile_name' was not found."

    printf '%s' "$test_result" |
        jq -e '
            any(
                .rootFolders[];
                .path == "/data/media/tv"
            )
        ' \
        >/dev/null ||
        fatal "Sonarr TV root folder '/data/media/tv' was not found."

    printf '%s' "$test_result" |
        jq -e '
            any(
                .rootFolders[];
                .path == "/data/media/anime"
            )
        ' \
        >/dev/null ||
        fatal "Sonarr Anime root folder '/data/media/anime' was not found."

    base_url="$(
        printf '%s' "$test_result" |
            jq -r '.urlBase // ""'
    )"

    desired="$(
        jq -cn \
            --arg hostname "$SEERR_SONARR_HOST" \
            --arg api_key "$api_key" \
            --arg base_url "$base_url" \
            --arg standard_profile "$SONARR_STANDARD_PROFILE_NAME" \
            --arg anime_profile "$anime_profile_name" \
            --argjson port "$SEERR_SONARR_PORT" \
            --argjson standard_profile_id "$standard_profile_id" \
            --argjson anime_profile_id "$anime_profile_id" '
                {
                    name: "Sonarr",
                    hostname: $hostname,
                    port: $port,
                    apiKey: $api_key,
                    useSsl: false,
                    baseUrl: $base_url,

                    activeProfileId: $standard_profile_id,
                    activeProfileName: $standard_profile,
                    activeDirectory: "/data/media/tv",
                    seriesType: "standard",

                    animeSeriesType: "anime",
                    activeAnimeProfileId: $anime_profile_id,
                    activeAnimeProfileName: $anime_profile,
                    activeAnimeDirectory: "/data/media/anime",

                    tags: [],
                    animeTags: [],

                    is4k: false,
                    isDefault: true,

                    enableSeasonFolders: true,

                    syncEnabled: true,
                    preventSearch: false,
                    tagRequests: false,

                    monitorNewItems: "all"
                }
            '
    )"

    save_arr_instance \
        "sonarr" \
        "$SEERR_SONARR_HOST" \
        "$SEERR_SONARR_PORT" \
        "$desired"

    info "Sonarr TV root folder configured."
    info "Sonarr Anime root folder configured."
    info "Sonarr standard quality profile configured: $SONARR_STANDARD_PROFILE_NAME"
    info "Sonarr Anime quality profile configured: $anime_profile_name"
    info "Sonarr automatic search enabled."
    info "Sonarr scan enabled."
}


verify_arr_services() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR STAGE 3 VERIFICATION\n'
    printf '============================================================\n'

    local radarr
    local sonarr
    local radarr_profile_name
    local anime_profile_name

    radarr_profile_name="$(
        read_profile_name \
            "$RADARR_DEFAULT_PROFILE_FILE"
    )"

    anime_profile_name="$(
        read_profile_name \
            "$SONARR_ANIME_PROFILE_FILE"
    )"

    radarr="$(
        get_arr_settings "radarr"
    )"

    printf '%s' "$radarr" |
        jq -e \
            --arg hostname "$SEERR_RADARR_HOST" \
            --arg profile "$radarr_profile_name" \
            --argjson port "$SEERR_RADARR_PORT" '
                any(
                    .[];
                    .hostname == $hostname
                    and
                    .port == $port
                    and
                    .activeDirectory == "/data/media/movies"
                    and
                    .activeProfileName == $profile
                    and
                    .isDefault == true
                    and
                    .syncEnabled == true
                    and
                    .preventSearch == false
                )
            ' \
        >/dev/null ||
        fatal "Seerr Radarr configuration verification failed."

    info "Radarr configuration verified."

    sonarr="$(
        get_arr_settings "sonarr"
    )"

    printf '%s' "$sonarr" |
        jq -e \
            --arg hostname "$SEERR_SONARR_HOST" \
            --arg standard_profile "$SONARR_STANDARD_PROFILE_NAME" \
            --arg anime_profile "$anime_profile_name" \
            --argjson port "$SEERR_SONARR_PORT" '
                any(
                    .[];
                    .hostname == $hostname
                    and
                    .port == $port

                    and
                    .activeDirectory == "/data/media/tv"
                    and
                    .activeProfileName == $standard_profile

                    and
                    .activeAnimeDirectory == "/data/media/anime"
                    and
                    .activeAnimeProfileName == $anime_profile

                    and
                    .seriesType == "standard"
                    and
                    .animeSeriesType == "anime"

                    and
                    .isDefault == true
                    and
                    .syncEnabled == true
                    and
                    .preventSearch == false
                )
            ' \
        >/dev/null ||
        fatal "Seerr Sonarr configuration verification failed."

    info "Sonarr TV configuration verified."
    info "Sonarr Anime configuration verified."
}

# ------------------------------------------------------------------------------
# Stage 4 - Finalize Seerr setup
# ------------------------------------------------------------------------------

finalize_seerr_setup() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR FINALIZATION\n'
    printf '============================================================\n'

    local public_settings
    local response

    public_settings="$(
        get_public_settings
    )"

    if printf '%s' "$public_settings" |
        jq -e '.initialized == true' \
        >/dev/null
    then
        info "Seerr is already initialized."
        return
    fi

    response="$(
        seerr_request \
            POST \
            "/api/v1/settings/initialize" \
            "{}" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Finalizing Seerr setup" \
        "$HTTP_BODY"

    info "Seerr setup finalized."
}


verify_seerr_initialization() {
    printf '\n'
    printf '============================================================\n'
    printf 'SEERR STAGE 4 VERIFICATION\n'
    printf '============================================================\n'

    local public_settings

    public_settings="$(
        get_public_settings
    )"

    printf '%s' "$public_settings" |
        jq -e '
            .initialized == true
            and
            .mediaServerType == 2
        ' \
        >/dev/null ||
        fatal "Seerr initialization verification failed."

    info "Seerr initialized state verified."
    info "Jellyfin media server verified."
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

printf '\n'
printf '============================================================\n'
printf 'SEERR QUICK CONFIGURATION\n'
printf '============================================================\n'

wait_for_seerr

public_settings="$(get_public_settings)"

initialized="$(
    printf '%s' "$public_settings" |
        jq -r '.initialized'
)"

media_server_type="$(
    printf '%s' "$public_settings" |
        jq -r '.mediaServerType'
)"


# ------------------------------------------------------------------------------
# Stage 1
# ------------------------------------------------------------------------------

if [[ "$media_server_type" == "2" ]]; then
    info "Existing Jellyfin-connected Seerr instance detected."

    login_existing_admin ||
        fatal "Seerr is configured, but Jellyfin administrator authentication failed."
else
    if [[ "$initialized" == "true" ]]; then
        fatal "Seerr is initialized with a media server other than Jellyfin."
    fi

    info "Fresh Seerr instance detected."

    setup_jellyfin_admin
fi

verify_admin_session

printf '\n'
printf '============================================================\n'
printf 'SEERR STAGE 1 COMPLETE\n'
printf '============================================================\n'


# ------------------------------------------------------------------------------
# Stage 2
# ------------------------------------------------------------------------------

configure_jellyfin_libraries
verify_jellyfin_libraries

printf '\n'
printf '============================================================\n'
printf 'SEERR STAGE 2 COMPLETE\n'
printf '============================================================\n'


# ------------------------------------------------------------------------------
# Stage 3
# ------------------------------------------------------------------------------

configure_radarr
configure_sonarr
verify_arr_services

printf '\n'
printf '============================================================\n'
printf 'SEERR STAGE 3 COMPLETE\n'
printf '============================================================\n'

# ------------------------------------------------------------------------------
# Stage 4
# ------------------------------------------------------------------------------

finalize_seerr_setup
verify_seerr_initialization


printf '\n'
printf '============================================================\n'
printf 'SEERR QUICK CONFIGURATION COMPLETE\n'
printf '============================================================\n'

info "Jellyfin connection configured."
info "Jellyfin libraries configured."
info "Radarr configured."
info "Sonarr configured."
info "Seerr setup finalized."
