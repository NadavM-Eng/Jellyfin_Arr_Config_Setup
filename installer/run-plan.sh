#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/installer/services"
PROFILES_DIR="$PROJECT_ROOT/installer/profiles"
PLAN_CHECKER="$PROJECT_ROOT/installer/show-plan.sh"
COMPOSE_HELPER="$PROJECT_ROOT/lib/linux/compose.sh"
ENV_FILE="$PROJECT_ROOT/.env"

heading() {
  printf '\n========================================================================\n'
  printf '%s\n' "$1"
  printf '========================================================================\n'
}

info() { printf '[+] %s\n' "$1"; }
fail() { printf '[X] %s\n' "$1" >&2; exit 1; }

profile_input="${1:-quick}"
if [[ -f "$profile_input" ]]; then
  profile_file="$profile_input"
else
  profile_file="$PROFILES_DIR/${profile_input%.json}.json"
fi

[[ -f "$PLAN_CHECKER" ]] || fail "Missing plan checker: $PLAN_CHECKER"
[[ -f "$COMPOSE_HELPER" ]] || fail "Missing Linux Compose helper: $COMPOSE_HELPER"

bash "$PLAN_CHECKER" "$profile_input"

[[ -f "$ENV_FILE" ]] || fail "Existing .env required. Run Quick Setup first."
command -v jq >/dev/null 2>&1 || fail "jq is required."
command -v docker >/dev/null 2>&1 || fail "Docker was not found in PATH."
docker info >/dev/null 2>&1 || fail "Docker is installed, but the Docker daemon is not available."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is not available."

# shellcheck disable=SC1090
source "$COMPOSE_HELPER"

declare -A service_files=()
plan_compose_files=()

shopt -s nullglob
definition_files=("$SERVICES_DIR"/*.json)

for definition_file in "${definition_files[@]}"; do
  service_id="$(jq -r '.id' "$definition_file")"
  service_files[$service_id]="$definition_file"
done

mapfile -t selected_services < <(jq -r '.services[]' "$profile_file")
mapfile -t selected_setups < <(jq -r '.setups[]' "$profile_file")

for service_id in "${selected_services[@]}"; do
  definition_file="${service_files[$service_id]}"

  while IFS= read -r compose_file; do
    plan_compose_files+=("$PROJECT_ROOT/$compose_file")
  done < <(jq -r '.composeFiles[]' "$definition_file")
done

heading "VALIDATING COMPOSE"
run_compose_files "$PROJECT_ROOT" "$ENV_FILE" plan_compose_files config --quiet
info "Compose configuration is valid."

heading "IMAGES TO DOWNLOAD / USE"
run_compose_files "$PROJECT_ROOT" "$ENV_FILE" plan_compose_files config --images |
  sort -u |
  sed 's/^/  - /'

printf '\nRun this plan? [y/N]: '
read -r answer
case "${answer:-N}" in
  y|Y|yes|YES|Yes) ;;
  *) info "Cancelled."; exit 0 ;;
esac

heading "PULLING IMAGES"
run_compose_files "$PROJECT_ROOT" "$ENV_FILE" plan_compose_files pull

heading "STARTING CONTAINERS"
run_compose_files "$PROJECT_ROOT" "$ENV_FILE" plan_compose_files up -d

profile_id="$(jq -r '.id' "$profile_file")"
if [[ "$profile_id" == "quick" ]]; then
  bash "$PROJECT_ROOT/linux-setup.sh" verify
fi

heading "APPLICATION SETUP"
for service_id in "${selected_setups[@]}"; do
  definition_file="${service_files[$service_id]}"
  setup_script="$(jq -r '.setup.linuxScript' "$definition_file")"

  info "Setting up $service_id..."
  bash "$PROJECT_ROOT/$setup_script"
  info "$service_id setup completed."
done

heading "STACK STATUS"
run_compose_files "$PROJECT_ROOT" "$ENV_FILE" plan_compose_files ps

heading "PLAN COMPLETE"
info "The selected services are running and configured."
