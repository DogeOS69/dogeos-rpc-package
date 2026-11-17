# DogeOS RPC Package

A Docker-based deployment of the DogeOS RPC stack for node and RPC operators.
It runs a Dogecoin node, the L1 Interface, and an L2Reth client.

Each network has its own directory with its Compose file, configuration,
scripts and documentation. Work inside the directory of your network.

| Network | Status | Start here |
|---------|--------|------------|
| Testnet | Supported | [testnet/README.md](testnet/README.md) |
| Mainnet | Not released | [mainnet/README.md](mainnet/README.md) |

## Moving an Existing Testnet Deployment

Earlier releases kept everything in the repository root. The files have moved
into `testnet/` without any change to images, settings or data. After
updating the repository, move your two local files and run commands from
`testnet/`:

```bash
mv .env.testnet testnet/.env.testnet
# Only if you created this optional override file:
mv envs/testnet/l1-interface.local.env testnet/config/l1-interface.local.env
cd testnet
docker compose --env-file .env.testnet up -d
```

The Compose project name and the Dogecoin volume name come from
`.env.testnet`, so the existing containers, volume and data are reused.
