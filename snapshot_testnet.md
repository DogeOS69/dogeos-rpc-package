# Testnet Snapshot Restoration Guide

This guide describes how to restore snapshots for **L2Reth**, the **Dogecoin
Node**, and the **L1 Interface**.

## Prerequisites

- Ensure `dogeos-rpc-package` is set up.
- Copy `.env.example.testnet` to `.env.testnet`, set `DATA_ROOT`, and run `./scripts/prepare-data-dir.sh .env.testnet`.
- Ensure `wget` and `tar` (with `zstd` support) are installed.
- Ensure you have the `latest.txt` URL:
  ```
  https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/latest.txt
  ```

---

# L2Reth Snapshot (Recommended)

The repository includes a one-command restore script with a versioned public
snapshot URL and SHA-256 built in:

```bash
./scripts/restore-l2reth-snapshot.sh .env.testnet
```

The script performs the complete workflow:

1. Reads and validates `NETWORK` and `DATA_ROOT` from `.env.testnet`.
2. Downloads or resumes the published archive into
   `${DATA_ROOT}/.snapshot-cache`.
3. Verifies the archive against the SHA-256 pinned in the script.
4. Rejects unsafe paths or an unexpected archive layout.
5. Confirms that secrets and environment-specific configuration are absent.
6. Extracts into a staging directory before changing the active datadir.
7. Stops `l2reth-node`, activates `${DATA_ROOT}/l2reth`, and starts the node
   with its dependencies.

The archive has one root directory, `l2reth/`, so it matches the bind mount in
`docker-compose.yml`. It contains the Reth databases and static files, but does
not contain:

- `genesis.json` or `protocol_context.json`
- `jwt.hex`
- P2P node keys or signer keys
- the source environment's `reth.toml`

The current genesis, hardfork times, peer list, P2P network ID, and runtime
settings always come from the checked-out version of `dogeos-rpc-package`.
This separation allows future fork fields to be added without republishing the
database archive.

## Replacing Existing L2Reth Data

By default, the script refuses to overwrite a non-empty L2Reth directory. To
replace existing data:

```bash
./scripts/restore-l2reth-snapshot.sh --force .env.testnet
```

`--force` does not delete the old data. After stopping `l2reth-node`, the script
moves it to a timestamped sibling such as:

```text
${DATA_ROOT}/l2reth.backup-20260730T120000Z
```

Remove that backup manually only after the restored node has been verified.

## Restore Without Starting Containers

To prepare the data but defer startup:

```bash
./scripts/restore-l2reth-snapshot.sh --no-start .env.testnet
```

Then start it later:

```bash
docker compose --env-file .env.testnet up -d l2reth-node
```

## URL and Cache Overrides

Normal users should rely on the URL and checksum pinned by the script.
Operators can override them for mirrors or pre-release snapshots:

```bash
./scripts/restore-l2reth-snapshot.sh \
  --snapshot-url https://mirror.example/l2reth-snapshot.tar.gz \
  --sha256 <64-hex-character-sha256> \
  --cache-dir /path/on/a/large/disk \
  .env.testnet
```

The download supports HTTP range resume. A cached archive with the correct
checksum is reused; a cached archive with the wrong checksum is preserved with
an `.invalid-<timestamp>` suffix before a fresh download.

The EBS source snapshot was taken online and is crash-consistent. The first
Reth startup may perform normal database recovery before continuing from the
snapshot head.

---

# Dogecoin Node Snapshot

## Step 1: Download Snapshot

Get the latest Dogecoin snapshot URL and download it.

```bash
# Get URL
DOGE_URL=$(curl -s https://dogecoin-testnet-snapshots-usa-west-2.s3.us-west-2.amazonaws.com/testnet/latest.txt | grep "^dogecoin|" | cut -d'|' -f2)

# Download
wget $DOGE_URL -O dogecoin-snapshot.tar.zst
```

## Step 2: Locate Data Directory
Dogecoin data lives in the named Docker volume set by `DOGECOIN_VOLUME_NAME` in `.env.testnet`. Resolve its host path (create the volume first if it does not exist yet):

```bash
docker volume create dogeos-rpc-package_dogecoin_data
DOGECOIN_DATA=$(docker volume inspect -f '{{ .Mountpoint }}' dogeos-rpc-package_dogecoin_data)
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

# L1 Interface Snapshot

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
