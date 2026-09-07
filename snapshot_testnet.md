# Testnet Snapshot and Recovery Guide

This guide covers the supported recovery paths for L2Reth, the bundled
Dogecoin node, and L1 Interface in the testnet RPC package.

## Common Prerequisites

Run commands from the repository root. First create the Compose env file and
prepare `DATA_ROOT`:

```bash
cp .env.example.testnet .env.testnet
chmod 600 .env.testnet

# Edit the Compose env before continuing:
# - set an absolute DATA_ROOT in .env.testnet
# - review the stable DOGECOIN_RPC_USER and DOGECOIN_RPC_PASSWORD values

./scripts/prepare-data-dir.sh .env.testnet
```

The tracked testnet configuration defaults to the public Ethereum endpoint
`https://ethereum-sepolia-rpc.publicnode.com`. To use another provider, copy
`envs/testnet/l1-interface.local.env.example` to `l1-interface.local.env` and
uncomment its RPC override. The endpoint must support Sepolia (`chainId`
`11155111`) and execution RPC methods such as `eth_getBlockByHash`. Keep
provider credentials in the gitignored local file. For the bundled Dogecoin
node, Compose mounts the configured `DOGECOIN_RPC_USER` and
`DOGECOIN_RPC_PASSWORD` from `.env.testnet` into both Dogecoin and L1 Interface
as secrets. `prepare-data-dir.sh` validates the credentials but never generates
or changes them. Only for temporary/debug use, an external Dogecoin node can be
configured in `l1-interface.local.env`.

## L2Reth Snapshot (Recommended)

The repository includes a one-command restore script with a versioned public
snapshot URL and SHA-256 pinned together:

```bash
./scripts/restore-l2reth-snapshot.sh .env.testnet
```

The script requires `curl`, `docker`, `sha256sum`, and GNU `tar` with gzip
support. It performs the following workflow:

1. Validates `NETWORK=testnet` and an absolute, safe `DATA_ROOT`.
2. Downloads or resumes the archive under `${DATA_ROOT}/.snapshot-cache`.
3. Verifies the archive against the pinned SHA-256.
4. Rejects unsafe archive paths, unexpected roots, and known key or
   environment-specific configuration paths.
5. Extracts into a staging directory before changing the active datadir.
6. Stops `l2reth-node`, activates `${DATA_ROOT}/l2reth`, and starts the complete
   testnet stack, including the user's Compose Dogecoin node.

The archive contains Reth databases and static files under one `l2reth/` root.
It intentionally excludes:

- `genesis.json` and `protocol_context.json`
- `jwt.hex`
- P2P node keys and keystores
- the source environment's `reth.toml`

Genesis, hardfork times, peer configuration, P2P network ID, and runtime flags
always come from the checked-out repository. Resolve any placeholder peer
hostnames in `envs/testnet/l2reth.env` before expecting those peers to connect.

### Replace Existing L2Reth Data

By default, the script refuses to replace a non-empty datadir. Use `--force` to
move the old directory to a timestamped sibling and activate the snapshot:

```bash
./scripts/restore-l2reth-snapshot.sh --force .env.testnet
```

The previous data remains recoverable at a path such as:

```text
${DATA_ROOT}/l2reth.backup-20260806T120000Z
```

Remove that backup manually only after verifying the restored node.

### Restore Without Starting Containers

```bash
./scripts/restore-l2reth-snapshot.sh --no-start .env.testnet
```

Start it later with:

```bash
docker compose --env-file .env.testnet up -d
```

### Use a Mirror or Alternate Cache

Normal operators should use the URL and checksum pinned by the script. For a
trusted mirror or pre-release archive, override both values together:

```bash
./scripts/restore-l2reth-snapshot.sh \
  --snapshot-url https://mirror.example/l2reth-snapshot.tar.gz \
  --sha256 <64-hex-character-sha256> \
  --cache-dir /path/on/a/large/disk \
  .env.testnet
```

A cached archive with the expected checksum is reused. A cached archive with a
different checksum is preserved with an `.invalid-<timestamp>` suffix before a
fresh download. The published EBS-derived snapshot is crash-consistent, so the
first Reth startup may perform normal database recovery.

## Dogecoin Node Recovery

No checksum-pinned Dogecoin testnet snapshot is published with this release.
The legacy `latest.txt` URL used by earlier documentation is no longer a
supported download interface. Preserve the named volume and let Dogecoin Core
continue syncing from peers:

```bash
set -a
. ./.env.testnet
set +a

: "${DOGECOIN_VOLUME_NAME:?DOGECOIN_VOLUME_NAME must be set}"
docker volume inspect "$DOGECOIN_VOLUME_NAME"
docker compose --env-file .env.testnet up -d dogecoin-node
docker compose --env-file .env.testnet logs --tail 100 dogecoin-node
```

Do not delete or rename this volume during an upgrade. If a trusted operator
provides a separate Dogecoin archive, require an independently supplied
checksum and archive-layout instructions before restoring it. Do not adapt the
L2Reth restore script or extract an unverified archive directly into the named
volume.

## L1 Interface Recovery

Do not restore a pre-v0.3.0 L1 Interface database into the current release. The
storage format changed in v0.3.0. The supported recovery path is to preserve the
old directory and let the Compose init job download the pinned, verified
historical artifact and replay bootstrap database again.

The generated testnet configuration supplies the public Ethereum RPC default.
If the deployment needs another provider, configure
`DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` in
`envs/testnet/l1-interface.local.env`, then run:

```bash
set -a
. ./.env.testnet
set +a
: "${DATA_ROOT:?DATA_ROOT must be set}"

case "$DATA_ROOT" in
  /*) ;;
  *) echo "DATA_ROOT must be absolute" >&2; exit 1 ;;
esac
case "$DATA_ROOT" in
  /|/tmp|/var/tmp) echo "Refusing unsafe DATA_ROOT: $DATA_ROOT" >&2; exit 1 ;;
esac

docker compose --env-file .env.testnet stop l2reth-node l1-interface

L1_BACKUP="${DATA_ROOT}/l1-interface.backup-$(date -u +%Y%m%dT%H%M%SZ)"
if [ -d "${DATA_ROOT}/l1-interface" ]; then
  mv "${DATA_ROOT}/l1-interface" "$L1_BACKUP"
  printf 'Previous L1 Interface data preserved at: %s\n' "$L1_BACKUP"
fi

./scripts/prepare-data-dir.sh .env.testnet

# Force the one-shot downloader to run again for the new empty directory.
docker compose --env-file .env.testnet rm -f l1-interface-init-fetch-sqlite
docker compose --env-file .env.testnet up -d l1-interface
```

The health endpoint may return HTTP 503 with
`"historical_sync":"in_progress"` during catch-up. Wait for HTTP 200 and
`"status":"ready"` before restarting L2Reth:

```bash
curl http://localhost:9090/health
docker compose --env-file .env.testnet up -d l2reth-node
```

Keep the timestamped backup until replay and indexing have caught up and the
L2Reth node is following the expected canonical chain.
