#!/bin/bash
set -e

export RUST_LOG=sqlx=off,info

#Available API
#admin,debug,eth,net,trace,txpool,web3,rpc,reth,ots,flashbots,miner,mev
# Parse the trusted peer list. Prefer L2RETH_PEER_LIST (manual override);
# fall back to L2GETH_PEER_LIST, the historical name gen-rpc-package writes
# with auto-resolved LoadBalancer domains.
PEER_LIST="${L2RETH_PEER_LIST:-${L2GETH_PEER_LIST:-}}"
PEER_FLAGS=""
if [ -n "$PEER_LIST" ]; then
    CLEAN_LIST=$(echo "$PEER_LIST" | sed 's/[][]//g' | sed 's/"//g')
    for peer in $(echo "$CLEAN_LIST" | tr ',' ' '); do
        PEER_FLAGS="$PEER_FLAGS --trusted-peers=$peer"
    done
fi

L1_ENDPOINT="${L2RETH_L1_ENDPOINT:-http://l1-interface:8545}"
BLOB_S3_URL="${L2RETH_BLOB_S3_URL:?L2RETH_BLOB_S3_URL must be set (DA blob archive URL)}"

# Must match the cluster's --network-id (NOT the chain id): the eth Status
# handshake compares network ids and silently drops peers on mismatch.
NETWORK_ID="${L2RETH_NETWORK_ID:?L2RETH_NETWORK_ID must be set (cluster p2p network id)}"

# Wait for the L1 interface RPC before starting the node. Waiting here instead
# of in a compose init container keeps the dependency daemon-managed, so
# startup survives the compose client (e.g. SSH session) going away.
echo "Waiting for L1 interface at $L1_ENDPOINT"
until curl -fsS --max-time 2 -H "content-type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$L1_ENDPOINT" >/dev/null 2>&1; do
  sleep 5
done
echo "L1 interface is ready"

exec rollup-node node --chain /l2reth/genesis/genesis.json --datadir=/l2reth --metrics=0.0.0.0:6060 --network.scroll-wire=true --network.bridge=true  \
  --network.legacy-geth-header-transform true \
  --network-id "$NETWORK_ID" \
  --http --http.addr=0.0.0.0 --http.port=8545 --http.corsdomain "*" --http.api eth,net,web3,debug,trace \
  --ws --ws.addr=0.0.0.0 --ws.port=8546 --ws.api eth,net,web3,debug,trace \
  --log.stdout.format log-fmt -vvv \
  --txpool.pending-max-count=1000 \
  --builder.gaslimit=30000000 \
  --sequencer.max-l1-messages 51 \
  --rpc.max-connections=5000 \
  $PEER_FLAGS \
  --engine.sync-at-startup false \
  --consensus.exit-on-signer-rotation \
  --l1.url "$L1_ENDPOINT" \
  --l1.query-range 100 \
  --l1.liveness-threshold 2147483647 \
  --l1.liveness-check-interval 3600 \
  --blob.s3_url "$BLOB_S3_URL"
