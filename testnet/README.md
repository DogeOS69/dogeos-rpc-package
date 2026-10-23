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
`l2reth-node` 16 GB, `l1-interface` 2 GB. Set `L2RETH_MEM_LIMIT` in `.env`
according to your machine's memory and RPC workload; 16 GB is a default cap,
not a reservation or a value suitable for every host. Leave memory for the
other services and the operating system. In particular, lower the limits on
a 32 GB host: the default service caps total 42 GB. Dogecoin and L1 Interface
limits are adjustable with `DOGECOIN_MEM_LIMIT` and `L1_INTERFACE_MEM_LIMIT`.
Swap is disabled, so a service that exceeds its limit can be OOM-killed.

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

Snapshots are published as groups with separate component archives. A group
may omit any component; it never silently borrows one from another group.
The catalog must use schema 2 (see [Snapshot Publishing](docs/snapshot-publishing.md)).

```bash
python3 scripts/snapshot-group.py list
python3 scripts/snapshot-group.py restore GROUP_ID --no-start
```

Choose an ID printed by `list`, or explicitly use `latest`. Existing nonempty
bind data requires `--force` and is backed up. A populated Dogecoin volume
cannot be replaced; use a group without a Dogecoin snapshot to retain it.
The helper checks archive checksums, fixed L1 layout, release identity and
image compatibility. See [Snapshots and Recovery](docs/snapshots.md).

### 4. Start Services

```bash
python3 scripts/snapshot-group.py start
```

For a fresh node this also works without any snapshots or catalog access.
The helper waits for Dogecoin initial sync, then L1 historical sync and replay
readiness, and verifies saved upstream checkpoints before starting L2Reth.
Missing L1 data uses the fixed testnet bootstrap. Missing L2 data syncs from
the package genesis and configured peers/L1/DA sources. Keep the foreground
startup session alive; sending RPC traffic should wait until L2 has caught up.

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
Compose configuration, documentation links); It also checks the fixed L1 data layout and runs offline snapshot/restore
tests. CI runs it on every pull request.
