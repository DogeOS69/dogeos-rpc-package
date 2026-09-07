# Mainnet Snapshot Status

The current release does not ship a supported full-stack mainnet snapshot or a
complete mainnet L2Reth/L1 Interface configuration. Do not use testnet L2Reth
snapshots, testnet SQLite bootstrap artifacts, genesis files, or protocol
context files for mainnet.

The tracked `.env.example.mainnet` preserves the pre-v0.3.0 named Dogecoin
volume convention so existing mainnet Dogecoin data is not accidentally
orphaned during an upgrade. Before touching that volume, confirm its exact name:

```bash
cp .env.example.mainnet .env.mainnet
set -a
. ./.env.mainnet
set +a

printf 'Dogecoin volume: %s\n' "$DOGECOIN_VOLUME_NAME"
docker volume inspect "$DOGECOIN_VOLUME_NAME"
```

Do not run the complete Compose stack with `.env.mainnet` as shipped. Mainnet
enablement requires all of the following deployment-specific inputs:

- `envs/mainnet/l2reth.env`
- `configs/mainnet/l2reth-genesis.json`
- `configs/mainnet/protocol_context.json`
- a generated mainnet L1 Interface env, an operator-local Ethereum RPC, and
  stable Dogecoin RPC credentials in `.env.mainnet`
- mainnet-specific, checksum-pinned L1 Interface bootstrap artifacts
- a separately published and verified mainnet L2Reth snapshot, if snapshot
  restoration is desired

The current `docker-compose.yml` init job is pinned to testnet SQLite artifacts.
Changing only `NETWORK=mainnet` is not sufficient and must not be used as a
mainnet migration procedure.
