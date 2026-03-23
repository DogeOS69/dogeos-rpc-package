# Dogecoin Testnet Snapshot Restoration Guide

This guide describes how to download and restore snapshots for the **Dogecoin Node** and **L1 Interface**.

## Prerequisites

- Ensure `dogeos-rpc-package` is set up.
- Ensure `wget` and `tar` (with `zstd` support) are installed.
- Ensure you have the `latest.txt` URL:
  ```
  https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/latest.txt
  ```

---

# Part 1: Dogecoin Node Snapshot

## Step 1: Download Snapshot

Get the latest Dogecoin snapshot URL and download it.

```bash
# Get URL
DOGE_URL=$(curl -s https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/latest.txt | grep "^dogecoin|" | cut -d'|' -f2)

# Download
wget $DOGE_URL -O dogecoin-snapshot.tar.zst

# Verify Checksum
wget ${DOGE_URL}.sha256 -O dogecoin-snapshot.tar.zst.sha256
EXPECTED_HASH=$(awk '{print $1}' dogecoin-snapshot.tar.zst.sha256)
echo "$EXPECTED_HASH  dogecoin-snapshot.tar.zst" | sha256sum -c
```

## Step 2: Locate Volume
Find the host path for `dogecoin_data`:
```bash
docker volume inspect dogeos-rpc-package_dogecoin_data --format '{{.Mountpoint}}'
# Example: /var/lib/docker/volumes/dogeos-rpc-package_dogecoin_data/_data
```

## Step 3: Restore
**1. Stop services:**
```bash
docker compose down
```

**2. Clean and Extract:**
```bash
# Replace <MOUNTPOINT> with the path found in Step 2
sudo mkdir -p <MOUNTPOINT>/testnet3
sudo rm -rf <MOUNTPOINT>/testnet3/blocks 
sudo rm -rf <MOUNTPOINT>/testnet3/chainstate

# Extract
sudo tar -I zstd --numeric-owner -xvf dogecoin-snapshot.tar.zst -C <MOUNTPOINT>/testnet3
```

**3. Restart:**
```bash
docker compose up -d dogecoin-node
```


---

# Part 2: L1 Interface Snapshot

## Step 1: Download Snapshot

Get the latest L1 Interface snapshot URL and download it.

```bash
# Get URL
L1_URL=$(curl -s https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/latest.txt | grep "^l1-interface|" | cut -d'|' -f2)

# Download
wget $L1_URL -O l1-interface-snapshot.tar.zst

# Verify Checksum
wget ${L1_URL}.sha256 -O l1-interface-snapshot.tar.zst.sha256
EXPECTED_HASH=$(awk '{print $1}' l1-interface-snapshot.tar.zst.sha256)
echo "$EXPECTED_HASH  l1-interface-snapshot.tar.zst" | sha256sum -c
```

## Step 2: Locate Volume
Find the host path for `l1_interface_data`:
```bash
docker volume inspect dogeos-rpc-package_l1_interface_data --format '{{.Mountpoint}}'
# Example: /var/lib/docker/volumes/dogeos-rpc-package_l1_interface_data/_data
```

## Step 3: Restore
**1. Stop services:**
```bash
docker compose down l1-interface
```

**2. Clean and Extract:**
```bash
# Replace <MOUNTPOINT> with the path found in Step 2
sudo rm -rf <MOUNTPOINT>/*

# Extract
sudo tar -I zstd --numeric-owner -xvf l1-interface-snapshot.tar.zst -C <MOUNTPOINT>
```

**3. Restart:**
```bash
docker compose up -d
```
