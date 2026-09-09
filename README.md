# DogeOS RPC Package

A Docker-based deployment of the DogeOS RPC stack for node and RPC operators. It runs a Dogecoin node, the L1 Interface, and an L2Reth client.

## What's New in v0.3.0

v0.3.0 is a major upgrade from the v0.2.x line. Key changes for operators:

- **Data Availability moved from Celestia to Ethereum.** The DA layer is now Ethereum-based. L2Reth reads blobs directly from the public S3 archive; L1 Interface uses the bundled public Ethereum Sepolia execution RPC for replay unless the operator overrides it. No Celestia node is run.
- **L1 Interface storage format is not backward compatible with v0.2.x.** Start it with fresh data; an init step downloads the pre-v0.3.0 history from S3 automatically. Existing deployments still require the configuration, container, and data steps in the [upgrade guide](upgrade_v0.3.0.md).
- **L2Reth is now the only supported L2 client.** The old package defaulted to L2Geth. Existing L2Geth operators must switch to L2Reth using its snapshot or a fresh sync; L2Geth databases cannot be reused as Reth databases.
- **No L2 history break.** From L2Reth's perspective the block history is continuous across the upgrade. A brand-new L2Reth node syncing from genesis will sync through and catch up to the chain head normally.

> [!NOTE]
> L2 chain history remains continuous, but that does not establish database
> compatibility between client versions. L2Reth storage also moved from a
> named Docker volume to `${DATA_ROOT}/l2reth`; old volumes are not migrated
> automatically. Follow the [v0.3.0 upgrade guide](upgrade_v0.3.0.md) for an
> existing node.

## Upgrading an Existing Node

For a deployment running the old `main` / v0.2.x package, follow
[Upgrading from v0.2.x to v0.3.0](upgrade_v0.3.0.md) **before pulling the new
code or copying a new env template**. It covers stopping the old Compose
project, retaining Dogecoin data and credentials, switching from L2Geth or
older L2Reth, initializing fresh L1 Interface data, and verifying the upgrade.

The procedure supports **testnet only**. It requires a maintenance window;
neither `git pull` followed by `up` nor the snapshot script alone migrates the
old deployment. Stop the old stack with its old Compose file **before
`git pull`**, because the new version removes old services. The Quick Start
below is for a new installation.

## Services

The testnet stack runs three services:

- **Dogecoin** stores and syncs Dogecoin chain data in a named Docker volume.
- **L1 Interface** indexes Dogecoin and replays Ethereum DA data. It initializes
  its historical data automatically on first start.
- **L2Reth** syncs the DogeOS L2 chain and serves Ethereum-compatible RPC.

L2Reth and L1 Interface store their data under the `DATA_ROOT` you configure.
The package includes the testnet network settings and peer addresses.

## Hardware Requirements

### Minimum Specifications (Testnet)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 32 GB | 64 GB |
| CPU | 4 cores | 8 cores |
| Disk | 300 GB SSD | 500 GB NVMe SSD |

### Memory Limits

Each service has a default memory limit configured in `docker-compose.yml`. The defaults are tuned for a **64 GB** host:

| Service | Default Limit | Notes |
|---------|--------------|-------|
| dogecoin-node | 20 GB | Largest consumer; RSS grows over time |
| l2reth-node | 8 GB | RSS grows with RPC traffic |
| l1-interface | 2 GB | Lightweight; higher usage during startup |

Memory limits can be adjusted in `.env.testnet` with `DOGECOIN_MEM_LIMIT`,
`L2RETH_MEM_LIMIT`, and `L1_INTERFACE_MEM_LIMIT`. Keep the default Dogecoin
limit unless you have measured its startup and steady-state requirements.
Leave memory available for the host and other services.

Container swap is disabled. A service that exceeds its memory limit can be
OOM-killed.

## Quick Start

The commands below are for testnet. Do not substitute `.env.mainnet`: the
current release does not ship a complete full-stack mainnet configuration.
See [Mainnet status](#mainnet-status) before using the mainnet templates.

### 1. Configure the Compose Environment

Copy the testnet template and review the stable Dogecoin RPC credentials,
`DATA_ROOT`, ports, memory limits, and the Dogecoin volume name:

```bash
if [ ! -e .env.testnet ]; then cp .env.example.testnet .env.testnet; fi
# REQUIRED: fill in DATA_ROOT; review credentials and any port/memory overrides
chmod 600 .env.testnet
```

The templates retain the old Compose project names: `dogeos-rpc-package` for
testnet and `dogeos-rpc-package-mainnet` for mainnet. Existing deployments
should keep their actual project name and Dogecoin volume name, including
any custom names; see the [upgrade guide](upgrade_v0.3.0.md).

`DATA_ROOT` uses a `/path/to/...` placeholder. Replace it with an absolute path
on your mounted data disk, outside the repository. Verify the disk mount
before starting; otherwise chain data can fill the host's root disk. For
example, use `findmnt -T /data` if your disk is mounted at `/data`.

The restore script and Compose create their data directories as needed.
`DATA_ROOT` controls L2Reth and L1 Interface storage; Dogecoin continues to use
its named Docker volume.

For compatibility with the earlier testnet package, `DOGECOIN_RPC_USER`
defaults to `doge` and `DOGECOIN_RPC_PASSWORD` defaults to `password`. Change
them once in the local `.env.testnet` if desired and keep them stable. Compose
supplies the same values to both `dogecoin-node` and L1 Interface as secrets,
so the credentials are configured only once. Supported characters are letters,
digits, and `._~:@%+=,-`. The defaults are public knowledge: never expose the
Dogecoin RPC port to an untrusted network while using them.

### 2. Check the Ethereum RPC

The package uses `https://ethereum-sepolia-rpc.publicnode.com` by default.
No extra configuration is required. If you need a different provider, follow
[Custom Ethereum RPC](#custom-ethereum-rpc) before starting the stack.

### 3. Restore the L2Reth Snapshot (Recommended for New Nodes)

If the bundled Dogecoin node has no existing chain data, first follow the
[Dogecoin testnet snapshot guide](snapshot_dogecoin_testnet.md) to restore its
chain data into a new named volume. Existing Dogecoin nodes should keep their
current volume; they do not need snapshot replacement.

For a new testnet RPC node, restore the published L2Reth database instead of
syncing from genesis:

```bash
./scripts/restore-l2reth-snapshot.sh --no-start .env.testnet
```

The script downloads the published snapshot, verifies its SHA-256 and archive
layout, and restores it to `${DATA_ROOT}/l2reth`. Downloads are resumable and
cached under `${DATA_ROOT}/.snapshot-cache`. `--no-start` leaves service startup
for the next step.

See the [testnet snapshot guide](snapshot_testnet.md#l2reth-snapshot-recommended)
for replacement and recovery options.

### 4. Start Services

Start the complete testnet stack, including the bundled Dogecoin node:

```bash
docker compose --env-file .env.testnet up -d
```

L1 Interface initializes its historical data and catches up during startup.
Allow Dogecoin to load its block index and the services to finish syncing
before returning RPC traffic.

### 5. Verify Services

Check container state and L1 Interface readiness:

```bash
docker compose --env-file .env.testnet ps -a
curl --fail http://localhost:9090/health
```

The ready response reports `"status":"ready"`. If it reports
`"historical_sync":"in_progress"`, wait and check again. Containers being
`Running` does not mean the node has finished syncing. Then verify L2Reth
using your configured HTTP port (`8545` by default):

```bash
curl --fail \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

Repeat the block-number query after a short interval to confirm it advances.

For snapshot recovery and replacement procedures, see the
[testnet snapshot guide](snapshot_testnet.md). Mainnet snapshot automation is
not available in this release; see [mainnet snapshot status](snapshot_mainnet.md).

## Mainnet Status

This release supports the complete RPC stack on **testnet only**. Mainnet
full-stack deployment and snapshots are not supported. Do not start this stack
with `.env.mainnet` or use testnet data for mainnet.

Existing mainnet operators should keep their current configuration and Dogecoin
volume. See [mainnet snapshot status](snapshot_mainnet.md).

## Service Endpoints

- **Dogecoin RPC**: `http://localhost:44555` (testnet)
- **L1 Interface RPC**: `http://localhost:8547` (L1 Ethereum client for L2Reth)
- **L1 Interface Health**: `http://localhost:9090/health`
- **L2Reth HTTP RPC**: `http://localhost:${L2_HTTP_PORT}` (`8545` by default on testnet)
- **L2Reth WebSocket**: `ws://localhost:${L2_WS_PORT}` (`8546` by default on testnet)

## Network Security

Compose currently publishes service ports on all host interfaces. Do not expose
Dogecoin RPC, L1 Interface RPC/health, or L2Reth HTTP/WebSocket directly to the
public internet. L2Reth exposes powerful `debug` and `trace` methods, and the
Dogecoin credentials are stored only in the Git-ignored local Compose env, but
RPC authentication is not a substitute for network isolation.

Use host/cloud firewalls, a private network or VPN, and an authenticated reverse
proxy where remote RPC access is required. Normally only the intended P2P ports
should be internet-reachable:

- Dogecoin P2P: `${DOGECOIN_P2P_PORT}` (`44556` on testnet)
- L2Reth P2P: `${L2_P2P_PORT}` TCP and UDP (`30303` by default)

To change the bundled Dogecoin RPC credentials, edit
`DOGECOIN_RPC_USER`/`DOGECOIN_RPC_PASSWORD` once in the local Compose env and
recreate both `dogecoin-node` and `l1-interface`. Do not edit `dogecoin.conf`:
both containers consume the same Compose Secrets at startup. Changing these
values restarts Dogecoin and also requires every external consumer to update,
so keep them stable unless a coordinated rotation is intended.

## Configuration

Edit these local files for your deployment:

| File | Settings |
|------|----------|
| `.env.testnet` | Project name, data path, Dogecoin volume and RPC credentials, ports, memory limits |
| `envs/testnet/l1-interface.local.env` | Optional Ethereum RPC or external Dogecoin RPC overrides |

Both files are gitignored. Keep them private and include them in your
configuration backups. Keep the project name, Dogecoin volume name, and RPC
credentials unchanged when upgrading an existing node.

Use the supplied genesis, protocol context, and peer settings. No configuration
generation or entrypoint-script edits are required for normal operation.

### Custom Ethereum RPC

Create the optional override file only if it does not already exist:

```bash
if [ ! -e envs/testnet/l1-interface.local.env ]; then
  cp envs/testnet/l1-interface.local.env.example envs/testnet/l1-interface.local.env
fi
chmod 600 envs/testnet/l1-interface.local.env
```

Uncomment and set this variable in that file:

```bash
DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL=https://your-sepolia-execution-rpc
```

The provider must support Sepolia (chain ID `11155111`) and execution methods
including `eth_getBlockByHash`. Keep endpoint API keys in the local override
file. If services are already running, [recreate L1 Interface](#apply-environment-changes)
to apply the change.

<details>
<summary>Advanced: use an external Dogecoin RPC</summary>

For temporary troubleshooting, set the external Dogecoin URL, user, and password
in `envs/testnet/l1-interface.local.env`, using its example file. Confirm that
the external node serves the required testnet history and is reachable from
L1 Interface before switching.

Stop the bundled node, then recreate L1 Interface and start L2Reth:

```bash
docker compose --env-file .env.testnet stop dogecoin-node
docker compose --env-file .env.testnet up -d --force-recreate l1-interface
docker compose --env-file .env.testnet up -d l2reth-node
```

To run only L1 Interface, omit the last command. Targeted startup does not start
the bundled Dogecoin node. Keep its volume for switching back.

To return to the bundled node, remove the external Dogecoin overrides, keep the
original volume and credentials in `.env.testnet`, and run:

```bash
docker compose --env-file .env.testnet up -d dogecoin-node
docker compose --env-file .env.testnet up -d --force-recreate l1-interface
docker compose --env-file .env.testnet up -d l2reth-node
```

</details>

## Maintenance

### Logs

```bash
docker compose --env-file .env.testnet logs -f [service_name]
```

Useful checks:

```bash
# L1 Interface readiness
curl --fail http://localhost:9090/health

# Established L2Reth P2P sessions (hexadecimal result)
curl --fail \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://localhost:8545
```

### Apply Environment Changes

`docker compose restart` does not reload env files. Recreate the affected
service after changing `l1-interface.local.env` or another service env file:

```bash
docker compose --env-file .env.testnet up -d --force-recreate l1-interface
```

### Troubleshooting

- **L1 Interface restarts with `RPC error -28: Loading block index...`:**
  Dogecoin is still starting. Check its logs and allow index loading to finish;
  L1 Interface retries automatically. This alone does not require a data reset.
- **L1 Interface health returns HTTP 503:** Read the response body. A status of
  `historical_sync=in_progress` is expected during startup. Follow logs until
  `/health` returns HTTP 200 and `status=ready`.
- **Ethereum RPC returns plan or unsupported-chain errors:** The configured
  provider project must permit Sepolia and `eth_getBlockByHash`. Update
  `DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL`, recreate L1 Interface, and
  confirm replay advances beyond the previous workflow transaction number.
- **L2Reth stays at `Waiting for L1 interface`:** L2Reth's entrypoint waits for
  an `eth_chainId` response from L1 Interface. Check L1 Interface health and
  logs first.
- **`net_peerCount` is `0x0`:** Confirm every enode hostname resolves, TCP/UDP
  port 30303 is reachable, and `L2RETH_NETWORK_ID` matches the remote peers.
  Configured enodes are not proof of completed devp2p handshakes.
- **An env edit appears to have no effect:** `docker compose restart` preserves
  the old container environment. Use `up -d --force-recreate` for the affected
  service.
- **Snapshot checksum fails:** Do not bypass the check. Confirm that URL and
  SHA-256 were updated together. The restore script preserves a bad cached
  archive with an `.invalid-<timestamp>` suffix and downloads a fresh copy.

### Stop Services

```bash
docker compose --env-file .env.testnet down
```

Service shutdown preserves chain data. Do not use `down -v` when you want to
keep the Dogecoin volume.

For data replacement or recovery, follow the
[testnet recovery guide](snapshot_testnet.md). Data resets are not part of a
normal shutdown or upgrade.

## Data Storage

L2Reth uses `${DATA_ROOT}/l2reth`; L1 Interface uses
`${DATA_ROOT}/l1-interface`. Dogecoin uses `DOGECOIN_VOLUME_NAME` in Docker's
volume storage, independently of `DATA_ROOT`.

Keep data outside the repository and retain the existing Dogecoin volume when
upgrading. This Compose file supports one complete stack per host; changing
only the project name and L2 ports is not sufficient to run a second stack.
