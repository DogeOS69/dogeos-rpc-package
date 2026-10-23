# Operations

Configuration, security, and maintenance for a running stack. Run every
command inside the network's directory (`testnet/` or `mainnet/`); Docker
Compose and the scripts read `.env` there. Examples use testnet.

## Configuration

`.env` in the network directory is the only file you edit. Create it from
`env.example` in the same directory; that template lists every setting with
its default. Keep it private (`chmod 600 .env`) and in your configuration
backups. Everything else in the network directory (`docker-compose.yml`,
`config/`, `scripts/`) is maintained by this package.

Testnet and mainnet share nothing. Run one network per host; their default
internal ports overlap.

`docker compose restart` does not reload settings. After changing `.env`, apply
it with:

```bash
docker compose up -d
```

Compose recreates only the services whose configuration changed.

<details>
<summary>Existing testnet nodes with <code>.env.testnet</code></summary>

Earlier releases kept the settings in `.env.testnet` in the repository root
and ran Compose there. Move the file once; the containers, the Dogecoin
volume, and `DATA_ROOT` stay the same:

```bash
mv .env.testnet testnet/.env
cd testnet
docker compose up -d
```

A `.env` in the repository root left by very old releases is no longer used
and can be removed.

</details>

### Dogecoin RPC Credentials

`DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD` are passed to `dogecoin-node`
and `l1-interface` as Docker secrets; do not put them in `dogecoin.conf`.
Supported characters are letters, digits, and `._~:@%+=,-`. Testnet keeps the
earlier package's public defaults (`doge`/`password`) for compatibility;
mainnet requires a password before the first start. Changing them recreates
both services, and every external consumer of the Dogecoin RPC must update.

### Custom Ethereum RPC

Testnet uses `https://ethereum-sepolia-rpc.publicnode.com` by default. To use
another provider, set in `.env`:

```bash
DOGEOS_ETHEREUM_RPC_URL=https://your-sepolia-execution-rpc
```

The provider must support Sepolia (chain ID `11155111`) and execution methods
including `eth_getBlockByHash`. Apply it with `docker compose up -d`.

Earlier releases set overrides in `envs/testnet/l1-interface.local.env` in the
repository root. On testnet that file is still read but deprecated: move its values to `.env`
(`DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` becomes `DOGEOS_ETHEREUM_RPC_URL`,
`DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL`/`__USER`/`__PASS` become
`DOGEOS_EXTERNAL_DOGECOIN_RPC_URL`/`_USER`/`_PASSWORD`) and delete it. Settings in
`.env` win.

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
docker compose stop l2reth-node dogecoin-node
docker compose up -d --force-recreate l1-interface
docker compose up -d l2reth-node
```

Targeted startup does not start the bundled Dogecoin node; its data is kept
for switching back. To return to it, remove the three settings and run:

```bash
docker compose stop l2reth-node
docker compose up -d dogecoin-node
docker compose up -d --force-recreate l1-interface
docker compose up -d l2reth-node
```

</details>

## Network Security

The package is built for RPC providers that serve L2Reth through their own
gateway or load balancer. Only these ports need to be internet-reachable:

- L2Reth HTTP/WebSocket, through your gateway
- Dogecoin P2P: `44556` on testnet, `22556` on mainnet
- L2Reth P2P: `${L2_P2P_PORT}` TCP and UDP

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
already set by the network's `scripts/l2reth_entrypoint.sh`; `rollup-node`
exits on duplicates. Recreate
`l2reth-node` after changing these values.

### Load Balancer Health

`eth_syncing` alone is not enough to decide whether to route traffic to a
node. Compare its `eth_blockNumber` with a reference node or your other
backends, and remove a node that falls more than a few blocks behind.

## Service Endpoints

| Endpoint | Address | Exposure |
|----------|---------|----------|
| L2Reth HTTP RPC | `http://<host>:${L2_HTTP_PORT}` | Public, behind your gateway |
| L2Reth WebSocket | `ws://<host>:${L2_WS_PORT}` | Public, behind your gateway |
| L2Reth metrics | `http://127.0.0.1:${L2_METRICS_PORT}/` (default `6060`) | Prometheus; this host only |
| Dogecoin RPC | `http://localhost:${DOGECOIN_RPC_PORT}` | Internal |
| L1 Interface RPC | `http://localhost:8547` | Internal (L1 client for L2Reth) |
| L1 Interface health | `http://localhost:9090/health`, `/api/v1/health/ready` | Internal |

Default ports per network are listed in each network's `env.example`;
set them in `.env` to change the host ports.
Internal ports follow `INTERNAL_BIND_ADDR`: mainnet sets `127.0.0.1`; testnet
leaves it unset, which keeps publishing them on all interfaces as earlier
releases did. Set it to `127.0.0.1` unless another host needs these ports.

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

Shutdown keeps all chain data. Do not use `down -v` if you want to keep a
Dogecoin Docker volume.

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
  permit Sepolia and `eth_getBlockByHash`. Update
  `DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` and recreate `l1-interface`.
- **L2Reth stays at `Waiting for L1 interface`:** the entrypoint waits for an
  `eth_chainId` response, which L1 Interface serves only after its startup
  sync. Check L1 Interface health and logs.
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
  environment; use `up -d --force-recreate` for the affected service.
- **Snapshot checksum fails:** do not bypass the check. The script keeps the
  bad archive with an `.invalid-<timestamp>` suffix and downloads a fresh copy.

## Data Storage

| Service | Location |
|---------|----------|
| L2Reth | `${DATA_ROOT}/l2reth` |
| L1 Interface | `${DATA_ROOT}/l1-interface` |
| Dogecoin (testnet) | Docker volume `DOGECOIN_VOLUME_NAME`, in Docker's data root |
| Dogecoin (mainnet) | `${DATA_ROOT}/dogecoin` |
| Snapshot downloads | `${DATA_ROOT}/.snapshot-cache` |

Keep `DATA_ROOT` on a mounted data disk outside the repository. Where Dogecoin
keeps its data is part of each network's `docker-compose.yml`, not an operator
setting.
