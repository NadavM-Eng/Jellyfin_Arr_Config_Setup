# shellcheck shell=bash

# Read a Compose manifest into the named Bash array.
load_compose_manifest() {
  local project_root="$1"
  local manifest_file="$2"
  local output_name="$3"
  local -n output_files="$output_name"
  local line

  output_files=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    output_files+=("$project_root/$line")
  done < "$manifest_file"
}

# Run Docker Compose with the files in the named Bash array.
run_compose_files() {
  local project_root="$1"
  local env_file="$2"
  local files_name="$3"
  shift 3

  local -n compose_files="$files_name"
  local command=(docker compose --project-directory "$project_root" --env-file "$env_file")
  local file

  for file in "${compose_files[@]}"; do
    command+=( -f "$file" )
  done

  command+=( "$@" )
  "${command[@]}"
}
