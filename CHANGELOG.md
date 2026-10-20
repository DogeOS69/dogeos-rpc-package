# Changelog

Each entry states which network it affects and what operators must do.
Mainnet is not released yet.

## Unreleased

### Testnet: what to do

No configuration changes are required. Keep your `.env.testnet`, project name,
Dogecoin volume, and RPC credentials.

```bash
git pull
docker compose --env-file .env.testnet up -d
```

All containers are recreated once (new log rotation, restart policy,
configuration file locations, and healthcheck). Chain data is kept. Dogecoin
reloads its block index, which takes several minutes; L1 Interface retries
until it is ready, and L2 RPC is briefly unavailable. Verify with
[Verify Services](README.md#5-verify-services).

Optional follow-ups:

- Move `envs/testnet/l1-interface.local.env`, if you have one, to
  `networks/testnet/l1-interface.local.env`. The old location still works.
- Set `INTERNAL_BIND_ADDR=127.0.0.1` in `.env.testnet` unless another host
  needs the Dogecoin RPC or L1 Interface ports.
- Use `./scripts/restore-snapshot.sh` for snapshots;
  `restore-l2reth-snapshot.sh` still works but is deprecated.

### Changes

- **Network isolation.** Each network has its own directory,
  `networks/<network>/`, with its images, configuration, service env files,
  and env template. Testnet and mainnet can run different image versions, and
  a change to one network does not affect the other. `configs/` and `envs/`
  are gone; `.env.example.<network>` is now `networks/<network>/env.example`.
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
[networks/mainnet/README.md](networks/mainnet/README.md).

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
