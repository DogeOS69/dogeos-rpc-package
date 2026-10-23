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
