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

generate_rpc_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi

  if command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    return
  fi

  fail "cannot generate Dogecoin RPC password: install openssl or od"
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

case "$NETWORK" in
  *[!A-Za-z0-9_-]*|'') fail "NETWORK contains unsupported characters: $NETWORK" ;;
esac

case "$DATA_ROOT" in
  /*) ;;
  *) fail "DATA_ROOT must be an absolute path, got: $DATA_ROOT" ;;
esac

DATA_ROOT_ABS="$(readlink -m "$DATA_ROOT")"
REPO_ROOT_ABS="$(readlink -m "$REPO_ROOT")"
DOGECOIN_SECRET_DIR="$REPO_ROOT_ABS/secrets/$NETWORK"
DOGECOIN_RPC_USER_FILE="$DOGECOIN_SECRET_DIR/dogecoin_rpc_user"
DOGECOIN_RPC_PASSWORD_FILE="$DOGECOIN_SECRET_DIR/dogecoin_rpc_password"

[ ! -L "$DOGECOIN_SECRET_DIR" ] || fail "Dogecoin secret directory must not be a symlink: $DOGECOIN_SECRET_DIR"

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

case "$DATA_ROOT_ABS" in
  /mnt/wsl/*)
    if ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
      fail "DATA_ROOT uses a WSL-only path on a non-WSL host: $DATA_ROOT_ABS"
    fi
    ;;
esac

echo "Network: $NETWORK"
echo "Data root: $DATA_ROOT_ABS"
echo

umask 077
mkdir -p "$DOGECOIN_SECRET_DIR"
chmod 700 "$DOGECOIN_SECRET_DIR"

if [ ! -e "$DOGECOIN_RPC_USER_FILE" ]; then
  printf '%s\n' doge > "$DOGECOIN_RPC_USER_FILE"
fi

if [ ! -e "$DOGECOIN_RPC_PASSWORD_FILE" ]; then
  generate_rpc_password > "$DOGECOIN_RPC_PASSWORD_FILE"
fi

[ ! -L "$DOGECOIN_RPC_USER_FILE" ] || fail "Dogecoin RPC user secret must not be a symlink: $DOGECOIN_RPC_USER_FILE"
[ ! -L "$DOGECOIN_RPC_PASSWORD_FILE" ] || fail "Dogecoin RPC password secret must not be a symlink: $DOGECOIN_RPC_PASSWORD_FILE"
[ -f "$DOGECOIN_RPC_USER_FILE" ] || fail "Dogecoin RPC user secret is not a regular file: $DOGECOIN_RPC_USER_FILE"
[ -f "$DOGECOIN_RPC_PASSWORD_FILE" ] || fail "Dogecoin RPC password secret is not a regular file: $DOGECOIN_RPC_PASSWORD_FILE"
[ -s "$DOGECOIN_RPC_USER_FILE" ] || fail "Dogecoin RPC user secret is empty: $DOGECOIN_RPC_USER_FILE"
[ -s "$DOGECOIN_RPC_PASSWORD_FILE" ] || fail "Dogecoin RPC password secret is empty: $DOGECOIN_RPC_PASSWORD_FILE"
chmod 600 "$DOGECOIN_RPC_USER_FILE" "$DOGECOIN_RPC_PASSWORD_FILE"

echo "Dogecoin RPC secrets:"
echo "  $DOGECOIN_RPC_USER_FILE"
echo "  $DOGECOIN_RPC_PASSWORD_FILE"
echo "  Existing secret files are preserved. Values are not printed."
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

echo "OK: DATA_ROOT and Dogecoin RPC secrets are ready for docker compose --env-file $ENV_FILE up -d"
