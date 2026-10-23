# DogeOS RPC Package

A Docker Compose deployment of the DogeOS RPC stack for RPC providers and node
operators: a Dogecoin node, the L1 Interface, and an L2Reth node serving
Ethereum-compatible RPC.

Each network is a self-contained directory with its own Compose file,
configuration, scripts, documentation, and changelog. The networks share
nothing; pick one and work entirely inside its directory.

| Network | Status | Start here |
|---------|--------|------------|
| Testnet | Supported | [testnet/README.md](testnet/README.md) |
| Mainnet | Not released | [mainnet/README.md](mainnet/README.md) |

Start with the README for your network. It walks through host requirements,
storage and `.env` settings, choosing a snapshot group or syncing from scratch,
ordered startup, and verification before serving RPC traffic. You need a Linux
host with Docker Compose 2.24+ and Python 3.9+; the network guide lists all tools
and memory/disk requirements.

For an existing deployment, read that network's changelog before applying an
update. Snapshot publication and mainnet release preparation are maintainer
workflows linked separately from the deployment steps.
