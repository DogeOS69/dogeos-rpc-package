# Changelog

Each entry states which network it affects and what operators must do.
Mainnet is not released yet.

## Unreleased

### Testnet: what to do

Testnet now lives in the `testnet/` directory and runs from there. Move your
settings file once; the containers, the Dogecoin volume, `DATA_ROOT`, and the
RPC credentials stay the same, and no data is migrated:

```bash
git pull
mv .env.testnet testnet/.env
cd testnet
docker compose up -d
```

Run all later commands inside `testnet/`. Compose recognizes the existing
containers (same project name) and recreates them once for the new log
rotation, restart policy, configuration file locations, and healthcheck.
Chain data is kept. Dogecoin reloads its block index, which takes several
minutes; L1 Interface retries until it is ready, and L2 RPC is briefly
unavailable. Verify with [Verify Services](README.md#5-verify-services).

A `.env` in the repository root left by a pre-v0.3.0 release is no longer used
and can be removed.

Recommended follow-ups:

- **Move overrides into `testnet/.env`.** If you have
  `envs/testnet/l1-interface.local.env`, move its values to `testnet/.env` and
  delete it; the file is still read but deprecated:

  | Old setting in `l1-interface.local.env` | New setting in `.env` |
  |-----------------------------------------|-----------------------|
  | `DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` | `DOGEOS_ETHEREUM_RPC_URL` |
  | `DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL` | `DOGEOS_EXTERNAL_DOGECOIN_RPC_URL` |
  | `DOGEOS_L1_INTERFACE_DOGECOIN_RPC__USER` | `DOGEOS_EXTERNAL_DOGECOIN_RPC_USER` |
  | `DOGEOS_L1_INTERFACE_DOGECOIN_RPC__PASS` | `DOGEOS_EXTERNAL_DOGECOIN_RPC_PASSWORD` |

- Set `INTERNAL_BIND_ADDR=127.0.0.1` unless another host needs the Dogecoin
  RPC or L1 Interface ports.
- Snapshots are restored with `./scripts/restore-snapshot.sh <component>`
  inside `testnet/`; `scripts/restore-l2reth-snapshot.sh` is gone.

### Changes

- **Self-contained networks.** `testnet/` and `mainnet/` each have their own
  `docker-compose.yml`, configuration, scripts, and env template, and share
  nothing, so they can run different versions and change independently. The
  root `docker-compose.yml`, `configs/`, `envs/`, and `scripts/` (except the
  repository check) are gone. Only testnet has the one-time L1 Interface
  history download.
- **One settings file per network.** Operator settings live in `.env` in the
  network directory, which Compose and the scripts read by default. Overrides
  formerly in `l1-interface.local.env` are `.env` settings, defaults are in
  `docker-compose.yml`, and the Dogecoin RPC host port no longer has to match
  `dogecoin.conf`. `DOGECOIN_P2P_PORT` is no longer used: P2P stays on the
  port Dogecoin advertises. `NETWORK` is no longer needed.
- **Snapshots.** `scripts/restore-snapshot.sh` restores Dogecoin, L1
  Interface, and L2Reth snapshots listed in a per-network index on S3, so new
  snapshots need no package release. It selects the newest snapshot compatible
  with the network's images, stops the restored service and every service that
  depends on it before activating data, and warns when a snapshot is ahead of
  its upstream service. See [Snapshots and Recovery](docs/snapshots.md).
- **L2Reth RPC options** for RPC providers: `L2RETH_HTTP_API`,
  `L2RETH_WS_API`, and `L2RETH_EXTRA_ARGS`; Prometheus metrics on
  `127.0.0.1:${L2_METRICS_PORT}` (default `6060`).
- **Stability.** Log rotation for every container (`LOG_MAX_SIZE`,
  `LOG_MAX_FILE`); `l2reth-node` restarts `unless-stopped`, which the
  signer-rotation exit (code 70) relies on; an `l1-interface` healthcheck on
  `/api/v1/health/ready`.
- **Internal ports** follow `INTERNAL_BIND_ADDR` (unset on testnet, keeping the
  previous behavior).
- **Cleanup.** Removed Celestia and L2Geth leftovers, unused env files, the
  unused `L2RETH_VALID_SIGNER`, and unnecessary permission changes in the L1
  Interface bootstrap. The peer list is now `L2RETH_PEER_LIST`
  (`L2GETH_PEER_LIST` is still accepted). Documentation moved to `docs/`.

### Mainnet

Not released. The layout is prepared: Dogecoin data under `DATA_ROOT`, internal
ports on `127.0.0.1`, wallet disabled, an explicit RPC password, and no testnet
bootstrap data. Missing configuration is listed in
[mainnet/README.md](mainnet/README.md).

## Testnet: L2Reth v0.3.0-beta.1c (Galileo, Galileo V2, and Tsuki)

For existing v0.3.0 testnet deployments.

- L2Reth image `dogeos69/rollup-node:0.3.0-beta.0` → `v0.3.0-beta.1c`.
- `galileoTime`, `galileoV2Time`, and `tsukiTime` fork activation settings
  added to the testnet L2Reth genesis.

Only L2Reth is recreated; data is kept and no resync is needed. After updating
the checkout:

```bash
docker compose --env-file .env.testnet pull l2reth-node
docker compose --env-file .env.testnet up -d --no-deps --force-recreate l2reth-node
```

`docker compose restart` alone does not apply a new image. Confirm that
`eth_blockNumber` advances afterwards.

## Testnet: v0.3.0

Moved Data Availability from Celestia to Ethereum, made L2Reth the only L2
client, and changed the L1 Interface storage format. Nodes on v0.2.x follow the
archived [v0.3.0 upgrade guide](docs/testnet/history/upgrade-v0.3.0.md).
