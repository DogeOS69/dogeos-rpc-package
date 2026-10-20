# Mainnet Snapshot Status

This release supports the complete RPC stack and published snapshots on
**testnet only**. Mainnet full-stack deployment and snapshots are not supported.
Do not use testnet snapshots or configuration for mainnet, or start this stack
by changing `NETWORK` to `mainnet`.

Mainnet has not been released. No mainnet snapshots are published, and the
mainnet template stores all service data under `DATA_ROOT`, including Dogecoin
at `${DATA_ROOT}/dogecoin`.
