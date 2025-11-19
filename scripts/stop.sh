#!/bin/bash

# DogeOS RPC Package Stop Script
# Usage: ./scripts/stop.sh <network>

if [ -z "$1" ]; then
    echo "Usage: ./scripts/stop.sh <network>"
    echo "  - network: directory inside envs/ (e.g., testnet, mainnet)"
    exit 1
fi

NETWORK=$1

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

# Set the project name to match start.sh
export COMPOSE_PROJECT_NAME=dogeos-${NETWORK}

# Detect docker-compose command
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo "Error: Neither 'docker compose' nor 'docker-compose' is available." >&2
    exit 1
fi

echo "Stopping DogeOS RPC Package for network: $NETWORK (Project: $COMPOSE_PROJECT_NAME)..."
$COMPOSE_CMD down

echo "Services stopped successfully."
