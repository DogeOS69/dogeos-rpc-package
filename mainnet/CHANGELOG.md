# Mainnet Changelog

Each entry states what mainnet operators must do. Testnet has its own
changelog in `testnet/`.

## Unreleased

Mainnet is not released; see [README.md](README.md) for what is still
missing. The prepared layout:

- Self-contained `mainnet/` directory with its own `docker-compose.yml`,
  configuration, scripts, documentation, and env template; nothing is shared
  with testnet.
- One settings file, `mainnet/.env`, created from `env.example`.
- All service data under `DATA_ROOT`, including Dogecoin in
  `${DATA_ROOT}/dogecoin`.
- Dogecoin RPC and L1 Interface ports published on `127.0.0.1` by default;
  Dogecoin wallet disabled; an explicit RPC password is required.
- No pre-v0.3.0 history bootstrap download.
- Snapshot restore through `scripts/restore-snapshot.sh` from the
  `mainnet/index.json` index, once published.
