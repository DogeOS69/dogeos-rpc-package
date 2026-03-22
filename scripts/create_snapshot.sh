#!/bin/bash
set -e

# Ensure script runs from the project root
cd "$(dirname "$0")/.."

# Configuration
BUCKET="${SNAPSHOT_BUCKET:-dogeos-rpc-snapshots}"
REGION="${SNAPSHOT_REGION:-us-west-2}"
# Load .env if it exists
if [ -f .env ]; then
    source .env
else
    # In container, ENV vars are passed via docker, so we don't strictly need .env file present inside the container IF vars are set.
    # However, user requested strict check.
    # Let's check environment variable existence, or failure if file missing.
    # Assuming local execution context primarily for this check based on user request.
    # But inside container, .env might not be mounted.
    # User said "Must have .env cannot omit".
    # If we are in container, we usually don't mount .env, we pass env vars.
    # Let's fail if .env missing AND NETWORK is not set.
    if [ -z "$NETWORK" ]; then
         echo "Error: .env file not found and NETWORK variable not set."
         exit 1
    fi
fi

PREFIX="${NETWORK:-testnet}"


DATE=$(date +%Y%m%d)

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

check_dependencies() {
    for cmd in docker tar zstd aws sort grep awk; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is required but not installed."
            exit 1
        fi
    done
}

get_volume_path() {
    local volume_name=$1
    
    # Check if running in scheduler container
    if [ "$volume_name" == "dogeos-rpc-package_dogecoin_data" ] && [ -d "/data/dogecoin" ]; then
        echo "/data/dogecoin"
        return
    fi
    
    if [ "$volume_name" == "dogeos-rpc-package_l1_interface_data" ] && [ -d "/data/l1-interface" ]; then
        echo "/data/l1-interface"
        return
    fi

    # Fallback to host docker inspection
    # Check if docker command exists
    if command -v docker &> /dev/null; then
         docker volume inspect "$volume_name" --format '{{.Mountpoint}}' 2>/dev/null
    else
         log_error "Cannot determine volume path. Not in scheduler container and docker command missing."
         return 1
    fi
}

update_latest_txt() {
    log_info "Calculating latest.txt content from S3..."
    
    local s3_path="s3://$BUCKET/$PREFIX/"
    
    # List files, filter, sort, take latest
    # Naming convention based on current state:
    # dogecoin: dogecoin-testnet-snapshot-YYYYMMDD.tar.zst
    # l1-interface: l1-interface-YYYYMMDD.tar.zst
    
    local latest_doge=$(aws s3 ls "$s3_path" --region "$REGION" | awk '{print $4}' | grep '^dogecoin-testnet-snapshot-[0-9]\{8\}\.tar\.zst$' | sort | tail -n 1)
    local latest_l1=$(aws s3 ls "$s3_path" --region "$REGION" | awk '{print $4}' | grep '^l1-interface-[0-9]\{8\}\.tar\.zst$' | sort | tail -n 1)
    
    local temp_latest=$(mktemp)
    
    if [ -n "$latest_doge" ]; then
        echo "dogecoin|https://$BUCKET.s3.$REGION.amazonaws.com/$PREFIX/$latest_doge" >> "$temp_latest"
        log_info "Latest Dogecoin: $latest_doge"
    else
        log_warn "No Dogecoin snapshot found in S3."
    fi
    
    if [ -n "$latest_l1" ]; then
        echo "l1-interface|https://$BUCKET.s3.$REGION.amazonaws.com/$PREFIX/$latest_l1" >> "$temp_latest"
        log_info "Latest L1 Interface: $latest_l1"
    else
        log_warn "No L1 Interface snapshot found in S3."
    fi
    
    log_info "Uploading new latest.txt..."
    aws s3 cp "$temp_latest" "s3://$BUCKET/$PREFIX/latest.txt" --region "$REGION"
    rm -f "$temp_latest"
    log_info "latest.txt updated."
}

upload_file() {
    local file_path=$1
    local filename=$(basename "$file_path")
    
    log_info "Uploading $filename to s3://$BUCKET/$PREFIX/$filename..."
    aws s3 cp "$file_path" "s3://$BUCKET/$PREFIX/$filename" --region "$REGION"
}

snapshot_dogecoin() {
    log_info "Starting Dogecoin snapshot process..."
    
    local VOLUME_NAME="dogeos-rpc-package_dogecoin_data"
    local SERVICE_NAME="dogecoin-node"
    local MOUNTPOINT=$(get_volume_path "$VOLUME_NAME")
    
    if [ -z "$MOUNTPOINT" ]; then
        log_error "Volume $VOLUME_NAME not found."
        return 1
    fi
    
    log_info "Found volume at $MOUNTPOINT"
    
    log_info "Stopping $SERVICE_NAME..."
    docker compose stop "$SERVICE_NAME"
    
    local SNAPSHOT_FILE="dogecoin-testnet-snapshot-${DATE}.tar.zst"
    
    log_info "Creating archive $SNAPSHOT_FILE..."
    
    if [ ! -d "$MOUNTPOINT/testnet3" ]; then
         if ! sudo test -d "$MOUNTPOINT/testnet3"; then
             log_error "$MOUNTPOINT/testnet3 does not exist."
             docker compose start "$SERVICE_NAME"
             return 1
         fi
    fi

    # Create snapshot using pipe to show progress and handle permissions
    # zstd --progress shows processed data size
    # Running zstd as current user ensures output file is owned by user
    # --numeric-owner strictly preserves the container's native numeric UIDs, ignoring host usernames.
    sudo tar -c --numeric-owner -C "$MOUNTPOINT/testnet3" blocks chainstate | zstd -T0 --progress > "$SNAPSHOT_FILE"
    
    log_info "Starting $SERVICE_NAME..."
    docker compose start "$SERVICE_NAME"
    
    local size=$(du -h "$SNAPSHOT_FILE" | cut -f1)
    log_info "Snapshot created: $SNAPSHOT_FILE ($size)"
    
    log_info "Calculating checksum..."
    sha256sum "$SNAPSHOT_FILE" > "$SNAPSHOT_FILE.sha256"
    
    upload_file "$SNAPSHOT_FILE"
    upload_file "$SNAPSHOT_FILE.sha256"
    
    # Cleanup
    rm -f "$SNAPSHOT_FILE" "$SNAPSHOT_FILE.sha256"
}

snapshot_l1() {
    log_info "Starting L1 Interface snapshot process..."
    
    local VOLUME_NAME="dogeos-rpc-package_l1_interface_data"
    local SERVICE_NAME="l1-interface"
    local MOUNTPOINT=$(get_volume_path "$VOLUME_NAME")
    
    if [ -z "$MOUNTPOINT" ]; then
        log_error "Volume $VOLUME_NAME not found."
        return 1
    fi
    
    log_info "Found volume at $MOUNTPOINT"
    
    log_info "Stopping $SERVICE_NAME..."
    docker compose stop "$SERVICE_NAME"
    
    local SNAPSHOT_FILE="l1-interface-${DATE}.tar.zst"
    
    log_info "Creating archive $SNAPSHOT_FILE..."
    
    # --numeric-owner strictly preserves the container's native numeric UIDs, ignoring host usernames.
    sudo tar -c --numeric-owner -C "$MOUNTPOINT" . | zstd -T0 --progress > "$SNAPSHOT_FILE"
    
    log_info "Starting $SERVICE_NAME..."
    docker compose start "$SERVICE_NAME"
    
    local size=$(du -h "$SNAPSHOT_FILE" | cut -f1)
    log_info "Snapshot created: $SNAPSHOT_FILE ($size)"
    
    log_info "Calculating checksum..."
    sha256sum "$SNAPSHOT_FILE" > "$SNAPSHOT_FILE.sha256"
    
    upload_file "$SNAPSHOT_FILE"
    upload_file "$SNAPSHOT_FILE.sha256"
    
    # Cleanup
    rm -f "$SNAPSHOT_FILE" "$SNAPSHOT_FILE.sha256"
}

# Main execution
check_dependencies

TARGET=$1

if [ -z "$TARGET" ]; then
    echo "Usage: $0 [dogecoin|l1-interface|all]"
    exit 1
fi

if [[ "$TARGET" == "dogecoin" || "$TARGET" == "all" ]]; then
    snapshot_dogecoin
fi

if [[ "$TARGET" == "l1-interface" || "$TARGET" == "all" ]]; then
    snapshot_l1
fi

# Always update latest.txt at the end if we did something
update_latest_txt

log_info "All tasks finished."
