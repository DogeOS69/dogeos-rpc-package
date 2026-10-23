# DogeOS RPC Package: Testnet

A Docker Compose deployment of the DogeOS testnet RPC stack for RPC providers
and node operators. It runs three services, each depending on the one before
it:

- **Dogecoin** — a Dogecoin Core node.
- **L1 Interface** — indexes Dogecoin and replays Ethereum DA data; L2Reth's
  L1 endpoint.
- **L2Reth** — syncs the DogeOS L2 chain and serves Ethereum-compatible RPC.

This directory is self-contained and shares nothing with mainnet. **Run every
command in this directory.** Your settings live in one file, `.env`, created
from `env.example`; Docker Compose and the scripts read it automatically.

## Components

| Service | Image | Source |
|---------|-------|--------|
| `dogecoin-node` | `dogeos69/dogecoin:1.14.9` | Dogecoin Core 1.14.9 |
| `l1-interface` | `dogeos69/l1-interface:v0.3.0-beta.3d` | DogeOS L1 Interface v0.3.0-beta.3d |
| `l2reth-node` | `dogeos69/rollup-node:v0.3.0-beta.1c` | DogeOS69/dogeos-rollup-node `d3260afe` |

Service behavior described in this documentation (health endpoints, startup
ordering, L1 reorg handling) was checked against these versions.

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Services, images, ports, data layout, and the one-time download of the pre-v0.3.0 testnet history for L1 Interface |
| `env.example` | Template for your `.env` |
| `config/` | Chain and service configuration, maintained by the package: `dogecoin.conf`, `l2reth-genesis.json`, `protocol_context.json`, `l2reth.env` (peers, P2P network ID, L1 endpoint, blob archive), `l1-interface.env` |
| `scripts/` | Service entrypoints (including the L2Reth flags for this version), `restore-snapshot.sh`, `reset-chain-data.sh`, `add-l2reth-peer.sh`, `check.sh` |
| `docs/` | Operations, snapshots and recovery, snapshot publishing, history |
| `CHANGELOG.md` | What changed and what operators must do |

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 32 GB | 64 GB |
| CPU | 4 cores | 8 cores |
| Disk | 300 GB SSD | 500 GB NVMe SSD |

Default memory limits are tuned for a 64 GB host: `dogecoin-node` 24 GB,
`l2reth-node` 8 GB, `l1-interface` 2 GB. Adjust them in `.env` with
`DOGECOIN_MEM_LIMIT`, `L2RETH_MEM_LIMIT`, and `L1_INTERFACE_MEM_LIMIT`. Swap is
disabled, so a service that exceeds its limit can be OOM-killed.

Docker Compose 2.24 or later is required.

## Quick Start

These steps set up a new testnet node.

### 1. Configure `.env`

```bash
cd testnet
if [ ! -e .env ]; then cp env.example .env; fi
# REQUIRED: set DATA_ROOT; optional settings are listed, commented out
chmod 600 .env
```

Set `DATA_ROOT` to an absolute path on your mounted data disk, outside the
repository, and check the mount (for example `findmnt -T /data`); otherwise
chain data can fill the root disk.

The Compose project name and Dogecoin volume name default to those of earlier
releases (`dogeos-rpc-package`, `dogeos-rpc-package_dogecoin_data`), and the
template keeps the earlier public RPC credentials (`doge`/`password`). Never
expose the Dogecoin RPC port to an untrusted network with these credentials;
setting `INTERNAL_BIND_ADDR=127.0.0.1` keeps it on this host.

### 2. Check the Ethereum RPC

Testnet uses `https://ethereum-sepolia-rpc.publicnode.com` by default. To use
another provider, see [Custom Ethereum RPC](docs/operations.md#custom-ethereum-rpc).

### 3. Restore Snapshots (Recommended for New Nodes)

Snapshots are published to S3. Restore Dogecoin first, then L2Reth, without
starting services yet:

```bash
./scripts/restore-snapshot.sh --list
./scripts/restore-snapshot.sh --no-start dogecoin
./scripts/restore-snapshot.sh --no-start l2reth
```

Skip the Dogecoin restore for a node that already has Dogecoin data. The
script verifies each archive and picks the newest snapshot compatible with the
images in `docker-compose.yml`. See [Snapshots and Recovery](docs/snapshots.md).

### 4. Start Services

```bash
docker compose up -d
```

On first start, L1 Interface downloads the testnet history bootstrap data and
catches up before serving L2Reth. Let Dogecoin load its block index and all
services finish syncing before sending RPC traffic.

### 5. Verify Services

```bash
docker compose ps -a
curl --fail http://localhost:9090/health
```

L1 Interface reports `"status":"ready"` when its startup sync is complete;
`"historical_sync":"in_progress"` means it is still catching up. A running
container does not mean syncing has finished. Then check that L2Reth's block
height advances between two queries (HTTP port `8545` by default):

```bash
curl --fail \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

Before serving traffic, review [Network Security](docs/operations.md#network-security).

## Upgrading

Follow the [changelog](CHANGELOG.md): each entry states the commands to run.
Keep your `.env`, project name, Dogecoin volume, and RPC credentials. Nodes set
up before the per-network directories (with `.env.testnet` in the repository
root) move once, as the changelog describes. Nodes still on the v0.2.x package
start with the archived [v0.3.0 upgrade guide](docs/history/upgrade-v0.3.0.md).

## Documentation

- [Operations](docs/operations.md) — configuration, security, endpoints,
  maintenance, troubleshooting, data storage
- [Snapshots and Recovery](docs/snapshots.md) — restoring snapshots, resetting
  and recovering data
- [Snapshot Publishing](docs/snapshot-publishing.md) — index format and
  publishing process (for the team that publishes snapshots)
- [Changelog](CHANGELOG.md)

Changes to this directory should pass `./scripts/check.sh` (shellcheck,
Compose configuration, documentation links); CI runs it on every pull request.
