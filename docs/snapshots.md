# Snapshots and Recovery

How to restore published snapshots and recover service data. Commands use
testnet; on mainnet use `.env.mainnet` instead of `.env.testnet`. Mainnet
snapshots are not published yet ([mainnet status](../networks/mainnet/README.md)).

Run commands from the repository root with an existing `.env.testnet` (see
[Quick Start](../README.md#quick-start)). When recovering a node, keep its env
file, project name, Dogecoin volume name, and RPC credentials; do not replace
the env file with the template.

## How Snapshots Work

Snapshots are published to S3 and listed in a per-network index
(`<network>/index.json` in the snapshot bucket), so new snapshots do not need a
package update. `scripts/restore-snapshot.sh`:

1. Reads the index for `NETWORK` and selects the newest snapshot whose
   compatible images include the image in `networks/<network>/compose.yml`, or
   the one given with `--snapshot-id`.
2. Checks free disk space, then downloads or resumes the archive under
   `${DATA_ROOT}/.snapshot-cache/<component>` and verifies its SHA-256.
3. Rejects unsafe archive paths and files that must not be in a snapshot
   (keys, wallets, configuration, credentials).
4. Extracts into a staging directory, stops the affected services, and
   activates the data. Previous data is kept as a timestamped backup when
   `--force` replaces it.
5. Starts the stack, unless `--no-start` is given.

The script needs `curl`, `docker`, `sha256sum`, GNU `tar`, and `jq`; without
`jq` it runs the `ghcr.io/jqlang/jq` image. Archives contain chain data only:
genesis, configuration, credentials, and peers always come from this package.

List the published snapshots, their heights, and whether they match your
images:

```bash
./scripts/restore-snapshot.sh --list .env.testnet
```

## Restore Order and Service Dependencies

Services depend on each other as **Dogecoin → L1 Interface → L2Reth**.

- Restoring a component stops it **and every service that depends on it**
  before the new data is activated:

  | Restore | Stopped first |
  |---------|---------------|
  | `dogecoin` | `l2reth-node`, `l1-interface`, `dogecoin-node` |
  | `l1-interface` | `l2reth-node`, `l1-interface` |
  | `l2reth` | `l2reth-node` |

  L2Reth must never keep running while L1 Interface data is replaced with
  older data: rollup-node treats a lower L1 Interface head as an L1 reorg and
  unwinds L2 state. Apply the same rule to any manual data change.
- For a new node, restore **Dogecoin, then L1 Interface (when published),
  then L2Reth**, with `--no-start`, and start the stack once at the end.
- Snapshots of different components may have different ages. A component
  whose snapshot is newer than its upstream service waits or restarts until
  the upstream catches up; its data is not affected. The script prints a
  warning when it can see this.

## L2Reth

Restore the newest compatible L2Reth snapshot into `${DATA_ROOT}/l2reth` and
start the stack:

```bash
./scripts/restore-snapshot.sh l2reth .env.testnet
```

The archive holds Reth databases and static files under one `l2reth/` root. It
excludes genesis, `protocol_context.json`, `jwt.hex`, node keys, keystores, and
`reth.toml`; those come from this package. The first startup may perform
database recovery; let it finish before checking sync progress.

The script refuses to replace a non-empty data directory unless `--force` is
given. With `--force`, the old directory is kept next to it, for example
`${DATA_ROOT}/l2reth.backup-20260806T120000Z-12345`. Remove the backup
manually only after verifying the restored node.

Use `--no-start` to restore without starting services, then start them with
`docker compose --env-file .env.testnet up -d`.

<details>
<summary>Advanced: use a mirror or alternate cache</summary>

`--index-url` (or `SNAPSHOT_INDEX_URL`) points the script at a mirrored index.
To bypass the index, supply both the archive URL and its SHA-256; no image
compatibility check is made in this mode:

```bash
./scripts/restore-snapshot.sh \
  --snapshot-url https://mirror.example/l2reth-snapshot.tar.gz \
  --sha256 'REPLACE_WITH_64_HEX_CHARACTER_SHA256' \
  --cache-dir /path/on/a/large/disk \
  l2reth .env.testnet
```

A cached archive with the expected checksum is reused. A cached archive with a
different checksum is preserved with an `.invalid-<timestamp>` suffix before a
fresh download. Do not bypass a checksum failure.

</details>

## Dogecoin

Restore a Dogecoin snapshot for a **new node** or to recover into **new
storage**. A healthy existing node should keep its data and continue syncing
from peers; upgrades never require a Dogecoin restore.

Each Dogecoin snapshot has a manifest, whose URL the script prints when it
selects the snapshot. It records the checkpoint height and hash, the Dogecoin
Core version, and the validation done before publishing. Archives are taken
with `txindex=1`, unpruned, and contain only `blocks/` and `chainstate/` (under
`testnet3/` on testnet). They exclude wallets, configuration, credentials,
cookies, peer state, and logs; a chain snapshot is not a wallet backup.

### Testnet: Restore into a New Docker Volume

On testnet, Dogecoin keeps its data in the Docker volume named by
`DOGECOIN_VOLUME_NAME`. **The script only restores into a volume that does not
exist yet.** For a new installation, the template's name is unused. To recover
an existing node, keep its original volume and set `DOGECOIN_VOLUME_NAME` in
`.env.testnet` to a new, unused name; you can switch back by restoring the old
name. Never delete or clear the original volume.

```bash
./scripts/restore-snapshot.sh --no-start dogecoin .env.testnet
```

With `--no-start`, running services are not touched and the script prints the
commands that switch to the new volume. They stop the dependent services first
and recreate `dogecoin-node`:

```bash
docker compose --env-file .env.testnet stop l2reth-node l1-interface dogecoin-node
docker compose --env-file .env.testnet up -d --force-recreate dogecoin-node
docker compose --env-file .env.testnet up -d
```

`DATA_ROOT` holds the download cache, but the extracted data goes to Docker's
volume storage; make sure the disk behind Docker's data root has room. If
extraction fails, the script names the partial volume: do not start the node
on it, and remove it before retrying.

### Mainnet: Restore into `${DATA_ROOT}/dogecoin`

On mainnet, `DOGECOIN_DATA` points Dogecoin at `${DATA_ROOT}/dogecoin`, and the
restore works like L2Reth: a non-empty directory is replaced only with
`--force`, and the old one is kept as a backup.

### Verify the Restored Node

Initial block-index loading and chain-state checks can take more than ten
minutes, including several minutes at `Rewinding blocks...` without another
log line. `-rpcwait` waits for RPC warmup:

```bash
docker compose --env-file .env.testnet logs --tail 100 dogecoin-node

docker compose --env-file .env.testnet exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -rpcwait -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockchaininfo

# Replace HEIGHT with the checkpoint height from the snapshot manifest.
docker compose --env-file .env.testnet exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockhash HEIGHT

docker compose --env-file .env.testnet exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data verifychain 3 288
```

Check that `chain` is `test` (`main` on mainnet), `pruned` is `false`, the
block hash matches the manifest's checkpoint hash, and `verifychain` returns
`true`. After catching up, `initialblockdownload` should be `false` and the tip
should agree with a trusted node. Avoid `-reindex`: the archive includes the
block and transaction indexes.

## L1 Interface

When L1 Interface snapshots are published for a network, restore them like
L2Reth; the script stops `l2reth-node` and `l1-interface` first:

```bash
./scripts/restore-snapshot.sh l1-interface .env.testnet
```

Do not restore a pre-v0.3.0 L1 Interface database; its storage format changed
in v0.3.0.

### Testnet: Rebuild from the Bootstrap Data

Without a snapshot, testnet L1 Interface data can be rebuilt from the pinned,
verified bootstrap data that the `l1-interface-init-fetch-sqlite` service
downloads. L2Reth is stopped first and started only after L1 Interface is
ready:

```bash
set -euo pipefail
set -a
. ./.env.testnet
set +a
: "${DATA_ROOT:?DATA_ROOT must be set}"
case "$DATA_ROOT" in
  /path/to|/path/to/*) echo 'Replace the DATA_ROOT placeholder first' >&2; exit 1 ;;
  /|/tmp|/var/tmp) echo "Refusing unsafe DATA_ROOT: $DATA_ROOT" >&2; exit 1 ;;
  /*) ;;
  *) echo "DATA_ROOT must be absolute" >&2; exit 1 ;;
esac

docker compose --env-file .env.testnet stop l2reth-node l1-interface

L1_BACKUP="${DATA_ROOT}/l1-interface.backup-$(date -u +%Y%m%dT%H%M%SZ)"
if [ -d "${DATA_ROOT}/l1-interface" ]; then
  mv "${DATA_ROOT}/l1-interface" "$L1_BACKUP"
  printf 'Previous L1 Interface data preserved at: %s\n' "$L1_BACKUP"
fi

# Run the one-shot downloader again for the new empty directory.
docker compose --env-file .env.testnet rm -f l1-interface-init-fetch-sqlite
docker compose --env-file .env.testnet up -d l1-interface
```

Wait until `curl http://localhost:9090/health` returns HTTP 200 with
`"status":"ready"` (HTTP 503 with `"historical_sync":"in_progress"` means it is
still catching up), then start L2Reth:

```bash
docker compose --env-file .env.testnet up -d l2reth-node
```

Keep the backup until L1 Interface has caught up and L2Reth follows the
canonical chain.

## Reset L2Reth and L1 Interface Data

Use this only when both services intentionally need fresh data; it is not an
upgrade step. The helper stops the stack, moves `${DATA_ROOT}/l2reth` and
`${DATA_ROOT}/l1-interface` to timestamped backups, and creates empty
directories. Dogecoin data and the snapshot cache are kept:

```bash
./scripts/reset-chain-data.sh .env.testnet
./scripts/restore-snapshot.sh --no-start l2reth .env.testnet
docker compose --env-file .env.testnet up -d
```

Verify with [Verify Services](../README.md#5-verify-services) and keep the
backups until the new data is verified.

<details>
<summary>Advanced: permanently delete L2Reth and L1 Interface data</summary>

This stops the stack and permanently deletes both data directories without
backups. Dogecoin data and the snapshot cache are kept.

```bash
./scripts/reset-chain-data.sh --delete --yes .env.testnet
```

</details>
