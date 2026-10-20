#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Reset the bind-mounted L1 Interface and L2Reth data directories.

Usage:
  scripts/reset-chain-data.sh [options] [env-file]

The env file defaults to .env in the repository root.

Examples:
  # Recommended: move existing data to timestamped backup directories.
  scripts/reset-chain-data.sh

  # Irreversibly delete existing data instead of keeping backups.
  scripts/reset-chain-data.sh --delete --yes

Options:
  --delete  Permanently delete the existing l1-interface and l2reth data.
            Without this option, both directories are moved to timestamped
            backups beside the new empty directories.
  --yes     Confirm the irreversible operation required by --delete.
  -h, --help
            Show this help.

This script stops the Compose project before resetting data. It does not touch
Dogecoin data (a Docker volume or DATA_ROOT/dogecoin) or DATA_ROOT/.snapshot-cache.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

DELETE=false
CONFIRMED=false
ENV_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --delete)
      DELETE=true
      shift
      ;;
    --yes)
      CONFIRMED=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [ -z "$ENV_FILE" ] || fail "only one env file may be supplied"
      ENV_FILE="$1"
      shift
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ -z "$ENV_FILE" ]; then
  ENV_FILE="$REPO_ROOT/.env"
  [ -f "$ENV_FILE" ] || fail "no env file given and $ENV_FILE does not exist; create it from networks/<network>/env.example"
fi

if "$CONFIRMED" && ! "$DELETE"; then
  fail "--yes is only valid together with --delete"
fi

if "$DELETE" && ! "$CONFIRMED"; then
  fail "--delete is irreversible; pass --delete --yes to confirm"
fi

require_command docker
require_command readlink

[ -f "$ENV_FILE" ] || fail "env file not found: $ENV_FILE"

ENV_DIR="$(cd "$(dirname "$ENV_FILE")" && pwd -P)"
ENV_FILE_ABS="$ENV_DIR/$(basename "$ENV_FILE")"
REPO_ROOT_ABS="$(readlink -m "$REPO_ROOT")"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE_ABS"
set +a

[ -n "${DATA_ROOT:-}" ] || fail "DATA_ROOT must be set in $ENV_FILE"
echo "Using env file: $ENV_FILE_ABS (NETWORK=${NETWORK:-unset})"

case "$DATA_ROOT" in
  /*) ;;
  *) fail "DATA_ROOT must be an absolute path, got: $DATA_ROOT" ;;
esac

DATA_ROOT_ABS="$(readlink -m "$DATA_ROOT")"

case "$DATA_ROOT_ABS" in
  /path/to|/path/to/*)
    fail "replace the DATA_ROOT placeholder with your mounted data disk path: $DATA_ROOT_ABS"
    ;;
  /|/tmp|/var/tmp)
    fail "DATA_ROOT is too broad or temporary: $DATA_ROOT_ABS"
    ;;
  "$REPO_ROOT_ABS"|"$REPO_ROOT_ABS"/*)
    fail "DATA_ROOT must not be inside the repository: $DATA_ROOT_ABS"
    ;;
esac

case "$DATA_ROOT_ABS" in
  /mnt/wsl/*)
    if ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
      fail "DATA_ROOT uses a WSL-only path on a non-WSL host: $DATA_ROOT_ABS"
    fi
    ;;
esac

L1_DIR="$DATA_ROOT_ABS/l1-interface"
L2_DIR="$DATA_ROOT_ABS/l2reth"

[ ! -L "$L1_DIR" ] || fail "refusing to reset symlink: $L1_DIR"
[ ! -L "$L2_DIR" ] || fail "refusing to reset symlink: $L2_DIR"

echo "Data reset targets:"
echo "  $L1_DIR"
echo "  $L2_DIR"
echo "Dogecoin data and the snapshot cache will be preserved."
echo

echo "Stopping Compose services..."
(
  cd "$REPO_ROOT_ABS"
  docker compose --project-directory "$REPO_ROOT_ABS" --env-file "$ENV_FILE_ABS" down
)

if "$DELETE"; then
  echo "Permanently deleting L1 Interface and L2Reth data..."
  rm -rf -- "$L1_DIR" "$L2_DIR"
else
  RESET_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  L1_BACKUP="$DATA_ROOT_ABS/l1-interface.backup-$RESET_STAMP"
  L2_BACKUP="$DATA_ROOT_ABS/l2reth.backup-$RESET_STAMP"

  [ ! -e "$L1_BACKUP" ] || fail "backup path already exists: $L1_BACKUP"
  [ ! -e "$L2_BACKUP" ] || fail "backup path already exists: $L2_BACKUP"

  if [ -e "$L1_DIR" ]; then
    mv -- "$L1_DIR" "$L1_BACKUP"
    echo "L1 Interface backup: $L1_BACKUP"
  fi

  if [ -e "$L2_DIR" ]; then
    mv -- "$L2_DIR" "$L2_BACKUP"
    echo "L2Reth backup: $L2_BACKUP"
  fi
fi

mkdir -p "$L1_DIR" "$L2_DIR"

echo
echo "Reset complete. Empty data directories were created; the services remain stopped."
echo "Next, from $REPO_ROOT_ABS, restore the published L2Reth snapshot and start"
echo "the stack:"
if [ "$ENV_FILE_ABS" = "$REPO_ROOT_ABS/.env" ]; then
  echo "  ./scripts/restore-snapshot.sh --no-start l2reth"
  echo "  docker compose up -d"
else
  printf '  ./scripts/restore-snapshot.sh --no-start l2reth %q\n' "$ENV_FILE_ABS"
  printf '  docker compose --env-file %q up -d\n' "$ENV_FILE_ABS"
fi
