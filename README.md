# DogeOS RPC Package

This project provides a Docker-based deployment of DogeOS RPC services including Dogecoin, L2Geth, and Celestia nodes.

## Architecture

The project follows a modular configuration approach with support for multiple networks:

```
dogeos-rpc-package/
├── docker-compose.yml          # Main Docker Compose configuration
├── configs/                    # Network-specific configuration files
│   ├── testnet/
│   │   ├── dogecoin.conf
│   │   └── genesis.json
│   └── mainnet/
│       ├── dogecoin.conf
│       └── genesis.json
├── envs/                       # Environment variables
│   ├── common/                 # Common settings for all networks
│   │   ├── dogecoin.env
│   │   ├── l2geth.env
│   │   └── celestia.env
│   ├── testnet/               # Testnet-specific settings
│   │   ├── dogecoin.env
│   │   ├── l2geth.env
│   │   └── celestia.env
│   └── mainnet/               # Mainnet-specific settings
│       ├── dogecoin.env
│       └── l2geth.env
└── scripts/                   # Utility scripts
    ├── start.sh              # Network-aware startup script
    └── entrypoint.sh         # L2Geth entrypoint
```

## Quick Start

### 1. Start Services

Use the provided script to start with your chosen network:
```bash
# Start with testnet (default)
./scripts/start.sh

# Start with mainnet
./scripts/start.sh mainnet

# Or use docker-compose directly with environment variable
NETWORK=testnet docker-compose up -d
NETWORK=mainnet docker-compose up -d
```

### 2. Verify Services

Check that all services are running:
```bash
docker-compose ps
```

## Service Endpoints

- **Dogecoin RPC**: `http://localhost:22555`
- **L2Geth HTTP RPC**: `http://localhost:8545`
- **L2Geth WebSocket**: `ws://localhost:8546`
- **Celestia RPC**: `http://localhost:26658`
- **Celestia Gateway**: `http://localhost:26659`

## Configuration

### Environment Variables

The configuration uses a layered approach:
1. **Common settings** (`envs/common/*.env`) - Applied to all networks
2. **Network-specific settings** (`envs/{network}/*.env`) - Override common settings

### Adding New Networks

1. Create network-specific environment files in `envs/{network}/`
2. Create network-specific configuration files in `configs/{network}/`
3. The startup script will automatically detect the new network

### Customizing Configuration

Edit the appropriate environment files in `envs/` directory:
- `envs/common/` - for settings shared across all networks
- `envs/{network}/` - for network-specific overrides

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
```

### Stop Services
```bash
docker-compose down
```

### Clean Up
```bash
docker-compose down -v  # Remove volumes
``` 