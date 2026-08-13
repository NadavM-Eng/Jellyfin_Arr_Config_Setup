#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Jellyfin Plugins
# ==============================================================================
#
# Responsibilities:
#   - Read one definition file for each selected plugin.
#   - Ensure required Jellyfin plugin repositories exist and are enabled.
#   - Install missing plugins.
#   - Enable disabled plugins.
#   - Restart Jellyfin once when plugin state changes.
#   - Verify all managed plugins are active.
#
# This file is sourced by bootstrap/jellyfin/setup.sh.
# ==============================================================================


PLUGIN_DEFINITIONS_DIR="$PROJECT_ROOT/bootstrap/jellyfin/plugins"
LEGACY_PLUGIN_MANIFEST="$PLUGIN_DEFINITIONS_DIR/plugins.json"

JELLYFIN_PLUGIN_RESTART_REQUIRED=false
PLUGIN_SOURCE=""
PLUGIN_DEFINITION_FILES=()


# ------------------------------------------------------------------------------
# Plugin definitions
# ------------------------------------------------------------------------------

validate_plugin_definition() {
    local definition_file="$1"

    jq -e '
        (.id | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
        and
        (.name | type == "string" and length > 0)
        and
        (.repositoryName | type == "string" and length > 0)
        and
        (.repositoryUrl | type == "string" and length > 0)
    ' "$definition_file" >/dev/null ||
        fatal "Invalid Jellyfin plugin definition: $definition_file"
}


validate_legacy_plugin_manifest() {
    jq -e '
        (.plugins | type == "array")
        and all(
            .plugins[];
            (.name | type == "string" and length > 0)
            and (.repositoryName | type == "string" and length > 0)
            and (.repositoryUrl | type == "string" and length > 0)
        )
    ' "$LEGACY_PLUGIN_MANIFEST" >/dev/null ||
        fatal "Invalid Jellyfin plugin manifest: $LEGACY_PLUGIN_MANIFEST"
}


load_plugin_definitions() {
    PLUGIN_DEFINITION_FILES=()

    local selection_is_set="${MASTERBUILDER_PLUGINS_SELECTED:-false}"
    local selected_ids="${MASTERBUILDER_PLUGIN_IDS:-}"
    local plugin_id
    local plugin_name
    local expected_id
    local definition_file
    local -A requested_ids_seen=()
    local -A seen_ids=()
    local -A seen_names=()

    if [[ "$selection_is_set" == "true" ]]; then
        if [[ -n "$selected_ids" ]]; then
            IFS=',' read -r -a requested_ids <<< "$selected_ids"

            for plugin_id in "${requested_ids[@]}"; do
                [[ "$plugin_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
                    fatal "Invalid selected Jellyfin plugin ID: $plugin_id"

                [[ -z "${requested_ids_seen[$plugin_id]+x}" ]] ||
                    fatal "Jellyfin plugin selected twice: $plugin_id"

                requested_ids_seen[$plugin_id]=1
                definition_file="$PLUGIN_DEFINITIONS_DIR/$plugin_id/plugin.json"

                [[ -f "$definition_file" ]] ||
                    fatal "Selected Jellyfin plugin definition is missing: $plugin_id"

                PLUGIN_DEFINITION_FILES+=("$definition_file")
            done
        fi

        PLUGIN_SOURCE="files"
    else
        shopt -s nullglob
        PLUGIN_DEFINITION_FILES=("$PLUGIN_DEFINITIONS_DIR"/*/plugin.json)
        shopt -u nullglob

        if ((${#PLUGIN_DEFINITION_FILES[@]} > 0)); then
            PLUGIN_SOURCE="files"
        elif [[ -f "$LEGACY_PLUGIN_MANIFEST" ]]; then
            validate_legacy_plugin_manifest
            PLUGIN_SOURCE="legacy"
            return
        else
            fatal "No Jellyfin plugin definitions were found."
        fi
    fi

    for definition_file in "${PLUGIN_DEFINITION_FILES[@]}"; do
        validate_plugin_definition "$definition_file"

        plugin_id="$(jq -r '.id' "$definition_file")"
        plugin_name="$(jq -r '.name' "$definition_file")"
        expected_id="$(basename -- "$(dirname -- "$definition_file")")"

        [[ "$plugin_id" == "$expected_id" ]] ||
            fatal "Jellyfin plugin ID does not match its folder: $definition_file"

        [[ -z "${seen_ids[$plugin_id]+x}" ]] ||
            fatal "Jellyfin plugin ID is used twice: $plugin_id"

        [[ -z "${seen_names[$plugin_name]+x}" ]] ||
            fatal "Jellyfin plugin name is used twice: $plugin_name"

        seen_ids[$plugin_id]=1
        seen_names[$plugin_name]=1
    done
}


plugin_rows() {
    local definition_file

    if [[ "$PLUGIN_SOURCE" == "legacy" ]]; then
        jq -r '.plugins[] | [.name, .repositoryName, .repositoryUrl] | @tsv' \
            "$LEGACY_PLUGIN_MANIFEST"
        return
    fi

    for definition_file in "${PLUGIN_DEFINITION_FILES[@]}"; do
        jq -r '[.name, .repositoryName, .repositoryUrl] | @tsv' "$definition_file"
    done
}


# ------------------------------------------------------------------------------
# Repository API
# ------------------------------------------------------------------------------

get_plugin_repositories() {
    local response

    response="$(
        jellyfin_status_request \
            GET \
            "/Repositories" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading Jellyfin plugin repositories" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


set_plugin_repositories() {
    local repositories="$1"
    local response

    response="$(
        jellyfin_status_request \
            POST \
            "/Repositories" \
            "$repositories" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Updating Jellyfin plugin repositories" \
        "$HTTP_BODY"
}


ensure_plugin_repository() {
    local name="$1"
    local url="$2"

    local current
    local desired

    current="$(get_plugin_repositories)"

    desired="$(
        printf '%s' "$current" |
            jq -c \
                --arg name "$name" \
                --arg url "$url" '

                    if any(.[]; .Url == $url) then

                        map(
                            if .Url == $url then
                                .Name = $name
                                | .Enabled = true
                            else
                                .
                            end
                        )

                    elif any(.[]; .Name == $name) then

                        map(
                            if .Name == $name then
                                .Url = $url
                                | .Enabled = true
                            else
                                .
                            end
                        )

                    else

                        . + [
                            {
                                Name: $name,
                                Url: $url,
                                Enabled: true
                            }
                        ]

                    end
                '
    )"

    if [[ "$(printf '%s' "$current" | jq -cS .)" == "$(printf '%s' "$desired" | jq -cS .)" ]]
    then
        info "Plugin repository already configured: $name"
        return
    fi

    info "Configuring plugin repository: $name"

    set_plugin_repositories "$desired"

    info "Plugin repository configured: $name"
}


# ------------------------------------------------------------------------------
# Installed plugin API
# ------------------------------------------------------------------------------

get_installed_plugins() {
    local response

    response="$(
        jellyfin_status_request \
            GET \
            "/Plugins" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Reading installed Jellyfin plugins" \
        "$HTTP_BODY"

    printf '%s' "$HTTP_BODY"
}


get_plugin_by_name() {
    local name="$1"

    get_installed_plugins |
        jq -c \
            --arg name "$name" '

                [
                    .[]
                    | select(.Name == $name)
                ]

                | sort_by(
                    if (.Status == "Active" or .Status == 0) then
                        0
                    elif (.Status == "Restart" or .Status == 1) then
                        1
                    elif (.Status == "Disabled" or .Status == -1) then
                        2
                    else
                        3
                    end
                )

                | first // empty
            '
}


# ------------------------------------------------------------------------------
# Package installation
# ------------------------------------------------------------------------------

install_plugin() {
    local name="$1"
    local repository_url="$2"

    local endpoint
    local response

    endpoint="/Packages/Installed/$(urlencode "$name")"
    endpoint+="?repositoryUrl=$(urlencode "$repository_url")"

    info "Installing Jellyfin plugin: $name"

    response="$(
        jellyfin_status_request \
            POST \
            "$endpoint" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Installing Jellyfin plugin '$name'" \
        "$HTTP_BODY"

    JELLYFIN_PLUGIN_RESTART_REQUIRED=true

    info "Plugin installation queued: $name"
}


enable_plugin() {
    local plugin="$1"

    local name
    local id
    local version
    local response

    name="$(
        printf '%s' "$plugin" |
            jq -r '.Name'
    )"

    id="$(
        printf '%s' "$plugin" |
            jq -r '.Id'
    )"

    version="$(
        printf '%s' "$plugin" |
            jq -r '.Version'
    )"

    [[ -n "$id" && "$id" != "null" ]] ||
        fatal "Could not determine plugin ID for $name."

    [[ -n "$version" && "$version" != "null" ]] ||
        fatal "Could not determine plugin version for $name."

    info "Enabling Jellyfin plugin: $name"

    response="$(
        jellyfin_status_request \
            POST \
            "/Plugins/$id/$version/Enable" \
            "" \
            true
    )"

    split_response "$response"

    require_success \
        "$HTTP_STATUS" \
        "Enabling Jellyfin plugin '$name'" \
        "$HTTP_BODY"

    JELLYFIN_PLUGIN_RESTART_REQUIRED=true

    info "Plugin enabled; restart required: $name"
}


# ------------------------------------------------------------------------------
# Desired plugin state
# ------------------------------------------------------------------------------

ensure_plugin() {
    local name="$1"
    local repository_url="$2"

    local plugin
    local status

    plugin="$(get_plugin_by_name "$name")"

    if [[ -z "$plugin" ]]; then
        install_plugin \
            "$name" \
            "$repository_url"

        return
    fi

    status="$(
        printf '%s' "$plugin" |
            jq -r '.Status'
    )"

    case "$status" in

        Active|0)
            info "Plugin already active: $name"
            ;;

        Restart|1)
            info "Plugin already installed and waiting for restart: $name"
            JELLYFIN_PLUGIN_RESTART_REQUIRED=true
            ;;

        Disabled|-1)
            enable_plugin "$plugin"
            ;;

        NotSupported|-2)
            fatal "Plugin is not supported by this Jellyfin version: $name"
            ;;

        Malfunctioned|-3)
            fatal "Plugin failed to load correctly: $name"
            ;;

        Deleted|-5)
            fatal "Plugin is currently marked for deletion: $name"
            ;;

        *)
            fatal "Plugin '$name' has unexpected status: $status"
            ;;
    esac
}


# ------------------------------------------------------------------------------
# Restart
# ------------------------------------------------------------------------------

restart_jellyfin_for_plugins() {
    if [[ "$JELLYFIN_PLUGIN_RESTART_REQUIRED" != "true" ]]; then
        info "Jellyfin restart is not required."
        return
    fi

    command -v docker >/dev/null 2>&1 ||
        fatal "Docker is required to restart Jellyfin after plugin changes."

    info "Restarting Jellyfin to activate plugin changes..."

    docker restart jellyfin >/dev/null

    JELLYFIN_TOKEN=""
    JELLYFIN_USER_ID=""

    wait_for_jellyfin

    if ! authenticate_admin; then
        fatal "Jellyfin restarted, but administrator authentication failed."
    fi

    info "Jellyfin restarted successfully."
}


# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

verify_plugin() {
    local name="$1"

    local plugin
    local status
    local version

    plugin="$(get_plugin_by_name "$name")"

    [[ -n "$plugin" ]] ||
        fatal "Jellyfin plugin is missing after installation: $name"

    status="$(
        printf '%s' "$plugin" |
            jq -r '.Status'
    )"

    version="$(
        printf '%s' "$plugin" |
            jq -r '.Version'
    )"

    case "$status" in
        Active|0)
            ;;
        *)
            fatal "Plugin '$name' is installed but not active. Status: $status"
            ;;
    esac

    info "$name active (version $version)."
}


verify_managed_plugins() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN PLUGIN VERIFICATION\n'
    printf '============================================================\n'

    while IFS=$'\t' read -r name _repository_name repository_url; do

        verify_plugin "$name"

    done < <(plugin_rows)

    info "All managed Jellyfin plugins verified."
}


# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

configure_jellyfin_plugins() {
    printf '\n'
    printf '============================================================\n'
    printf 'JELLYFIN PLUGINS\n'
    printf '============================================================\n'

    load_plugin_definitions

    if [[ "$PLUGIN_SOURCE" == "files" && ${#PLUGIN_DEFINITION_FILES[@]} -eq 0 ]]; then
        info "No Jellyfin plugins selected."
        return
    fi

    while IFS=$'\t' read -r name repository_name repository_url; do

        ensure_plugin_repository \
            "$repository_name" \
            "$repository_url"

    done < <(plugin_rows)

    while IFS=$'\t' read -r name _repository_name repository_url; do

        ensure_plugin \
            "$name" \
            "$repository_url"

    done < <(plugin_rows)

    restart_jellyfin_for_plugins
    verify_managed_plugins
}
