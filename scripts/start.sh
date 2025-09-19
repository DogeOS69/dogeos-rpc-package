#!/bin/bash

# DogeOS RPC Package Startup Script
# Usage: ./scripts/start.sh [network]
# Default network: testnet

NETWORK=${1:-testnet}

# Validate network
if [ ! -d "envs/$NETWORK" ]; then
    echo "Error: Network configuration for '$NETWORK' not found!"
    echo "Available networks:"
    ls -1 envs/ | grep -v common
    exit 1
fi

echo "Starting DogeOS RPC Package with network: $NETWORK"

# Export NETWORK environment variable for docker-compose
export NETWORK=$NETWORK

# Export variables used directly in docker-compose.yml (for variable substitution)
echo "Loading variables for docker-compose variable substitution..."

# Load variables safely (ignore comments and malformed lines)
load_env_file() {
    if [ -f "$1" ]; then
        export $(grep -v '^#' "$1" | grep -v '^$' | xargs -d '\n')
    fi
}

# Load common variables used in docker-compose.yml
load_env_file envs/common/l2geth.env
load_env_file envs/common/celestia.env
load_env_file envs/common/l1-interface.env

# Load network-specific variables used in docker-compose.yml
load_env_file envs/$NETWORK/dogecoin.env
load_env_file envs/$NETWORK/celestia.env
load_env_file envs/$NETWORK/l2geth.env
load_env_file envs/$NETWORK/l1-interface.env

echo "Environment configuration:"
echo "  - Network: $NETWORK"
echo "  - Common configs: envs/common/"
echo "  - Network configs: envs/$NETWORK/"

# Start services
docker-compose up -d

echo "Services started successfully!"
echo "You can check the status with: docker-compose ps" 