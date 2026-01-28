# Dogecoin Testnet Snapshot Restoration Guide

This guide describes how to download and restore the Dogecoin Testnet snapshot.

## Prerequisites

- Ensure `dogeos-rpc-package` is set up.
- Ensure `wget` and `tar` (with `zstd` support) are installed.

## Step 1: Get Latest Snapshot URL

Get the download link for the latest snapshot from the following URL:

```bash
curl https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/latest.txt
```

*Example output:*

```
https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/dogecoin-testnet-snapshot-20260128.tar.zst
```

## Step 2: Download Snapshot

Use `wget` to download the snapshot file using the URL obtained in Step 1.

```bash
# Replace <SNAPSHOT_URL> with the actual URL
wget <SNAPSHOT_URL>
```

## Step 3: Locate Docker Volume Mountpoint

Find the host path for the `dogecoin_data` volume where the data should be restored.

```bash
docker volume inspect dogeos-rpc-package_dogecoin_data --format '{{.Mountpoint}}'
```

*Example output:*

```
/var/lib/docker/volumes/dogeos-rpc-package_dogecoin_data/_data
```

## Step 4: Restore Snapshot

**Important**: Shut down the services before restoring data to avoid corruption and ensure a clean state.

```bash
docker compose down
```

Extract the snapshot to the volume's mountpoint.

```bash
# Replace <SNAPSHOT_FILE> with the downloaded filename (e.g., dogecoin-testnet-snapshot-20260128.tar.zst)
# Replace <MOUNTPOINT> with the path found in Step 3
sudo mkdir -p <MOUNTPOINT>/testnet3
sudo rm -rf <MOUNTPOINT>/testnet3/blocks 
sudo rm -rf <MOUNTPOINT>/testnet3/chainstate
sudo tar -I zstd -xvf <SNAPSHOT_FILE> -C <MOUNTPOINT>/testnet3
```

## Step 5: Restart Node

After restoration is complete, restart the dogecoin node.

```bash
docker compose up -d
```
