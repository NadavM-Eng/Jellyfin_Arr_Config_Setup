mapfile -t compose_files < <(
    grep -vE '^[[:space:]]*(#|$)' quick-stack.txt
)

compose_args=()

for file in "${compose_files[@]}"; do
    compose_args+=( -f "$file" )
done

docker compose \
    --project-directory "$PWD" \
    --env-file .env \
    "${compose_args[@]}" \
    down --remove-orphans
