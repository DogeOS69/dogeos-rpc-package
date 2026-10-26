#!/bin/bash
set -eu

DATA_DIR=/l2reth
P2P_KEY_FILE=/run/dogeos/l2reth-p2p.key
# Never let Reth generate a replacement identity implicitly.
if [ ! -f "$P2P_KEY_FILE" ] || [ -L "$P2P_KEY_FILE" ] ||
   [ ! -r "$P2P_KEY_FILE" ] || [ "$(wc -c < "$P2P_KEY_FILE")" -ne 64 ] ||
   ! grep -Eq '^[0-9a-fA-F]{64}$' "$P2P_KEY_FILE" ||
   grep -Eq '^0{64}$' "$P2P_KEY_FILE"; then
  echo "ERROR: invalid/missing persistent P2P key; run scripts/p2p-identity.py init on the host." >&2
  exit 1
fi
P2P_PORT="${L2RETH_P2P_PORT:-30303}"
case "$P2P_PORT" in
  ''|*[!0-9]*) echo "ERROR: invalid P2P port" >&2; exit 1 ;;
esac
[ "$P2P_PORT" -ge 1 ] && [ "$P2P_PORT" -le 65535 ] || exit 1
# Keep exported allowlist information consistent with the running node.
set -f
for flag in ${L2RETH_EXTRA_ARGS:-}; do
  case "$flag" in
    --p2p-secret-key*|--nat|--nat=*|--port|--port=*|--discovery.port|--discovery.port=*|--instance|--instance=*|--with-unused-ports|--with-unused-ports=*)
      echo "ERROR: use dedicated P2P settings instead of L2RETH_EXTRA_ARGS overrides." >&2
      exit 1 ;;
  esac
done
set --
if [ -n "${L2RETH_P2P_PUBLIC_IP:-}" ]; then
  set -- --nat "extip:$L2RETH_P2P_PUBLIC_IP"
fi

mkdir -p "$DATA_DIR"
if [ ! -w "$DATA_DIR" ]; then
  echo "ERROR: L2Reth data directory is not writable: $DATA_DIR" >&2
  echo "Check DATA_ROOT and the ownership of its l2reth directory on the host." >&2
  exit 1
fi

export RUST_LOG=sqlx=off,info

# RPC namespaces. Available: admin,debug,eth,net,trace,txpool,web3,rpc,reth,
# ots,flashbots,miner,mev. The defaults keep debug and trace for RPC providers
# that filter methods in their own gateway.
HTTP_API="${L2RETH_HTTP_API:-eth,net,web3,debug,trace}"
WS_API="${L2RETH_WS_API:-eth,net,web3,debug,trace}"
# Operator flags, split on whitespace (no quoting). Do not repeat a flag set
# below; rollup-node rejects duplicates.
EXTRA_ARGS="${L2RETH_EXTRA_ARGS:-}"
# Parse the trusted peer list from config/l2reth.env.
# L2GETH_PEER_LIST is the name used by earlier releases and is still accepted.
PEER_LIST="${L2RETH_PEER_LIST:-${L2GETH_PEER_LIST:-}}"
PEER_FLAGS=""
if [ -n "$PEER_LIST" ]; then
    CLEAN_LIST=$(echo "$PEER_LIST" | sed 's/[][]//g' | sed 's/"//g')
    for peer in $(echo "$CLEAN_LIST" | tr ',' ' '); do
        PEER_FLAGS="$PEER_FLAGS --trusted-peers=$peer"
    done
fi

L1_ENDPOINT="${L2RETH_L1_ENDPOINT:-http://l1-interface:8545}"
L1_READY_URL="${L2RETH_L1_READY_URL:-http://l1-interface:9090/api/v1/health/ready}"
BLOB_S3_URL="${L2RETH_BLOB_S3_URL:?L2RETH_BLOB_S3_URL must be set (DA blob archive URL)}"

# Must match the cluster's --network-id (NOT the chain id): the eth Status
# handshake compares network ids and silently drops peers on mismatch.
NETWORK_ID="${L2RETH_NETWORK_ID:?L2RETH_NETWORK_ID must be set (cluster p2p network id)}"

# Wait for both RPC availability and replay/database readiness on every start.
# Keeping this in the entrypoint also covers daemon restarts without Compose.
# Readiness is not proof that replay has reached a particular chain checkpoint.
echo "Waiting for L1 interface RPC and readiness"
until curl -fsS --max-time 2 -H "content-type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$L1_ENDPOINT" >/dev/null 2>&1 && \
    READY_STATUS=$(curl -fsS --max-time 2 -o /dev/null -w '%{http_code}' \
      "$L1_READY_URL" 2>/dev/null) && [ "$READY_STATUS" = 200 ]; do
  sleep 5
done
echo "L1 interface RPC is available and readiness returned HTTP 200"

# The unquoted flag lists below are split on whitespace only; never glob them.
# The rollup-node flags depend on its version; review them when the mainnet
# image is chosen, and keep --consensus.exit-on-signer-rotation (exit code 70
# when the L1 signer rotates; the restart policy starts the node again).
set -f
exec rollup-node node \
  --chain /l2reth/genesis/genesis.json \
  --datadir=/l2reth \
  --p2p-secret-key "$P2P_KEY_FILE" \
  --port "$P2P_PORT" --discovery.port "$P2P_PORT" \
  "$@" \
  --metrics=0.0.0.0:6060 \
  --network-id "$NETWORK_ID" \
  --http --http.addr=0.0.0.0 --http.port=8545 --http.corsdomain "*" --http.api "$HTTP_API" \
  --ws --ws.addr=0.0.0.0 --ws.port=8546 --ws.api "$WS_API" \
  --log.stdout.format log-fmt -vvv \
  --rpc.max-connections=5000 \
  $PEER_FLAGS \
  --l1.url "$L1_ENDPOINT" \
  --blob.s3_url "$BLOB_S3_URL" \
  --network.scroll-wire=true \
  --network.bridge=true \
  --network.legacy-geth-header-transform true \
  --txpool.pending-max-count=1000 \
  --builder.gaslimit=30000000 \
  --sequencer.max-l1-messages 51 \
  --engine.sync-at-startup false \
  --consensus.exit-on-signer-rotation \
  --l1.query-range 100 \
  --l1.liveness-threshold 2147483647 \
  --l1.liveness-check-interval 3600 \
  $EXTRA_ARGS
