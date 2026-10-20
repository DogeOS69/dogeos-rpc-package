# Dogecoin Testnet Snapshot

This snapshot is for a **new testnet Dogecoin node** or recovery into a **new
Docker volume**. An existing, healthy node should keep its current volume and
continue syncing. The [v0.3.0 upgrade procedure](upgrade_v0.3.0.md) does not
require restoring or replacing Dogecoin data.

## Published Snapshots

Snapshots are published to S3 and listed in the testnet snapshot index. Check
the newest one, its block height, and its size with:

```bash
./scripts/restore-snapshot.sh --list .env.testnet
```

Each Dogecoin snapshot has a manifest, whose URL the restore script prints when
it selects the snapshot. The manifest records the checkpoint height and hash,
the Dogecoin Core version, and the validation performed before publishing. Archives are taken from Dogecoin Core
with `txindex=1`, unpruned, and contain only:

```text
dogecoin/
└── testnet3/
    ├── blocks/       # Block/undo files and block/transaction index
    └── chainstate/   # UTXO database
```

They exclude wallets, wallet backups, RPC credentials, configuration, peer
identity/state, cookies, and application logs. Runtime configuration and RPC
credentials come from your local RPC package. This is not a wallet backup.

## Restore into a New Volume

First prepare `.env.testnet` as described in [Quick Start](README.md#quick-start).
Preserve an existing local env file instead of overwriting it with a template.

**The destination `DOGECOIN_VOLUME_NAME` must not exist yet.** For a new
installation, the template's name is unused. If recovering an existing
deployment, stop the stack first, keep its original volume, and change
`DOGECOIN_VOLUME_NAME` in `.env.testnet` to a new, unused name. This allows
switching back to the old volume if needed. Do not delete or clear the original
volume.

```bash
./scripts/restore-snapshot.sh --no-start dogecoin .env.testnet
```

The script:

1. Selects the newest snapshot compatible with the Dogecoin image in
   `docker-compose.yml` (or the one given with `--snapshot-id`).
2. Downloads or resumes the archive under `${DATA_ROOT}/.snapshot-cache/dogecoin`
   and verifies its SHA-256.
3. Rejects unsafe paths and any wallet, configuration, cookie, or peer-state
   file in the archive.
4. Creates the Docker volume, refusing one that already exists, and extracts
   `testnet3/` into it.

`DATA_ROOT` holds the download cache, but the extracted data goes to Docker's
volume storage. Make sure the disk that backs Docker's data root has room for
the extracted chain data and continued growth.

If extraction fails, the script stops and names the partial volume. Do not
start the node on it; remove that new volume and retry after diagnosing the
failure.

## Start and Verify

Initial block-index loading and chain-state checks can take more than ten
minutes. Startup can spend several minutes at `Rewinding blocks...` without
another log line. Keep the node running while it makes progress; `-rpcwait`
below waits for RPC warmup to finish.

The restored volume replaces the one an existing container used, so recreate
`dogecoin-node`:

```bash
docker compose --env-file .env.testnet up -d --force-recreate dogecoin-node
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

Check that `chain` is `test`, `pruned` is `false`, and the node loads the
snapshot's block history. The block hash should match the manifest's
checkpoint hash, and `verifychain` should return `true`. Let it connect to
peers and catch up, then confirm `initialblockdownload` is `false` and its
current block hash agrees with a trusted testnet node. Avoid `-reindex` during
an ordinary restore; the archive includes the existing block and transaction
indexes.

The testnet configuration has wallet support enabled; because this archive
contains no wallet, Dogecoin can create a new local wallet on startup. Restore
your own wallet separately if you need one; a chain snapshot cannot recover
wallet keys.

After Dogecoin is ready, continue with [L2Reth restoration](snapshot_testnet.md#l2reth-snapshot-recommended)
or start the complete stack. Keep any previous Dogecoin volume until recovery
is accepted.
