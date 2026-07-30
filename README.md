# DogeOS RPC Package

A Docker-based deployment of the DogeOS RPC stack for node and RPC operators. It runs a Dogecoin node, the L1 Interface, and an L2Reth client.

## What's New in v0.3.0

v0.3.0 is a major upgrade from the v0.2.x line. Key changes for operators:

- **Data Availability moved from Celestia to Ethereum.** The DA layer is now Ethereum-based, and L2Reth reads blobs through the L1 Interface (no Celestia node is run).
- **L1 Interface storage format is not backward compatible with v0.2.x.** The pre-v0.3.0 history is supplied as S3 archive files, which an init step downloads automatically on first start, so the upgrade is seamless.
- **No L2 history break.** From L2Reth's perspective the block history is continuous across the upgrade. A brand-new L2Reth node syncing from genesis will sync through and catch up to the chain head normally.

> [!NOTE]
> Because the L1 Interface storage format changed, v0.3.0 uses fresh `l1-interface` data (the S3 archive supplies the historical data automatically). L2 client data is unaffected by the format change.

## Architecture

The project follows a modular configuration approach with support for multiple networks. The tracked L2Reth runtime configuration is currently complete for testnet; mainnet requires generated L2Reth env/genesis/protocol context files before it can be started.

```
├── .env.example.mainnet        # Mainnet environment template
├── .env.example.testnet        # Testnet environment template
├── docker-compose.yml          # Main Docker Compose configuration
├── snapshot_mainnet.md         # Dogecoin mainnet snapshot guide
├── snapshot_testnet.md         # Dogecoin testnet snapshot guide
├── configs                     # Network-specific configuration files
│   ├── mainnet
│   │   └── dogecoin.conf        # L2Reth files must be generated before mainnet use
│   └── testnet
│       ├── dogecoin.conf
│       ├── l2reth-genesis.json
│       └── protocol_context.json
├── envs                        # Environment variables (per network)
│   ├── mainnet
│   │   ├── dogecoin.env
│   │   └── l1-interface.env     # l2reth.env must be generated before mainnet use
│   └── testnet
│       ├── dogecoin.env
│       ├── l1-interface.env
│       ├── l1-interface.local.env.example  # Template for operator overrides
│       └── l2reth.env
├── README.md
└── scripts                     # Utility scripts
    ├── prepare-data-dir.sh             # Prepare host data directories
    ├── restore-l2reth-snapshot.sh      # One-command L2Reth snapshot restore
    └── l2reth_entrypoint.sh            # L2Reth entrypoint
```

## Hardware Requirements

### Minimum Specifications (Testnet)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 32 GB | 64 GB |
| CPU | 4 cores | 8 cores |
| Disk | 300 GB SSD | 500 GB NVMe SSD |

### Memory Limits

Each service has a default memory limit configured in `docker-compose.yml`. The defaults are tuned for a **64 GB** host:

| Service | Default Limit | Notes |
|---------|--------------|-------|
| dogecoin-node | 20 GB | Largest consumer; RSS grows over time |
| l2reth-node | 8 GB | RSS grows with RPC traffic |
| l1-interface | 2 GB | Lightweight; higher usage during startup |

To override any limit, set the corresponding environment variable in your env file, for example `.env.testnet`:

```bash
# Example: reduce dogecoin limit for a 32 GB host
DOGECOIN_MEM_LIMIT=20g
```

Available variables: `DOGECOIN_MEM_LIMIT`, `L2RETH_MEM_LIMIT`, `L1_INTERFACE_MEM_LIMIT`.

Swap is disabled for all containers (`memswap_limit` == `mem_limit`), so containers will be OOM-killed rather than swapping to disk. This provides more predictable performance.

## Quick Start

### 1. Configure Environment
For testnet, copy the example configuration and review `DATA_ROOT`:

```bash
cp .env.example.testnet .env.testnet
# edit DATA_ROOT and any port/memory overrides before starting
```

For mainnet, generate and review the mainnet L2Reth files first:

```bash
# Required before mainnet startup:
# - envs/mainnet/l2reth.env
# - configs/mainnet/l2reth-genesis.json
# - configs/mainnet/protocol_context.json
cp .env.example.mainnet .env.mainnet
# edit DATA_ROOT and any port/memory overrides before starting
```

### 2. Prepare Data Directory
L2Reth and L1 Interface follow the same operational model as Arbitrum Nitro: chain databases live in an explicit host directory, not in anonymous Docker volumes. `DATA_ROOT` should point to a dedicated data disk, for example `/mnt/wsl/data/dogeos-data/testnet` or `/mnt/wsl/data/dogeos-data/mainnet`.

Dogecoin is the exception: its data stays in the named Docker volume used by earlier releases (`DOGECOIN_VOLUME_NAME` in the env file), so nodes upgrading from pre-v0.3.0 keep their synced chain without migration. If you changed `COMPOSE_PROJECT_NAME` in an earlier release, set `DOGECOIN_VOLUME_NAME=<your-old-project-name>_dogecoin_data` (check with `docker volume ls | grep dogecoin_data`).

```bash
./scripts/prepare-data-dir.sh .env.testnet
# or
./scripts/prepare-data-dir.sh .env.mainnet
```

The script creates:

```text
${DATA_ROOT}/l2reth
${DATA_ROOT}/l1-interface
```

Do not set `DATA_ROOT` to a path inside this repository.

If Docker cannot write to the prepared directories, fix ownership or permissions on the data disk before starting the stack. Prefer assigning the directory to the operator user/group or the container UID used by your runtime; avoid blanket `chmod 777` unless it is a deliberate emergency workaround.

### 3. Restore the L2Reth Snapshot

For a new testnet RPC node, restore the published L2Reth database instead of
syncing from genesis:

```bash
./scripts/restore-l2reth-snapshot.sh .env.testnet
```

The script downloads the current snapshot from the built-in public HTTPS URL,
verifies its built-in SHA-256, validates the archive layout, restores it to
`${DATA_ROOT}/l2reth`, and starts `l2reth-node` with its dependencies. Downloads
are resumable and cached under `${DATA_ROOT}/.snapshot-cache`.

The snapshot contains chain data only. The current genesis, hardfork schedule,
peer list, and runtime configuration continue to come from this repository.
See [the testnet snapshot guide](snapshot_testnet.md#l2reth-snapshot-recommended)
for replacement and recovery options.

### 4. Start Services
Start the services using Docker Compose:

```bash
docker compose --env-file .env.testnet up -d
# or
docker compose --env-file .env.mainnet up -d
```

### 4. Restore from Snapshot (Optional)

If you want to speed up the synchronization process, you can restore data from a snapshot.

- [Testnet Snapshot Guide: L2Reth, Dogecoin, and L1 Interface](snapshot_testnet.md)
- [Dogecoin Mainnet Snapshot Guide](snapshot_mainnet.md)

### 5. Verify Services
Check that all services are running:

```bash
docker compose --env-file .env.testnet ps
```



## Service Endpoints

- **Dogecoin RPC**: `http://localhost:22555` (mainnet) or `http://localhost:44555` (testnet)
- **L1 Interface RPC**: `http://localhost:8547` (L1 Ethereum client for L2Reth)
- **L1 Interface Health**: `http://localhost:9090`
- **L2Reth HTTP RPC**: `http://localhost:${L2_HTTP_PORT}` (`8545` by default on testnet)
- **L2Reth WebSocket**: `ws://localhost:${L2_WS_PORT}` (`8546` by default on testnet)

## Services Overview

### L1 Interface
The L1 Interface service provides the Ethereum-compatible L1 RPC data consumed by L2Reth (`L2RETH_L1_ENDPOINT`) and bridges the Dogecoin chain into the L2 network. It is not a Beacon blob source for L2Reth: L2Reth reads DA blobs directly from the public S3 archive configured by `L2RETH_BLOB_S3_URL`. L1 Interface also uses its configured Ethereum DA source for replay, while the pre-v0.3.0 history is supplied by the S3 archive files that the `l1-interface-init-fetch-sqlite` init container downloads on first start. Set your own Ethereum L1 RPC endpoint in `l1-interface.local.env` (`DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL`).

#### Blob Data Pruning

To manage storage space, L1 Interface supports automatic pruning of historical blob data. Pruning behavior is controlled via the following configuration options:
file: `envs/testnet/l1-interface.env`
- **`DOGEOS_L1_INTERFACE_BLOB_RETENTION`** (Default: `1000`)
  - The number of most recent distinct DA block heights to retain.
  - For example, setting it to `1000` means keeping blob data for the 1000 most recent heights.
  - Blob data for older heights will be pruned (set to `NULL`).

- **`DOGEOS_L1_INTERFACE_BLOB_PRUNING_INTERVAL_SECS`** (Default: `3600`)
  - The execution interval of the pruning task in seconds.
  - For example, setting it to `3600` means pruning runs once every hour.
  - Smaller values allow for more frequent pruning but may increase database load.

> [!IMPORTANT]
> If you add a new `l2reth` node and connect it to this `l1-interface`, please comment out these two options and restart `l1-interface`. This is because the new node requires historical Blob Data during the finalization process.

### L2Reth
L2Reth is the only supported L2 client in this package. It starts by default when you run `docker compose --env-file <env-file> up -d`; no Docker Compose profile selection is required. Its entrypoint script lives at `scripts/l2reth_entrypoint.sh`.


## Configuration

### Environment Variables

The project uses an explicit env file for configuration. Start by copying one of the example templates:
- `.env.example.testnet` - Template for Testnet
- `.env.example.mainnet` - Template for Mainnet

The env file contains:
- `NETWORK` - Network selection (testnet or mainnet)
- `COMPOSE_PROJECT_NAME` - Docker Compose project name (for container and network isolation)
- `DATA_ROOT` - Host path for persistent L2Reth and L1 Interface data
- `DOGECOIN_VOLUME_NAME` - Named Docker volume holding Dogecoin chain data (kept compatible with pre-v0.3.0 releases)
- Port configurations

Recommended filenames are `.env.testnet` and `.env.mainnet`, and both are gitignored to prevent accidental commits of local configurations.

### Layered Configuration

Each network has a self-contained configuration. For `l1-interface` the env is layered:
1. **Generated settings** (`envs/{network}/l1-interface.env`) - Complete, deterministic config produced by the CLI. Overwritten on every run; do not edit.
2. **Operator overrides** (`envs/{network}/l1-interface.local.env`) - Your infrastructure values (L1 RPC endpoint, beacon node, dogecoin RPC credentials). Loaded last, so it wins. Never overwritten by the CLI.

Create your override file from the tracked template (the real file is gitignored, so credentials stay out of version control):

```bash
cp envs/testnet/l1-interface.local.env.example envs/testnet/l1-interface.local.env
# then edit envs/testnet/l1-interface.local.env
```

### Generating Configuration Files[For internal DogeOS developers only]

You can automatically generate configuration files using the Scroll SDK CLI:

```bash
# Generate configuration files from a Scroll SDK deployment

# Install scroll-sdk-cli
git clone git@github.com:DogeOS69/scroll-sdk-cli.git
cd scroll-sdk-cli && yarn install && yarn build && npm install -g .

# Generate configuration
cd /path/to/scroll-setup-repo
scrollsdk setup gen-rpc-package -d /path/to/dogeos-rpc-package
```

This command will:
- Generate `l2reth.env` with the public S3 blob URL, updated peer list, network settings, and tuning defaults
- Generate `l1-interface.env` (complete, self-contained) and scaffold `l1-interface.local.env` for operator overrides
- Extract `genesis.json` and `protocol_context.json` from your deployment
- Never overwrite operator values in `*.local.env`

### Manual Configuration

1. Create network-specific environment files in `envs/{network}/`
2. Create network-specific configuration files in `configs/{network}/`
3. Copy the appropriate `.env.example.*` to `.env.<network>` and set a dedicated `DATA_ROOT`
4. Prepare the host data directory and start services with

```bash
./scripts/prepare-data-dir.sh .env.testnet
docker compose --env-file .env.testnet up -d
```

Replace `.env.testnet` with `.env.mainnet` for mainnet.


### Customizing Configuration

Edit the appropriate environment files in `envs/` directory:
- `envs/{network}/l1-interface.local.env` - for operator overrides (L1 RPC, beacon, dogecoin creds)
- `envs/{network}/*.env` - generated per-network config (regenerated by the CLI)

If you need to decide which APIs to enable, you can modify them in `scripts/l2reth_entrypoint.sh`.

## Development

### Adding Services

1. Add service definition to `docker-compose.yml`
2. Create common and network-specific environment files
3. Add any required configuration files to `configs/`

### Environment Management

- Keep sensitive values (passwords, keys) in network-specific env files
- Use common env files for shared settings across networks
- Environment variables are loaded via `env_file` directive in docker-compose.yml

## Maintenance

### Logs
```bash
docker compose --env-file .env.testnet logs -f [service_name]
```

### Stop Services
```bash
docker compose --env-file .env.testnet down
```

### Clean Up
**WARNING: This will delete all data!**

L2Reth and L1 Interface data lives under `DATA_ROOT`; Dogecoin data lives in the named Docker volume `DOGECOIN_VOLUME_NAME`. Stop services first, verify the path, then delete only the intended network data:

```bash
docker compose --env-file .env.testnet down
# Example only. Verify this is the intended DATA_ROOT before running:
rm -rf /mnt/wsl/data/dogeos-data/testnet
# Only if you also want to delete the synced Dogecoin chain (days to resync):
docker volume rm dogeos-rpc-package_dogecoin_data
```

## Data Isolation

- **Data root**: `DATA_ROOT` controls where L2Reth and L1 Interface data is stored. Use a dedicated data disk path, not a path inside this repository.
  - Testnet example: `/mnt/wsl/data/dogeos-data/testnet`
  - Mainnet example: `/mnt/wsl/data/dogeos-data/mainnet`
- **Directory layout**: Docker bind-mounts `${DATA_ROOT}/l2reth` and `${DATA_ROOT}/l1-interface` into the corresponding containers. Dogecoin uses the named Docker volume `DOGECOIN_VOLUME_NAME`; use different volume names for mainnet and testnet (the defaults already differ).
- **Project naming**: `COMPOSE_PROJECT_NAME` controls Compose container and network names. Use different values for mainnet and testnet.
- **Ports**: Use different `L2_HTTP_PORT`, `L2_WS_PORT`, and `L2_P2P_PORT` values when running multiple networks on the same host.
- **Switching networks**: Stop the current environment with `docker compose --env-file <env-file> down`, then start the target environment with its own env file. Do not reuse the same `DATA_ROOT` across networks.
