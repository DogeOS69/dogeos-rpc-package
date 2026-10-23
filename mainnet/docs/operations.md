# Operations

Configuration, security, and maintenance for a mainnet stack. Mainnet is not
released yet (see [README.md](../README.md)). Run every command inside the
`mainnet/` directory; Docker Compose and the scripts read `.env` there.

## Configuration

Keep persistent service settings in `mainnet/.env`, created from
`env.example` in the same directory. The template lists service settings and
their defaults. Snapshot download options use command-line flags or exported
shell variables, as described in [Snapshots and Recovery](snapshots.md). Keep
`.env` private (`chmod 600 .env`) and in your configuration backups. Everything else
in `mainnet/` (`docker-compose.yml`, `config/`, `scripts/`, `docs/`) is
maintained by this package.

Mainnet shares nothing with testnet. Run one network per host; their default
internal ports overlap.

`docker compose restart` does not reload settings. After changing `.env`, apply
it with:

```bash
python3 scripts/snapshot-group.py start
```

The staged helper stops downstream services first, then waits for upstream
sync/readiness and saved snapshot checkpoints. This briefly interrupts L2 RPC.
Use it for cold startup and recovery; plain Compose startup does not enforce
these host-side gates. It requires the bundled L1 Interface endpoints; custom
external L1 endpoints need their own verified startup orchestration.

### L1 Interface Data Paths

`DATA_ROOT` selects the host disk; L1 Interface always uses
`${DATA_ROOT}/l1-interface` mounted at `/data`. Its database paths are fixed:
`/data/l1-interface.sqlite`, `/data/replay.sqlite`, and the derived
`/data/replay.artifacts/` tree. The historical artifact, when configured, is
`/data/l1-interface-historical-artifact.sqlite`. Custom database paths are
rejected at startup and snapshot restore checks the resolved mounts too.
Remove path overrides from legacy env files only after reconciling the data
with this layout; no automatic migration is performed. See
[Fixed Data Layout](snapshots.md#fixed-data-layout).

### L2Reth Memory Limit

`L2RETH_MEM_LIMIT` defaults to `16g` (16 GB). Set it in `.env` according to
your machine's available memory and RPC workload, especially tracing traffic.
Leave memory for Dogecoin, L1 Interface, the operating system, and other
services; smaller hosts need lower limits. This is a cap, not a reservation.
Swap is disabled for the container, so exceeding the cap can cause an OOM kill.
Apply changes with `python3 scripts/snapshot-group.py start` in a maintenance window.

### Dogecoin RPC Credentials

`DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD` are passed to `dogecoin-node`
and `l1-interface` as Docker secrets; do not put them in `dogecoin.conf`.
Supported characters are letters, digits, and `._~:@%+=,-`. The template
leaves the password empty, and Dogecoin refuses to start until it is set.
Changing secret values alone does not change the Compose service configuration
hash, so `docker compose up -d` may keep the existing containers and credentials.
After updating `.env`, explicitly recreate both consumers during a maintenance
window, stopping L2Reth while its upstream services restart:

```bash
docker compose stop l2reth-node l1-interface dogecoin-node
docker compose create --force-recreate dogecoin-node l1-interface
python3 scripts/snapshot-group.py start
```

`create` refreshes the stopped consumers without starting them; the helper
then starts them in dependency order. Every external consumer of the Dogecoin
RPC must also update its credentials.

### Custom Ethereum RPC

Whether mainnet ships a default Ethereum RPC is not decided yet (see
[README.md](../README.md)). To use your own provider, set in `.env`:

```bash
DOGEOS_ETHEREUM_RPC_URL=https://your-ethereum-execution-rpc
```

The provider must support Ethereum mainnet (chain ID `1`) and execution
methods including `eth_getBlockByHash`. Apply it with `python3 scripts/snapshot-group.py start`.

<details>
<summary>Advanced: use an external Dogecoin RPC</summary>

For temporary troubleshooting, L1 Interface can use another Dogecoin node.
Confirm that the external node serves the required history, is reachable from
L1 Interface, and is not behind the data L1 Interface has already indexed.
Set in `.env`:

```bash
DOGEOS_EXTERNAL_DOGECOIN_RPC_URL=https://your-dogecoin-rpc
DOGEOS_EXTERNAL_DOGECOIN_RPC_USER=...
DOGEOS_EXTERNAL_DOGECOIN_RPC_PASSWORD=...
```

Then stop L2Reth while L1 Interface switches, and stop the bundled node:

```bash
docker compose stop l2reth-node l1-interface dogecoin-node
docker compose create --force-recreate l1-interface
python3 scripts/snapshot-group.py start
```

The helper checks the external Dogecoin RPC and does not start the bundled node; its data is kept
for switching back. To return to it, remove the three settings and run:

```bash
docker compose stop l2reth-node l1-interface dogecoin-node
docker compose create --force-recreate l1-interface
python3 scripts/snapshot-group.py start
```

</details>

## Network Security

The package is built for RPC providers that serve L2Reth through their own
gateway or load balancer. Only these ports need to be internet-reachable:

- L2Reth HTTP/WebSocket, through your gateway
- Dogecoin P2P: `22556`
- L2Reth P2P: `${L2_P2P_PORT}` (default `30303`), TCP and UDP

Keep Dogecoin RPC and the L1 Interface ports private with `INTERNAL_BIND_ADDR`,
host or cloud firewalls, or a private network. RPC authentication is not a
substitute for network isolation.

### `debug` and `trace` Methods

L2Reth enables `eth,net,web3,debug,trace` on HTTP and WebSocket by default, so
providers can offer tracing. Filter and rate-limit `debug_*` and `trace_*` in
your gateway, including inside JSON-RPC batch requests and WebSocket sessions.
Tracing is memory- and CPU-intensive: a burst can push L2Reth to its memory
limit, and an OOM restart also interrupts syncing. As a second limit, cap
concurrent tracing on the node:

```bash
# .env
L2RETH_EXTRA_ARGS=--rpc.max-tracing-requests 8
```

To serve without them, set `L2RETH_HTTP_API` and `L2RETH_WS_API` to
`eth,net,web3`. `L2RETH_EXTRA_ARGS` accepts other `rollup-node` flags, such as
`--rpc.gascap` or `--rpc-cache.*`, separated by spaces. Do not repeat a flag
already set by `scripts/l2reth_entrypoint.sh`; `rollup-node` exits on
duplicates. Apply changes with `python3 scripts/snapshot-group.py start`.

### Load Balancer Health

Before adding a node to the serving pool, follow [Verify Your RPC Node](verify-node.md)
to compare network identity, head lag and a shared block hash.

`eth_syncing` alone is not enough to decide whether to route traffic to a
node. Compare its `eth_blockNumber` with a reference node or your other
backends, and remove a node that falls more than a few blocks behind.

## Service Endpoints

| Endpoint | Address | Exposure |
|----------|---------|----------|
| L2Reth HTTP RPC | `http://<host>:${L2_HTTP_PORT}` (default `8545`) | Public, behind your gateway |
| L2Reth WebSocket | `ws://<host>:${L2_WS_PORT}` (default `8546`) | Public, behind your gateway |
| L2Reth metrics | `http://127.0.0.1:${L2_METRICS_PORT}/` (default `6060`) | Prometheus; this host only |
| Dogecoin RPC | `http://localhost:${DOGECOIN_RPC_PORT}` (default `22555`) | Internal |
| L1 Interface RPC | `http://localhost:8547` | Internal (L1 client for L2Reth) |
| L1 Interface health | `http://localhost:9090/health`, `/api/v1/health/ready` | Internal |

Set the port variables in `.env` to change the host ports (defaults are listed
in `env.example`). Internal ports follow `INTERNAL_BIND_ADDR`, which defaults
to `127.0.0.1`; set another address only if another host needs these ports.

## Maintenance

### Logs

```bash
docker compose logs -f [service_name]
```

Each container keeps at most `LOG_MAX_FILE` files of `LOG_MAX_SIZE` (5 × 100 MB
by default). Ship logs elsewhere if you need longer retention.

Useful checks:

```bash
# L1 Interface startup completed (HTTP 200, "status":"ready")
curl --fail http://localhost:9090/health

# L1 Interface currently ready (database and replay read model)
curl --fail http://localhost:9090/api/v1/health/ready

# Established L2Reth P2P sessions (hexadecimal result)
curl --fail \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://localhost:8545
```

`docker compose ps` shows `l1-interface` as `healthy` when
`/api/v1/health/ready` succeeds.

On every container start or restart, L2Reth waits for both L1 JSON-RPC
availability and HTTP 200 from that readiness endpoint before launching
`rollup-node`. The default readiness URL inside the Compose network is
`http://l1-interface:9090/api/v1/health/ready`. If using a different L1
Interface endpoint, set `L2RETH_L1_READY_URL` alongside `L2RETH_L1_ENDPOINT`
in `config/l2reth.env` so both checks target the same instance. These checks
cover startup RPC availability and local database/replay health; they do not
prove Dogecoin has finished initial sync or replay has reached a specific
chain checkpoint.

### Check Synchronization Progress

Run these read-only checks in a second terminal in this network's directory.
Repeat them after 30–60 seconds and compare values. Do not re-run `start` to
check status: it stops L1/L2 before checking upstream services.

**1. Dogecoin:**

```bash
docker compose exec -T dogecoin-node /dogecoin/bin/dogecoin-cli \
  -conf=/run/dogeos/dogecoin.conf -datadir=/data getblockchaininfo \
  | jq '{blocks, headers, initialblockdownload, verificationprogress}'
docker compose exec -T dogecoin-node /dogecoin/bin/dogecoin-cli \
  -conf=/run/dogeos/dogecoin.conf -datadir=/data getconnectioncount
```

- Increasing `blocks` means block processing is progressing; compare it with
  `headers`. `verificationprogress` is an estimate between 0 and 1, not an ETA
  or the startup gate.
- The helper waits until `initialblockdownload=false` and `blocks >= headers`,
  then checks any saved snapshot checkpoints. L1 being stopped until then is
  expected.
- RPC error `-28` / `Loading block index` means the RPC is warming up. Check
  `docker compose logs --tail=100 dogecoin-node` for index-loading progress.
- A flat height with `initialblockdownload=true` needs investigation if it
  persists: check peer count, repeated network/disk errors and container
  restarts. A flat tip after catch-up may simply mean no new block arrived.

If configured to use an external Dogecoin node, inspect those same RPC methods
on that node instead; the bundled container may intentionally be stopped.

**2. L1 historical indexing and replay:**

```bash
# Keep HTTP 503 bodies visible during startup; these commands intentionally
# omit --fail. Adjust localhost if you changed INTERNAL_BIND_ADDR.
curl --silent --show-error --max-time 10 \
  --write-out '\nHTTP %{http_code}\n' http://localhost:9090/health
curl --silent --show-error --max-time 10 \
  --write-out '\nHTTP %{http_code}\n' http://localhost:9090/api/v1/health/ready
docker compose logs --tail=200 l1-interface
```

`/health` reports HTTP 503 with `historical_sync=in_progress` until indexing
finishes, then HTTP 200 with `historical_sync=completed`. It **does not expose
a percentage or indexed block height**. In the logs, compare successive
`Processing block range START - END` messages; advancing ranges show work
progressing. `Dogecoin historical sync completed ... (final block: ...)`
marks the end of the historical phase. The API/readiness routes may not yet
be available while historical indexing runs; a connection failure at that
stage is not by itself evidence of a crash.

After historical sync, `/api/v1/health/ready` should return HTTP 200 with
`ready=true`. If it reports `ready=false`, inspect `critical_components`:
`database` describes database health and `replay_read_model` includes its
message/details. When present, increasing `validated_up_to` indicates replay
validation progress; compare it with `discovered_up_to`. These are replay
positions, not Dogecoin heights. A `stop_reason` or a repeated database/replay
error needs investigation; do not delete data or bypass readiness.

**3. L2 catch-up:** after L1 is ready and the helper starts L2Reth, use
[Verify Your RPC Node](verify-node.md) to compare its decimal head height with
the reference. L2 remaining stopped during either upstream phase is expected.

| Observation | Interpretation / next action |
|-------------|------------------------------|
| Increasing Dogecoin height or L1 processed ranges/replay positions | Keep waiting; the upstream is doing work |
| Dogecoin RPC warming up, with index-loading logs | Wait for loading; it is not downloading blocks yet |
| One unchanged sample without errors | Not enough to diagnose a stall; sample again and check whether the upstream tip moved |
| Repeated errors, growing restart count or no processing progress over several observations while behind | Inspect logs, peers, disk space and RPC access; see Troubleshooting below |
| Helper reports checkpoint hash mismatch | It has stopped for a consistency failure, not normal lag; investigate before restarting downstream |

`docker compose ps -a` shows stopped/restarting containers. To inspect restart
counts without modifying anything:

```bash
docker compose ps -aq | xargs -r docker inspect \
  --format '{{.Name}} status={{.State.Status}} restarts={{.RestartCount}}'
```

### Changing Data

Services depend on each other as Dogecoin → L1 Interface → L2Reth. Before
replacing, resetting, or rolling back the data of any service, stop it and
every service that depends on it, then start them again. In particular, never
replace L1 Interface data while L2Reth is running: rollup-node treats a lower
L1 Interface head as an L1 reorg and unwinds L2 state. The snapshot and reset
scripts follow this rule; see [Snapshots and Recovery](snapshots.md).

### Stop Services

```bash
docker compose down
```

Shutdown keeps all chain data; it lives under `DATA_ROOT`.

## Troubleshooting

- **L1 Interface restarts with `RPC error -28: Loading block index...`:**
  Dogecoin is still starting. Let index loading finish; L1 Interface retries
  automatically.
- **L1 Interface restarts repeatedly after Dogecoin data was restored:** the
  restored Dogecoin node is behind the height L1 Interface had indexed. It
  recovers once Dogecoin catches up; no data reset is needed.
- **L1 Interface health returns HTTP 503:** `historical_sync=in_progress` is
  expected during startup. Follow the logs until `/health` returns HTTP 200.
- **Ethereum RPC returns plan or unsupported-chain errors:** the provider must
  permit Ethereum mainnet and `eth_getBlockByHash`. Set `DOGEOS_ETHEREUM_RPC_URL` in
  `.env` to a provider that does and run `python3 scripts/snapshot-group.py start`.
- **L2Reth stays at `Waiting for L1 interface`:** the entrypoint waits for an
  `eth_chainId` HTTP success and HTTP 200 from `/api/v1/health/ready` in the
  same retry cycle. Connection failures, timeouts, and other readiness status
  codes keep L2Reth waiting; checks repeat every 5 seconds. Check L1 Interface
  health and logs.
- **L2Reth logs repeated `failed to fetch ... block` errors:** its data is
  ahead of L1 Interface, for example after restoring a newer L2Reth snapshot.
  It continues once L1 Interface catches up.
- **L2Reth exits with code 70 and restarts:** expected after the authorized
  signer in the L1 system contract rotates. L2Reth always runs with
  `--consensus.exit-on-signer-rotation`, which exits so that the restart reads
  the new signer. Under your own orchestrator, keep a restart-always policy
  and do not treat a single exit 70 as a crash.
- **`net_peerCount` is `0x0`:** confirm every enode hostname resolves, the P2P
  port is reachable over TCP and UDP, and `L2RETH_NETWORK_ID` matches the
  peers.
- **An env edit has no effect:** `docker compose restart` keeps the old
  environment; apply changes with `python3 scripts/snapshot-group.py start`
  in a maintenance window. For changed secret contents, follow
  [Dogecoin RPC Credentials](#dogecoin-rpc-credentials).
- **Snapshot checksum fails:** the script exits without extracting the newly
  downloaded archive. Run the restore command again: on that next run it moves
  the bad cached archive to an `.invalid-<timestamp>` filename and downloads a
  fresh copy. Do not bypass the check.

## Data Storage

| Service | Location |
|---------|----------|
| L2Reth | `${DATA_ROOT}/l2reth` |
| L1 Interface | `${DATA_ROOT}/l1-interface` |
| Dogecoin | `${DATA_ROOT}/dogecoin` |
| Snapshot downloads | `${DATA_ROOT}/.snapshot-cache` |

Keep `DATA_ROOT` on a mounted data disk outside the repository; all three
services store their data there.
