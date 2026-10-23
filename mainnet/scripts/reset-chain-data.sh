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

NETWORK=mainnet
NETWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=mainnet/scripts/lib/env.sh
. "$NETWORK_DIR/scripts/lib/env.sh"

if "$CONFIRMED" && ! "$DELETE"; then
  fail "--yes is only valid together with --delete"
fi

if "$DELETE" && ! "$CONFIRMED"; then
  fail "--delete is irreversible; pass --delete --yes to confirm"
fi

require_command docker
require_command readlink

ENV_FILE_ABS="$(resolve_env_file "$ENV_FILE" "$NETWORK_DIR")"
# Data must not live anywhere inside the repository checkout.
REPO_ROOT_ABS="$(readlink -m "$NETWORK_DIR/..")"

# DATA_ROOT as Compose resolves it (see scripts/lib/env.sh), so the directories
# reset are the ones the stack mounts.
COMPOSE_JSON="$(compose_config_json "$ENV_FILE_ABS" "$NETWORK_DIR")"
DATA_ROOT="$(printf '%s' "$COMPOSE_JSON" | config_data_root)"
[ -n "$DATA_ROOT" ] || fail "cannot determine DATA_ROOT from the Compose configuration"
echo "Using env file: $ENV_FILE_ABS (NETWORK=$NETWORK, DATA_ROOT=$DATA_ROOT)"

DATA_ROOT_ABS="$(check_data_path DATA_ROOT "$DATA_ROOT" "$REPO_ROOT_ABS")"

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
  cd "$NETWORK_DIR"
  docker compose --project-directory "$NETWORK_DIR" --env-file "$ENV_FILE_ABS" down
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
echo "Next, from $NETWORK_DIR, restore the published L2Reth snapshot and start"
echo "the stack:"
if [ "$ENV_FILE_ABS" = "$NETWORK_DIR/.env" ]; then
  echo "  ./scripts/restore-snapshot.sh --no-start l2reth"
  echo "  docker compose up -d"
else
  printf '  ./scripts/restore-snapshot.sh --no-start l2reth %q\n' "$ENV_FILE_ABS"
  printf '  docker compose --env-file %q up -d\n' "$ENV_FILE_ABS"
fi
