# Snapshots and Recovery

How to restore published mainnet snapshots and recover service data. Run
commands inside the `mainnet/` directory; the scripts use its `.env`. Mainnet
is not released yet and no mainnet snapshots are published; the commands below
work once the mainnet index is published with the release.

When recovering a node, keep its `.env`, `DATA_ROOT`, and RPC credentials; do
not replace `.env` with the template.

## How Snapshots Work

Snapshots are published to S3 and listed in the mainnet index
(`mainnet/index.json` in the snapshot bucket), so new snapshots do not need a
package update. `scripts/restore-snapshot.sh`:

1. Reads the index and selects the newest snapshot whose compatible images
   include the image in `docker-compose.yml`, or the one given with
   `--snapshot-id`.
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
./scripts/restore-snapshot.sh --list
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
./scripts/restore-snapshot.sh l2reth
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
`docker compose up -d`.

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
  l2reth
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
with `txindex=1`, unpruned, and contain only `blocks/` and `chainstate/`. They
exclude wallets, configuration, credentials, cookies, peer state, and logs; a
chain snapshot is not a wallet backup.

### Restore into `${DATA_ROOT}/dogecoin`

```bash
./scripts/restore-snapshot.sh --no-start dogecoin
```

The restore works like L2Reth: a non-empty `${DATA_ROOT}/dogecoin` is replaced
only with `--force`, and the old directory is kept as a backup. The script
stops L2Reth, L1 Interface, and Dogecoin before activating the data.

### Verify the Restored Node

Initial block-index loading and chain-state checks can take more than ten
minutes, including several minutes at `Rewinding blocks...` without another
log line. `-rpcwait` waits for RPC warmup:

```bash
docker compose logs --tail 100 dogecoin-node

docker compose exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -rpcwait -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockchaininfo

# Replace HEIGHT with the checkpoint height from the snapshot manifest.
docker compose exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockhash HEIGHT

docker compose exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data verifychain 3 288
```

Check that `chain` is `main`, `pruned` is `false`, the block hash matches the manifest's checkpoint hash, and `verifychain` returns
`true`. After catching up, `initialblockdownload` should be `false` and the tip
should agree with a trusted node. Avoid `-reindex`: the archive includes the
block and transaction indexes.

## L1 Interface

When L1 Interface snapshots are published, restore them like L2Reth; the
script stops `l2reth-node` and `l1-interface` first:

```bash
./scripts/restore-snapshot.sh l1-interface
```

## Reset L2Reth and L1 Interface Data

Use this only when both services intentionally need fresh data; it is not an
upgrade step. The helper stops the stack, moves `${DATA_ROOT}/l2reth` and
`${DATA_ROOT}/l1-interface` to timestamped backups, and creates empty
directories. Dogecoin data (`${DATA_ROOT}/dogecoin`) and the snapshot cache are
kept:

```bash
./scripts/reset-chain-data.sh
./scripts/restore-snapshot.sh --no-start l2reth
docker compose up -d
```

Check that the services start and L2Reth's block height advances, and keep the
backups until the new data is verified.

<details>
<summary>Advanced: permanently delete L2Reth and L1 Interface data</summary>

This stops the stack and permanently deletes both data directories without
backups. Dogecoin data and the snapshot cache are kept.

```bash
./scripts/reset-chain-data.sh --delete --yes
```

</details>
