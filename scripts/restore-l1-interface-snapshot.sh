#!/usr/bin/env bash
set -euo pipefail

# Update these values together when publishing a newer testnet snapshot set.
# The L1 Interface archive belongs to the same set as the L2Reth archive pinned
# in restore-l2reth-snapshot.sh. REQUIRED_DOGECOIN_HEIGHT is the Dogecoin height
# the archive was indexed against plus the indexer confirmation depth; the
# L1 Interface must never start ahead of its Dogecoin node.
DEFAULT_SNAPSHOT_URL="https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/l1-interface/snapshots/dogeos-l1-interface-testnet-20261114024603.tar.gz"
DEFAULT_SNAPSHOT_SHA256="8a78f7cb0b68e092d66d2b4adb9c0de503e80008d6428503e237e44731f1eb2e"
REQUIRED_DOGECOIN_HEIGHT=68064014

usage() {
  cat <<'USAGE'
Restore the published L1 Interface testnet snapshot into DATA_ROOT.

Usage:
  scripts/restore-l1-interface-snapshot.sh [options] <env-file>

Example:
  scripts/restore-l1-interface-snapshot.sh --no-start .env.testnet

Options:
  --force                 Replace a non-empty l1-interface directory. The old
                          directory is moved to a timestamped backup.
  --no-start              Restore the snapshot without starting services.
  --snapshot-url URL      Override the built-in snapshot URL.
  --sha256 SHA256         Override the built-in snapshot SHA-256.
  --cache-dir DIR         Download/cache directory. Defaults to
                          DATA_ROOT/.snapshot-cache.
  -h, --help              Show this help.

Environment overrides:
  L1_INTERFACE_SNAPSHOT_URL
  L1_INTERFACE_SNAPSHOT_SHA256
  L1_INTERFACE_SNAPSHOT_CACHE_DIR

The archive contains the L1 Interface databases and replay artifacts only.
Configuration, credentials, and the pinned historical artifact come from
dogeos-rpc-package. Without --no-start, the script starts dogecoin-node first
and starts the rest of the stack only after Dogecoin reaches the height the
snapshot requires.
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
SNAPSHOT_URL="${L1_INTERFACE_SNAPSHOT_URL:-$DEFAULT_SNAPSHOT_URL}"
SNAPSHOT_SHA256="${L1_INTERFACE_SNAPSHOT_SHA256:-$DEFAULT_SNAPSHOT_SHA256}"
CACHE_DIR="${L1_INTERFACE_SNAPSHOT_CACHE_DIR:-}"
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

# Paths below match envs/testnet/l1-interface.env:
#   DOGEOS_L1_INTERFACE_DATABASE_URL            -> /data/l1-interface.sqlite
#   DOGEOS_L1_INTERFACE_REPLAY_READ__SQLITE_PATH -> /data/replay.sqlite
#   replay artifacts are derived from the replay path -> /data/replay.artifacts
# and Compose mounts ${DATA_ROOT}/l1-interface at /data.
TARGET_DIR="$DATA_ROOT_ABS/l1-interface"
case "$CACHE_DIR" in
  "$TARGET_DIR"|"$TARGET_DIR"/*)
    fail "cache directory must not be inside the L1 Interface data directory"
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
  echo "Downloading L1 Interface snapshot:"
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

# Only the two databases and the replay artifact tree are allowed. SQLite
# sidecars, the historical artifact (downloaded by the init job), configuration,
# and credentials must never be part of the archive.
awk '
  /^\// { bad = 1; print "absolute path: " $0 > "/dev/stderr"; next }
  /(^|\/)\.\.(\/|$)/ {
    bad = 1
    print "parent traversal: " $0 > "/dev/stderr"
    next
  }
  /(-wal|-shm|-journal)$/ {
    bad = 1
    print "SQLite sidecar: " $0 > "/dev/stderr"
    next
  }
  $0 == "l1-interface/" { next }
  $0 == "l1-interface/l1-interface.sqlite" { next }
  $0 == "l1-interface/replay.sqlite" { next }
  /^l1-interface\/replay\.artifacts(\/|$)/ { next }
  {
    bad = 1
    print "unexpected archive path: " $0 > "/dev/stderr"
  }
  END { exit bad }
' "$LISTING_PATH" || fail "snapshot archive contains unsafe or unexpected paths"

grep -Fxq "l1-interface/l1-interface.sqlite" "$LISTING_PATH" ||
  fail "snapshot does not contain l1-interface/l1-interface.sqlite"
grep -Fxq "l1-interface/replay.sqlite" "$LISTING_PATH" ||
  fail "snapshot does not contain l1-interface/replay.sqlite"
grep -Eq '^l1-interface/replay\.artifacts(/|$)' "$LISTING_PATH" ||
  fail "snapshot does not contain l1-interface/replay.artifacts"

if [ -d "$TARGET_DIR" ] &&
   find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  if [ "$FORCE" != true ]; then
    fail "$TARGET_DIR is not empty; rerun with --force to preserve it as a backup and restore the snapshot"
  fi
fi

STAGING_DIR="$DATA_ROOT_ABS/.l1-interface-snapshot-restore-$$"
[ ! -e "$STAGING_DIR" ] ||
  fail "staging directory already exists: $STAGING_DIR"
mkdir "$STAGING_DIR"

echo "Extracting snapshot to staging directory:"
echo "  $STAGING_DIR"
tar --extract --gzip --file "$ARCHIVE_PATH" \
  --directory "$STAGING_DIR" \
  --no-same-owner

[ -f "$STAGING_DIR/l1-interface/l1-interface.sqlite" ] ||
  fail "extracted snapshot is missing l1-interface.sqlite"
[ -f "$STAGING_DIR/l1-interface/replay.sqlite" ] ||
  fail "extracted snapshot is missing replay.sqlite"

# Match the permissions the init job applies to a fresh bootstrap directory.
chmod 777 "$STAGING_DIR/l1-interface"
chmod 666 "$STAGING_DIR/l1-interface/replay.sqlite"

cd "$REPO_ROOT"
COMPOSE=(docker compose --env-file "$ENV_FILE_ABS")

echo "Stopping l2reth-node and l1-interface before activating the restored data..."
"${COMPOSE[@]}" stop l2reth-node l1-interface ||
  fail "could not stop l2reth-node and l1-interface (see the error above); $TARGET_DIR was not changed and the extracted snapshot remains at $STAGING_DIR"

BACKUP_DIR=""
if [ -d "$TARGET_DIR" ]; then
  if find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    BACKUP_DIR="$DATA_ROOT_ABS/l1-interface.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    [ ! -e "$BACKUP_DIR" ] ||
      fail "backup destination already exists: $BACKUP_DIR"
    mv "$TARGET_DIR" "$BACKUP_DIR"
  else
    rmdir "$TARGET_DIR"
  fi
fi

mv "$STAGING_DIR/l1-interface" "$TARGET_DIR"
rmdir "$STAGING_DIR"

# The one-shot init job must run again for the new directory so it downloads
# and verifies the pinned historical artifact. It keeps the restored replay DB.
"${COMPOSE[@]}" rm -f l1-interface-init-fetch-sqlite >/dev/null

echo
echo "L1 Interface snapshot restored to:"
echo "  $TARGET_DIR"
if [ -n "$BACKUP_DIR" ]; then
  echo "Previous L1 Interface data was preserved at:"
  echo "  $BACKUP_DIR"
fi

if [ "$START_AFTER_RESTORE" = true ]; then
  echo
  echo "Starting dogecoin-node first; the L1 Interface must not run ahead of it."
  "${COMPOSE[@]}" up -d dogecoin-node
  dogecoin_height() {
    "${COMPOSE[@]}" exec -T dogecoin-node /dogecoin/bin/dogecoin-cli \
      -rpcwait -conf=/run/dogeos/dogecoin.conf -datadir=/data getblockcount
  }
  while :; do
    height="$(dogecoin_height)" ||
      fail "could not read the Dogecoin block height; start the remaining services manually after Dogecoin reaches $REQUIRED_DOGECOIN_HEIGHT"
    if [ "$height" -ge "$REQUIRED_DOGECOIN_HEIGHT" ]; then
      echo "Dogecoin height $height >= required $REQUIRED_DOGECOIN_HEIGHT."
      break
    fi
    echo "Dogecoin height $height; waiting for $REQUIRED_DOGECOIN_HEIGHT..."
    sleep 30
  done
  echo
  echo "Starting the testnet stack..."
  "${COMPOSE[@]}" up -d
  echo
  echo "Container status:"
  "${COMPOSE[@]}" ps
else
  echo
  echo "Restore complete. Before starting l1-interface, make sure Dogecoin has"
  echo "reached block $REQUIRED_DOGECOIN_HEIGHT or higher:"
  printf '  docker compose --env-file %q up -d dogecoin-node\n' "$ENV_FILE_ABS"
  printf '  docker compose --env-file %q exec -T dogecoin-node /dogecoin/bin/dogecoin-cli -rpcwait -conf=/run/dogeos/dogecoin.conf -datadir=/data getblockcount\n' "$ENV_FILE_ABS"
  echo "Then start the remaining services:"
  printf '  docker compose --env-file %q up -d\n' "$ENV_FILE_ABS"
fi

echo
echo "The downloaded archive remains cached at:"
echo "  $ARCHIVE_PATH"
