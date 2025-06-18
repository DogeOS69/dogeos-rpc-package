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

# Start services
docker-compose up -d

echo "Services started successfully!"
echo "You can check the status with: docker-compose ps" 