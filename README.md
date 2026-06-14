# DogeOS RPC Package

A Docker-based deployment of the DogeOS RPC stack for node and RPC operators. It runs a Dogecoin node, the L1 Interface, and an L2 client (L2Geth or L2Reth).

## What's New in v0.3.0

v0.3.0 is a major upgrade from the v0.2.x line. Key changes for operators:

- **Data Availability moved from Celestia to Ethereum.** The DA layer is now Ethereum-based, and L2Geth fetches DA blobs from a public S3 archive by default (no Celestia node is run).
- **L1 Interface storage format is not backward compatible with v0.2.x.** The pre-v0.3.0 history is supplied as S3 archive files, which an init step downloads automatically on first start, so the upgrade is seamless.
- **No L2 history break.** From L2Geth's perspective the block history is continuous across the upgrade — there is no gap or reorg in L2 blocks. A brand-new L2Geth node syncing from genesis will sync through and catch up to the chain head normally.

> [!NOTE]
> Because the L1 Interface storage format changed, v0.3.0 uses fresh `l1-interface` data (the S3 archive supplies the historical data automatically). L2 client data is unaffected by the format change.

## Architecture

The project follows a modular configuration approach with support for multiple networks:

```
├── .env.example.mainnet        # Mainnet environment template
├── .env.example.testnet        # Testnet environment template
├── docker-compose.yml          # Main Docker Compose configuration
├── snapshot_mainnet.md         # Dogecoin mainnet snapshot guide
├── snapshot_testnet.md         # Dogecoin testnet snapshot guide
├── configs                     # Network-specific configuration files
│   ├── mainnet
│   │   └── dogecoin.conf
│   └── testnet
│       ├── dogecoin.conf
│       ├── l2geth-genesis.json
│       ├── l2reth-genesis.json
│       └── protocol_context.json
├── envs                        # Environment variables (per network)
│   ├── mainnet
│   │   ├── dogecoin.env
│   │   ├── l1-interface.env
│   │   └── l2geth.env
│   └── testnet
│       ├── dogecoin.env
│       ├── l1-interface.env
│       ├── l1-interface.local.env.example  # Template for operator overrides
│       ├── l2geth.env
│       └── l2reth.env
├── README.md
└── scripts                     # Utility scripts
    ├── l2geth_entrypoint.sh    # L2Geth entrypoint
    ├── l2reth_entrypoint.sh    # L2Reth entrypoint
    └── rewind-l1-sync.sh       # Manual L1-sync rewind helper (see Maintenance)
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
| l2geth-node | 8 GB | RSS grows with RPC traffic |
| l2reth-node | 8 GB | RSS grows with RPC traffic |
| l1-interface | 2 GB | Lightweight; higher usage during startup |

> [!NOTE]
> Only one of l2geth or l2reth runs at a time, so the actual total is **~30 GB** (not 38 GB).

To override any limit, set the corresponding environment variable in your `.env` file:

```bash
# Example: reduce dogecoin limit for a 32 GB host
DOGECOIN_MEM_LIMIT=20g
```

Available variables: `DOGECOIN_MEM_LIMIT`, `L2GETH_MEM_LIMIT`, `L2RETH_MEM_LIMIT`, `L1_INTERFACE_MEM_LIMIT`.

Swap is disabled for all containers (`memswap_limit` == `mem_limit`), so containers will be OOM-killed rather than swapping to disk. This provides more predictable performance.

## Quick Start

### 1. Configure Environment
Choose your network (testnet or mainnet) and copy the example configuration:

```bash
# For Testnet
cp .env.example.testnet .env

# For Mainnet
cp .env.example.mainnet .env
```

### 2. Start Services
Start the services using Docker Compose:

```bash
docker compose up -d
```

### 3. Restore from Snapshot (Optional)

If you want to speed up the synchronization process, you can restore data from a snapshot.

- [Dogecoin Testnet Snapshot Guide](snapshot_testnet.md)
- [Dogecoin Mainnet Snapshot Guide](snapshot_mainnet.md)

### 4. Verify Services
Check that all services are running:

```bash
docker compose ps
```



## Service Endpoints

- **Dogecoin RPC**: `http://localhost:22555` (mainnet) or `http://localhost:44555` (testnet)
- **L1 Interface RPC**: `http://localhost:8547` (L1 Ethereum client for L2Geth)
- **L1 Interface Beacon API**: `http://localhost:5052`
- **L1 Interface Health**: `http://localhost:9090`
- **L2 Client HTTP RPC**: `http://localhost:8545` (l2geth or l2reth)
- **L2 Client WebSocket**: `ws://localhost:8546` (l2geth or l2reth)

## Services Overview

### L1 Interface
The L1 Interface service acts as an L1 Ethereum client that provides Ethereum-compatible RPC endpoints and a Beacon-style blob API. It serves as the L1 endpoint for the L2 client (`L2GETH_L1_ENDPOINT`) and bridges the Dogecoin chain into the L2 network. As of v0.3.0 the Data Availability layer is Ethereum-based: DA batches/blobs are read from a public S3 archive (`DOGEOS_L1_INTERFACE_ETHEREUM_DA__BLOB_SOURCE__AWS_S3__URL`), and the pre-v0.3.0 history is supplied as S3 archive files that the `l1-interface-init-fetch-sqlite` init container downloads on first start. Set your own Ethereum L1 RPC endpoint in `l1-interface.local.env` (`DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL`).

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
> If you add a new `l2geth` or `l2reth` node and connect it to this `l1-interface`, please comment out these two options and restart `l1-interface`. This is because the new node requires historical Blob Data during the finalization process.

### L2 Client (L2Geth / L2Reth)
The L2 client is selected via `COMPOSE_PROFILES` (see [Docker Compose Profiles](#docker-compose-profiles)). Its entrypoint scripts live in `scripts/`.

#### Automatic L1-reorg recovery (L2Geth)
The Dogecoin testnet experienced a one-time L1 reorg earlier in its history. This left a single gap in the L1→L2 message queue: an L2Geth node syncing across that point reaches the message right after the reorg and cannot apply the next one, logging `Unexpected queue index in SyncService expected=<a> got=<b>` and pausing block import at that point. This is a known, one-time condition and is **handled automatically — no operator action is required**.

`scripts/l2geth_entrypoint.sh` runs a background monitor that detects this specific condition directly from the node:

- `scroll.latestRelayedQueueIndex` — the last L1 message consumed by L2; at the affected point it stops at `L2GETH_REORG_STUCK_QUEUE_INDEX`.
- `scroll.getL1MessageByIndex(relayed + 1)` — the next L1 message; it is `null` because the reorg dropped that entry.

When both conditions hold across several consecutive polls, the monitor rewinds the L1 message and rollup-event synced heights to just before the reorg (via `admin.setL1MessageSyncedL1Height` / `admin.setRollupEventSyncedL1Height`), prompting the watchers to re-fetch and re-index the affected entries so block import continues normally.

The monitor runs for the lifetime of the container (a node syncing from genesis only reaches the affected point well after startup). It takes no action on a node that is still catching up, and it **clears itself on recovery** — once the message is re-fetched it goes quiet — so it is effectively a no-op outside the one-time condition. Behavior is configurable via environment variables (the defaults target the known testnet event):

| Variable | Default | Purpose |
|----------|---------|---------|
| `L2GETH_REORG_FIX_ENABLE` | `true` | Set to `false` to disable the monitor entirely |
| `L2GETH_REORG_STUCK_QUEUE_INDEX` | `24921` | `scroll.latestRelayedQueueIndex` at the affected point (last message consumed before the gap) |
| `L2GETH_REORG_REWIND_ROLLUP_HEIGHT` | `38702192` | Value passed to `admin.setRollupEventSyncedL1Height` |
| `L2GETH_REORG_REWIND_MESSAGE_HEIGHT` | `38702191` | Value passed to `admin.setL1MessageSyncedL1Height` |
| `L2GETH_REORG_POLL_INTERVAL` | `30` | Seconds between polls |
| `L2GETH_REORG_STUCK_CONFIRMATIONS` | `3` | Consecutive matching polls required before acting |
| `L2GETH_REORG_COOLDOWN` | `600` | Seconds to wait after acting (during re-sync) before re-checking |


## Configuration

### Environment Variables

The project uses a `.env` file for configuration. Start by copying one of the example templates:
- `.env.example.testnet` - Template for Testnet
- `.env.example.mainnet` - Template for Mainnet

The `.env` file contains:
- `NETWORK` - Network selection (testnet or mainnet)
- `COMPOSE_PROJECT_NAME` - Docker Compose project name (for volume and container isolation)
- `COMPOSE_PROFILES` - ETH client selection (`l2geth` or `l2reth`)
- Port configurations

**Note**: The `.env` file is gitignored to prevent accidental commits of local configurations.

### Docker Compose Profiles

This project uses Docker Compose Profiles to select which ETH client to run:
- `l2geth` - Scroll L2Geth client (supported on both testnet and mainnet)
- `l2reth` - Scroll Reth client (currently testnet only)

To switch clients, edit `COMPOSE_PROFILES` in your `.env` file.

> [!WARNING]
> **Port Conflict**: Both `l2geth` and `l2reth` use the same ports (8545, 8546, 30303). You can only run ONE client at a time. If you need to run both simultaneously, you must modify the port mappings in `docker-compose.yml`.

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
- Generate `l2geth.env`/`l2reth.env` with updated peer list, network settings, and tuning defaults
- Generate `l1-interface.env` (complete, self-contained) and scaffold `l1-interface.local.env` for operator overrides
- Extract `genesis.json` and `protocol_context.json` from your deployment
- Never overwrite operator values in `*.local.env`

### Manual Configuration

1. Create network-specific environment files in `envs/{network}/`
2. Create network-specific configuration files in `configs/{network}/`
3. Copy the appropriate `.env.example.*` to `.env` and start services with 
```
docker compose up -d
#OR
docker-compose up -d
```


### Customizing Configuration

Edit the appropriate environment files in `envs/` directory:
- `envs/{network}/l1-interface.local.env` - for operator overrides (L1 RPC, beacon, dogecoin creds)
- `envs/{network}/*.env` - generated per-network config (regenerated by the CLI)

If you need to decide which APIs to enable, you can modify them in `scripts/l2geth_entrypoint.sh` or `scripts/l2reth_entrypoint.sh`.

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
docker-compose logs -f [service_name]
#OR 
docker compose logs -f [service_name]
```

### Stop Services
```bash
docker compose down
```

### Clean Up
**WARNING: This will delete all data!**

```bash
docker compose down -v
```

### Manually Rewinding L2Geth L1 Sync
L2Geth normally self-heals from the known L1 reorg automatically (see [Automatic L1-reorg recovery](#automatic-l1-reorg-recovery-l2geth)). If you need to rewind the L1 synced heights manually — for a different reorg or a one-off correction — use `scripts/rewind-l1-sync.sh`, which calls the admin RPCs over the running container's IPC:

```bash
./scripts/rewind-l1-sync.sh
```

Edit the target heights in the script before running. The L2Geth admin namespace is only exposed over IPC, so these calls must run inside the container.

## Data Isolation

- **Project naming**: The Compose project name (defined in `.env`) controls volume prefixes.
  - `testnet` uses `dogeos-rpc-package` to keep existing data intact (no migration required).
  - `mainnet` uses `dogeos-rpc-package-mainnet` to ensure isolation from testnet data.
- **Resulting volume names**: Docker Compose will create volumes like `dogeos-rpc-package_dogecoin_data` (testnet) and `dogeos-rpc-package-mainnet_dogecoin_data` (mainnet).
- **Switching networks**: To switch between testnet and mainnet, run `docker compose down`, copy the appropriate `.env.example.*` to `.env`, and run `docker compose up -d`.
