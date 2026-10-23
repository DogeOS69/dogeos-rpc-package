# Mainnet Snapshot Status

No mainnet snapshots are published. A new mainnet L2Reth follower syncs from
genesis; see [Mainnet Follower](README.md#mainnet-follower). Do not use testnet
snapshots or configuration for mainnet.

If you already run a mainnet Dogecoin node, retain its existing configuration,
RPC credentials, and data volume. Read its current local env file and deployment
records when checking volume names; do not overwrite `.env.mainnet` with the
example template. The mainnet template uses the old default project and volume
names.
