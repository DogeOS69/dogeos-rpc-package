# Mainnet Snapshot Status

This release supports the complete RPC stack and published snapshots on
**testnet only**. Mainnet full-stack deployment and snapshots are not supported.
Do not use testnet snapshots or configuration for mainnet, or start this stack
by changing `NETWORK` to `mainnet`.

If you already run a mainnet Dogecoin node, retain its existing configuration,
RPC credentials, and data volume. Read its current local env file and deployment
records when checking volume names; do not overwrite `.env.mainnet` with the
example template. The retained mainnet template uses the old default project
and volume names, but does not provide a supported full-stack upgrade procedure.
