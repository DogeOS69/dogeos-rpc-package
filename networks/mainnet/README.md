# Mainnet Configuration Status

Mainnet is not released. With `NETWORK=mainnet` in `.env`, `docker compose`
fails until the missing files below are added, which keeps an incomplete
mainnet stack from starting.

| File | Status |
|------|--------|
| `compose.yml` | Present; images are placeholders until mainnet versions are chosen. Dogecoin data is in `${DATA_ROOT}/dogecoin`; internal ports default to `127.0.0.1` |
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
- Decide whether `l1-interface.env` ships a default Ethereum RPC or operators
  must set `DOGEOS_ETHEREUM_RPC_URL`.
- Publish `mainnet/index.json` in the snapshot bucket
  ([snapshot publishing](../../docs/snapshot-publishing.md)).
