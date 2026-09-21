# Galileo, Galileo V2, and Tsuki Hardfork Activation Times

This update is for existing **v0.3.0 testnet RPC deployments**.

## Changes

- Upgrade the L2Reth image from `dogeos69/rollup-node:0.3.0-beta.0` to
  `dogeos69/rollup-node:v0.3.0-beta.1c`.
- Add the `galileoTime`, `galileoV2Time`, and `tsukiTime` fork activation
  settings to `configs/testnet/l2reth-genesis.json`.

## Upgrade

Only L2Reth needs to be recreated. Existing chain data is retained; no data
reset, snapshot restore, or resync is required. Dogecoin and L1 Interface can
remain running. L2 RPC will be briefly unavailable while L2Reth restarts.

1. Update the existing deployment checkout to the package release containing
   this update. Both `docker-compose.yml` and
   `configs/testnet/l2reth-genesis.json` must be updated together.
2. Keep the existing `.env.testnet`, Compose project name, `DATA_ROOT`,
   Dogecoin volume name, and RPC credentials. Do not replace the local env
   file with a template.
3. With the existing stack running, execute the following in its deployment
   directory. If you use a custom env-file path or Compose options such as
   `-p` or `-f`, retain those options in every command below.

```bash
docker compose --env-file .env.testnet pull l2reth-node
docker compose --env-file .env.testnet up -d --no-deps --force-recreate l2reth-node
```

`--no-deps` limits startup to L2Reth. `--force-recreate` ensures its container
is recreated with the new image and the updated genesis file mounted.
`docker compose restart` alone does not apply the new image tag.

## Verify

Check that L2Reth is running and inspect its recent logs for startup or sync
errors:

```bash
docker compose --env-file .env.testnet ps l2reth-node
docker compose --env-file .env.testnet logs --tail=100 l2reth-node
```

Query the L2 block height using your configured HTTP port (`8545` by default):

```bash
curl --fail \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

Repeat the query after a short interval and confirm that the block height
advances. A running container alone does not confirm that syncing has resumed.
