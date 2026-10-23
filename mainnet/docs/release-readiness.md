# Mainnet Release Readiness

Maintainer checklist. Mainnet is not released; these are release prerequisites,
not instructions for operators to fill in arbitrary values.

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

- Publish the mainnet reference RPC for operator acceptance checks and set
  its default in `scripts/verify-rpc.py`; no address is configured yet.

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
  [Fixed Data Layout](snapshots.md#fixed-data-layout).
- Publish a schema-2 `mainnet/index.json` and immutable group manifests in the snapshot bucket
  ([snapshot publishing](snapshot-publishing.md)).
