# Dogecoin Testnet Snapshot Restoration Guide

This guide describes how to download and restore snapshots for the **Dogecoin Node** and **L1 Interface**.

## Prerequisites

- Ensure `dogeos-rpc-package` is set up.
- Copy `.env.example.testnet` to `.env.testnet`, set `DATA_ROOT`, and run `./scripts/prepare-data-dir.sh .env.testnet`.
- Ensure `wget` and `tar` (with `zstd` support) are installed.
- Ensure you have the `latest.txt` URL:
  ```
  https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/latest.txt
  ```

---

# Part 1: Dogecoin Node Snapshot

## Step 1: Download Snapshot

Get the latest Dogecoin snapshot URL and download it.

```bash
# Get URL
DOGE_URL=$(curl -s https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/latest.txt | grep "^dogecoin|" | cut -d'|' -f2)

# Download
wget $DOGE_URL -O dogecoin-snapshot.tar.zst
```

## Step 2: Locate Data Directory
Use the Dogecoin data directory under `DATA_ROOT`:

```bash
# Example if DATA_ROOT=/mnt/wsl/data/dogeos-data/testnet
DOGECOIN_DATA=/mnt/wsl/data/dogeos-data/testnet/dogecoin
```

## Step 3: Restore
**1. Stop services:**
```bash
docker compose --env-file .env.testnet down
```

**2. Clean and Extract:**
```bash
sudo mkdir -p "$DOGECOIN_DATA/testnet3"
sudo rm -rf "$DOGECOIN_DATA/testnet3/blocks"
sudo rm -rf "$DOGECOIN_DATA/testnet3/chainstate"

# Extract
sudo tar -I zstd -xvf dogecoin-snapshot.tar.zst -C "$DOGECOIN_DATA/testnet3"
```

**3. Restart:**
```bash
docker compose --env-file .env.testnet up -d dogecoin-node
```


---

# Part 2: L1 Interface Snapshot

## Step 1: Download Snapshot

Get the latest L1 Interface snapshot URL and download it.

```bash
# Get URL
L1_URL=$(curl -s https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/latest.txt | grep "^l1-interface|" | cut -d'|' -f2)

# Download
wget $L1_URL -O l1-interface-snapshot.tar.zst
```

## Step 2: Locate Data Directory
Use the L1 Interface data directory under `DATA_ROOT`:

```bash
# Example if DATA_ROOT=/mnt/wsl/data/dogeos-data/testnet
L1_INTERFACE_DATA=/mnt/wsl/data/dogeos-data/testnet/l1-interface
```

## Step 3: Restore
**1. Stop services:**
```bash
docker compose --env-file .env.testnet down
```

**2. Clean and Extract:**
```bash
sudo rm -rf "$L1_INTERFACE_DATA"/*

# Extract
sudo tar -I zstd -xvf l1-interface-snapshot.tar.zst -C "$L1_INTERFACE_DATA"
```

**3. Restart:**
```bash
docker compose --env-file .env.testnet up -d
```
