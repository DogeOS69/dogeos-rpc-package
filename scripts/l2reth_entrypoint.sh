#!/bin/bash
set -e

export RUST_LOG=sqlx=off,scroll=trace,reth=trace,rollup=trace,info

exec rollup-node node --chain /l2reth/genesis/genesis.json --datadir=/l2reth --metrics=0.0.0.0:6060 --network.scroll-wire --network.bridge \
  --http --http.addr=0.0.0.0 --http.port=8545 --http.corsdomain "*" --http.api admin,debug,eth,net,trace,txpool,web3,rpc,reth,ots,flashbots,miner,mev \
  --ws --ws.addr=0.0.0.0 --ws.port=8546 --ws.api admin,debug,eth,net,trace,txpool,web3,rpc,reth,ots,flashbots,miner,mev \
  --log.stdout.format log-fmt -vvv \
  --txpool.pending-max-count=1000 \
  --builder.gaslimit=30000000 \
  --rpc.max-connections=5000 \
  --trusted-peers="$L2GETH_PEER_0" --trusted-peers="$L2GETH_PEER_1" \
  --engine.sync-at-startup false \
  --l1.url http://l1-node:8545 \
  --blob.beacon_node_urls="$L2RETH_DA_BLOB_BEACON_NODE" \
  --network.valid_signer="$L2RETH_VALID_SIGNER"
