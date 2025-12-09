# DogeOS RPC Package

This project provides a Docker-based deployment of DogeOS RPC services including Dogecoin, L2Geth, Celestia nodes, and L1 Interface.

## Architecture

The project follows a modular configuration approach with support for multiple networks:

```
├── .env.example.mainnet        # Mainnet environment template
├── .env.example.testnet        # Testnet environment template
├── configs                     # Network-specific configuration files
│   ├── mainnet
│   │   └── dogecoin.conf
│   └── testnet
│       ├── celestia
│       │   └── config.toml
│       ├── dogecoin.conf
│       ├── l2geth-genesis.json
│       └── l2reth-genesis.json
├── docker-compose.yml          # Main Docker Compose configuration
├── envs                        # Environment variables
│   ├── common                  # Common settings for all networks
│   │   ├── l1-interface.env
│   │   └── l2geth.env
│   ├── mainnet                 # Mainnet-specific settings
│   │   ├── celestia.env
│   │   ├── dogecoin.env
│   │   ├── l1-interface.env
│   │   └── l2geth.env
│   └── testnet                 # Testnet-specific settings
│       ├── celestia.env
│       ├── dogecoin.env
│       ├── l1-interface.env
│       ├── l2geth.env
│       └── l2reth.env
├── README.md
└── scripts                     # Utility scripts
    ├── celestia-entrypoint.sh
    ├── l2geth_entrypoint.sh    # L2Geth entrypoint
    └── l2reth_entrypoint.sh    # L2Reth entrypoint
```

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

### 3. Verify Services
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
- **Celestia RPC**: `http://localhost:26658`
- **Celestia Gateway**: `http://localhost:26659`

## Services Overview

### L1 Interface
The L1 Interface service acts as an L1 Ethereum client that provides Ethereum-compatible RPC endpoints. It serves as the L1 endpoint for L2Geth and enables cross-chain functionality between Dogecoin, Celestia, and the L2 network.

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

The configuration uses a layered approach:
1. **Common settings** (`envs/common/*.env`) - Applied to all networks
2. **Network-specific settings** (`envs/{network}/*.env`) - Override common settings

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
- Generate `l2geth.env` with updated peer list and network settings
- Generate `l1-interface.env` with contract addresses and network configuration
- Extract `genesis.json` from your deployment
- Preserve local service configurations (dogecoin RPC, celestia RPC)

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
- `envs/common/` - for settings shared across all networks
- `envs/{network}/` - for network-specific overrides

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

## Data Isolation

- **Project naming**: The Compose project name (defined in `.env`) controls volume prefixes.
  - `testnet` uses `dogeos-rpc-package` to keep existing data intact (no migration required).
  - `mainnet` uses `dogeos-rpc-package-mainnet` to ensure isolation from testnet data.
- **Resulting volume names**: Docker Compose will create volumes like `dogeos-rpc-package_dogecoin_data` (testnet) and `dogeos-rpc-package-mainnet_dogecoin_data` (mainnet).
- **Switching networks**: To switch between testnet and mainnet, run `docker compose down`, copy the appropriate `.env.example.*` to `.env`, and run `docker compose up -d`.
