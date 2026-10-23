# Testnet

Testnet is the supported network in this release. This directory is
self-contained: run every command here, with your settings in `.env` (created
from `env.example`). See the [Quick Start](../README.md#quick-start).

## Components

| Service | Image | Source |
|---------|-------|--------|
| `dogecoin-node` | `dogeos69/dogecoin:1.14.9` | Dogecoin Core 1.14.9 |
| `l1-interface` | `dogeos69/l1-interface:v0.3.0-beta.3d` | DogeOS L1 Interface v0.3.0-beta.3d |
| `l2reth-node` | `dogeos69/rollup-node:v0.3.0-beta.1c` | DogeOS69/dogeos-rollup-node `d3260afe` |

Images and all service settings are defined in [docker-compose.yml](docker-compose.yml).
Service behavior described in the documentation (health endpoints, startup
ordering, L1 reorg handling) was checked against these versions.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Services, images, ports, data layout, and the one-time download of the pre-v0.3.0 testnet history for L1 Interface |
| `env.example` | Template for your `.env` |
| `config/dogecoin.conf` | Dogecoin Core settings (RPC credentials come from `.env`) |
| `config/l2reth-genesis.json`, `config/protocol_context.json` | Chain configuration |
| `config/l2reth.env` | L2Reth peers, P2P network ID, L1 endpoint, blob archive |
| `config/l1-interface.env` | L1 Interface settings |
| `scripts/` | Service entrypoints (including the L2Reth flags for this version), `restore-snapshot.sh`, `reset-chain-data.sh`, `add-l2reth-peer.sh` |

## Defaults

- Compose project `dogeos-rpc-package` and Dogecoin volume
  `dogeos-rpc-package_dogecoin_data`, as in earlier releases. Existing nodes
  keep their actual names.
- Dogecoin data in the Docker volume `DOGECOIN_VOLUME_NAME`.
- Dogecoin P2P `44556`, RPC `44555`; L2Reth HTTP `8545`, WebSocket `8546`,
  P2P `30303`, metrics `6060`.
- Internal ports are published on all interfaces unless `INTERNAL_BIND_ADDR`
  is set.
- Ethereum DA reads the public Sepolia RPC and the public S3 blob archive.

## Upgrading

Follow the [changelog](../CHANGELOG.md) for each update. Nodes still on the
v0.2.x package first follow the archived
[v0.3.0 upgrade guide](../docs/testnet/history/upgrade-v0.3.0.md).
