#!/bin/bash
set -e

# This script is a targeted testnet snapshot reorg recovery flow.
# It restores the latest L1 Interface snapshot and then resets
# l2geth's RollupEventSyncedL1Height to a manually chosen recovery height.
# It does not support l2reth recovery.

ROLLUP_EVENT_SYNCED_L1_HEIGHT=38702000
L1_INTERFACE_HEIGHT_EXIT_THRESHOLD=38702347
L1_INTERFACE_RPC_URL=http://127.0.0.1:8547
L1_INTERFACE_EXPECTED_CHAIN_ID=111111

cd "$(dirname "$0")" || { echo "Error: Failed to navigate to script directory"; exit 1; }

echo "Starting L1 Interface Snapshot Restoration..."

if [ ! -f .env ]; then
    echo "Error: .env file not found."
    exit 1
fi

NETWORK_VALUE=$(grep '^NETWORK=' .env | cut -d'=' -f2- || true)
if [ -z "$NETWORK_VALUE" ]; then
    echo "Error: NETWORK is not set in .env."
    exit 1
fi

COMPOSE_PROFILES_VALUE=$(grep '^COMPOSE_PROFILES=' .env | cut -d'=' -f2- || true)
if [[ ",${COMPOSE_PROFILES_VALUE}," != *",l2geth,"* ]]; then
    echo "Error: This reorg recovery script requires COMPOSE_PROFILES to include 'l2geth'."
    exit 1
fi

COMPOSE_PROJECT_NAME_VALUE=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d'=' -f2- || true)
if [ -z "$COMPOSE_PROJECT_NAME_VALUE" ]; then
    echo "Error: COMPOSE_PROJECT_NAME is not set in .env."
    exit 1
fi

VOLUME_NAME="${COMPOSE_PROJECT_NAME_VALUE}_l1_interface_data"

echo "Checking current l1-interface chain ID..."
CURRENT_CHAIN_ID_HEX=$(curl -s --max-time 10 \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$L1_INTERFACE_RPC_URL" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]\+\)".*/\1/p')

if [ -z "$CURRENT_CHAIN_ID_HEX" ]; then
    echo "Error: Failed to query l1-interface chain ID from $L1_INTERFACE_RPC_URL."
    exit 1
fi

CURRENT_CHAIN_ID=$((16#${CURRENT_CHAIN_ID_HEX#0x}))
echo "Current l1-interface chain ID: $CURRENT_CHAIN_ID"

if [ "$CURRENT_CHAIN_ID" -ne "$L1_INTERFACE_EXPECTED_CHAIN_ID" ]; then
    echo "Error: $L1_INTERFACE_RPC_URL returned chain ID $CURRENT_CHAIN_ID, expected $L1_INTERFACE_EXPECTED_CHAIN_ID."
    echo "This likely means the port is pointing to the wrong service."
    echo "Exiting without restoring the snapshot."
    exit 1
fi

echo "Checking current l1-interface height..."
CURRENT_L1_HEIGHT_HEX=$(curl -s --max-time 10 \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$L1_INTERFACE_RPC_URL" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]\+\)".*/\1/p')

if [ -z "$CURRENT_L1_HEIGHT_HEX" ]; then
    echo "Error: Failed to query current l1-interface height from $L1_INTERFACE_RPC_URL."
    exit 1
fi

CURRENT_L1_HEIGHT=$((16#${CURRENT_L1_HEIGHT_HEX#0x}))
echo "Current l1-interface height: $CURRENT_L1_HEIGHT"

if [ "$CURRENT_L1_HEIGHT" -gt "$L1_INTERFACE_HEIGHT_EXIT_THRESHOLD" ]; then
    echo "Current l1-interface height ($CURRENT_L1_HEIGHT) is greater than the reorg recovery cutoff ($L1_INTERFACE_HEIGHT_EXIT_THRESHOLD)."
    echo "This node appears to have already recovered past the target reorg window."
    echo "Skipping snapshot restore and exiting successfully."
    exit 0
fi

echo "Fetching latest snapshot URL..."
L1_URL=$(curl -s https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/latest.txt | grep "^l1-interface|" | cut -d'|' -f2)

if [ -z "$L1_URL" ]; then
    echo "Error: Failed to fetch L1 snapshot URL."
    exit 1
fi

echo "Downloading snapshot from $L1_URL..."
wget "$L1_URL" -O l1-interface-snapshot.tar.zst

echo "Downloading checksum..."
wget "${L1_URL}.sha256" -O l1-interface-snapshot.tar.zst.sha256

echo "Verifying checksum..."
EXPECTED_HASH=$(awk '{print $1}' l1-interface-snapshot.tar.zst.sha256)
if ! echo "$EXPECTED_HASH  l1-interface-snapshot.tar.zst" | sha256sum -c - > /dev/null 2>&1; then
    echo "Error: Checksum verification failed! Aborting."
    exit 1
fi
echo "Checksum verified successfully."

echo "Locating docker volume '$VOLUME_NAME'..."
MOUNTPOINT=$(docker volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}' 2>/dev/null || true)

if [ -z "$MOUNTPOINT" ]; then
    echo "Error: Could not find Docker volume '$VOLUME_NAME'."
    echo "Ensure the container has been run at least once."
    exit 1
fi

echo "Mountpoint found at: $MOUNTPOINT"

echo "Stopping l1-interface container..."
docker compose down l1-interface

echo "Cleaning existing volume data at $MOUNTPOINT..."
sudo rm -rf "${MOUNTPOINT:?}"/l1-interface.sqlite*

echo "Extracting snapshot to $MOUNTPOINT..."
sudo tar -I zstd --numeric-owner -xvf l1-interface-snapshot.tar.zst -C "$MOUNTPOINT"

echo "Restarting services..."
docker compose up -d

echo "L1 Interface Snapshot restored successfully!"


echo "Setting RollupEventSyncedL1Height in l2geth-node..."
docker exec l2geth-node geth attach /l2geth/data/geth.ipc --exec "admin.setRollupEventSyncedL1Height($ROLLUP_EVENT_SYNCED_L1_HEIGHT)"

echo "Verifying new RollupEventSyncedL1Height..."
docker exec l2geth-node geth attach /l2geth/data/geth.ipc --exec "scroll.syncStatus.l1RollupSyncHeight"
