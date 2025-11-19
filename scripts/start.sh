#!/bin/bash

# DogeOS RPC Package Startup Script
# Usage: ./scripts/start.sh <network> <ethclient>

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./scripts/start.sh <network> <ethclient>"
    echo "  - network: directory inside envs/ (e.g., testnet, mainnet)"
    echo "  - ethclient: l2geth or l2reth"
    exit 1
fi

NETWORK=$1
ETHCLIENT_INPUT=$2

# Validate supported network values
case "$(echo "$NETWORK" | tr '[:upper:]' '[:lower:]')" in
    testnet|mainnet)
        NETWORK=$(echo "$NETWORK" | tr '[:upper:]' '[:lower:]')
        ;;
    *)
        echo "Error: Unsupported network '$NETWORK'. Valid options are 'testnet' or 'mainnet'."
        exit 1
        ;;
esac

# Determine which ETH client service to run
case "$(echo "$ETHCLIENT_INPUT" | tr '[:upper:]' '[:lower:]')" in
    l2geth|l2geth-node)
        ETHCLIENT_NAME="l2geth"
        ETHCLIENT_SERVICE="l2geth-node"
        ;;
    l2reth|l2reth-node)
        ETHCLIENT_NAME="l2reth"
        ETHCLIENT_SERVICE="l2reth-node"
        ;;
    *)
        echo "Error: Unsupported ETH client '$ETHCLIENT_INPUT'. Valid options are 'l2geth' or 'l2reth'."
        exit 1
        ;;
esac

# Validate network
if [ ! -d "envs/$NETWORK" ]; then
    echo "Error: Network configuration for '$NETWORK' not found!"
    echo "Available networks:"
    ls -1 envs/ | grep -v common
    exit 1
fi

echo "Starting DogeOS RPC Package with network: $NETWORK and ETH client: $ETHCLIENT_NAME"

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
load_env_file "envs/common/${ETHCLIENT_NAME}.env"
load_env_file envs/common/celestia.env
load_env_file envs/common/l1-interface.env

# Load network-specific variables used in docker-compose.yml
load_env_file envs/$NETWORK/dogecoin.env
load_env_file envs/$NETWORK/celestia.env
load_env_file "envs/$NETWORK/${ETHCLIENT_NAME}.env"
load_env_file envs/$NETWORK/l1-interface.env

echo "Environment configuration:"
echo "  - Network: $NETWORK"
echo "  - ETH client: $ETHCLIENT_SERVICE"
echo "  - Common configs: envs/common/"
echo "  - Network configs: envs/$NETWORK/"

# Detect docker-compose command
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo "Error: Neither 'docker compose' nor 'docker-compose' is available." >&2
    exit 1
fi

# Start services
echo "Starting services with '$COMPOSE_CMD'..."
$COMPOSE_CMD up dogecoin-node celestia-light-node l1-interface ${ETHCLIENT_SERVICE} -d

echo "Services started successfully!"
echo "You can check the status with: $COMPOSE_CMD ps" 
