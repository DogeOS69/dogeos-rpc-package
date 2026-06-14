#!/bin/bash
set -e

DATADIR="/l2geth/data"
GENESIS_FILE="/l2geth/genesis/genesis.json"
CONFIG_FILE="/l2geth/config.toml"

# Always (re-)apply genesis: creates the DB on first run, and on subsequent runs
# updates the stored chain config (e.g. newly added hard-fork params) idempotently.
# Existing block/state data is preserved; init only fails (exits non-zero) when a
# new fork is incompatible with already-committed blocks, which is the safe behavior.
echo "Initializing/updating geth chain config from genesis..."
geth --datadir "$DATADIR" init "$GENESIS_FILE"

# Create config.toml with static nodes
echo "[Node.P2P] StaticNodes = $L2GETH_PEER_LIST" > "$CONFIG_FILE"

# --- Automatic L1-reorg dirty-state recovery --------------------------------
# A deterministic L1 reorg in this network's history corrupts the L1->L2 message
# queue indexing: L2 block import reaches the message right after the reorg and
# can never apply the next one (SyncService logs "Unexpected queue index ...
# expected < got"), so the L2 chain freezes there forever while the L1 watchers
# (l1RollupSyncHeight / l1MessageSyncHeight) keep advancing. Because every
# operator replays the same L1 history through l1-interface, everyone hits the
# same wall. Recovery = rewind the L1 message / rollup-event synced heights to
# just before the reorg so the watchers re-fetch and re-index the missing queue
# entries, after which import continues past the wall.
#
# Detection is semantic, read directly from the node (no block-number guessing):
#   * scroll.latestRelayedQueueIndex  -> last L1 message consumed by L2; this is
#     frozen at exactly L2GETH_REORG_STUCK_QUEUE_INDEX at the reorg wall.
#   * scroll.getL1MessageByIndex(n)   -> the L1 message stored locally at queue
#     index n; the next one (relayed+1) is null because the reorg dropped it.
# Requiring BOTH (a) frozen at the known stuck index and (b) the next message
# missing pins this to the specific known incident and matches the configured
# rewind targets. It auto-clears on recovery: once the watcher re-fetches the
# message, getL1MessageByIndex stops returning null and the monitor goes quiet.
#
# This is a continuous background monitor, NOT a one-shot at boot: a node syncing
# from scratch only reaches the wall long after startup. It is a no-op for a
# fresh node still catching up (relayed index advancing) and for a node that
# already crossed the reorg (relayed index past the wall / next message present).
# After a rewind it waits out a cooldown (re-sync takes a while) before re-checking.
#
# Values are network-specific; override (or set _ENABLE=false to disable) via env.
L2GETH_REORG_FIX_ENABLE="${L2GETH_REORG_FIX_ENABLE:-true}"
L2GETH_REORG_STUCK_QUEUE_INDEX="${L2GETH_REORG_STUCK_QUEUE_INDEX:-24921}"
L2GETH_REORG_REWIND_ROLLUP_HEIGHT="${L2GETH_REORG_REWIND_ROLLUP_HEIGHT:-38702192}"
L2GETH_REORG_REWIND_MESSAGE_HEIGHT="${L2GETH_REORG_REWIND_MESSAGE_HEIGHT:-38702191}"
L2GETH_REORG_POLL_INTERVAL="${L2GETH_REORG_POLL_INTERVAL:-30}"
L2GETH_REORG_STUCK_CONFIRMATIONS="${L2GETH_REORG_STUCK_CONFIRMATIONS:-3}"
L2GETH_REORG_COOLDOWN="${L2GETH_REORG_COOLDOWN:-600}"

reconcile_l1_reorg() {
    # Runs in a backgrounded subshell for the lifetime of the container.
    set +e
    ipc="$DATADIR/geth.ipc"
    stuck_count=0
    # One round-trip: "<relayedIndex>/<nextMessageMissing>/<l2BlockSyncHeight>".
    probe_js='var r = scroll.latestRelayedQueueIndex; r + "/" + (scroll.getL1MessageByIndex(r + 1) === null) + "/" + scroll.syncStatus.l2BlockSyncHeight'

    while true; do
        sleep "$L2GETH_REORG_POLL_INTERVAL"
        [ -S "$ipc" ] || continue

        probe=$(geth attach "$ipc" --exec "$probe_js" 2>/dev/null | tr -d '"' | tr -d '[:space:]')
        relayed=$(printf '%s' "$probe" | cut -d/ -f1)
        missing=$(printf '%s' "$probe" | cut -d/ -f2)
        height=$(printf '%s' "$probe" | cut -d/ -f3)
        # Skip if the node isn't answering yet / gave a malformed read.
        case "$relayed" in ''|*[!0-9]*) continue ;; esac

        # Dirty iff frozen at the known reorg wall AND the next L1 message is
        # missing locally. Anything else (catching up, recovered, idle) resets.
        if [ "$relayed" = "$L2GETH_REORG_STUCK_QUEUE_INDEX" ] && [ "$missing" = "true" ]; then
            stuck_count=$((stuck_count + 1))
            echo "[l1-reorg-fix] Stuck at L1 message queue index $relayed (next message missing), L2 block $height ($stuck_count/$L2GETH_REORG_STUCK_CONFIRMATIONS confirmations)."
        else
            stuck_count=0
            continue
        fi

        [ "$stuck_count" -ge "$L2GETH_REORG_STUCK_CONFIRMATIONS" ] || continue

        echo "[l1-reorg-fix] Confirmed L1-reorg dirty state; rewinding L1 synced heights."
        geth attach "$ipc" --exec "admin.setL1MessageSyncedL1Height($L2GETH_REORG_REWIND_MESSAGE_HEIGHT)"
        geth attach "$ipc" --exec "admin.setRollupEventSyncedL1Height($L2GETH_REORG_REWIND_ROLLUP_HEIGHT)"
        echo "[l1-reorg-fix] Applied setL1MessageSyncedL1Height($L2GETH_REORG_REWIND_MESSAGE_HEIGHT) and setRollupEventSyncedL1Height($L2GETH_REORG_REWIND_ROLLUP_HEIGHT); re-syncing, waiting ${L2GETH_REORG_COOLDOWN}s before re-checking."
        stuck_count=0
        sleep "$L2GETH_REORG_COOLDOWN"
    done
}

if [ "$L2GETH_REORG_FIX_ENABLE" = "true" ]; then
    echo "[l1-reorg-fix] Monitor armed; will rewind L1 synced heights if L2 stays stuck at L1 message queue index $L2GETH_REORG_STUCK_QUEUE_INDEX with the next message missing."
    reconcile_l1_reorg &
fi

# Start geth with exact parameters matching DogeOS official configuration
#Available API
#admin,debug,eth,net,trace,txpool,web3,rpc,ots,flashbots,miner,mev
exec geth \
    --datadir "$DATADIR" \
    --port 30303 --nodiscover --syncmode full --networkid "$CHAIN_ID" \
    --config "$CONFIG_FILE" \
    --http --http.port 8545 --http.addr "0.0.0.0" --http.vhosts="*" --http.corsdomain '*' --http.api "eth,net,web3,debug,trace,scroll" \
    --pprof --pprof.addr "0.0.0.0" --pprof.port 6060 \
    --ws --ws.port 8546 --ws.addr "0.0.0.0" --ws.api "eth,net,web3,debug,trace,scroll" \
    $L2GETH_CCC_FLAG --ccc.numworkers "$L2GETH_CCC_NUMWORKERS" \
    $METRICS_FLAGS \
    --scroll-mpt \
    --rollup.verify --da.blob.beaconnode "http://l1-interface:5052" \
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
    --l1.sync.fetchblockrange "8" \
    --l1.sync.interval 2s \
    $L2GETH_EXTRA_PARAMS
    
