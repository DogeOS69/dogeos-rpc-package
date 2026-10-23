#!/usr/bin/env bash
set -euo pipefail

# Published snapshots are listed in a per-network index on S3, so a new
# snapshot needs only an S3 upload, not a package release. See
# docs/snapshot-publishing.md in this directory for the index format.
NETWORK=testnet
DEFAULT_INDEX_BASE="https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com"
EXTRACT_IMAGE="alpine:3.20"
SIGNER_IDENTITY="dogeos-snapshots"
SIGNATURE_NAMESPACE="dogeos-snapshot-index"

usage() {
  cat <<'USAGE'
Restore a published testnet Dogecoin, L1 Interface, or L2Reth snapshot.

Usage (in the testnet directory):
  ./scripts/restore-snapshot.sh [options] <dogecoin|l1-interface|l2reth> [env-file]
  ./scripts/restore-snapshot.sh --list [env-file]

The env file defaults to .env in the testnet directory.

Examples:
  ./scripts/restore-snapshot.sh --list
  ./scripts/restore-snapshot.sh --no-start dogecoin
  ./scripts/restore-snapshot.sh l2reth

Legacy schema-1 component restore. For pinned groups use:
  python3 scripts/snapshot-group.py list
  python3 scripts/snapshot-group.py restore GROUP_ID
The newest component snapshot compatible with docker-compose.yml is used.

Services depend on each other as Dogecoin -> L1 Interface -> L2Reth. Before
the restored data is activated, the component and every service that depends
on it are stopped, so L2Reth never runs while L1 Interface data moves
backwards. Staged startup waits for Dogecoin sync and L1 readiness.

Options:
  --list                  List published snapshots and exit.
  --snapshot-id ID        Restore this snapshot instead of the newest one.
  --force                 Replace non-empty bind-mounted data. The old
                          directory is moved to a timestamped backup.
                          Docker volumes are never replaced.
  --no-start              Restore without starting services.
  --index-url URL         Override the snapshot index URL.
  --snapshot-url URL      Skip the index and use this archive. Requires
                          --sha256. No compatibility check is made.
  --sha256 SHA256         SHA-256 of --snapshot-url.
  --cache-dir DIR         Download cache. Defaults to DATA_ROOT/.snapshot-cache.
  --skip-space-check      Do not check free disk space before downloading.
  -h, --help              Show this help.

Environment overrides:
  SNAPSHOT_INDEX_URL      Same as --index-url.
  SNAPSHOT_CACHE_DIR      Same as --cache-dir.
  L2RETH_SNAPSHOT_URL, L2RETH_SNAPSHOT_SHA256, L2RETH_SNAPSHOT_CACHE_DIR
                          Earlier l2reth overrides; still honored.

Requirements: bash, curl, docker, sha256sum, GNU tar, and jq (run from the
ghcr.io/jqlang/jq image when jq is not installed), and Python 3.

Archives contain chain data only. Genesis, configuration, credentials, and
peer settings always come from this package.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

human_size() {
  awk -v b="$1" 'BEGIN {
    if (b == "") { print "?"; exit }
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f %s\n", b, u[i]
  }'
}

LIST=false
FORCE=false
START_AFTER_RESTORE=true
SKIP_SPACE_CHECK=false
SNAPSHOT_ID=""
INDEX_URL="${SNAPSHOT_INDEX_URL:-}"
SNAPSHOT_URL=""
SNAPSHOT_SHA256=""
CACHE_DIR="${SNAPSHOT_CACHE_DIR:-}"
COMPONENT=""
ENV_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) LIST=true; shift ;;
    --force) FORCE=true; shift ;;
    --no-start) START_AFTER_RESTORE=false; shift ;;
    --skip-space-check) SKIP_SPACE_CHECK=true; shift ;;
    --snapshot-id|--index-url|--snapshot-url|--sha256|--cache-dir)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in
        --snapshot-id) SNAPSHOT_ID="$2" ;;
        --index-url) INDEX_URL="$2" ;;
        --snapshot-url) SNAPSHOT_URL="$2" ;;
        --sha256) SNAPSHOT_SHA256="$2" ;;
        --cache-dir) CACHE_DIR="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown option: $1" ;;
    *)
      if [ "$LIST" = false ] && [ -z "$COMPONENT" ]; then
        COMPONENT="$1"
      elif [ -z "$ENV_FILE" ]; then
        ENV_FILE="$1"
      else
        fail "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

# `--list <env-file>` may also be written after a component-less parse.
if [ "$LIST" = true ] && [ -n "$COMPONENT" ] && [ -z "$ENV_FILE" ]; then
  ENV_FILE="$COMPONENT"
  COMPONENT=""
fi

NETWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=testnet/scripts/lib/env.sh
. "$NETWORK_DIR/scripts/lib/env.sh"
ENV_FILE_ABS="$(resolve_env_file "$ENV_FILE" "$NETWORK_DIR")"
if [ "$LIST" = false ]; then
  case "$COMPONENT" in
    dogecoin|l1-interface|l2reth) ;;
    *) fail "component must be dogecoin, l1-interface, or l2reth, got: ${COMPONENT:-none}" ;;
  esac
fi

if [ "$COMPONENT" = l2reth ]; then
  SNAPSHOT_URL="${SNAPSHOT_URL:-${L2RETH_SNAPSHOT_URL:-}}"
  SNAPSHOT_SHA256="${SNAPSHOT_SHA256:-${L2RETH_SNAPSHOT_SHA256:-}}"
  CACHE_DIR="${CACHE_DIR:-${L2RETH_SNAPSHOT_CACHE_DIR:-}}"
fi
if [ -n "$SNAPSHOT_URL" ] || [ -n "$SNAPSHOT_SHA256" ]; then
  [ -n "$SNAPSHOT_URL" ] && [ -n "$SNAPSHOT_SHA256" ] ||
    fail "--snapshot-url and --sha256 must be given together"
  [ -z "$SNAPSHOT_ID" ] || fail "--snapshot-id cannot be combined with --snapshot-url"
fi

require_command curl
require_command docker
require_command sha256sum
require_command tar
require_command python3

COMPOSE=(docker compose -f "$NETWORK_DIR/docker-compose.yml" --project-directory "$NETWORK_DIR" --env-file "$ENV_FILE_ABS")

# DATA_ROOT as Compose resolves it (see scripts/lib/env.sh). Resolved once;
# callers of compose_json run in subshells.
COMPOSE_JSON="$(compose_config_json "$ENV_FILE_ABS" "$NETWORK_DIR")"
compose_json() {
  printf '%s' "$COMPOSE_JSON"
}
DATA_ROOT="$(compose_json | config_data_root)"
[ -n "${DATA_ROOT:-}" ] || fail "cannot determine DATA_ROOT from the Compose configuration"
if [ "$LIST" = false ] && [ "${DOGEOS_GROUP_RESTORE:-}" != 1 ] &&
   [ -e "$DATA_ROOT/.snapshot-group-state.json" ]; then
  fail "data is managed by a snapshot group; use snapshot-group.py restore to preserve dependency metadata"
fi
echo "Using env file: $ENV_FILE_ABS (NETWORK=$NETWORK, DATA_ROOT=$DATA_ROOT)"

# Validate the resolved mount and env (including legacy overrides) before
# downloading anything. The result specifies the network historical-file requirement.
L1_HISTORICAL=none
if [ "$COMPONENT" = l1-interface ]; then
  require_command python3
  L1_HISTORICAL="$(compose_json | python3 "$NETWORK_DIR/scripts/validate-l1-snapshot.py" \
    config --network "$NETWORK")" || fail "L1 Interface data layout does not match this package"
fi

# Data must not live anywhere inside the repository checkout.
REPO_ROOT_ABS="$(readlink -m "$NETWORK_DIR/..")"

# How to repeat a Compose command for this env file, from any directory.
COMPOSE_HINT="cd $(printf '%q' "$NETWORK_DIR") && docker compose"
if [ "$ENV_FILE_ABS" != "$NETWORK_DIR/.env" ]; then
  COMPOSE_HINT="$COMPOSE_HINT --env-file $(printf '%q' "$ENV_FILE_ABS")"
fi

# --- Snapshot index ---------------------------------------------------------

INDEX_URL="${INDEX_URL:-$DEFAULT_INDEX_BASE/$NETWORK/index.json}"
TMP_DIR="$(mktemp -d)"
STAGING_DIR=""
PENDING_BACKUP=""
PENDING_TARGET=""
CREATED_VOLUME=""
cleanup() {
  rm -rf "$TMP_DIR"
  # Interrupted between moving the current data aside and activating the
  # restored data: put the current data back.
  if [ -n "$PENDING_BACKUP" ] && [ ! -e "$PENDING_TARGET" ] && [ -d "$PENDING_BACKUP" ]; then
    echo "Restoring previous data to $PENDING_TARGET" >&2
    mv "$PENDING_BACKUP" "$PENDING_TARGET"
  fi
  # Only this run's own staging directory; it is gone after a successful restore.
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    echo "Removing incomplete staging directory: $STAGING_DIR" >&2
    rm -rf "$STAGING_DIR"
  fi
  # Only a volume this run created and did not finish filling.
  if [ -n "$CREATED_VOLUME" ]; then
    echo "Removing incomplete Docker volume: $CREATED_VOLUME" >&2
    docker volume rm "$CREATED_VOLUME" >/dev/null 2>&1 ||
      echo "Could not remove it; remove it with: docker volume rm $CREATED_VOLUME" >&2
  fi
}
trap cleanup EXIT
INDEX_PATH="$TMP_DIR/index.json"

fetch_index() {
  case "$INDEX_URL" in
    https://*) ;;
    *) fail "snapshot index URL must use HTTPS: $INDEX_URL" ;;
  esac
  curl -fsSL --retry 3 --retry-delay 2 -o "$INDEX_PATH" "$INDEX_URL" ||
    fail "cannot download snapshot index: $INDEX_URL"

  # Signature checking turns on once the package ships a signer list.
  local signers="$NETWORK_DIR/snapshots/allowed_signers"
  if [ -f "$signers" ]; then
    require_command ssh-keygen
    curl -fsSL --retry 3 --retry-delay 2 -o "$INDEX_PATH.sig" "$INDEX_URL.sig" ||
      fail "cannot download snapshot index signature: $INDEX_URL.sig"
    ssh-keygen -Y verify -f "$signers" -I "$SIGNER_IDENTITY" \
      -n "$SIGNATURE_NAMESPACE" -s "$INDEX_PATH.sig" <"$INDEX_PATH" >/dev/null ||
      fail "snapshot index signature verification failed: $INDEX_URL"
    echo "Snapshot index signature verified."
  fi

  local header
  header="$(jqx -r '[.schema_version, .network] | @tsv' <"$INDEX_PATH")" ||
    fail "snapshot index is not valid JSON: $INDEX_URL"
  [ "${header%%$'\t'*}" = 1 ] ||
    fail "unsupported snapshot index schema_version: ${header%%$'\t'*}"
  [ "${header#*$'\t'}" = "$NETWORK" ] ||
    fail "snapshot index is for network ${header#*$'\t'}, not $NETWORK"
}

service_for() {
  case "$1" in
    dogecoin) echo dogecoin-node ;;
    l1-interface) echo l1-interface ;;
    l2reth) echo l2reth-node ;;
  esac
}

# The component and every service downstream of it, downstream first.
# rollup-node treats a lower L1 Interface head as an L1 reorg and unwinds L2
# state, so L2Reth must be stopped whenever data upstream of it is replaced.
services_to_stop() {
  case "$1" in
    dogecoin) echo "l2reth-node l1-interface dogecoin-node" ;;
    l1-interface) echo "l2reth-node l1-interface" ;;
    l2reth) echo "l2reth-node" ;;
  esac
}

# Height of the upstream data a snapshot was built against, when recorded:
# L2Reth -> L1 Interface block (l1_height); L1 Interface -> Dogecoin
# block (dogecoin_height).
UPSTREAM_JQ='(if $c == "l2reth" then .l1_height elif $c == "l1-interface" then .dogecoin_height else null end) // "" | tostring'

service_image() {
  compose_json | jqx -r --arg s "$(service_for "$1")" '.services[$s].image // empty'
}

if [ "$LIST" = true ]; then
  fetch_index
  echo "Snapshot index: $INDEX_URL"
  for component in dogecoin l1-interface l2reth; do
    image="$(service_image "$component")"
    echo
    echo "$component (compose image: $image)"
    rows="$(jqx -r --arg c "$component" --arg img "$image" '
      (.components[$c] // []) | sort_by(.created_at) | reverse | .[]
      | [.id, .created_at, (.height // "" | tostring), ('"$UPSTREAM_JQ"'),
         (.archive.size_bytes // "" | tostring),
         (if ((.compatible_images // []) | index($img)) != null then "yes" else "no" end)]
      | join("\u001f")' <"$INDEX_PATH")"
    if [ -z "$rows" ]; then
      echo "  (no snapshots published)"
      continue
    fi
    printf '  %-16s %-22s %12s %12s %10s  %s\n' ID CREATED HEIGHT UPSTREAM SIZE COMPATIBLE
    while IFS=$'\x1f' read -r id created height upstream size compatible; do
      printf '  %-16s %-22s %12s %12s %10s  %s\n' \
        "$id" "$created" "${height:--}" "${upstream:--}" "$(human_size "$size")" "$compatible"
    done <<<"$rows"
  done
  exit 0
fi

# Listing needs no data directory; restoring does.
DATA_ROOT_ABS="$(check_data_path DATA_ROOT "$DATA_ROOT" "$REPO_ROOT_ABS")"

SERVICE="$(service_for "$COMPONENT")"
SIZE_BYTES=""
UNCOMPRESSED_BYTES=""
HEIGHT=""
UPSTREAM_HEIGHT=""

if [ -n "$SNAPSHOT_URL" ]; then
  echo "Using the snapshot given on the command line; skipping the index and"
  echo "the image compatibility check."
  if [ "${DOGEOS_GROUP_RESTORE:-}" = 1 ]; then
    [ -n "${DOGEOS_GROUP_ENTRY:-}" ] || fail "group entry metadata is missing"
    printf '%s' "$DOGEOS_GROUP_ENTRY" | jqx -e --arg url "$SNAPSHOT_URL" --arg sha "$SNAPSHOT_SHA256" \
      '.archive.url == $url and .archive.sha256 == $sha' >/dev/null || fail "group entry does not match archive"
    SIZE_BYTES="$(printf '%s' "$DOGEOS_GROUP_ENTRY" | jqx -r '.archive.size_bytes')"
    UNCOMPRESSED_BYTES="$(printf '%s' "$DOGEOS_GROUP_ENTRY" | jqx -r '.archive.uncompressed_bytes')"
  fi
else
  fetch_index
  IMAGE="$(service_image "$COMPONENT")"
  [ -n "$IMAGE" ] || fail "cannot determine the $SERVICE image from docker compose"

  ENTRY="$(jqx -c --arg c "$COMPONENT" --arg id "$SNAPSHOT_ID" --arg img "$IMAGE" '
    (.components[$c] // []) | sort_by(.created_at) | reverse
    | if $id != "" then map(select(.id == $id))
      else map(select(((.compatible_images // []) | index($img)) != null)) end
    | first // empty' <"$INDEX_PATH")"

  if [ -z "$ENTRY" ]; then
    if [ -n "$SNAPSHOT_ID" ]; then
      fail "snapshot $SNAPSHOT_ID is not listed for $COMPONENT; see --list"
    fi
    fail "no published $COMPONENT snapshot is compatible with $IMAGE; see --list"
  fi

  FIELDS="$(
    printf '%s' "$ENTRY" | jqx -r --arg img "$IMAGE" --arg c "$COMPONENT" '
      [.id, .created_at, (.height // "" | tostring), ('"$UPSTREAM_JQ"'),
       .archive.url, .archive.sha256,
       (.archive.size_bytes // "" | tostring),
       (.archive.uncompressed_bytes // "" | tostring),
       (.manifest_url // ""),
       (if ((.compatible_images // []) | index($img)) != null then "yes" else "no" end)]
      | join("\u001f")')" || fail "snapshot index entry is malformed"
  IFS=$'\x1f' read -r SELECTED_ID CREATED_AT HEIGHT UPSTREAM_HEIGHT SNAPSHOT_URL SNAPSHOT_SHA256 \
    SIZE_BYTES UNCOMPRESSED_BYTES MANIFEST_URL COMPATIBLE <<<"$FIELDS"
  [ "$COMPATIBLE" = yes ] ||
    fail "snapshot $SELECTED_ID does not list $IMAGE as compatible; see --list"

  echo "Selected $COMPONENT snapshot $SELECTED_ID"
  echo "  created: $CREATED_AT   height: ${HEIGHT:-unknown}   size: $(human_size "$SIZE_BYTES")"
  echo "  compatible with: $IMAGE"
  [ -z "$MANIFEST_URL" ] || echo "  manifest: $MANIFEST_URL"
fi

# Warn when the snapshot is ahead of the running service it depends on. That
# requires upstream catch-up; legacy metadata alone cannot prove compatibility.
check_upstream() {
  local current="" upstream_name=""
  case "$COMPONENT" in
    l2reth)
      upstream_name="L1 Interface"
      if [ -n "$UPSTREAM_HEIGHT" ]; then
        # The published L1 Interface RPC port, on the address it is bound to.
        local l1_rpc
        l1_rpc="$(compose_json | jqx -r '.services["l1-interface"].ports // [] | map(select(.target == 8545)) | first
          | if . == null then "" else
              "\((if (.host_ip // "") == "" or .host_ip == "0.0.0.0" then "127.0.0.1" else .host_ip end)):\(.published)" end')"
        current="$(curl -fsS --max-time 3 -H 'content-type: application/json' \
          --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
          "http://$l1_rpc" 2>/dev/null | jqx -r '.result // empty' 2>/dev/null || true)"
        case "$current" in 0x*) current=$((current)) ;; *) current="" ;; esac
      fi
      ;;
    l1-interface)
      upstream_name="Dogecoin"
      if [ -n "$UPSTREAM_HEIGHT" ]; then
        current="$("${COMPOSE[@]}" exec -T dogecoin-node /dogecoin/bin/dogecoin-cli \
          -conf=/run/dogeos/dogecoin.conf -datadir=/data getblockcount 2>/dev/null || true)"
        case "$current" in ''|*[!0-9]*) current="" ;; esac
      fi
      ;;
    dogecoin)
      if [ -n "$HEIGHT" ]; then
        echo "Note: if L1 Interface has indexed Dogecoin beyond height $HEIGHT, it restarts"
        echo "until the restored node catches up. Verify checkpoints before starting downstream."
      fi
      return 0
      ;;
  esac
  [ -n "$UPSTREAM_HEIGHT" ] || return 0
  if [ -z "$current" ]; then
    echo "Note: could not read the running $upstream_name height to compare with this"
    echo "snapshot ($UPSTREAM_HEIGHT)."
  elif [ "$current" -lt "$UPSTREAM_HEIGHT" ]; then
    echo "WARNING: this snapshot was built against $upstream_name height $UPSTREAM_HEIGHT,"
    echo "but the running $upstream_name is at $current. Verify the required checkpoint"
    echo "before starting downstream; legacy component restore does not enforce this checkpoint."
  fi
}
check_upstream

case "$SNAPSHOT_URL" in
  https://*) ;;
  *) fail "snapshot URL must use HTTPS: $SNAPSHOT_URL" ;;
esac
[ "${#SNAPSHOT_SHA256}" -eq 64 ] ||
  fail "snapshot SHA-256 must contain exactly 64 hex characters"
case "$SNAPSHOT_SHA256" in
  *[!0-9a-fA-F]*) fail "snapshot SHA-256 must contain only hexadecimal characters" ;;
esac

# --- Restore target ---------------------------------------------------------

# L2Reth and L1 Interface data are directories under DATA_ROOT. Dogecoin data is
# whatever the network's compose file mounts at /data: a Docker volume
# (testnet) or a directory (mainnet).
TARGET_DIR=""
TARGET_VOLUME=""
case "$COMPONENT" in
  l2reth)
    TARGET_DIR="$DATA_ROOT_ABS/l2reth"
    ARCHIVE_ROOT="l2reth"
    STRIP_COMPONENTS=0
    ;;
  l1-interface)
    TARGET_DIR="$DATA_ROOT_ABS/l1-interface"
    [ ! -L "$TARGET_DIR" ] || fail "refusing to replace a symlink: $TARGET_DIR"
    [ ! -e "$TARGET_DIR" ] || [ -d "$TARGET_DIR" ] || fail "not a directory: $TARGET_DIR"
    ARCHIVE_ROOT="l1-interface"
    STRIP_COMPONENTS=0
    ;;
  dogecoin)
    ARCHIVE_ROOT="dogecoin"
    STRIP_COMPONENTS=1
    IFS=$'\x1f' read -r DATA_TYPE DATA_SOURCE < <(compose_json | jqx -r '
      (.services["dogecoin-node"].volumes // [] | map(select(.target == "/data")) | first) as $m
      | if $m == null then "" else
          [$m.type, (if $m.type == "volume" then (.volumes[$m.source].name // $m.source) else $m.source end)]
          | join("\u001f") end')
    case "$DATA_TYPE" in
      volume) TARGET_VOLUME="$DATA_SOURCE" ;;
      bind) TARGET_DIR="$(check_data_path "Dogecoin data directory" "$DATA_SOURCE" "$REPO_ROOT_ABS")" ;;
      *) fail "cannot determine where dogecoin-node keeps its data" ;;
    esac
    COMPOSE_PROJECT="$(compose_json | jqx -r '.name')"
    ;;
esac

if [ -n "$TARGET_VOLUME" ]; then
  docker info >/dev/null 2>&1 || fail "cannot reach the Docker daemon"
  if docker volume inspect "$TARGET_VOLUME" >/dev/null 2>&1; then
    fail "Docker volume $TARGET_VOLUME already exists. Keep it, set a new, unused
DOGECOIN_VOLUME_NAME in $ENV_FILE_ABS to restore into, and rerun."
  fi
elif [ -d "$TARGET_DIR" ] &&
     find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q . &&
     [ "$FORCE" != true ]; then
  fail "$TARGET_DIR is not empty; rerun with --force to keep it as a backup and restore the snapshot"
fi

mkdir -p "$DATA_ROOT_ABS"
[ -w "$DATA_ROOT_ABS" ] || fail "DATA_ROOT is not writable by the current user: $DATA_ROOT_ABS"
if [ -n "$TARGET_DIR" ]; then
  TARGET_PARENT="$(dirname "$TARGET_DIR")"
  mkdir -p "$TARGET_PARENT"
  [ -w "$TARGET_PARENT" ] || fail "not writable by the current user: $TARGET_PARENT"
fi

CACHE_DIR="${CACHE_DIR:-$DATA_ROOT_ABS/.snapshot-cache}"
case "$CACHE_DIR" in
  /*) ;;
  *) CACHE_DIR="$(readlink -m "$PWD/$CACHE_DIR")" ;;
esac
CACHE_BASE="$CACHE_DIR"
CACHE_DIR="$CACHE_BASE/$COMPONENT"
if [ -n "$TARGET_DIR" ]; then
  case "$CACHE_DIR" in
    "$TARGET_DIR"|"$TARGET_DIR"/*) fail "cache directory must not be inside $TARGET_DIR" ;;
  esac
fi

ARCHIVE_NAME="${SNAPSHOT_URL%%\?*}"
ARCHIVE_NAME="${ARCHIVE_NAME##*/}"
case "$ARCHIVE_NAME" in
  *.tar.gz) ;;
  *) fail "snapshot filename must end in .tar.gz: $ARCHIVE_NAME" ;;
esac

mkdir -p "$CACHE_DIR"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE_NAME"
PARTIAL_PATH="$ARCHIVE_PATH.partial"

# Earlier releases cached L2Reth archives directly in the cache directory.
# Move such a download (complete or partial) into place instead of fetching it
# again; its checksum is verified below as usual.
if [ "$COMPONENT" = l2reth ] && [ ! -e "$ARCHIVE_PATH" ] && [ ! -e "$PARTIAL_PATH" ]; then
  for suffix in "" .partial; do
    if [ -f "$CACHE_BASE/$ARCHIVE_NAME$suffix" ]; then
      echo "Reusing archive cached by an earlier release: $CACHE_BASE/$ARCHIVE_NAME$suffix"
      mv "$CACHE_BASE/$ARCHIVE_NAME$suffix" "$ARCHIVE_PATH$suffix"
      break
    fi
  done
fi

# A cached archive with the wrong checksum is set aside first, so the space
# check below counts the download it will need.
verify_checksum() {
  printf '%s  %s\n' "$SNAPSHOT_SHA256" "$1" | sha256sum --check --status -
}

if [ -f "$ARCHIVE_PATH" ] && ! verify_checksum "$ARCHIVE_PATH"; then
  INVALID_PATH="$ARCHIVE_PATH.invalid-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Cached archive has the wrong checksum; preserving it as:"
  echo "  $INVALID_PATH"
  mv "$ARCHIVE_PATH" "$INVALID_PATH"
fi

# --- Disk space -------------------------------------------------------------

available_bytes() { df -PB1 "$1" | awk 'NR == 2 { print $4 }'; }
filesystem_id() { stat -c %d "$1"; }
file_bytes() { if [ -f "$1" ]; then stat -c %s "$1"; else echo 0; fi; }

if [ "$SKIP_SPACE_CHECK" != true ] && [ -n "$SIZE_BYTES" ]; then
  download_need=0
  if [ ! -f "$ARCHIVE_PATH" ]; then
    download_need=$(( SIZE_BYTES - $(file_bytes "$PARTIAL_PATH") ))
  fi
  extract_need="${UNCOMPRESSED_BYTES:-0}"
  if [ -n "$TARGET_DIR" ] && [ "$(filesystem_id "$CACHE_DIR")" = "$(filesystem_id "$TARGET_PARENT")" ]; then
    need=$(( download_need + extract_need ))
    have="$(available_bytes "$CACHE_DIR")"
    [ "$have" -ge "$need" ] ||
      fail "not enough space on $CACHE_DIR: need $(human_size "$need"), have $(human_size "$have") (--skip-space-check to override)"
  else
    have="$(available_bytes "$CACHE_DIR")"
    [ "$have" -ge "$download_need" ] ||
      fail "not enough space for the download in $CACHE_DIR: need $(human_size "$download_need"), have $(human_size "$have")"
    if [ -n "$TARGET_DIR" ]; then
      have="$(available_bytes "$TARGET_PARENT")"
      [ "$have" -ge "$extract_need" ] ||
        fail "not enough space in $TARGET_PARENT: need $(human_size "$extract_need"), have $(human_size "$have")"
    fi
  fi
  if [ -z "$UNCOMPRESSED_BYTES" ]; then
    echo "Note: the index does not list the extracted size; only the download size was checked."
  fi
  if [ -n "$TARGET_VOLUME" ]; then
    echo "Note: check that Docker's data root has room for $(human_size "${UNCOMPRESSED_BYTES:-0}") of extracted Dogecoin data."
  fi
fi

# --- Download and verify ----------------------------------------------------

if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "Downloading $COMPONENT snapshot:"
  echo "  $SNAPSHOT_URL"
  echo "Download cache:"
  echo "  $ARCHIVE_PATH"
  echo
  curl --fail --location --retry 5 --retry-delay 3 --continue-at - \
    --output "$PARTIAL_PATH" "$SNAPSHOT_URL"
  mv "$PARTIAL_PATH" "$ARCHIVE_PATH"
else
  echo "Using cached snapshot: $ARCHIVE_PATH"
fi

echo "Verifying SHA-256..."
verify_checksum "$ARCHIVE_PATH" || fail "snapshot checksum mismatch: $ARCHIVE_PATH"
echo "SHA-256 verified."
if [ -n "$SIZE_BYTES" ]; then
  [ "$(stat -c%s "$ARCHIVE_PATH")" -eq "$SIZE_BYTES" ] || fail "archive size does not match metadata"
fi

# Reject forbidden subtrees, duplicate members, links and non-regular data
# before tar can extract anything. L1 uses its stricter fixed-layout validator.
if [ "$COMPONENT" != l1-interface ]; then
  python3 "$NETWORK_DIR/scripts/validate-data-archive.py" "$ARCHIVE_PATH" \
    --component "$COMPONENT" --network "$NETWORK" || fail "invalid data archive"
fi

# --- Archive layout ---------------------------------------------------------

LISTING_PATH="$TMP_DIR/listing"
echo "Validating archive layout (reads the whole archive)..."
tar -tzf "$ARCHIVE_PATH" >"$LISTING_PATH"

awk -v root="$ARCHIVE_ROOT" '
  /^\// { bad = 1; print "absolute path: " $0 > "/dev/stderr" }
  /(^|\/)\.\.(\/|$)/ { bad = 1; print "parent traversal: " $0 > "/dev/stderr" }
  $0 != root && $0 != root "/" && index($0, root "/") != 1 {
    bad = 1; print "unexpected archive root: " $0 > "/dev/stderr"
  }
  END { exit bad }
' "$LISTING_PATH" || fail "snapshot archive contains unsafe or unexpected paths"

require_member() {
  grep -Eq "$1" "$LISTING_PATH" || fail "snapshot does not contain $2"
}

case "$COMPONENT" in
  l2reth)
    for forbidden_path in l2reth/jwt.hex l2reth/reth.toml l2reth/lost+found \
        l2reth/genesis l2reth/protocol_context.json; do
      if grep -Fxq "$forbidden_path" "$LISTING_PATH" ||
         grep -Fxq "$forbidden_path/" "$LISTING_PATH"; then
        fail "snapshot contains forbidden path: $forbidden_path"
      fi
    done
    if grep -Eq '(^|/)(nodekey|keystore[^/]*)(/|$)' "$LISTING_PATH"; then
      fail "snapshot contains a P2P node key or keystore path"
    fi
    require_member '^l2reth/db/mdbx\.dat$' l2reth/db/mdbx.dat
    require_member '^l2reth/db/scroll\.db$' l2reth/db/scroll.db
    require_member '^l2reth/static_files(/|$)' l2reth/static_files
    REQUIRED_FILES="db/mdbx.dat db/scroll.db"
    ;;
  l1-interface)
    python3 "$NETWORK_DIR/scripts/validate-l1-snapshot.py" archive "$ARCHIVE_PATH" \
      --network "$NETWORK" --historical "$L1_HISTORICAL" || fail "invalid L1 Interface snapshot layout"
    if grep -Eq '(^|/)[^/]*\.(env|toml|conf)$' "$LISTING_PATH"; then
      fail "snapshot contains a configuration or environment file"
    fi
    require_member '^l1-interface/l1-interface\.sqlite$' l1-interface/l1-interface.sqlite
    require_member '^l1-interface/replay\.sqlite$' l1-interface/replay.sqlite
    REQUIRED_FILES="l1-interface.sqlite replay.sqlite"
    ;;
  dogecoin)
    CHAIN_DIR="testnet3/"
    if grep -Eq '(^|/)(wallet\.dat|wallets|[^/]*\.conf|\.cookie|peers\.dat|banlist\.dat|\.lock)(/|$)' "$LISTING_PATH"; then
      fail "snapshot contains a wallet, configuration, credential, or peer-state file"
    fi
    require_member "^dogecoin/${CHAIN_DIR}blocks/index/CURRENT\$" "dogecoin/${CHAIN_DIR}blocks/index"
    require_member "^dogecoin/${CHAIN_DIR}chainstate/CURRENT\$" "dogecoin/${CHAIN_DIR}chainstate"
    REQUIRED_FILES="${CHAIN_DIR}blocks/index/CURRENT ${CHAIN_DIR}chainstate/CURRENT"
    ;;
esac

# --- Extract and activate ---------------------------------------------------

STOPPED_SERVICES=""
stop_services() {
  STOPPED_SERVICES="$(services_to_stop "$COMPONENT")"
  echo "Stopping $STOPPED_SERVICES before activating the restored data..."
  # Stopping services that do not exist succeeds; any other failure must not
  # let data be replaced under a running service.
  # shellcheck disable=SC2086
  "${COMPOSE[@]}" stop $STOPPED_SERVICES ||
    fail "could not stop $STOPPED_SERVICES; the restored data was not activated"
}

if [ -n "$TARGET_VOLUME" ]; then
  if docker volume inspect "$TARGET_VOLUME" >/dev/null 2>&1; then
    fail "Docker volume $TARGET_VOLUME was created during the download; stop and inspect it"
  fi
  echo "Creating Docker volume $TARGET_VOLUME and extracting the snapshot..."
  docker volume create \
    --label "com.docker.compose.project=$COMPOSE_PROJECT" \
    --label "com.docker.compose.volume=dogecoin_data" \
    "$TARGET_VOLUME" >/dev/null
  CREATED_VOLUME="$TARGET_VOLUME"
  if ! docker run --rm --network none \
      --mount "type=volume,source=$TARGET_VOLUME,target=/data" \
      --mount "type=bind,source=$CACHE_DIR,target=/snapshot,readonly" \
      -e ARCHIVE_NAME="$ARCHIVE_NAME" -e REQUIRED_FILES="$REQUIRED_FILES" \
      "$EXTRACT_IMAGE" sh -eu -c '
        test -z "$(ls -A /data)" || { echo "volume is not empty" >&2; exit 1; }
        tar -xzf "/snapshot/$ARCHIVE_NAME" --strip-components=1 -C /data
        for f in $REQUIRED_FILES; do test -f "/data/$f"; done
      '; then
    fail "extraction into $TARGET_VOLUME failed; the partial volume is removed"
  fi
  CREATED_VOLUME=""
  echo
  echo "Dogecoin snapshot restored to Docker volume: $TARGET_VOLUME"
else
  STAGING_DIR="$TARGET_PARENT/.$COMPONENT-snapshot-restore-$$"
  [ ! -e "$STAGING_DIR" ] || fail "staging directory already exists: $STAGING_DIR"
  mkdir "$STAGING_DIR"

  echo "Extracting snapshot to staging directory:"
  echo "  $STAGING_DIR"
  tar --extract --gzip --file "$ARCHIVE_PATH" --directory "$STAGING_DIR" \
    --no-same-owner --strip-components="$STRIP_COMPONENTS"
  if [ "$STRIP_COMPONENTS" -eq 0 ]; then
    EXTRACTED="$STAGING_DIR/$ARCHIVE_ROOT"
  else
    EXTRACTED="$STAGING_DIR"
  fi
  for f in $REQUIRED_FILES; do
    [ -f "$EXTRACTED/$f" ] || fail "extracted snapshot is missing $f"
  done

  if [ "$COMPONENT" = l1-interface ]; then
    python3 "$NETWORK_DIR/scripts/validate-l1-snapshot.py" extracted "$EXTRACTED" \
      --network "$NETWORK" --historical "$L1_HISTORICAL" || fail "invalid L1 Interface snapshot data"
  fi

  stop_services

  BACKUP_DIR=""
  if [ -d "$TARGET_DIR" ]; then
    if find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      BACKUP_DIR="$TARGET_DIR.backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
      [ ! -e "$BACKUP_DIR" ] || fail "backup destination already exists: $BACKUP_DIR"
      PENDING_TARGET="$TARGET_DIR"
      PENDING_BACKUP="$BACKUP_DIR"
      mv "$TARGET_DIR" "$BACKUP_DIR"
    else
      rmdir "$TARGET_DIR"
    fi
  fi

  if [ "$STRIP_COMPONENTS" -eq 0 ]; then
    mv "$EXTRACTED" "$TARGET_DIR"
    rmdir "$STAGING_DIR"
  else
    mv "$STAGING_DIR" "$TARGET_DIR"
  fi
  STAGING_DIR=""
  PENDING_BACKUP=""

  echo
  echo "$COMPONENT snapshot restored to:"
  echo "  $TARGET_DIR"
  if [ -n "$BACKUP_DIR" ]; then
    echo "Previous data was preserved at:"
    echo "  $BACKUP_DIR"
  fi
fi

if [ "$START_AFTER_RESTORE" = true ]; then
  echo
  if [ -n "$TARGET_VOLUME" ]; then
    stop_services
  fi
  echo "Starting the $NETWORK stack..."
  if [ -n "$TARGET_VOLUME" ]; then
    # The service still names the same volume key, so Compose would otherwise
    # keep an existing container attached to the previous volume.
    "${COMPOSE[@]}" up -d --force-recreate dogecoin-node
  fi
  python3 "$NETWORK_DIR/scripts/snapshot-group.py" start --env-file "$ENV_FILE_ABS"
  echo
  "${COMPOSE[@]}" ps
else
  echo
  if [ -n "$TARGET_VOLUME" ]; then
    echo "Restore complete; running services were not touched. Switch to the new"
    echo "volume by stopping the services that depend on Dogecoin first:"
    echo "  $COMPOSE_HINT stop $(services_to_stop dogecoin)"
    echo "  $COMPOSE_HINT up -d --force-recreate dogecoin-node"
  else
    echo "Restore complete. Stopped services: $STOPPED_SERVICES"
    echo "Start the stack later with:"
  fi
  printf '  python3 %q start --env-file %q\n' "$NETWORK_DIR/scripts/snapshot-group.py" "$ENV_FILE_ABS"
fi

echo
echo "The downloaded archive remains cached at:"
echo "  $ARCHIVE_PATH"
