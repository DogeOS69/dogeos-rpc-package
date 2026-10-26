# Testnet Changelog

Each entry states what testnet operators must do. Mainnet has its own
changelog in `mainnet/`.

## Unreleased

L2Reth now requires an independent persistent P2P key. **Before the first
restart, snapshot restore or reset after this upgrade**, run
`python3 scripts/p2p-identity.py init` with the existing data still present.
It copies the old `l2reth/discovery-secret` when available, preserving the node
ID. Custom identities can be imported with `--import-key`; existing destination
keys are never overwritten. See [P2P Identity](docs/p2p-identity.md) for migration,
secure backup and the public JSON to send to operations for IP/key allowlisting.
`L2_P2P_PORT` now sets both the host and container TCP/UDP ports. P2P identity,
NAT and port overrides in `L2RETH_EXTRA_ARGS` must move to the dedicated settings.
Snapshots must exclude `discovery-secret` and all other node identity files.

The deployment guide now separates fresh sync, grouped restore, startup progress
and RPC verification. `snapshot-group.py list` fetches pinned manifests and
shows components, heights, sizes and compatible images. With `.env` present
(or `--env-file`), it checks local identity/image/upstream compatibility without
starting services or downloading archives; otherwise it reports `NOT CHECKED`.

Snapshot groups now use a schema-2 catalog and immutable manifests with explicit
missing components, archive checksums, release identity and dependency
checkpoints. Use `python3 scripts/snapshot-group.py list`, then `restore GROUP_ID`.
Publish a schema-2 catalog before using these commands; older component
catalogs require the legacy script and an explicit legacy index URL.

Use `python3 scripts/snapshot-group.py start` for cold startup and recovery.
It waits for Dogecoin initial sync, L1 startup/replay readiness, and recorded
checkpoint hashes before starting downstream services. Group restores keep an
interruption journal and require the same group on retry. Direct component
restore/reset refuses grouped data. L2Reth archive checks now reject forbidden
subtrees even when tar directory headers are absent, plus links and duplicate
members. See [Snapshots and Recovery](docs/snapshots.md).

L2Reth now waits for L1 RPC availability and HTTP 200 from
`/api/v1/health/ready` on every start, including daemon restarts. If using a
custom L1 endpoint, also set `L2RETH_L1_READY_URL` in `config/l2reth.env`.
Apply this entrypoint change during a maintenance window:

```bash
docker compose stop l2reth-node l1-interface dogecoin-node
docker compose create --force-recreate l2reth-node
python3 scripts/snapshot-group.py start
```

`create` refreshes the container without starting it; the helper then performs
upstream checks. L2 RPC remains unavailable until startup and catch-up finish.

L1 Interface snapshots now require the complete fixed `/data` layout: both
service databases, `replay.artifacts/` (including its DA metadata DB and file
directory), and the historical artifact when configured. Restore validates
paths, archive structure, SQLite integrity, and the testnet historical checksum
before stopping services. Old custom database-path overrides are rejected;
reconcile such deployments before upgrading. Components can be published
independently; service images remain pinned by Compose. See
[Snapshots and Recovery](docs/snapshots.md#l1-interface) for snapshot and
no-snapshot initialization paths.

L2Reth now defaults to a 16 GB memory cap (`L2RETH_MEM_LIMIT=16g`). Review
this setting in `.env` for your host's memory and RPC workload, leaving room
for the other services and the OS. An existing explicit override is preserved.
Apply it with `python3 scripts/snapshot-group.py start` during a maintenance
window. This applies changed limits and stops L1/L2 while upstream checks run.

### Testnet: what to do

Testnet now lives in the `testnet/` directory and runs from there. Move your
settings file once; the containers, the Dogecoin volume, `DATA_ROOT`, and the
RPC credentials stay the same, and no data is migrated:

```bash
git pull
mv .env.testnet testnet/.env
cd testnet
python3 scripts/snapshot-group.py start
```

Run all later commands inside `testnet/`. **Update anything that runs Compose
from the repository root** — cron jobs, systemd units, deploy or monitoring
scripts: after the pull, `docker compose --env-file .env.testnet ...` there
fails with "no configuration file provided". Change them to run in `testnet/`
without `--env-file`. Startup jobs should run
`cd /path/to/repo/testnet && python3 scripts/snapshot-group.py start`, allowing
the foreground process enough time to finish upstream synchronization. Do not
schedule it as a periodic health check: it stops L1/L2 on every invocation.

Compose recognizes the existing
containers (same project name) and recreates them once for the new log
rotation, restart policy, configuration file locations, and healthcheck.
Chain data is kept. Dogecoin reloads its block index, which takes several
minutes or longer; the helper waits before starting L1 and L2. L2 RPC is
unavailable throughout this maintenance and any subsequent catch-up. Verify with [Verify Services](README.md#5-verify-services).

A `.env` in the repository root left by a pre-v0.3.0 release is no longer used
and can be removed.

Recommended follow-ups:

- **Move overrides into `testnet/.env`.** If you have
  `envs/testnet/l1-interface.local.env`, move its values to `testnet/.env` and
  delete it; the file is still read but deprecated:

  | Old setting in `l1-interface.local.env` | New setting in `.env` |
  |-----------------------------------------|-----------------------|
  | `DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` | `DOGEOS_ETHEREUM_RPC_URL` |
  | `DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL` | `DOGEOS_EXTERNAL_DOGECOIN_RPC_URL` |
  | `DOGEOS_L1_INTERFACE_DOGECOIN_RPC__USER` | `DOGEOS_EXTERNAL_DOGECOIN_RPC_USER` |
  | `DOGEOS_L1_INTERFACE_DOGECOIN_RPC__PASS` | `DOGEOS_EXTERNAL_DOGECOIN_RPC_PASSWORD` |

- Set `INTERNAL_BIND_ADDR=127.0.0.1` unless another host needs the Dogecoin
  RPC or L1 Interface ports.
- Restore a selected group with `python3 scripts/snapshot-group.py restore GROUP_ID --no-start`,
  then run `python3 scripts/snapshot-group.py start`. The component script
  `restore-snapshot.sh` is only for the explicit legacy/direct-archive workflows
  in [Snapshots and Recovery](docs/snapshots.md#legacy-component-restore);
  `scripts/restore-l2reth-snapshot.sh` is gone.
- Documentation and the changelog are now in `testnet/` as well; the root
  directory only has a short README.

### Changes

- **Self-contained networks.** `testnet/` and `mainnet/` each have their own
  `docker-compose.yml`, configuration, scripts, documentation, changelog, and
  env template, and share nothing, so they can run different versions and
  change independently. The root `docker-compose.yml`, `configs/`, `envs/`,
  `scripts/`, and `docs/` are gone. Only testnet has the one-time L1 Interface
  history download.
- **One settings file per network.** Operator settings live in `.env` in the
  network directory, which Compose and the scripts read by default. Overrides
  formerly in `l1-interface.local.env` are `.env` settings, defaults are in
  `docker-compose.yml`, and the Dogecoin RPC host port no longer has to match
  `dogecoin.conf`. `DOGECOIN_P2P_PORT` is no longer used: P2P stays on the
  port Dogecoin advertises. `NETWORK` is no longer needed.
- **Snapshots.** `scripts/snapshot-group.py` selects one schema-2 group, pins
  its component archives, checks compatibility and restores with dependency
  checkpoints. Use it for current deployments. The component script remains
  an internal restore mechanism and a documented legacy recovery tool.
- **L2Reth RPC options** for RPC providers: `L2RETH_HTTP_API`,
  `L2RETH_WS_API`, and `L2RETH_EXTRA_ARGS`; Prometheus metrics on
  `127.0.0.1:${L2_METRICS_PORT}` (default `6060`).
- **Stability.** Log rotation for every container (`LOG_MAX_SIZE`,
  `LOG_MAX_FILE`); `l2reth-node` restarts `unless-stopped`, which the
  signer-rotation exit (code 70) relies on; an `l1-interface` healthcheck on
  `/api/v1/health/ready`.
- **Internal ports** follow `INTERNAL_BIND_ADDR` (unset on testnet, keeping the
  previous behavior).
- **Cleanup.** Removed Celestia and L2Geth leftovers, unused env files, the
  unused `L2RETH_VALID_SIGNER`, and unnecessary permission changes in the L1
  Interface bootstrap. The peer list is now `L2RETH_PEER_LIST`
  (`L2GETH_PEER_LIST` is still accepted).

The entries below predate the `testnet/` directory: their commands run in the
repository root with `--env-file .env.testnet`. These are historical release instructions, not the current startup/recovery
procedure. On the current layout use the Unreleased instructions above and
[Snapshots and Recovery](docs/snapshots.md).

## Testnet: L2Reth v0.3.0-beta.1c (Galileo, Galileo V2, and Tsuki)

For existing v0.3.0 testnet deployments.

- L2Reth image `dogeos69/rollup-node:0.3.0-beta.0` → `v0.3.0-beta.1c`.
- `galileoTime`, `galileoV2Time`, and `tsukiTime` fork activation settings
  added to the testnet L2Reth genesis.

Only L2Reth is recreated; data is kept and no resync is needed. After updating
the checkout:

```bash
docker compose --env-file .env.testnet pull l2reth-node
docker compose --env-file .env.testnet up -d --no-deps --force-recreate l2reth-node
```

`docker compose restart` alone does not apply a new image. Confirm that
`eth_blockNumber` advances afterwards.

## Testnet: v0.3.0

Moved Data Availability from Celestia to Ethereum, made L2Reth the only L2
client, and changed the L1 Interface storage format. Nodes on v0.2.x follow the
archived [v0.3.0 upgrade guide](docs/history/upgrade-v0.3.0.md).
