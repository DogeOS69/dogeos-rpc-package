# Snapshots and Recovery

How to restore published testnet snapshots and recover service data. Run
commands inside the `testnet/` directory; the scripts use its `.env` (see
[Quick Start](../README.md#quick-start)).

When recovering a node, keep its `.env`, project name, Dogecoin volume name,
and RPC credentials; do not replace `.env` with the template.

## How Snapshots Work

Snapshots are published to S3 and listed in the testnet index
(`testnet/index.json` in the snapshot bucket), so new snapshots do not need a
package update. `scripts/restore-snapshot.sh`:

1. Reads the index and selects the newest snapshot whose compatible images
   include the image in `docker-compose.yml`, or the one given with
   `--snapshot-id`.
2. Checks free disk space, then downloads or resumes the archive under
   `${DATA_ROOT}/.snapshot-cache/<component>` and verifies its SHA-256.
3. Checks archive member paths, required database files, and known forbidden
   filenames. These checks do not enforce every publishing rule; see
   [Archive Layout](snapshot-publishing.md#archive-layout).
4. Extracts into a staging directory, stops the affected services, and
   activates the data. Previous data is kept as a timestamped backup when
   `--force` replaces it.
5. Starts the stack, unless `--no-start` is given.

Run the script on a Linux host with Bash, Docker Compose, `curl`, GNU `tar`,
and GNU coreutils (`sha256sum`, `readlink`, `stat`, and `df`). It uses local
`jq` when available, otherwise the `ghcr.io/jqlang/jq` image. Published archives
must contain chain data only. The package supplies genesis, configuration, and
peer settings; operator credentials come from `.env`.

List the published snapshots, their heights, and whether they match your
images:

```bash
./scripts/restore-snapshot.sh --list
```

## Independent Snapshots and Missing Components

Dogecoin, L1 Interface, and L2Reth snapshots may be published independently;
matching timestamps or a three-component bundle are not required. The script
selects a compatible snapshot for the requested component only. It does not
select or change service images: the network's Compose file pins those images.
`compatible_images` describes a component's database compatibility, not proof
that an arbitrary combination of three service versions works together.

For a new node, a missing Dogecoin snapshot means syncing from Dogecoin peers
with the package's unpruned, `txindex=1` configuration. A missing L2Reth snapshot
means starting from the package genesis and syncing with the configured peers
and L1/DA sources after upstream initialization. The L1 Interface fallback is
network-specific, as described below. Existing nodes retain their current data.

Only a successfully fetched index with no compatible entry is an availability
case. Network, checksum, layout, or compatibility errors must be resolved;
do not treat a failed restore as permission to erase data or initialize anew.
No snapshot grouping or automatic image-combination selection is implemented.

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
  whose snapshot is newer than its upstream needs the upstream to catch up.
  Use the staged startup below and check recorded checkpoints before starting
  downstream services. The script reports height differences when metadata and
  running upstream RPC are available; it does not enforce checkpoint gates.

## L2Reth

Restore the newest compatible L2Reth snapshot into `${DATA_ROOT}/l2reth` and
start the stack:

```bash
./scripts/restore-snapshot.sh l2reth
```

The archive holds Reth databases and static files under one `l2reth/` root. It
must exclude genesis, `protocol_context.json`, `jwt.hex`, node keys, keystores,
and `reth.toml`. The package supplies chain configuration, not node keys or
wallets; a chain snapshot does not restore node identity. The first startup
may perform database recovery; let it finish before checking sync progress.

The script refuses to replace a non-empty data directory unless `--force` is
given. With `--force`, the old directory is kept next to it, for example
`${DATA_ROOT}/l2reth.backup-20260806T120000Z-12345`. Remove the backup
manually only after verifying the restored node.

Use `--no-start` to restore without starting services, then start them with
`docker compose up -d`.

<details>
<summary>Advanced: use a mirror or alternate cache</summary>

`--index-url` points the script at a mirrored index. Alternatively, export
`SNAPSHOT_INDEX_URL` in the shell before running the script. Snapshot-specific
variables (`SNAPSHOT_INDEX_URL`, `SNAPSHOT_CACHE_DIR`, and the legacy
`L2RETH_SNAPSHOT_*` variables) are read from the process environment, **not
from `.env`**. Use command-line flags for a one-off override.

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
with `txindex=1`, unpruned, and contain only `testnet3/blocks/` and
`testnet3/chainstate/`. They exclude wallets, configuration, credentials,
cookies, peer state, and logs; a chain snapshot is not a wallet backup.

### Restore into a New Docker Volume

Dogecoin keeps its data in the Docker volume named by `DOGECOIN_VOLUME_NAME`
(default `dogeos-rpc-package_dogecoin_data`). **The script only restores into
a volume that does not exist yet.** For a new installation, the default name is
unused. To recover
an existing node, keep its original volume and set `DOGECOIN_VOLUME_NAME` in
`.env` to a new, unused name; you can switch back by restoring the old
name. Never delete or clear the original volume.

```bash
./scripts/restore-snapshot.sh --no-start dogecoin
```

With `--no-start`, running services are not touched and the script prints the
commands that switch to the new volume. They stop the dependent services first
and recreate `dogecoin-node`:

```bash
docker compose stop l2reth-node l1-interface dogecoin-node
docker compose up -d --force-recreate dogecoin-node
docker compose up -d
```

`DATA_ROOT` holds the download cache, but the extracted data goes to Docker's
volume storage; make sure the disk behind Docker's data root has room. If
extraction fails or is interrupted, the script removes the partly filled
volume it created; fix the cause and run it again.

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

Check that `chain` is `test`, `pruned` is `false`, the
block hash matches the manifest's checkpoint hash, and `verifychain` returns
`true`. After catching up, `initialblockdownload` should be `false` and the tip
should agree with a trusted node. Avoid `-reindex`: the archive includes the
block and transaction indexes.

## L1 Interface

L1 Interface is a separately published component, restored with the same
script as Dogecoin and L2Reth. It does not require the three snapshots to be
published together. `--list` shows available entries; an explicit restore
fails if none matches the pinned L1 Interface image. A failed download or
checksum check never silently falls back to bootstrap.

### Fixed Data Layout

Only `DATA_ROOT` is configurable. The host directory
`${DATA_ROOT}/l1-interface` is mounted read-write at `/data`. Database filenames
and paths inside the container are fixed by the package:

```text
l1-interface/                               # single archive root
  l1-interface.sqlite                      # /data/l1-interface.sqlite
  replay.sqlite                            # /data/replay.sqlite
  replay.artifacts/                        # /data/replay.artifacts/
    eth_da_artifacts.sqlite
    eth_da_artifacts/                       # include even when empty
    ...                                    # all other replay artifacts
  l1-interface-historical-artifact.sqlite   # required when configured
```

Restore activates the archive root as `${DATA_ROOT}/l1-interface`, without
adding a second `l1-interface/` directory. Configuration and genesis stay in
`config/`; they are not snapshot contents. Do not override database paths in
service env files or add nested mounts under `/data`. Startup rejects custom
database paths; restore also checks the resolved Compose mounts and paths
before downloading. An existing deployment with custom paths must reconcile
its data layout before using these operations; the package does not move it
automatically.

The databases and artifacts are one unit: never combine files from different
snapshots. The restore requires Python 3 with SQLite support. It checks archive
layout, rejects links, special files, duplicate members and SQLite sidecars,
and runs read-only SQLite `quick_check` in staging before stopping services.
Publishers must checkpoint all databases before archiving; deleting WAL files
is not a substitute. Protocol compatibility and the completeness of database
artifact references also require the publisher's restore/start test with the
compatible image; these are not proved by `quick_check`.

### With a Compatible Snapshot

For a new node, restore Dogecoin first if desired, then L1 Interface, then
L2Reth. Keep services stopped while restoring:

```bash
./scripts/restore-snapshot.sh --list
# Run only when --list shows a compatible L1 Interface snapshot.
./scripts/restore-snapshot.sh --no-start l1-interface
```

For an existing node, the script refuses a non-empty L1 directory unless
`--force` is supplied. It validates the staged data, stops L2Reth and L1
Interface, then preserves the old directory as a timestamped backup and
activates the entire new directory. Dogecoin data is unchanged. Keep the
backup until startup and syncing are verified.

Start Dogecoin first and let it catch up, then L1 Interface. Check
`/api/v1/health/ready` and its logs. Before starting an existing or restored
L2Reth, ensure L1 Interface has reached the upstream checkpoint required by
that L2 data; compare checkpoint hashes when provided. A lower upstream
height calls for catch-up, while a hash mismatch needs investigation. A health
response alone does not establish checkpoint compatibility.

```bash
docker compose up -d dogecoin-node
# Wait for Dogecoin RPC warmup and the required chain checkpoint.
docker compose up -d l1-interface
# Wait for readiness and the required L1 checkpoint before continuing.
curl --fail http://localhost:9090/api/v1/health/ready
docker compose up -d l2reth-node
```

These are staged operator checks, not an automatic checkpoint gate in the
restore script. Without `--no-start`, the existing script starts the stack
immediately after restore. Use `--no-start` when combining snapshots or
replacing upstream data of an existing L2 node.

### Without a Compatible Snapshot

A fresh testnet node uses the fixed historical bootstrap in
`l1-interface-init-fetch-sqlite`: the pre-upgrade historical artifact and an
initial replay DB. This bootstrap is a versioned initialization prerequisite,
not a periodic runtime snapshot. Start Dogecoin and then L1 Interface as above;
the initializer downloads and verifies the pinned bootstrap, and L1 Interface
builds its index and catches up from Dogecoin and Ethereum DA.

After a runtime snapshot restore, the initializer preserves the existing
`replay.sqlite`. The restored historical artifact must match the package's
pinned bootstrap SHA-256; the restore checks it before activation. An existing
`l1-interface.sqlite` without `replay.sqlite` is an incomplete data set: the
initializer refuses to insert a fresh bootstrap DB into it. Restore a complete
L1 snapshot or deliberately rebuild using the procedure below.

Never enable fresh-genesis initialization for this upgraded testnet or reuse
a pre-v0.3.0 L1 Interface database. Existing healthy data should simply continue
syncing; absence of a published snapshot is not a reason to reset it.

### Rebuild from the Bootstrap Data

Without a snapshot, L1 Interface data can be rebuilt from the pinned,
verified bootstrap data that the `l1-interface-init-fetch-sqlite` service
downloads. L2Reth is stopped first and started only after L1 Interface is
ready.

The block runs in its own `bash`, so an error stops it without closing your
shell. It takes `DATA_ROOT` from the configuration Docker Compose resolves
(this needs `jq`), so it acts on the directory the stack actually mounts:

```bash
bash <<'EOF'
set -euo pipefail
DATA_ROOT="$(docker compose config --format json |
  jq -r '.services["l2reth-node"].volumes[] | select(.target == "/l2reth") | .source | rtrimstr("/l2reth")')"
case "$DATA_ROOT" in
  /path/to|/path/to/*) echo 'Replace the DATA_ROOT placeholder first' >&2; exit 1 ;;
  /|/tmp|/var/tmp) echo "Refusing unsafe DATA_ROOT: $DATA_ROOT" >&2; exit 1 ;;
  /*) ;;
  *) echo "DATA_ROOT must be absolute" >&2; exit 1 ;;
esac

docker compose stop l2reth-node l1-interface

L1_BACKUP="${DATA_ROOT}/l1-interface.backup-$(date -u +%Y%m%dT%H%M%SZ)"
if [ -d "${DATA_ROOT}/l1-interface" ]; then
  mv "${DATA_ROOT}/l1-interface" "$L1_BACKUP"
  printf 'Previous L1 Interface data preserved at: %s\n' "$L1_BACKUP"
fi

# Run the one-shot downloader again for the new empty directory.
docker compose rm -f l1-interface-init-fetch-sqlite
docker compose up -d l1-interface
EOF
```

Wait until `curl http://localhost:9090/health` returns HTTP 200 with
`"status":"ready"` (HTTP 503 with `"historical_sync":"in_progress"` means it is
still catching up), then start L2Reth:

```bash
docker compose up -d l2reth-node
```

Keep the backup until L1 Interface has caught up and L2Reth follows the
canonical chain.

## Reset L2Reth and L1 Interface Data

Use this only when both services intentionally need fresh data; it is not an
upgrade step. The helper stops the stack, moves `${DATA_ROOT}/l2reth` and
`${DATA_ROOT}/l1-interface` to timestamped backups, and creates empty
directories. Dogecoin data and the snapshot cache are kept:

```bash
./scripts/reset-chain-data.sh
./scripts/restore-snapshot.sh --no-start l2reth
docker compose up -d
```

Verify with [Verify Services](../README.md#5-verify-services) and keep the
backups until the new data is verified.

<details>
<summary>Advanced: permanently delete L2Reth and L1 Interface data</summary>

This stops the stack and permanently deletes both data directories without
backups. Dogecoin data and the snapshot cache are kept.

```bash
./scripts/reset-chain-data.sh --delete --yes
```

</details>
