# Mainnet Configuration Status

Mainnet is not released. This directory is self-contained and shares nothing
with testnet. `docker compose` here fails until the missing files below are
added, which keeps an incomplete mainnet stack from starting.

| File | Status |
|------|--------|
| `docker-compose.yml` | Present; images are placeholders until mainnet versions are chosen. Dogecoin data is in `${DATA_ROOT}/dogecoin`; internal ports default to `127.0.0.1`; there is no history bootstrap download |
| `env.example` | Present |
| `config/dogecoin.conf` | Present |
| `scripts/` | Present; copied from testnet. The L2Reth flags in `scripts/l2reth_entrypoint.sh` must be reviewed for the mainnet version |
| `config/l2reth.env` | Missing: peer list, network ID, blob archive URL, L1 endpoint |
| `config/l2reth-genesis.json` | Missing |
| `config/protocol_context.json` | Missing |
| `config/l1-interface.env` | Missing: generate for the mainnet L1 Interface version. It must not point at bootstrap data (`EVENT_PLANE_ARTIFACT_PATH`, `REPLAY_READ__*` bootstrap settings) |

Before release, also:

- Choose the mainnet images in `docker-compose.yml` and review the L2Reth flags
  in `scripts/l2reth_entrypoint.sh` and the L1 Interface healthcheck for those
  versions.
- Decide whether `config/l1-interface.env` ships a default Ethereum RPC or operators
  must set `DOGEOS_ETHEREUM_RPC_URL`.
- Publish `mainnet/index.json` in the snapshot bucket
  ([snapshot publishing](../docs/snapshot-publishing.md)).
