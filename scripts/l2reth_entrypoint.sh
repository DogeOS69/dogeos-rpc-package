#!/bin/bash
set -e

export RUST_LOG=sqlx=off,scroll=trace,reth=trace,rollup=trace,info

#Available API
#admin,debug,eth,net,trace,txpool,web3,rpc,reth,ots,flashbots,miner,mev
# Parse L2GETH_PEER_LIST
PEER_FLAGS=""
if [ -n "$L2GETH_PEER_LIST" ]; then
    CLEAN_LIST=$(echo "$L2GETH_PEER_LIST" | sed 's/[][]//g' | sed 's/"//g')
    for peer in $(echo "$CLEAN_LIST" | tr ',' ' '); do
        PEER_FLAGS="$PEER_FLAGS --trusted-peers=$peer"
    done
fi

exec rollup-node node --chain /l2reth/genesis/genesis.json --datadir=/l2reth --metrics=0.0.0.0:6060 --network.scroll-wire=true --network.bridge=true  \
  --http --http.addr=0.0.0.0 --http.port=8545 --http.corsdomain "*" --http.api eth,net,web3,debug,trace \
  --ws --ws.addr=0.0.0.0 --ws.port=8546 --ws.api eth,net,web3,debug,trace \
  --log.stdout.format log-fmt -vvv \
  --txpool.pending-max-count=1000 \
  --builder.gaslimit=30000000 \
  --rpc.max-connections=5000 \
  $PEER_FLAGS \
  --engine.sync-at-startup false \
  --l1.url "http://l1-interface:8545" \
  --blob.beacon_node_urls="http://l1-interface:5052" \
  --network.valid_signer="$L2RETH_VALID_SIGNER"
