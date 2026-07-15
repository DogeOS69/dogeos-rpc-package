#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/prepare-data-dir.sh <env-file>

Example:
  scripts/prepare-data-dir.sh .env.testnet
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ENV_FILE="${1:-}"
[ -n "$ENV_FILE" ] || { usage; exit 1; }
[ -f "$ENV_FILE" ] || fail "env file not found: $ENV_FILE"

ENV_DIR="$(cd "$(dirname "$ENV_FILE")" && pwd -P)"
ENV_FILE_ABS="$ENV_DIR/$(basename "$ENV_FILE")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE_ABS"
set +a

[ -n "${NETWORK:-}" ] || fail "NETWORK must be set in $ENV_FILE"
[ -n "${DATA_ROOT:-}" ] || fail "DATA_ROOT must be set in $ENV_FILE"

case "$DATA_ROOT" in
  /*) ;;
  *) fail "DATA_ROOT must be an absolute path, got: $DATA_ROOT" ;;
esac

DATA_ROOT_ABS="$(readlink -m "$DATA_ROOT")"
REPO_ROOT_ABS="$(readlink -m "$REPO_ROOT")"

case "$DATA_ROOT_ABS" in
  "$REPO_ROOT_ABS"|"$REPO_ROOT_ABS"/*)
    fail "DATA_ROOT must not be inside the repository: $DATA_ROOT_ABS"
    ;;
esac

case "$DATA_ROOT_ABS" in
  /|/tmp|/var/tmp)
    fail "DATA_ROOT is too broad or temporary: $DATA_ROOT_ABS"
    ;;
esac

echo "Network: $NETWORK"
echo "Data root: $DATA_ROOT_ABS"
echo

mkdir -p \
  "$DATA_ROOT_ABS/l2reth" \
  "$DATA_ROOT_ABS/l1-interface"

for dir in \
  "$DATA_ROOT_ABS/l2reth" \
  "$DATA_ROOT_ABS/l1-interface"
do
  test_file="$dir/.dogeos-write-test"
  if ! touch "$test_file" 2>/dev/null; then
    fail "current user cannot write to $dir. Create it with the correct owner or adjust permissions."
  fi
  rm -f "$test_file"
done

echo "Prepared directories:"
echo "  $DATA_ROOT_ABS/l2reth"
echo "  $DATA_ROOT_ABS/l1-interface"
echo
echo "Note: Dogecoin data lives in the named Docker volume \${DOGECOIN_VOLUME_NAME}, not under DATA_ROOT."
echo

echo "Filesystem:"
df -hP "$DATA_ROOT_ABS"
echo

echo "OK: DATA_ROOT is ready for docker compose --env-file $ENV_FILE up -d"
