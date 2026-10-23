# Mainnet Changelog

Each entry states what mainnet operators must do. Testnet has its own
changelog in `testnet/`.

## Unreleased

L2Reth now waits for L1 RPC availability and HTTP 200 from
`/api/v1/health/ready` on every start, including daemon restarts. If using a
custom L1 endpoint, also set `L2RETH_L1_READY_URL` in `config/l2reth.env`.
After mainnet is released, restart an existing L2Reth container with
`docker compose up -d --force-recreate l2reth-node` to apply this startup check;
this briefly interrupts L2 RPC.

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
`docker compose up -d l2reth-node` in this network directory. This recreates
L2Reth when its limit changes and briefly interrupts L2 RPC.

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
- Snapshot restore through `scripts/restore-snapshot.sh` from the
  `mainnet/index.json` index, once published.
