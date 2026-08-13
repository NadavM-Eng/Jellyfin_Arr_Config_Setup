#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/installer/services"
PROFILES_DIR="$PROJECT_ROOT/installer/profiles"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required."

profile_input="${1:-quick}"
if [[ -f "$profile_input" ]]; then
  profile_file="$profile_input"
else
  profile_file="$PROFILES_DIR/${profile_input%.json}.json"
fi

[[ -f "$profile_file" ]] || fail "Profile not found: $profile_input"
jq -e '
  (.id | type == "string" and length > 0) and
  (.name | type == "string" and length > 0) and
  (.services | type == "array") and
  (.setups | type == "array")
' "$profile_file" >/dev/null || fail "Profile is not valid JSON: $profile_file"

declare -A service_files=()
declare -A service_names=()
declare -A selected_services=()
declare -A selected_setups=()
declare -A completed_setups=()

shopt -s nullglob
definition_files=("$SERVICES_DIR"/*.json)
((${#definition_files[@]} > 0)) || fail "No service files were found."

for definition_file in "${definition_files[@]}"; do
  jq -e '
    (.id | type == "string" and length > 0) and
    (.name | type == "string" and length > 0) and
    (.composeFiles | type == "array") and
    (.dockerServices | type == "array") and
    (.needs | type == "array") and
    (.setup == null or (
      (.setup | type == "object") and
      (.setup.linuxScript | type == "string" and length > 0) and
      (.setup.needsRunning | type == "array") and
      (.setup.runsAfterSetup | type == "array")
    ))
  ' "$definition_file" >/dev/null || fail "Service file is not valid: $definition_file"

  service_id="$(jq -r '.id' "$definition_file")"
  [[ -z "${service_files[$service_id]+x}" ]] || fail "Service ID is used twice: $service_id"
  service_files[$service_id]="$definition_file"
  service_names[$service_id]="$(jq -r '.name' "$definition_file")"
done

mapfile -t profile_services < <(jq -r '.services[]' "$profile_file")
mapfile -t profile_setups < <(jq -r '.setups[]' "$profile_file")

for service_id in "${profile_services[@]}"; do
  [[ -n "${service_files[$service_id]+x}" ]] || fail "Unknown service: $service_id"
  [[ -z "${selected_services[$service_id]+x}" ]] || fail "Service is selected twice: $service_id"
  selected_services[$service_id]=1
done

for service_id in "${profile_setups[@]}"; do
  [[ -n "${selected_services[$service_id]+x}" ]] || fail "Setup service is not selected: $service_id"
  [[ -z "${selected_setups[$service_id]+x}" ]] || fail "Setup is selected twice: $service_id"
  selected_setups[$service_id]=1
done

for service_id in "${profile_services[@]}"; do
  definition_file="${service_files[$service_id]}"

  while IFS= read -r needed_id; do
    [[ -n "${selected_services[$needed_id]+x}" ]] || fail "$service_id needs missing service: $needed_id"
  done < <(jq -r '.needs[]' "$definition_file")

  while IFS= read -r compose_file; do
    [[ -f "$PROJECT_ROOT/$compose_file" ]] || fail "$service_id has missing Compose file: $compose_file"
  done < <(jq -r '.composeFiles[]' "$definition_file")
done

for service_id in "${profile_setups[@]}"; do
  definition_file="${service_files[$service_id]}"
  jq -e '.setup != null' "$definition_file" >/dev/null || fail "$service_id has no setup."

  setup_script="$(jq -r '.setup.linuxScript' "$definition_file")"
  [[ -f "$PROJECT_ROOT/$setup_script" ]] || fail "$service_id has missing setup script: $setup_script"

  while IFS= read -r needed_id; do
    [[ -n "${selected_services[$needed_id]+x}" ]] || fail "$service_id setup needs missing service: $needed_id"
  done < <(jq -r '.setup.needsRunning[]' "$definition_file")

  while IFS= read -r needed_id; do
    [[ -n "${completed_setups[$needed_id]+x}" ]] || fail "$service_id setup must run after: $needed_id"
  done < <(jq -r '.setup.runsAfterSetup[]' "$definition_file")

  completed_setups[$service_id]=1
done

profile_name="$(jq -r '.name' "$profile_file")"
printf 'Plan: %s\n\n' "$profile_name"

printf 'Services:\n'
for index in "${!profile_services[@]}"; do
  service_id="${profile_services[$index]}"
  printf '  %d. %s (%s)\n' "$((index + 1))" "${service_names[$service_id]}" "$service_id"
done

printf '\nSetup order:\n'
if ((${#profile_setups[@]} == 0)); then
  printf '  None\n'
else
  for index in "${!profile_setups[@]}"; do
    service_id="${profile_setups[$index]}"
    printf '  %d. %s (%s)\n' "$((index + 1))" "${service_names[$service_id]}" "$service_id"
  done
fi

printf '\nPlan is valid. Nothing was changed.\n'
