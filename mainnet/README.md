# DogeOS RPC Package: Mainnet

**Mainnet is not released.** This directory holds the mainnet stack as far as
it is prepared. It is self-contained and shares nothing with testnet: its own
`docker-compose.yml`, configuration, scripts, documentation, and changelog.
`docker compose` here fails until the missing files below are added, which
keeps an incomplete mainnet stack from starting.

## Release Status

| File | Status |
|------|--------|
| `docker-compose.yml` | Present; images are placeholders until mainnet versions are chosen. Dogecoin data is in `${DATA_ROOT}/dogecoin`; internal ports default to `127.0.0.1`; there is no history bootstrap download |
| `env.example` | Present |
| `config/dogecoin.conf` | Present (wallet disabled) |
| `scripts/` | Present; copied from testnet. The L2Reth flags in `scripts/l2reth_entrypoint.sh` must be reviewed for the mainnet version |
| `docs/` | Present |
| `config/l2reth.env` | Missing: peer list, network ID, blob archive URL, L1 endpoint |
| `config/l2reth-genesis.json` | Missing |
| `config/protocol_context.json` | Missing |
| `config/l1-interface.env` | Missing: generate for the mainnet L1 Interface version. It must not point at bootstrap data (`EVENT_PLANE_ARTIFACT_PATH`, `REPLAY_READ__*` bootstrap settings) |

Before release, also:

- Choose the mainnet images in `docker-compose.yml` and review the L2Reth flags
  in `scripts/l2reth_entrypoint.sh` and the L1 Interface healthcheck for those
  versions.
- Decide whether `config/l1-interface.env` ships a default Ethereum RPC or
  operators must set `DOGEOS_ETHEREUM_RPC_URL`.
- Publish a bootnode for `scripts/add-l2reth-peer.sh`, which has no default
  enode yet.
- Define and test L1 Interface startup without a runtime snapshot: select a
  mainnet image supporting explicit fresh-genesis replay initialization, or
  supply a validated genesis seed DB. The current `v0.3.0-beta.3d` placeholder
  requires an existing replay DB. Never reuse testnet bootstrap data.
- Keep L1 Interface paths fixed at `/data/l1-interface.sqlite`,
  `/data/replay.sqlite`, and `/data/replay.artifacts/`; see
  [Fixed Data Layout](docs/snapshots.md#fixed-data-layout).
- Publish `mainnet/index.json` in the snapshot bucket
  ([snapshot publishing](docs/snapshot-publishing.md)).

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 16 GB | 32 GB |
| CPU | 4 cores | 8 cores |
| Disk | 500 GB SSD | 1 TB NVMe SSD |

Memory per service (`docker-compose.yml` defaults, adjustable in `.env`):

| Service | Typical use | Limit | Notes |
|---------|-------------|-------|-------|
| `dogecoin-node` | about 3–4 GB (4 GB reserved) | 8 GB | Block index for every block (~1.6 GB at 6.5M blocks), dbcache 450 MB, mempool up to 300 MB; the limit covers startup and catch-up peaks |
| `l2reth-node` | grows with RPC traffic | 16 GB | Set `L2RETH_MEM_LIMIT` in `.env` to suit your machine and RPC workload; tracing calls use the most |
| `l1-interface` | small; more during startup | 2 GB | |

Set `L2RETH_MEM_LIMIT` in `.env` according to your machine's available memory
and RPC workload. The 16 GB default is a cap, not a reservation. Leave memory
for Dogecoin, L1 Interface, the operating system, and other services. On a
16 GB host, lower the limits before starting: the default service caps total
26 GB. A service that exceeds its limit can be OOM-killed (swap is disabled).

Disk: the Dogecoin mainnet chain alone is about 170 GiB of blocks (October
2026), roughly 200–250 GB with undo data, chain state, and the transaction
index, and it keeps growing. L2Reth and L1 Interface data start small. A
snapshot restore needs room for the downloaded archive and the extracted data
at the same time. Keep `DATA_ROOT` on an SSD.

## Usage After Release

Run every command in this directory. Your settings live in one file, `.env`,
created from `env.example`:

```bash
cd mainnet
if [ ! -e .env ]; then cp env.example .env; fi
# REQUIRED: set DATA_ROOT and DOGECOIN_RPC_PASSWORD
chmod 600 .env
./scripts/restore-snapshot.sh --list
./scripts/restore-snapshot.sh --no-start dogecoin
# If --list shows a compatible L1 Interface snapshot:
./scripts/restore-snapshot.sh --no-start l1-interface
./scripts/restore-snapshot.sh --no-start l2reth
docker compose up -d
```

L1 snapshot restore requires Python 3 with SQLite support. If no compatible
L1 snapshot exists, use the mainnet genesis initialization procedure selected
at release; that procedure is not available in the current placeholder stack.
See [Snapshots and Recovery](docs/snapshots.md#l1-interface) for fixed data
paths and staged startup checks when combining snapshots.

Compared with testnet:

- Dogecoin needs far less memory: the default limit is 8 GB instead of 24 GB.
  Dogecoin Core keeps every block's index entry in memory, and mainnet has
  about a tenth of testnet's blocks.
- Dogecoin data lives in `${DATA_ROOT}/dogecoin`.
- The Dogecoin RPC and L1 Interface ports are published on `127.0.0.1` by
  default, and the RPC password has no default.
- Default host ports: L2Reth HTTP `8545`, WebSocket `8546`, P2P
  `30303`; Dogecoin P2P `22556`, RPC `22555`.
- Mainnet and testnet are intended to run on separate hosts. If you run both
  on one host, configure host ports yourself to avoid conflicts.

## Documentation

- [Operations](docs/operations.md) — configuration, security, endpoints,
  maintenance, troubleshooting, data storage
- [Snapshots and Recovery](docs/snapshots.md) — restoring snapshots, resetting
  and recovering data
- [Snapshot Publishing](docs/snapshot-publishing.md) — index format and
  publishing process (for the team that publishes snapshots)
- [Changelog](CHANGELOG.md)

Changes to this directory should pass `./scripts/check.sh` (shellcheck,
Compose configuration with the missing files stubbed, documentation links);
It also checks the fixed L1 data layout and runs offline snapshot/restore
tests. CI runs it on every pull request.
