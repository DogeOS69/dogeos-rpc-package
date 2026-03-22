#!/bin/sh
set -e

# Define paths
CELESTIA_USER="celestia"
CELESTIA_HOME="/home/celestia"
NODE_STORE_PATH="/home/celestia/.celestia-light-${CELESTIA_P2P_NETWORK}"
CONFIG_FILE="/etc/celestia/config.toml"
AUTH_TOKEN_PATH="/home/celestia/celestia-auth"
AUTH_TOKEN_FILE="${AUTH_TOKEN_PATH}/xtoken.json"

if [ "$(id -u)" = "0" ] && [ "${CELESTIA_DROP_PRIVS_DONE:-0}" != "1" ]; then
  echo "=== Repairing Celestia data directory ownership... ==="
  mkdir -p "${CELESTIA_HOME}"
  chown -R "${CELESTIA_USER}:${CELESTIA_USER}" "${CELESTIA_HOME}"
  exec su "${CELESTIA_USER}" -s /bin/sh -c "CELESTIA_DROP_PRIVS_DONE=1 exec /bin/sh /entrypoint.sh"
fi

echo "=== Celestia Light Node Configuration ==="
echo "Network: ${CELESTIA_P2P_NETWORK}"
echo "Core IP: ${CELESTIA_CORE_IP}"
echo "Core Port: ${CELESTIA_CORE_PORT}"
echo "Auth Token: $([ -n "$CELESTIA_AUTH_TOKEN" ] && echo "Enabled" || echo "Disabled")"

# Initialize the node only if the data store doesn't exist
if [ ! -d "$NODE_STORE_PATH" ]; then
  echo "=== Initializing Celestia light node... ==="
  celestia light init --p2p.network "${CELESTIA_P2P_NETWORK}" --node.config "$CONFIG_FILE"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to initialize Celestia light node"
    exit 1
  fi
  echo "=== Initialization completed successfully ==="
else
  echo "=== Celestia light node already initialized ==="
fi

# Handle authentication token if it exists
if [ -n "$CELESTIA_AUTH_TOKEN" ]; then
  echo "=== Generating xtoken for RPC authentication... ==="
  mkdir -p "$AUTH_TOKEN_PATH"
  printf '{ "x-token": "%s" }\n' "$CELESTIA_AUTH_TOKEN" > "$AUTH_TOKEN_FILE"
  chmod 700 "$AUTH_TOKEN_PATH"
  chmod 600 "$AUTH_TOKEN_FILE"
  echo "=== Authentication token generated at ${AUTH_TOKEN_FILE} ==="

  echo "=== Starting Celestia light node with authentication... ==="
  exec celestia light start \
    --p2p.network "${CELESTIA_P2P_NETWORK}" \
    --node.config "${CONFIG_FILE}" \
    --core.ip "${CELESTIA_CORE_IP}" \
    --core.port "${CELESTIA_CORE_PORT}" \
    --core.tls \
    --core.xtoken.path "$AUTH_TOKEN_PATH"
else
  echo "=== Starting Celestia light node without authentication... ==="
  exec celestia light start \
    --p2p.network "${CELESTIA_P2P_NETWORK}" \
    --node.config "${CONFIG_FILE}" \
    --core.ip "${CELESTIA_CORE_IP}" \
    --core.port "${CELESTIA_CORE_PORT}"
fi
