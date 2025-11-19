# DogeOS RPC Package

This project provides a Docker-based deployment of DogeOS RPC services including Dogecoin, L2Geth, Celestia nodes, and L1 Interface.

## Architecture

The project follows a modular configuration approach with support for multiple networks:

```
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
│   ├── mainnet                # Mainnet-specific settings
│   │   ├── celestia.env
│   │   ├── dogecoin.env
│   │   ├── l1-interface.env
│   │   └── l2geth.env
│   └── testnet                # Testnet-specific settings
│       ├── celestia.env
│       ├── dogecoin.env
│       ├── l1-interface.env
│       ├── l2geth.env
│       └── l2reth.env
├── README.md
└── scripts                     # Utility scripts
    ├── celestia-entrypoint.sh
    ├── l2geth_entrypoint.sh    # L2Geth entrypoint
    ├── l2reth_entrypoint.sh    # L2Reth entrypoint
    └── start.sh                # Network-aware startup script
```

## Quick Start

### 1. Start Services

Use the provided script to start with your chosen network and ETH client:
```bash
# Testnet with l2geth
./scripts/start.sh testnet l2geth

# Mainnet with l2geth
./scripts/start.sh mainnet l2geth

# Start testnet with the l2reth client
./scripts/start.sh testnet l2reth
```
The `network` argument must match a directory in `envs/` (currently `testnet` or `mainnet`), and the `ethclient` argument must be either `l2geth` or `l2reth`.

### 2. Verify Services

Check that all services are running:
```bash
docker-compose ps
#OR
docker compose ps
```



## Service Endpoints

- **Dogecoin RPC**: `http://localhost:22555`
- **L1 Interface RPC**: `http://localhost:8547` (L1 Ethereum client for L2Geth)
- **L1 Interface Beacon API**: `http://localhost:5052`
- **L1 Interface Health**: `http://localhost:9090`
- **L2Geth HTTP RPC**: `http://localhost:8545`
- **L2Geth WebSocket**: `ws://localhost:8546`
- **Celestia RPC**: `http://localhost:26658`
- **Celestia Gateway**: `http://localhost:26659`

## Services Overview

### L1 Interface
The L1 Interface service acts as an L1 Ethereum client that provides Ethereum-compatible RPC endpoints. It serves as the L1 endpoint for L2Geth (`L2GETH_L1_ENDPOINT`) and enables cross-chain functionality between Dogecoin, Celestia, and the L2 network.

## Configuration

### Environment Variables

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
3. The startup script will automatically detect the new network


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
./scripts/stop.sh <network>
# Example:
./scripts/stop.sh testnet
```

### Clean Up
```bash
./scripts/clean.sh <network>
# Example (WARNING: Deletes all data):
./scripts/clean.sh testnet
```

## Data Isolation & Migration

- **Data Isolation**: Data is isolated by network. `testnet` data is stored in volumes prefixed with `dogeos-testnet_`, and `mainnet` data in `dogeos-mainnet_`. This prevents accidental data overwrites.
- **Automatic Migration**: If you are upgrading from an older version (where volumes were prefixed with `dogeos-rpc-package_`), the startup script will automatically detect and migrate your data to the new isolated volumes. The old data is preserved as a backup. 
