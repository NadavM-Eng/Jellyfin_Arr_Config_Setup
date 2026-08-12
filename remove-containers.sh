#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
QUICK_MANIFEST="$PROJECT_ROOT/quick-stack.txt"

[[ -f "$ENV_FILE" ]] || {
    printf '[X] Missing .env file: %s\n' "$ENV_FILE" >&2
    exit 1
}

[[ -f "$QUICK_MANIFEST" ]] || {
    printf '[X] Missing quick-stack.txt.\n' >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    printf '[X] Docker was not found.\n' >&2
    exit 1
}

mapfile -t compose_files < <(
    grep -vE '^[[:space:]]*(#|$)' \
        "$QUICK_MANIFEST"
)

compose_args=()

for file in "${compose_files[@]}"; do
    compose_args+=(
        -f "$PROJECT_ROOT/$file"
    )
done

docker compose \
    --project-directory "$PROJECT_ROOT" \
    --env-file "$ENV_FILE" \
    "${compose_args[@]}" \
    down --remove-orphans
