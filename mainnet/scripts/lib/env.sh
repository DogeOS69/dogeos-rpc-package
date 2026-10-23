# shellcheck shell=bash
# Helpers for this network's scripts. Source this file; callers define fail().
#
# Settings are taken from the configuration Docker Compose resolves, never by
# reading the env file directly: Compose syntax is not shell syntax, exported
# shell variables take precedence over the file, and values may reference
# other variables. The scripts therefore always act on the same DATA_ROOT that
# `docker compose up` uses.

JQ_IMAGE="ghcr.io/jqlang/jq:1.7.1"

# jq from the host, or from a pinned container image. Input must come from
# stdin so the container variant can read it.
jqx() {
  if command -v jq >/dev/null 2>&1; then
    jq "$@"
  else
    docker run --rm -i "$JQ_IMAGE" "$@"
  fi
}

# resolve_env_file <arg-or-empty> <network-dir>: print the absolute env file
# path, defaulting to .env in the network directory.
resolve_env_file() {
  local file="$1" network_dir="$2"
  if [ -z "$file" ]; then
    file="$network_dir/.env"
    [ -f "$file" ] ||
      fail "no env file given and $file does not exist; create it from $network_dir/env.example"
  fi
  [ -f "$file" ] || fail "env file not found: $file"
  printf '%s/%s\n' "$(cd "$(dirname "$file")" && pwd -P)" "$(basename "$file")"
}

# compose_config_json <env-file> <network-dir>: print the resolved configuration.
compose_config_json() {
  docker compose -f "$2/docker-compose.yml" --project-directory "$2" \
    --env-file "$1" config --format json ||
    fail "docker compose cannot read the configuration for $1"
}

# config_data_root: DATA_ROOT, from the L2Reth data mount. Reads the
# configuration JSON on stdin.
config_data_root() {
  jqx -r '.services["l2reth-node"].volumes // [] | map(select(.target == "/l2reth"))
    | first | .source // "" | rtrimstr("/l2reth")'
}

# check_data_path <name> <path> <repo-root-abs>: print the normalized path, or
# fail for placeholder, broad, temporary, in-repository, or WSL-only paths.
check_data_path() {
  local name="$1" path="$2" repo_root_abs="$3"
  case "$path" in
    /*) ;;
    *) fail "$name must be an absolute path, got: $path" ;;
  esac
  path="$(readlink -m "$path")"
  case "$path" in
    /path/to|/path/to/*)
      fail "replace the $name placeholder with your mounted data disk path: $path" ;;
    /|/tmp|/var/tmp)
      fail "$name is too broad or temporary: $path" ;;
    "$repo_root_abs"|"$repo_root_abs"/*)
      fail "$name must not be inside the repository: $path" ;;
    /mnt/wsl/*)
      grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null ||
        fail "$name uses a WSL-only path on a non-WSL host: $path" ;;
  esac
  printf '%s\n' "$path"
}
