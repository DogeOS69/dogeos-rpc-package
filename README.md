# DogeOS RPC Package

A Docker-based deployment of the DogeOS RPC stack for node and RPC operators. It runs a Dogecoin node, the L1 Interface, and an L2Reth client.

## What's New in v0.3.0

v0.3.0 is a major upgrade from the v0.2.x line. Key changes for operators:

- **Data Availability moved from Celestia to Ethereum.** The DA layer is now Ethereum-based. L2Reth reads blobs directly from the public S3 archive; L1 Interface uses the bundled public Ethereum Sepolia execution RPC for replay unless the operator overrides it. No Celestia node is run.
- **L1 Interface storage format is not backward compatible with v0.2.x.** When migrating from v0.2.x, start it with fresh data; an init step downloads the pre-v0.3.0 history from S3 automatically. The configuration, container, and data steps in the [upgrade guide](upgrade_v0.3.0.md) apply to that migration.
- **L2Reth is now the only supported L2 client.** The old package defaulted to L2Geth. Existing L2Geth operators must switch to L2Reth using its snapshot or a fresh sync; L2Geth databases cannot be reused as Reth databases.
- **No L2 history break.** From L2Reth's perspective the block history is continuous across the upgrade. A brand-new L2Reth node syncing from genesis will sync through and catch up to the chain head normally.

> [!NOTE]
> L2 chain history remains continuous, but that does not establish database
> compatibility between client versions. L2Reth storage also moved from a
> named Docker volume to `${DATA_ROOT}/l2reth`; old volumes are not migrated
> automatically. These migration steps apply to nodes upgrading from v0.2.x;
> see the [v0.3.0 upgrade guide](upgrade_v0.3.0.md).

## Upgrading an Existing Node

For an existing **v0.3.0 testnet deployment**, follow the release notes for
the target update. The [Galileo, Galileo V2, and Tsuki hardfork activation notes](release_notes_l2reth_v0.3.0-beta.1c.md)
cover the latest image and chain configuration update: pull the new image and
recreate only `l2reth-node`, retaining its existing data. Dogecoin and
L1 Interface do not need to be restarted.

For historical v0.2.x deployments, follow
[Upgrading from v0.2.x to v0.3.0](upgrade_v0.3.0.md) **before pulling new code**.
That migration requires stopping the old stack with its old Compose file and
completing the documented data and configuration steps.

The Quick Start below is for a new installation.

## Services

The stack runs three services:

- **Dogecoin** stores and syncs Dogecoin chain data in a named Docker volume.
- **L1 Interface** indexes Dogecoin and replays Ethereum DA data. It initializes
  its historical data automatically on first start.
- **L2Reth** syncs the DogeOS L2 chain and serves Ethereum-compatible RPC.

L2Reth and L1 Interface store their data under the `DATA_ROOT` you configure.
The package includes the testnet network settings and peer addresses. On
mainnet, the values that are not public yet come from operator onboarding; see
[Mainnet Follower](#mainnet-follower).

L2Reth runs as a follower with `--consensus.exit-on-signer-rotation`. When the
sequencer signer rotates on L1, the node logs
`authorized signer rotated on L1; exiting for supervised restart` (with
`exit_code=70`) and shuts down with exit code 70. Docker restarts it
(`restart: unless-stopped`), and the restarted node reads the new signer from
L1. Docker clears the exit code once the container runs again, so the log line
is the record of a rotation restart.

The node reads the signer from L1 Interface about every 12 seconds and exits
only after three successful reads in a row return the same new signer; failed
reads in between are skipped. With working reads, that is roughly 25 to 40 seconds after
L1 Interface first returns the new signer. Failed reads never cause an exit:
while L1 Interface is unreachable, L2Reth keeps running with the old signer and
logs a warning after every 25 failed reads in a row. The node reads its signer
once at startup, and the check starts from its own first successful read a
moment later. A rotation that lands between those two reads is missed: the node
keeps the old signer and does not exit until a later rotation. Restarting
L2Reth picks up the new signer, without the rotation log line.

The same policy brings a running L2Reth back after a host or Docker restart. A
container stopped with `docker compose stop` stays stopped, and
`docker compose down` removes it. An existing container keeps its old restart
policy and shutdown time until it is recreated with
`docker compose --env-file .env.testnet up -d --no-deps l2reth-node`, which
briefly interrupts L2 RPC; `docker compose restart` does not apply them.

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
| dogecoin-node | 24 GB | Largest consumer; RSS grows over time |
| l2reth-node | 8 GB | RSS grows with RPC traffic |
| l1-interface | 2 GB | Lightweight; higher usage during startup |

Memory limits can be adjusted in `.env.testnet` with `DOGECOIN_MEM_LIMIT`,
`L2RETH_MEM_LIMIT`, and `L1_INTERFACE_MEM_LIMIT`. Keep the default Dogecoin
limit unless you have measured its startup and steady-state requirements.
Leave memory available for the host and other services.

Container swap is disabled. A service that exceeds its memory limit can be
OOM-killed.

## Quick Start

The commands below are for testnet. For mainnet, follow
[Mainnet Follower](#mainnet-follower).

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

Docker starts L2Reth and L1 Interface again when the host boots
(`restart: unless-stopped`), so the data disk must be mounted before Docker
starts; otherwise they can start on an empty directory on the root disk. Mount
the disk at boot (for example through `/etc/fstab`) and make Docker wait for it
with `sudo systemctl edit docker.service`, using your disk's mount point:

```ini
[Unit]
RequiresMountsFor=/data
```

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

## Mainnet Follower

Mainnet is private. The package includes the public mainnet pieces: the L2
genesis (chain ID `1122005`), the mainnet L2Reth settings, and the L2Reth image
`dogeos69/rollup-node:v0.3.0-beta.2`, set by `L2RETH_IMAGE_TAG` in
`.env.example.mainnet`. Values that are not public yet are left empty or set to
`provided-at-onboarding`; operators receive them at onboarding. The stack does
not start until they are filled in. Do not use testnet data or settings for
mainnet.

1. Create the Compose env file:

   ```bash
   if [ ! -e .env.mainnet ]; then cp .env.example.mainnet .env.mainnet; fi
   chmod 600 .env.mainnet
   ```

   Set `DATA_ROOT` and the Dogecoin RPC credentials as in
   [Quick Start step 1](#1-configure-the-compose-environment), and the
   onboarding values for `L1_INTERFACE_IMAGE_TAG`, `L1_INTERFACE_ARTIFACT_URL`,
   and `L1_INTERFACE_REPLAY_DB_URL`. If you already run a mainnet Dogecoin node
   from this package, keep your `.env.mainnet`, project name, and Dogecoin
   volume, and add the "Image Tags and Bootstrap Artifacts" settings from the
   template.

2. Put the other onboarding values in gitignored override files, so they stay
   out of tracked files:

   | File | Settings |
   |------|----------|
   | `envs/mainnet/l2reth.local.env` | `L2RETH_PEER_LIST`, `L2RETH_NETWORK_ID`, `L2RETH_BLOB_S3_URL`, and optionally `L2RETH_SEQUENCER_URL` |
   | `envs/mainnet/l1-interface.local.env` | Every empty setting in `envs/mainnet/l1-interface.env`, including your own Ethereum mainnet execution RPC in `DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` |

   ```bash
   chmod 600 envs/mainnet/l2reth.local.env envs/mainnet/l1-interface.local.env
   ```

   Replace `configs/mainnet/protocol_context.json` with the protocol context
   from onboarding. It is a tracked file that package updates may change, so
   keep a copy.

3. Check the configuration and start the stack:

   ```bash
   docker compose --env-file .env.mainnet config --quiet
   docker compose --env-file .env.mainnet up -d
   ```

   No mainnet snapshots are published, so L2Reth syncs from genesis. Verify the
   services as in [Quick Start step 5](#5-verify-services), using
   `.env.mainnet` and the mainnet L2 HTTP port (`18545` by default).

L2Reth runs with `--consensus.exit-on-signer-rotation` on mainnet too, and the
restart behaviour under [Services](#services) applies unchanged.

## Service Endpoints

- **Dogecoin RPC**: `http://localhost:${DOGECOIN_RPC_PORT}` (`44555` on testnet, `22555` on mainnet)
- **L1 Interface RPC**: `http://localhost:8547` (L1 Ethereum client for L2Reth)
- **L1 Interface Health**: `http://localhost:9090/health`
- **L2Reth HTTP RPC**: `http://localhost:${L2_HTTP_PORT}` (`8545` by default on testnet, `18545` on mainnet)
- **L2Reth WebSocket**: `ws://localhost:${L2_WS_PORT}` (`8546` by default on testnet, `18546` on mainnet)

## Network Security

Compose currently publishes service ports on all host interfaces. Do not expose
Dogecoin RPC, L1 Interface RPC/health, or L2Reth HTTP/WebSocket directly to the
public internet. L2Reth exposes powerful `debug` and `trace` methods, and the
Dogecoin credentials are stored only in the Git-ignored local Compose env, but
RPC authentication is not a substitute for network isolation.

Use host/cloud firewalls, a private network or VPN, and an authenticated reverse
proxy where remote RPC access is required. Normally only the intended P2P ports
should be internet-reachable:

- Dogecoin P2P: `${DOGECOIN_P2P_PORT}` (`44556` on testnet, `22556` on mainnet)
- L2Reth P2P: `${L2_P2P_PORT}` TCP and UDP (`30303` by default on testnet, `40303` on mainnet)

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
credentials unchanged when upgrading an existing node. Mainnet uses
`.env.mainnet` and the files listed in [Mainnet Follower](#mainnet-follower).

On testnet, use the supplied genesis, protocol context, and peer settings. No
configuration generation or entrypoint-script edits are required for normal
operation.

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

### Restart Monitoring

Docker restarts L2Reth after every exit except a manual stop or kill
(`docker compose stop`, `down` or `kill`), so a node that keeps failing never
stays down on its own. A signer rotation
exits with code 70 (see [Services](#services)). A running node that finishes
shutting down after `docker compose stop` or a host shutdown exits with code 0;
after a host shutdown, Docker starts it again at boot. Exit 137 means Docker
killed the process: an out-of-memory kill, a stop while the node still waits for
L1 Interface, or a stop that outlasts the 30-second grace period. Any other
exit, and a 137 you did not cause by stopping the node, is a failure. Docker
resets its restart back-off after a run of 10 seconds or more, so a node that
fails later than that restarts again right away, without end.

```bash
# Restarts since the container was last started by hand, recreated, or
# started by a Docker daemon start. oom=true means the last exit was an
# out-of-memory kill; Docker clears it when the container starts again.
docker inspect -f '{{.RestartCount}} oom={{.State.OOMKilled}}' \
  "$(docker compose --env-file .env.testnet ps -q l2reth-node)"

# Each exit (die, with its code) and out-of-memory kill (oom) as it happens
docker events --filter event=die --filter event=oom \
  --filter container="$(docker compose --env-file .env.testnet ps -q l2reth-node)" \
  --format '{{.Time}} {{.Action}} exitCode={{.Actor.Attributes.exitCode}}'
```

Alert when the restart count rises by 3 or more within 30 minutes, on any `oom`
event, or on any exit other than 70 that you did not request. Also compare the
node's head with an RPC you trust (the block number and the block hash at that
height): this catches a node that keeps running but stops syncing.

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
- **L2Reth keeps restarting, and the exits are not the signer-rotation log line
  (code 70):** run `docker compose --env-file .env.testnet stop l2reth-node`; it
  stays down across reboots. Save the logs with
  `docker compose --env-file .env.testnet logs --since 2h l2reth-node > l2reth-node.log`
  and look for `fail-stopping`, `Fatal error in consensus engine`,
  `panicked at`, or `genesis hash in the storage does not match`. Do not reset
  or restore data until someone has read them.
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
