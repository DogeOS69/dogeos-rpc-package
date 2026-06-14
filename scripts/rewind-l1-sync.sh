#!/bin/bash
#geth attach /l2geth/data/geth.ipc --exec "admin.setL1MessageSyncedL1Height(38702191)"
#geth attach /l2geth/data/geth.ipc --exec "admin.setRollupEventSyncedL1Height(38702192)"
docker compose exec l2geth-node geth attach /l2geth/data/geth.ipc --exec "admin.setL1MessageSyncedL1Height(38702191)"
docker compose exec l2geth-node geth attach /l2geth/data/geth.ipc --exec "admin.setRollupEventSyncedL1Height(38702192)"

