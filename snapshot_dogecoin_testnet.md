# Dogecoin Testnet Snapshot

This snapshot is for a **new testnet Dogecoin node** or recovery into a **new
Docker volume**. An existing, healthy node should keep its current volume and
continue syncing. The [v0.3.0 upgrade procedure](upgrade_v0.3.0.md) does not
require restoring or replacing Dogecoin data.

## Published Artifact

| Property | Value |
|----------|-------|
| Network | Dogecoin testnet (`testnet3` data directory) |
| Dogecoin Core | `1.14.9`, with `txindex=1`, unpruned |
| Source snapshot time | 2026-09-08 19:45:12 UTC |
| Validated block height | 67,878,838 |
| Validated block hash | `550c9202f0f15266c13f2de4f3c8bbbd7f4010a20f59cb9aa5aebee504da2385` |
| Compressed size | 25,313,829,142 bytes (23.58 GiB) |
| SHA-256 | `639b8ed83bad78795d3cc06c9f528e2e6ed604dd76b077ebdbd17b3477549320` |

- [Download the snapshot](https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/dogecoin/dogeos-dogecoin-testnet-20260908194510.tar.gz)
- [SHA-256 checksum](https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/dogecoin/dogeos-dogecoin-testnet-20260908194510.tar.gz.sha256)
- [Snapshot manifest](https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/dogecoin/dogeos-dogecoin-testnet-20260908194510.manifest.json)

The archive contains only:

```text
dogecoin/
└── testnet3/
    ├── blocks/       # Block/undo files and block/transaction index
    └── chainstate/   # UTXO database
```

It excludes wallets, wallet backups, RPC credentials, configuration, peer
identity/state, cookies, and application logs. Runtime configuration and RPC
credentials come from your local RPC package. This is not a wallet backup.

## Restore into a New Volume

Run these commands in Bash from the repository root, stopping on any error.
First prepare `.env.testnet` as described in [Quick Start](README.md#quick-start).
Preserve an existing local env file instead of overwriting it with a template.

**The destination `DOGECOIN_VOLUME_NAME` must not exist yet.** If recovering an
existing deployment, stop the stack using its current configuration first,
retain its original volume, and then change `DOGECOIN_VOLUME_NAME` in
`.env.testnet` to a new, unused name. This allows switching back to the old
volume if needed. Do not delete or clear the original volume.

### 1. Check the Destination and Download

This download happens on the operator's node during restoration. Snapshot
production itself runs entirely in AWS and streams directly to S3.

```bash
set -euo pipefail
set -a
. ./.env.testnet
set +a

test "$NETWORK" = testnet
: "${DOGECOIN_VOLUME_NAME:?Set a new Dogecoin volume name}"
: "${DATA_ROOT:?Set DATA_ROOT on the mounted data disk}"
case "$DATA_ROOT" in
  /*) ;;
  *) echo 'DATA_ROOT must be absolute' >&2; exit 1 ;;
esac
docker info >/dev/null
if docker volume inspect "$DOGECOIN_VOLUME_NAME" >/dev/null 2>&1; then
  echo 'Refusing to restore over an existing Dogecoin volume.' >&2
  echo 'Keep that volume; choose a new DOGECOIN_VOLUME_NAME if recovery is needed.' >&2
  exit 1
fi

SNAPSHOT_DIR="$DATA_ROOT/.snapshot-cache/dogecoin"
SNAPSHOT_FILE=dogeos-dogecoin-testnet-20260908194510.tar.gz
SNAPSHOT_SHA256=639b8ed83bad78795d3cc06c9f528e2e6ed604dd76b077ebdbd17b3477549320
mkdir -p "$SNAPSHOT_DIR"
curl --fail --location --retry 5 --continue-at - \
  --output "$SNAPSHOT_DIR/$SNAPSHOT_FILE" \
  "https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/dogecoin/$SNAPSHOT_FILE"
printf '%s  %s\n' "$SNAPSHOT_SHA256" "$SNAPSHOT_DIR/$SNAPSHOT_FILE" |
  sha256sum --check -
```

Verify the data disk is mounted before downloading. Also check the disk that
backs Docker's named volumes: `DATA_ROOT` controls the download cache, but it
does not move Docker volume storage. Allow room for the compressed download,
the extracted chain data, and continued chain growth. The snapshot manifest
records both compressed and uncompressed file sizes.

### 2. Extract the Verified Archive

Run this before starting Compose or the L2Reth restore helper, because those
commands can create/start the Dogecoin volume. The extraction container
refuses a non-empty destination. Do not run another restore or start the stack
concurrently.

```bash
# Recheck after the download in case another process created the volume.
if docker volume inspect "$DOGECOIN_VOLUME_NAME" >/dev/null 2>&1; then
  echo 'Destination volume now exists; stop and inspect it.' >&2
  exit 1
fi
docker volume create "$DOGECOIN_VOLUME_NAME"
docker run --rm --network none \
  --mount "type=volume,source=$DOGECOIN_VOLUME_NAME,target=/data" \
  --mount "type=bind,source=$SNAPSHOT_DIR,target=/snapshot,readonly" \
  -e SNAPSHOT_FILE="$SNAPSHOT_FILE" \
  alpine:3.20 sh -eu -c '
    test -z "$(ls -A /data)" || {
      echo "Refusing to overwrite non-empty Dogecoin data" >&2
      exit 1
    }
    tar -xzf "/snapshot/$SNAPSHOT_FILE" --strip-components=1 -C /data
    test -f /data/testnet3/blocks/index/CURRENT
    test -f /data/testnet3/chainstate/CURRENT
  '
```

Stripping the `dogecoin/` wrapper leaves `/data/testnet3/blocks` and
`/data/testnet3/chainstate`, matching the bundled node's `-datadir=/data` and
`testnet=1` settings. Use the checksum pinned above before extraction; do not
substitute an unverified archive or a mainnet snapshot.

If extraction fails, do not start the partially restored node. Preserve the
original volume and retry with another new destination after diagnosing the
failure. No automatic cleanup command in this guide deletes a volume.

### 3. Start and Verify

Initial block-index loading and chain-state checks can take more than ten
minutes. Startup can spend several minutes at `Rewinding blocks...` without
another log line. Keep the node running while it makes progress; `-rpcwait`
below waits for RPC warmup to finish.

Compose may warn that the volume was not created by Compose. This is expected
for the volume explicitly created and restored in step 2.

```bash
docker compose --env-file .env.testnet up -d dogecoin-node
docker compose --env-file .env.testnet logs --tail 100 dogecoin-node

docker compose --env-file .env.testnet exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -rpcwait -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockchaininfo

docker compose --env-file .env.testnet exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data getblockhash 67878838

docker compose --env-file .env.testnet exec -T dogecoin-node \
  /dogecoin/bin/dogecoin-cli -conf=/run/dogeos/dogecoin.conf \
  -datadir=/data verifychain 3 288
```

Check that `chain` is `test`, `pruned` is `false`, and the node loads the
snapshot's block history. The checkpoint hash should match the table above,
and `verifychain` should return `true`. Let it connect to peers and catch up, then confirm
`initialblockdownload` is `false` and its current block hash agrees with a
trusted testnet node. Avoid `-reindex` during an ordinary restore; the archive
includes the existing block and transaction indexes.

The full-stack configuration has wallet support enabled; because this archive
contains no wallet, Dogecoin can create a new local wallet on startup. Restore
your own wallet separately if you need one; a chain snapshot cannot recover
wallet keys.

After Dogecoin is ready, continue with [L2Reth restoration](snapshot_testnet.md#l2reth-snapshot-recommended)
or start the complete stack. Keep any previous Dogecoin volume until recovery
is accepted.

## How This Snapshot Was Produced

The source is the testnet Kubernetes Dogecoin PVC. Kubernetes `VolumeSnapshot`
and the EBS CSI driver created an encrypted EBS snapshot while the source node
continued running. A temporary AWS worker mounted a volume restored from that
snapshot; no file-level copy of the production data directory was made.

On the temporary volume, Dogecoin Core 1.14.9 ran with wallet access disabled
and networking disabled. Validation included loading the database with
`txindex=1`, `verifychain 3 288`, and retrieving an old transaction through the
transaction index. The node then shut down cleanly and the temporary volume
was remounted read-only. Only the allowed block/index and chainstate files
were streamed through `tar` and parallel gzip into S3 multipart upload.

The published S3 object was read back on the AWS worker to verify its complete
SHA-256, gzip integrity, and exact archive file list. Production did not use
the operator's local machine to store or relay the archive. The manifest records
validation results and the block checkpoint; the archive is a database snapshot, not a
substitute for independent full historical chain validation.

The published archive was also downloaded for a local restore test. Its pinned
checksum and the extraction commands above passed. The bundled Compose service
started with its default 20 GiB memory limit, using an isolated network and a new
volume, and returned the exact checkpoint above. `verifychain 3 288`, a transaction
lookup from block 1,000,000, and clean shutdown all passed without OOM. Separate
tests confirmed that an existing destination volume and a non-empty extraction
directory are refused without changing the existing data.
