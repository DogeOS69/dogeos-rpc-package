# Shared helpers for scripts that read the Compose env file. Source this file;
# callers define fail().
#
# The env file uses Docker Compose syntax, which is not shell syntax (unquoted
# values may contain spaces), so it is never sourced. env_value reads single
# keys instead.

# resolve_env_file <arg-or-empty> <repo-root>: print the absolute env file
# path, defaulting to .env in the repository root.
resolve_env_file() {
  local file="$1" repo_root="$2"
  if [ -z "$file" ]; then
    file="$repo_root/.env"
    [ -f "$file" ] ||
      fail "no env file given and $file does not exist; create it from networks/<network>/env.example"
  fi
  [ -f "$file" ] || fail "env file not found: $file"
  printf '%s/%s\n' "$(cd "$(dirname "$file")" && pwd -P)" "$(basename "$file")"
}

# env_value <file> <key>: print the last value assigned to key, without
# surrounding quotes or a trailing " # comment". Variable references are not
# expanded; the keys read by the scripts do not use them.
env_value() {
  local line value=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#export }"
    case "$line" in
      "$2="*) value="${line#*=}" ;;
    esac
  done <"$1"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    *)
      value="${value%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
      ;;
  esac
  printf '%s' "$value"
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
