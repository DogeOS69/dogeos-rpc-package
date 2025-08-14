#!/bin/bash
set -e

DATADIR="/l2geth/data"
GENESIS_FILE="/l2geth/genesis/genesis.json"
CONFIG_FILE="/l2geth/config.toml"

# Initialize geth if not already done
if [ ! -d "$DATADIR/geth" ]; then
  echo "Initializing geth..."
  geth --datadir "$DATADIR" init "$GENESIS_FILE"
fi

# Create config.toml with static nodes
echo "[Node.P2P] StaticNodes = $L2GETH_PEER_LIST" > "$CONFIG_FILE"

# Start geth with exact parameters matching DogeOS official configuration
exec geth \
    --datadir "$DATADIR" \
    --port "$L2GETH_P2P_PORT" --nodiscover --syncmode full --networkid "$CHAIN_ID" \
    --config "$CONFIG_FILE" \
    --http --http.port "$L2GETH_RPC_HTTP_PORT" --http.addr "0.0.0.0" --http.vhosts="*" --http.corsdomain '*' --http.api "eth,scroll,net,web3,debug" \
    --pprof --pprof.addr "0.0.0.0" --pprof.port 6060 \
    --ws --ws.port "$L2GETH_RPC_WS_PORT" --ws.addr "0.0.0.0" --ws.api "eth,scroll,net,web3,debug" \
    $L2GETH_CCC_FLAG --ccc.numworkers "$L2GETH_CCC_NUMWORKERS" \
    $METRICS_FLAGS \
    --scroll-mpt \
    --gcmode archive \
    --cache.noprefetch --cache.snapshot=0 \
    --snapshot=false \
    --verbosity 3 \
    --txpool.globalqueue "$L2GETH_GLOBAL_QUEUE" --txpool.accountqueue "$L2GETH_ACCOUNT_QUEUE" \
    --txpool.globalslots "$L2GETH_GLOBAL_SLOTS" --txpool.accountslots "$L2GETH_ACCOUNT_SLOTS" \
    --miner.gasprice "$L2GETH_MIN_GAS_PRICE" --rpc.gascap 0 \
    --gpo.ignoreprice "$L2GETH_MIN_GAS_PRICE" --gpo.percentile 20 --gpo.blocks 100 \
    --gpo.maxprice "$L2GETH_GPO_MAX_PRICE" \
    --l1.endpoint "$L2GETH_L1_ENDPOINT" --l1.confirmations "$L2GETH_L1_WATCHER_CONFIRMATIONS" --l1.sync.startblock "$L2GETH_L1_CONTRACT_DEPLOYMENT_BLOCK" \
    --metrics --metrics.expensive \
    $L2GETH_EXTRA_PARAMS 