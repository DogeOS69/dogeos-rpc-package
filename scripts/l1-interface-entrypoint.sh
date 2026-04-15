#!/bin/sh
set -e

DB_PATH="/data/l1-interface.sqlite"

# ──────────────────────────────────────────────────────────────────────
# Auto-download snapshot if the DB doesn't exist yet.
#
# Supported formats (detected by file extension):
#   .sqlite.gz   — gzipped SQLite (compact fixture, ~63 MB)
#   .tar.zst     — zstd-compressed tar (full snapshot, ~1.5 GB)
#   .sqlite      — raw SQLite (no decompression)
#
# Set L1_INTERFACE_SNAPSHOT_URL in your .env / docker-compose env.
# If the URL uses the S3 "latest.txt" pattern, set
# L1_INTERFACE_SNAPSHOT_LATEST_URL instead and the script resolves it.
#
# The image is Debian-slim and has no wget/curl by default. The script
# installs wget on first run if needed, then removes it.
# ──────────────────────────────────────────────────────────────────────
ensure_wget() {
  if command -v wget >/dev/null 2>&1; then return 0; fi
  echo "Installing wget..."
  apt-get update -qq && apt-get install -y -qq wget >/dev/null 2>&1
}

cleanup_wget() {
  # Only remove if we installed it (marker file)
  if [ -f /tmp/.wget-installed ]; then
    apt-get remove -y -qq wget >/dev/null 2>&1 || true
    rm -f /tmp/.wget-installed
  fi
}

download_snapshot() {
  local url="$1"
  local tmp_dir="/data/.snapshot-download"
  mkdir -p "$tmp_dir"

  ensure_wget
  touch /tmp/.wget-installed

  echo "Downloading snapshot from: $url"

  case "$url" in
    *.sqlite.gz)
      wget -q --show-progress -O "$tmp_dir/snapshot.sqlite.gz" "$url"
      echo "Decompressing gzipped SQLite..."
      gunzip -c "$tmp_dir/snapshot.sqlite.gz" > "$DB_PATH"
      rm -f "$tmp_dir/snapshot.sqlite.gz"
      ;;
    *.tar.zst)
      echo "Installing zstd..."
      apt-get install -y -qq zstd >/dev/null 2>&1
      wget -q --show-progress -O "$tmp_dir/snapshot.tar.zst" "$url"
      echo "Extracting tar.zst snapshot..."
      tar -I zstd -xf "$tmp_dir/snapshot.tar.zst" -C /data
      rm -f "$tmp_dir/snapshot.tar.zst"
      apt-get remove -y -qq zstd >/dev/null 2>&1 || true
      ;;
    *.sqlite)
      wget -q --show-progress -O "$DB_PATH" "$url"
      ;;
    *)
      echo "ERROR: Unknown snapshot format: $url"
      echo "Supported extensions: .sqlite.gz, .tar.zst, .sqlite"
      exit 1
      ;;
  esac

  rmdir "$tmp_dir" 2>/dev/null || true
  cleanup_wget
  echo "Snapshot restored to $DB_PATH ($(du -h "$DB_PATH" | cut -f1))"
}

if [ ! -f "$DB_PATH" ]; then
  echo "=== L1 Interface database not found at $DB_PATH ==="

  # Resolve URL: direct URL takes precedence over latest.txt lookup
  SNAPSHOT_URL="${L1_INTERFACE_SNAPSHOT_URL:-}"

  if [ -z "$SNAPSHOT_URL" ] && [ -n "${L1_INTERFACE_SNAPSHOT_LATEST_URL:-}" ]; then
    echo "Resolving latest snapshot URL..."
    ensure_wget
    touch /tmp/.wget-installed
    SNAPSHOT_URL=$(wget -qO- "$L1_INTERFACE_SNAPSHOT_LATEST_URL" | grep "^l1-interface|" | cut -d'|' -f2)
    cleanup_wget
  fi

  if [ -n "$SNAPSHOT_URL" ]; then
    download_snapshot "$SNAPSHOT_URL"
  else
    echo "No snapshot URL configured."
    echo "Set L1_INTERFACE_SNAPSHOT_URL or L1_INTERFACE_SNAPSHOT_LATEST_URL"
    echo "The service will start and create an empty database."
  fi
else
  echo "=== L1 Interface database exists ($(du -h "$DB_PATH" | cut -f1)) ==="
fi

echo "=== Starting L1 Interface ==="
exec /usr/local/bin/l1_interface "$@"
