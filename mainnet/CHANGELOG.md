# Mainnet Changelog

Each entry states what mainnet operators must do. Testnet has its own
changelog in `testnet/`.

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
After mainnet is released, apply this entrypoint change during a maintenance window:

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
paths, archive structure, and SQLite integrity before stopping services. Old custom database-path overrides are rejected;
reconcile such deployments before upgrading. Components can be published
independently; service images remain pinned by Compose. See
[Snapshots and Recovery](docs/snapshots.md#l1-interface) for snapshot and
no-snapshot initialization paths.

L2Reth now defaults to a 16 GB memory cap (`L2RETH_MEM_LIMIT=16g`). Review
this setting in `.env` for your host's memory and RPC workload, leaving room
for the other services and the OS. An existing explicit override is preserved.
After mainnet is released, apply limit changes with
`python3 scripts/snapshot-group.py start` during a maintenance window.
This applies changed limits and stops L1/L2 while upstream checks run.

Mainnet is not released; see [README.md](README.md) for what is still
missing. The prepared layout:

- Self-contained `mainnet/` directory with its own `docker-compose.yml`,
  configuration, scripts, documentation, and env template; nothing is shared
  with testnet.
- One settings file, `mainnet/.env`, created from `env.example`.
- All service data under `DATA_ROOT`, including Dogecoin in
  `${DATA_ROOT}/dogecoin`.
- Dogecoin RPC and L1 Interface ports published on `127.0.0.1` by default;
  Dogecoin wallet disabled; an explicit RPC password is required.
- Dogecoin memory: 8 GB limit and 4 GB reservation by default (testnet uses
  24 GB), sized for mainnet's block count.
- No pre-v0.3.0 history bootstrap download.
- Snapshot restore through `scripts/snapshot-group.py restore GROUP_ID --no-start`
  from the schema-2 `mainnet/index.json` catalog, once published; then use
  `scripts/snapshot-group.py start`. The component script is reserved for
  internal restore and explicit legacy/direct-archive workflows.
