#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK_PROFILE="$PROJECT_ROOT/installer/profiles/quick.json"
SERVICES_DIR="$PROJECT_ROOT/installer/services"
PLAN_CHECKER="$PROJECT_ROOT/installer/show-plan.sh"
OUTPUT_FILE="${1:-$PROJECT_ROOT/runtime/plans/custom.json}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required."
[[ -f "$QUICK_PROFILE" ]] || fail "Missing Quick profile: $QUICK_PROFILE"
[[ -f "$PLAN_CHECKER" ]] || fail "Missing plan checker: $PLAN_CHECKER"

if [[ "$OUTPUT_FILE" != /* ]]; then
  OUTPUT_FILE="$PROJECT_ROOT/$OUTPUT_FILE"
fi

declare -A service_files=()
declare -A service_names=()
declare -A selected_services=()
declare -A selected_setups=()
declare -A selected_plugins=()

mapfile -t available_services < <(jq -r '.services[]' "$QUICK_PROFILE")
mapfile -t available_setups < <(jq -r '.setups[]' "$QUICK_PROFILE")

for service_id in "${available_services[@]}"; do
  definition_file="$SERVICES_DIR/$service_id.json"
  [[ -f "$definition_file" ]] || fail "Missing service file: $service_id"
  service_files[$service_id]="$definition_file"
  service_names[$service_id]="$(jq -r '.name' "$definition_file")"
done

select_service() {
  local service_id="$1"
  [[ -n "${service_files[$service_id]+x}" ]] || fail "Unknown service: $service_id"
  selected_services[$service_id]=1
}

select_setup() {
  local service_id="$1"
  select_service "$service_id"

  if jq -e '.setup != null' "${service_files[$service_id]}" >/dev/null; then
    selected_setups[$service_id]=1
  fi
}

printf 'Available services:\n'
for service_id in "${available_services[@]}"; do
  printf '  %-24s %s\n' "$service_id" "${service_names[$service_id]}"
done

printf '\nEnter service IDs separated by spaces. Use "all" or "none": '
read -r service_choice
service_choice="${service_choice:-none}"

case "$service_choice" in
  all)
    for service_id in "${available_services[@]}"; do
      select_setup "$service_id"
    done
    ;;
  none)
    ;;
  *)
    read -r -a requested_services <<< "$service_choice"
    for service_id in "${requested_services[@]}"; do
      select_setup "$service_id"
    done
    ;;
esac

if [[ -n "${selected_services[jellyfin]+x}" ]]; then
  jellyfin_definition="${service_files[jellyfin]}"
  plugins_directory="$(jq -r '.pluginsDirectory' "$jellyfin_definition")"

  shopt -s nullglob
  plugin_files=("$PROJECT_ROOT/$plugins_directory"/*/plugin.json)
  shopt -u nullglob

  declare -A available_plugins=()

  printf '\nAvailable Jellyfin plugins:\n'
  for plugin_file in "${plugin_files[@]}"; do
    plugin_id="$(jq -r '.id' "$plugin_file")"
    plugin_name="$(jq -r '.name' "$plugin_file")"
    available_plugins[$plugin_id]="$plugin_name"
    printf '  %-24s %s\n' "$plugin_id" "$plugin_name"
  done

  printf '\nEnter plugin IDs separated by spaces. Use "all" or "none" [none]: '
  read -r plugin_choice
  plugin_choice="${plugin_choice:-none}"

  case "$plugin_choice" in
    all)
      for plugin_file in "${plugin_files[@]}"; do
        plugin_id="$(jq -r '.id' "$plugin_file")"
        selected_plugins[$plugin_id]=1
      done
      ;;
    none)
      ;;
    *)
      read -r -a requested_plugins <<< "$plugin_choice"
      for plugin_id in "${requested_plugins[@]}"; do
        [[ -n "${available_plugins[$plugin_id]+x}" ]] ||
          fail "Unknown Jellyfin plugin: $plugin_id"
        selected_plugins[$plugin_id]=1
      done
      ;;
  esac
fi

# Add only the services and setup steps required by the user's choices.
changed=true
while [[ "$changed" == "true" ]]; do
  changed=false

  for service_id in "${!selected_services[@]}"; do
    while IFS= read -r needed_id; do
      if [[ -z "${selected_services[$needed_id]+x}" ]]; then
        select_service "$needed_id"
        changed=true
      fi
    done < <(jq -r '.needs[]' "${service_files[$service_id]}")
  done

  for service_id in "${!selected_setups[@]}"; do
    definition_file="${service_files[$service_id]}"

    while IFS= read -r needed_id; do
      if [[ -z "${selected_services[$needed_id]+x}" ]]; then
        select_service "$needed_id"
        changed=true
      fi
    done < <(jq -r '.setup.needsRunning[]' "$definition_file")

    while IFS= read -r needed_id; do
      if [[ -z "${selected_setups[$needed_id]+x}" ]]; then
        select_setup "$needed_id"
        changed=true
      fi
    done < <(jq -r '.setup.runsAfterSetup[]' "$definition_file")
  done
done

ordered_services=()
for service_id in "${available_services[@]}"; do
  [[ -n "${selected_services[$service_id]+x}" ]] && ordered_services+=("$service_id")
done

ordered_setups=()
for service_id in "${available_setups[@]}"; do
  [[ -n "${selected_setups[$service_id]+x}" ]] && ordered_setups+=("$service_id")
done

ordered_plugins=()
if [[ -n "${selected_services[jellyfin]+x}" ]]; then
  for plugin_file in "${plugin_files[@]}"; do
    plugin_id="$(jq -r '.id' "$plugin_file")"
    [[ -n "${selected_plugins[$plugin_id]+x}" ]] && ordered_plugins+=("$plugin_id")
  done
fi

json_array() {
  if (($# == 0)); then
    printf '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -s .
  fi
}

services_json="$(json_array "${ordered_services[@]}")"
setups_json="$(json_array "${ordered_setups[@]}")"
plugins_json='{}'

if [[ -n "${selected_services[jellyfin]+x}" ]]; then
  jellyfin_plugins_json="$(json_array "${ordered_plugins[@]}")"
  plugins_json="$(jq -n --argjson choices "$jellyfin_plugins_json" '{jellyfin: $choices}')"
fi

mkdir -p "$(dirname -- "$OUTPUT_FILE")"
temporary_file="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "$temporary_file"' EXIT

jq -n \
  --arg id "custom" \
  --arg name "Custom" \
  --argjson services "$services_json" \
  --argjson setups "$setups_json" \
  --argjson plugins "$plugins_json" '
    {
      id: $id,
      name: $name,
      services: $services,
      setups: $setups,
      plugins: $plugins
    }
  ' > "$temporary_file"

mv -- "$temporary_file" "$OUTPUT_FILE"
trap - EXIT

printf '\nCustom plan saved: %s\n\n' "$OUTPUT_FILE"
bash "$PLAN_CHECKER" "$OUTPUT_FILE"
