#!/usr/bin/env bash
set -euo pipefail

# Update these two values together when publishing a newer testnet snapshot.
DEFAULT_SNAPSHOT_URL="https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/l2reth/dogeos-l2reth-testnet-5350474-20260730.tar.gz"
DEFAULT_SNAPSHOT_SHA256="8dbdd977f8ee6a68dcf15db87453a170c6c0d0beaadc1d46f8391fdc167db115"

usage() {
  cat <<'USAGE'
Restore the published L2Reth testnet snapshot into DATA_ROOT and start L2Reth.

Usage:
  scripts/restore-l2reth-snapshot.sh [options] <env-file>

Example:
  scripts/restore-l2reth-snapshot.sh .env.testnet

Options:
  --force                 Replace a non-empty l2reth directory. The old
                          directory is moved to a timestamped backup.
  --no-start              Restore the snapshot without starting l2reth-node.
  --snapshot-url URL      Override the built-in snapshot URL.
  --sha256 SHA256         Override the built-in snapshot SHA-256.
  --cache-dir DIR         Download/cache directory. Defaults to
                          DATA_ROOT/.snapshot-cache.
  -h, --help              Show this help.

Environment overrides:
  L2RETH_SNAPSHOT_URL
  L2RETH_SNAPSHOT_SHA256
  L2RETH_SNAPSHOT_CACHE_DIR

The archive contains chain data only. The current genesis, hardfork schedule,
peer list, and runtime settings always come from dogeos-rpc-package.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

FORCE=false
START_AFTER_RESTORE=true
SNAPSHOT_URL="${L2RETH_SNAPSHOT_URL:-$DEFAULT_SNAPSHOT_URL}"
SNAPSHOT_SHA256="${L2RETH_SNAPSHOT_SHA256:-$DEFAULT_SNAPSHOT_SHA256}"
CACHE_DIR="${L2RETH_SNAPSHOT_CACHE_DIR:-}"
ENV_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --no-start)
      START_AFTER_RESTORE=false
      shift
      ;;
    --snapshot-url)
      [ "$#" -ge 2 ] || fail "--snapshot-url requires a value"
      SNAPSHOT_URL="$2"
      shift 2
      ;;
    --sha256)
      [ "$#" -ge 2 ] || fail "--sha256 requires a value"
      SNAPSHOT_SHA256="$2"
      shift 2
      ;;
    --cache-dir)
      [ "$#" -ge 2 ] || fail "--cache-dir requires a value"
      CACHE_DIR="$2"
      shift 2
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

[ -n "$ENV_FILE" ] || {
  usage >&2
  exit 1
}

require_command curl
require_command docker
require_command sha256sum
require_command tar

[ -f "$ENV_FILE" ] || fail "env file not found: $ENV_FILE"
ENV_DIR="$(cd "$(dirname "$ENV_FILE")" && pwd -P)"
ENV_FILE_ABS="$ENV_DIR/$(basename "$ENV_FILE")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE_ABS"
set +a

[ "${NETWORK:-}" = "testnet" ] ||
  fail "this published snapshot is for NETWORK=testnet, got: ${NETWORK:-unset}"
[ -n "${DATA_ROOT:-}" ] || fail "DATA_ROOT must be set in $ENV_FILE"

case "$DATA_ROOT" in
  /*) ;;
  *) fail "DATA_ROOT must be an absolute path, got: $DATA_ROOT" ;;
esac

DATA_ROOT_ABS="$(readlink -m "$DATA_ROOT")"
REPO_ROOT_ABS="$(readlink -m "$REPO_ROOT")"

case "$DATA_ROOT_ABS" in
  /|/tmp|/var/tmp)
    fail "DATA_ROOT is too broad or temporary: $DATA_ROOT_ABS"
    ;;
  "$REPO_ROOT_ABS"|"$REPO_ROOT_ABS"/*)
    fail "DATA_ROOT must not be inside the repository: $DATA_ROOT_ABS"
    ;;
esac

case "$SNAPSHOT_URL" in
  https://*) ;;
  *) fail "snapshot URL must use HTTPS: $SNAPSHOT_URL" ;;
esac

[ "${#SNAPSHOT_SHA256}" -eq 64 ] ||
  fail "snapshot SHA-256 must contain exactly 64 hex characters"
case "$SNAPSHOT_SHA256" in
  *[!0-9a-fA-F]*)
    fail "snapshot SHA-256 must contain only hexadecimal characters"
    ;;
esac

mkdir -p "$DATA_ROOT_ABS"
[ -w "$DATA_ROOT_ABS" ] ||
  fail "DATA_ROOT is not writable by the current user: $DATA_ROOT_ABS"

if [ -z "$CACHE_DIR" ]; then
  CACHE_DIR="$DATA_ROOT_ABS/.snapshot-cache"
fi
case "$CACHE_DIR" in
  /*) ;;
  *) CACHE_DIR="$(readlink -m "$PWD/$CACHE_DIR")" ;;
esac

TARGET_DIR="$DATA_ROOT_ABS/l2reth"
case "$CACHE_DIR" in
  "$TARGET_DIR"|"$TARGET_DIR"/*)
    fail "cache directory must not be inside the L2Reth data directory"
    ;;
esac

ARCHIVE_NAME="${SNAPSHOT_URL%%\?*}"
ARCHIVE_NAME="${ARCHIVE_NAME##*/}"
[ -n "$ARCHIVE_NAME" ] || fail "cannot derive archive filename from URL"
case "$ARCHIVE_NAME" in
  *.tar.gz) ;;
  *) fail "snapshot filename must end in .tar.gz: $ARCHIVE_NAME" ;;
esac

mkdir -p "$CACHE_DIR"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE_NAME"
PARTIAL_PATH="$ARCHIVE_PATH.partial"

verify_checksum() {
  local path="$1"
  printf '%s  %s\n' "$SNAPSHOT_SHA256" "$path" | sha256sum --check --status -
}

if [ -f "$ARCHIVE_PATH" ] && ! verify_checksum "$ARCHIVE_PATH"; then
  INVALID_PATH="$ARCHIVE_PATH.invalid-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Cached archive has the wrong checksum; preserving it as:"
  echo "  $INVALID_PATH"
  mv "$ARCHIVE_PATH" "$INVALID_PATH"
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "Downloading L2Reth snapshot:"
  echo "  $SNAPSHOT_URL"
  echo "Download cache:"
  echo "  $ARCHIVE_PATH"
  echo
  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 3 \
    --continue-at - \
    --output "$PARTIAL_PATH" \
    "$SNAPSHOT_URL"
  mv "$PARTIAL_PATH" "$ARCHIVE_PATH"
else
  echo "Using cached snapshot: $ARCHIVE_PATH"
fi

echo "Verifying SHA-256..."
verify_checksum "$ARCHIVE_PATH" ||
  fail "snapshot checksum mismatch: $ARCHIVE_PATH"
echo "SHA-256 verified."

LISTING_PATH="$(mktemp)"
trap 'rm -f "$LISTING_PATH"' EXIT

echo "Validating archive layout..."
tar -tzf "$ARCHIVE_PATH" >"$LISTING_PATH"

awk '
  /^\// { bad = 1; print "absolute path: " $0 > "/dev/stderr" }
  /(^|\/)\.\.(\/|$)/ {
    bad = 1
    print "parent traversal: " $0 > "/dev/stderr"
  }
  !/^l2reth(\/|$)/ {
    bad = 1
    print "unexpected archive root: " $0 > "/dev/stderr"
  }
  END { exit bad }
' "$LISTING_PATH" || fail "snapshot archive contains unsafe or unexpected paths"

for forbidden_path in \
  "l2reth/jwt.hex" \
  "l2reth/reth.toml" \
  "l2reth/lost+found" \
  "l2reth/genesis" \
  "l2reth/protocol_context.json"
do
  if grep -Fxq "$forbidden_path" "$LISTING_PATH" ||
     grep -Fxq "$forbidden_path/" "$LISTING_PATH"; then
    fail "snapshot contains forbidden path: $forbidden_path"
  fi
done

if grep -Eq '(^|/)(nodekey|keystore[^/]*)(/|$)' "$LISTING_PATH"; then
  fail "snapshot contains a P2P node key or keystore path"
fi

grep -Fxq "l2reth/db/mdbx.dat" "$LISTING_PATH" ||
  fail "snapshot does not contain l2reth/db/mdbx.dat"
grep -Fxq "l2reth/db/scroll.db" "$LISTING_PATH" ||
  fail "snapshot does not contain l2reth/db/scroll.db"
grep -Eq '^l2reth/static_files(/|$)' "$LISTING_PATH" ||
  fail "snapshot does not contain l2reth/static_files"

if [ -d "$TARGET_DIR" ] &&
   find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  if [ "$FORCE" != true ]; then
    fail "$TARGET_DIR is not empty; rerun with --force to preserve it as a backup and restore the snapshot"
  fi
fi

STAGING_DIR="$DATA_ROOT_ABS/.l2reth-snapshot-restore-$$"
[ ! -e "$STAGING_DIR" ] ||
  fail "staging directory already exists: $STAGING_DIR"
mkdir "$STAGING_DIR"

echo "Extracting snapshot to staging directory:"
echo "  $STAGING_DIR"
tar --extract --gzip --file "$ARCHIVE_PATH" \
  --directory "$STAGING_DIR" \
  --no-same-owner

[ -f "$STAGING_DIR/l2reth/db/mdbx.dat" ] ||
  fail "extracted snapshot is missing db/mdbx.dat"
[ -f "$STAGING_DIR/l2reth/db/scroll.db" ] ||
  fail "extracted snapshot is missing db/scroll.db"

cd "$REPO_ROOT"
COMPOSE=(docker compose --env-file "$ENV_FILE_ABS")

echo "Stopping l2reth-node before activating the restored data..."
"${COMPOSE[@]}" stop l2reth-node >/dev/null 2>&1 || true

BACKUP_DIR=""
if [ -d "$TARGET_DIR" ]; then
  if find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    BACKUP_DIR="$DATA_ROOT_ABS/l2reth.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    [ ! -e "$BACKUP_DIR" ] ||
      fail "backup destination already exists: $BACKUP_DIR"
    mv "$TARGET_DIR" "$BACKUP_DIR"
  else
    rmdir "$TARGET_DIR"
  fi
fi

mv "$STAGING_DIR/l2reth" "$TARGET_DIR"
rmdir "$STAGING_DIR"

echo
echo "L2Reth snapshot restored to:"
echo "  $TARGET_DIR"
if [ -n "$BACKUP_DIR" ]; then
  echo "Previous L2Reth data was preserved at:"
  echo "  $BACKUP_DIR"
fi

if [ "$START_AFTER_RESTORE" = true ]; then
  echo
  echo "Starting l2reth-node and its dependencies..."
  "${COMPOSE[@]}" up -d l2reth-node
  echo
  echo "L2Reth container status:"
  "${COMPOSE[@]}" ps l2reth-node
else
  echo
  echo "Restore complete. Start it later with:"
  printf '  docker compose --env-file %q up -d l2reth-node\n' "$ENV_FILE_ABS"
fi

echo
echo "The downloaded archive remains cached at:"
echo "  $ARCHIVE_PATH"
