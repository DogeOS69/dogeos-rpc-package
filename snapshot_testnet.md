# Testnet Snapshot and Recovery Guide

This guide covers the supported recovery paths for L2Reth, the bundled
Dogecoin node, and L1 Interface in the testnet RPC package.

**Upgrading from the old `main` / v0.2.x package?** Start with the
[v0.3.0 upgrade guide](upgrade_v0.3.0.md). This snapshot script does not migrate
old Docker volumes or stop an old Compose project with a different name.

## Common Prerequisites

Run commands from the repository root. For a new installation, create the
Compose env file below. For recovery of an existing v0.3.0 installation, keep
its `.env.testnet` and review the settings; do not overwrite it with a template.

```bash
if [ ! -e .env.testnet ]; then cp .env.example.testnet .env.testnet; fi
chmod 600 .env.testnet

# Edit the Compose env before continuing:
# - replace the /path/to/... placeholder in DATA_ROOT with your data disk path
# - review the stable DOGECOIN_RPC_USER and DOGECOIN_RPC_PASSWORD values
```

No separate directory-preparation command is required. The snapshot script
creates its cache, staging, and L2Reth target directories itself. For a normal
start, Compose creates the L2Reth and L1 Interface bind-mount source
directories, and Docker creates the Dogecoin named volume. Before either path,
fill in `DATA_ROOT` and verify that its data disk is mounted (for example,
`findmnt -T /data` if you mounted your disk at `/data`); otherwise Docker can
create the path on the root filesystem.

The package includes a public Ethereum RPC default. For another provider, follow
[Custom Ethereum RPC](README.md#custom-ethereum-rpc). Bundled Dogecoin credentials
come from `.env.testnet`; keep their existing values when recovering a node.

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
come from the supplied repository configuration. The first Reth startup may
perform database recovery; allow it to finish before checking sync progress.

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

<details>
<summary>Advanced: use a mirror or alternate cache</summary>

Use the URL and checksum pinned by the script unless you need a trusted mirror.
When overriding the URL, supply the matching SHA-256 as well:

```bash
./scripts/restore-l2reth-snapshot.sh \
  --snapshot-url https://mirror.example/l2reth-snapshot.tar.gz \
  --sha256 'REPLACE_WITH_64_HEX_CHARACTER_SHA256' \
  --cache-dir /path/on/a/large/disk \
  .env.testnet
```

A cached archive with the expected checksum is reused. A cached archive with a
different checksum is preserved with an `.invalid-<timestamp>` suffix before a
fresh download.

</details>

## Dogecoin Node Recovery

For a new node or recovery into a new volume, use the
[checksum-pinned Dogecoin testnet snapshot](snapshot_dogecoin_testnet.md).
It includes block data, the transaction index, and chainstate, with no wallet
or deployment credentials. Use the versioned URL and checksum in that guide.

For a healthy existing node, preserve its named volume and let Dogecoin Core
continue syncing from peers; an upgrade does not require snapshot restoration:

```bash
set -euo pipefail
set -a
. ./.env.testnet
set +a

: "${DOGECOIN_VOLUME_NAME:?DOGECOIN_VOLUME_NAME must be set}"
docker volume inspect "$DOGECOIN_VOLUME_NAME"
docker compose --env-file .env.testnet up -d dogecoin-node
docker compose --env-file .env.testnet logs --tail 100 dogecoin-node
```

Do not delete or rename this volume during an upgrade. If recovery is needed,
the Dogecoin snapshot guide restores into a new volume and refuses an existing
destination. Keep the previous volume until recovery is accepted. Do not use
the L2Reth restore script for Dogecoin; their archive layouts and storage
destinations differ.

## L1 Interface Recovery

Do not restore a pre-v0.3.0 L1 Interface database into the current release. The
storage format changed in v0.3.0. The supported recovery path is to preserve the
old directory and let the Compose init job download the pinned, verified
historical artifact and replay bootstrap database again.

The supplied testnet configuration includes the public Ethereum RPC default.
If the deployment needs another provider, configure
`DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` in
`envs/testnet/l1-interface.local.env`, then run:

```bash
set -euo pipefail
set -a
. ./.env.testnet
set +a
: "${DATA_ROOT:?DATA_ROOT must be set}"

case "$DATA_ROOT" in
  /path/to|/path/to/*) echo 'Replace the DATA_ROOT placeholder first' >&2; exit 1 ;;
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

## Reset L2Reth and L1 Interface Data

Use this only when you intentionally need fresh data for both services. It is
not an upgrade step. For a problem affecting one service, use its recovery
procedure above instead.

The reset helper stops the stack, moves `${DATA_ROOT}/l2reth` and
`${DATA_ROOT}/l1-interface` to timestamped backups, and creates empty
replacement directories. It preserves the Dogecoin named volume and snapshot
cache:

```bash
./scripts/reset-chain-data.sh .env.testnet
```

Then restore L2Reth and start the stack:

```bash
./scripts/restore-l2reth-snapshot.sh --no-start .env.testnet
docker compose --env-file .env.testnet up -d
```

Verify readiness and sync using [Verify Services](README.md#5-verify-services).
Keep the backups until the replacement data is verified.

<details>
<summary>Advanced: permanently delete L2Reth and L1 Interface data</summary>

Only use this when you intend to discard both databases without keeping
backups. The command stops the stack and permanently deletes the two data
directories before creating empty replacements. It preserves the Dogecoin
volume and snapshot cache.

```bash
./scripts/reset-chain-data.sh --delete --yes .env.testnet
```

Restore and start the stack using the commands above after deletion completes.

</details>
