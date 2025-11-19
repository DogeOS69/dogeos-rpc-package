#!/bin/bash

# DogeOS RPC Package Clean Script
# Usage: ./scripts/clean.sh <network>
# This script stops services and REMOVES all data volumes.

if [ -z "$1" ]; then
    echo "Usage: ./scripts/clean.sh <network>"
    echo "  - network: directory inside envs/ (e.g., testnet, mainnet)"
    echo "WARNING: This will DELETE ALL DATA for the specified network."
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

echo "WARNING: You are about to DELETE ALL DATA volumes for network: $NETWORK (Project: $COMPOSE_PROJECT_NAME)"
read -p "Are you sure? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 1
fi

echo "Removing services and volumes..."
$COMPOSE_CMD down -v

echo "Cleanup complete."
