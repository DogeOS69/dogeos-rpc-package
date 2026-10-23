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
- Publish `mainnet/index.json` in the snapshot bucket
  ([snapshot publishing](docs/snapshot-publishing.md)).

## Usage After Release

Run every command in this directory. Your settings live in one file, `.env`,
created from `env.example`:

```bash
cd mainnet
if [ ! -e .env ]; then cp env.example .env; fi
# REQUIRED: set DATA_ROOT and DOGECOIN_RPC_PASSWORD
chmod 600 .env
./scripts/restore-snapshot.sh --no-start dogecoin
./scripts/restore-snapshot.sh --no-start l2reth
docker compose up -d
```

Compared with testnet:

- Dogecoin needs far less memory: the default limit is 8 GB instead of 24 GB.
  Dogecoin Core keeps every block's index entry in memory, and mainnet has
  about a tenth of testnet's blocks.
- Dogecoin data lives in `${DATA_ROOT}/dogecoin`.
- The Dogecoin RPC and L1 Interface ports are published on `127.0.0.1` by
  default, and the RPC password has no default.
- Default host ports differ: L2Reth HTTP `18545`, WebSocket `18546`, P2P
  `40303`; Dogecoin P2P `22556`, RPC `22555`.

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
CI runs it on every pull request.
