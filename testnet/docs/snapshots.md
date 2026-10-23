# Snapshots and Recovery

Run commands inside `testnet/`. Keep the existing `.env`, `DATA_ROOT`, and RPC
credentials when recovering a node. Existing testnet initialization uses the pinned history bootstrap.

## How Snapshots Work

The group catalog is `testnet/index.json` in the snapshot bucket. A group
manifest pins its component archives by SHA-256 and records network identity,
image compatibility, data checkpoints and upstream requirements. Archives keep
their independent component layouts; they are not nested inside one large tar.

```bash
python3 scripts/snapshot-group.py list
# Select an ID printed by list, or explicitly use latest.
python3 scripts/snapshot-group.py restore GROUP_ID --no-start
python3 scripts/snapshot-group.py start
```

`list` fetches the catalog and its checksum-verified group manifests, but no
component archives. It shows present/absent components, capture times,
component checkpoint heights, archive sizes and compatible images. Heights
belong to each service's own chain (L1 Interface uses its synthetic chain).
With `.env` (or `--env-file PATH`), it also checks the resolved package identity,
images and upstream configuration: `MATCH` or `INCOMPATIBLE` with a reason.
Without `.env`, it reports `NOT CHECKED`; configure the node and list again
before choosing. Invalid local configuration is an error. Listing never starts
or stops services or changes their data. `MATCH` does not check existing data,
free space or runtime readiness; restore and startup still enforce their checks.
Totals are archive metadata, not a complete disk-space estimate: allow room for
retained backups, caches and chain growth on each relevant filesystem.

`latest` resolves one group once. It does not select a separate latest snapshot
for each service. The chosen manifest is checked against the catalog checksum,
then against the package genesis/protocol-context files and configured images.
Missing/incompatible groups, download failures and checksum errors are errors;
none triggers an automatic fallback to another group or a data reset.

Use `--env-file PATH` for a different env file and `--index-url HTTPS_URL` for a
catalog mirror. `SNAPSHOT_INDEX_URL` is a process-environment override, not an
`.env` service setting. The host needs Python 3.9+ with SQLite, Bash, Docker
Compose, curl, GNU tar/coreutils and jq (or the pinned jq helper image).

## Independent Snapshots and Missing Components

A group explicitly contains all three component names, each an entry or JSON
`null`. Single-component and all-null groups are supported. Missing components
are never fetched from another group:

- Dogecoin starts from existing data or syncs from peers using the unpruned,
  transaction-indexed configuration.
- L1 Interface keeps known local data or uses the network initialization path
  described below.
- L2Reth keeps known local data or starts from package genesis, then syncs with
  peers and the configured L1/DA sources.

No snapshot is required for a fresh node. Start it without accessing a catalog:

```bash
python3 scripts/snapshot-group.py start
```

Snapshot absence does not remove requirements for genesis, protocol context,
bootstrap history (testnet), release configuration, or reachable DA data.

For a partial group on an existing node, missing components keep their local
data. Previously recorded checkpoints remain lower bounds, not proof of the
current dependency after a node has continued running. Therefore, if a group
replaces upstream data while omitting a populated downstream component, restore
refuses to guess that downstream's current dependency. Include its snapshot in
the recovery group. An L2-only restore can retain an unchanged L1/Dogecoin;
a fresh node can omit any or all snapshots. No data is silently deleted.

## Restore Order and Service Dependencies

The group helper preflights metadata and image/identity compatibility, records
a pending restore, stops all three services, and restores present components
in **Dogecoin -> L1 Interface -> L2Reth** order with the component script's
`--no-start` mode. Existing nonempty bind data requires `--force`; previous data
is moved to timestamped backups. Existing Dogecoin Docker volumes are never
replaced. See [Dogecoin](#dogecoin) for the testnet volume restriction.

This is not an atomic three-database transaction. A later download/validation
failure can leave earlier components restored, with their old data in backups.
Services stay stopped and `.snapshot-group-state.json` remains `restoring`.
Retry the **same group ID** with `--force`; the saved manifest is reused even
if the catalog changed, and components recorded as completed are skipped.
`start` refuses a pending restore. Never delete the journal to bypass an
incomplete recovery. If the process died during component activation before
completion was recorded, inspect its staging/backup data first. In particular,
an already-created Dogecoin volume is never overwritten automatically.

On successful restore, `start` reads the saved effective manifest and:

1. Stops L2Reth and L1 Interface before upstream catch-up.
2. Starts bundled Dogecoin, or checks the configured external Dogecoin RPC.
   It requires the correct network, unpruned data, `initialblockdownload=false`,
   blocks caught up to known headers, and matching required checkpoint hashes.
3. Starts L1 Interface. It waits for `/health` to report historical sync
   complete, `/api/v1/health/ready` to report ready, and its synthetic chain to
   cover and match the recorded checkpoints required by restored L2Reth.
4. Starts L2Reth without restarting its Compose dependencies. Check L2 progress
   before exposing RPC traffic.

A low upstream height waits and retries; a hash mismatch aborts with downstream
stopped. Hash requirements may deliberately refer to heights older than the
upstream snapshot tip. Capture order does not replace these checks. No-snapshot
startup has no snapshot checkpoints to verify, but retains the synchronization
and health waits.

These host-side waits require published L1 RPC/health ports and a reachable
Docker daemon. They run in the foreground; keep the session alive (for example
with tmux). Re-running `start` after interruption is safe but stops downstream
again. Plain `docker compose up -d` and daemon auto-restart do **not** run this
host-side checkpoint sequence. Use `start` after data replacement or a cold
recovery. L2Reth still performs its RPC/readiness check on every container start.
A normal container healthcheck is not a continuous guarantee of chain sync.

## L2Reth

The archive is rooted at `l2reth/`, including `db/mdbx.dat`, `db/scroll.db` and
`static_files/`. It excludes chain configuration, credentials, node keys and
keystores. Forbidden `genesis/` and `lost+found/` descendants are rejected even
without explicit tar directory entries. Keep backups until restored sync is
verified.

### Legacy Component Restore

`restore-snapshot.sh` is retained for schema-1 catalogs and explicit archives.
It validates archive checksums/layout and uses staged startup by default, but
has no group checkpoint contract. It refuses to modify data already managed
by a group. Prefer group restore for normal recovery.

```bash
./scripts/restore-snapshot.sh --index-url https://YOUR-BUCKET/testnet/legacy-index.json --list
./scripts/restore-snapshot.sh --no-start \
  --index-url https://YOUR-BUCKET/testnet/legacy-index.json l2reth
python3 scripts/snapshot-group.py start
```

Advanced direct-archive mode requires `--snapshot-url HTTPS_URL` and `--sha256
HASH`; it bypasses index/network/image metadata checks. The group helper uses
this mode internally only after validating its pinned metadata. A direct
operator restore must independently verify those properties and required
checkpoints. `--cache-dir`, `SNAPSHOT_CACHE_DIR`, and legacy `L2RETH_SNAPSHOT_*`
overrides apply to component mode; group mode ignores those overrides so they
cannot replace a pinned selection.

Cached archives live at `${DATA_ROOT}/.snapshot-cache/<component>`. A cached
checksum mismatch is quarantined before redownload. A newly downloaded
checksum mismatch exits without activation; the next run quarantines it.
Never bypass a checksum failure.

## Dogecoin

Do not restore over a healthy Dogecoin node simply for an upgrade. A partial
group can omit Dogecoin and retain it. Testnet uses a Docker volume. Group restore can populate a new empty volume only. For a populated existing volume, omit Dogecoin from the group and let it catch up, or deliberately configure a new volume before recovery. `--force` never replaces an existing volume.

The archive root is `dogecoin/`, with `testnet3/blocks/` and `testnet3/chainstate/`. Keep block/transaction
indexes and chainstate together; snapshots are not wallet backups.

### Verify the Restored Node

```bash
docker compose exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockchaininfo

docker compose exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data verifychain 3 288
```

Expect `chain=test`, `pruned=false`, completed initial sync, and a true
`verifychain` result. The group startup helper also verifies the manifest's
Dogecoin block hashes. Avoid reindexing a valid archive unnecessarily.

## L1 Interface

L1 data can be a component of a full or partial group. Missing snapshots use
the network's initialization path; corrupt or incompatible snapshots never
silently fall back to bootstrap.

### Fixed Data Layout

The host `${DATA_ROOT}/l1-interface` is mounted as `/data`. Only the host root
is configurable; internal database and artifact paths are fixed:

```text
l1-interface/
  l1-interface.sqlite
  replay.sqlite
  replay.artifacts/
    eth_da_artifacts.sqlite
    eth_da_artifacts/
    ...
  l1-interface-historical-artifact.sqlite  # when configured
```

These files are one unit from one stopped instance. Never mix databases or
artifacts from different captures. The package supplies configuration and
genesis outside the archive. Restore checks fixed mounts/paths, archive
members, SQLite integrity and the pinned testnet historical-file checksum. These checks do not prove
semantic consistency of replay and referenced DA artifacts; the publisher
must test restore/start and historical data reads with the intended image.

### With a Compatible Snapshot

```bash
python3 scripts/snapshot-group.py restore GROUP_ID --no-start
python3 scripts/snapshot-group.py start
```

Use `--force` only when intentionally replacing nonempty bind-mounted data;
old directories are preserved. The group state records the L1/Dogecoin and
L2/L1 dependencies used during staged startup. Low upstream height causes
waiting; a block hash mismatch requires investigation.

### Without a Compatible Snapshot

For a fresh testnet data directory, the one-shot initializer downloads and
verifies the pinned historical artifact and replay seed. The startup helper
recreates this initializer before starting L1 so an old completed init
container cannot skip validation. Existing replay data is preserved. An L1
index database without its replay database is rejected as an incomplete data
set. Never enable fresh-genesis mode for this upgraded testnet or combine
pre-upgrade L1 databases with the replay seed.

### Rebuild from the Bootstrap Data

For an ungrouped node that intentionally needs fresh L1/L2 data, use the reset
procedure below and then `start`. For grouped recovery, publish/select a valid
replacement group and use `restore --force`. Avoid manually replacing only
part of the L1 data directory or bypassing the recorded checkpoint gates.

## Reset L2Reth and L1 Interface Data

`reset-chain-data.sh` is for intentional resets of legacy, ungrouped data. It
stops services and moves L1/L2 data to backups (or deletes it only with the
explicit `--delete --yes` options), retaining Dogecoin and download caches.
It refuses grouped data so dependency metadata cannot silently become stale;
use a validated group restore with `--force` for grouped recovery.

```bash
./scripts/reset-chain-data.sh
python3 scripts/snapshot-group.py start
```

Keep backups until sync and RPC behavior are verified. Mainnet cold startup
still depends on its release initialization prerequisites.
