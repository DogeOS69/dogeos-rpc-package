# Mainnet Configuration Status

Mainnet is not released. `docker compose --env-file .env.mainnet config` fails
until the missing files below are added, which keeps an incomplete mainnet
stack from starting.

| File | Status |
|------|--------|
| `compose.yml` | Present; images are placeholders until mainnet versions are chosen |
| `env.example` | Present |
| `dogecoin.conf` | Present |
| `l1-interface-bootstrap.env` | Present; empty, mainnet has no pre-v0.3.0 history |
| `l2reth.env` | Missing: peer list, network ID, blob archive URL, L1 endpoint |
| `l2reth-genesis.json` | Missing |
| `protocol_context.json` | Missing |
| `l1-interface.env` | Missing: generate for the mainnet L1 Interface version. It must not point at bootstrap data (`EVENT_PLANE_ARTIFACT_PATH`, `REPLAY_READ__*` bootstrap settings) |

Before release, also:

- Choose the mainnet images in `compose.yml` and review `L2RETH_NETWORK_ARGS`
  and the L1 Interface healthcheck for those versions.
- Publish `mainnet/index.json` in the snapshot bucket
  ([snapshot publishing](../../docs/snapshot-publishing.md)).
