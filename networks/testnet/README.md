# Testnet

Testnet is the supported network in this release.

## Components

| Service | Image | Source |
|---------|-------|--------|
| `dogecoin-node` | `dogeos69/dogecoin:1.14.9` | Dogecoin Core 1.14.9 |
| `l1-interface` | `dogeos69/l1-interface:v0.3.0-beta.3d` | DogeOS69/dogeos-core `413c5fc8` |
| `l2reth-node` | `dogeos69/rollup-node:v0.3.0-beta.1c` | DogeOS69/dogeos-rollup-node `d3260afe` |

Images and version-specific settings are defined in [compose.yml](compose.yml).
Service behavior described in the documentation (health endpoints, startup
ordering, L1 reorg handling) was checked against these revisions.

## Files

| File | Purpose |
|------|---------|
| `compose.yml` | Images, version-specific L2Reth flags, L1 Interface healthcheck |
| `env.example` | Template for your `.env.testnet` |
| `dogecoin.conf` | Dogecoin Core settings (RPC credentials come from `.env.testnet`) |
| `l2reth-genesis.json`, `protocol_context.json` | Chain configuration |
| `l2reth.env` | L2Reth peers, P2P network ID, L1 endpoint, blob archive |
| `l1-interface.env` | L1 Interface settings |
| `l1-interface-bootstrap.env` | One-time bootstrap of the pre-v0.3.0 testnet history |
| `l1-interface.local.env.example` | Template for optional operator overrides |

## Defaults

- Compose project `dogeos-rpc-package` and Dogecoin volume
  `dogeos-rpc-package_dogecoin_data`, as in earlier releases. Existing nodes
  keep their actual names.
- Dogecoin P2P `44556`, RPC `44555`; L2Reth HTTP `8545`, WebSocket `8546`,
  P2P `30303`.
- Internal ports are published on all interfaces unless `INTERNAL_BIND_ADDR`
  is set.
- Ethereum DA reads the public Sepolia RPC and the public S3 blob archive.

## Upgrading

Follow the [changelog](../../CHANGELOG.md) for each update. Nodes still on the
v0.2.x package first follow the archived
[v0.3.0 upgrade guide](../../docs/testnet/history/upgrade-v0.3.0.md).
