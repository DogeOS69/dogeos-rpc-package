# DogeOS RPC Package: Testnet

A Docker Compose deployment of the DogeOS testnet RPC stack for RPC providers
and node operators. It runs three services, each depending on the one before
it:

- **Dogecoin** — a Dogecoin Core node.
- **L1 Interface** — indexes Dogecoin and replays Ethereum DA data; L2Reth's
  L1 endpoint.
- **L2Reth** — syncs the DogeOS L2 chain and serves Ethereum-compatible RPC.

This directory is self-contained and shares nothing with mainnet. **Run every
command in this directory.** Your settings live in one file, `.env`, created
from `env.example`; Docker Compose and the scripts read it automatically.

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 32 GB | 64 GB |
| CPU | 4 cores | 8 cores |
| Disk | 300 GB SSD | 500 GB NVMe SSD |

Default memory limits are tuned for a 64 GB host: `dogecoin-node` 24 GB,
`l2reth-node` 16 GB, `l1-interface` 2 GB. Set `L2RETH_MEM_LIMIT` in `.env`
according to your machine's memory and RPC workload; 16 GB is a default cap,
not a reservation or a value suitable for every host. Leave memory for the
other services and the operating system. In particular, lower the limits on
a 32 GB host: the default service caps total 42 GB. Dogecoin and L1 Interface
limits are adjustable with `DOGECOIN_MEM_LIMIT` and `L1_INTERFACE_MEM_LIMIT`.
Swap is disabled, so a service that exceeds its limit can be OOM-killed.

## Before You Start

Use a Linux host with Docker Engine running and Docker Compose **2.24+**.
The host scripts need Bash, Python **3.9+ with SQLite**, curl, GNU tar/coreutils,
jq and `findmnt` (util-linux). Install these with your host's package manager
before proceeding.
Your login user must be able to run Docker commands. Check:

```bash
docker compose version
docker info --format '{{.DockerRootDir}}'
python3 -c 'import sys, sqlite3; assert sys.version_info >= (3, 9); print(sys.version, "SQLite", sqlite3.sqlite_version)'
bash --version
curl --version
tar --version
stat --version
jq --version
findmnt --version
```

`tar` and `stat` should report GNU versions. Run the deployment commands below
in Bash. Allow outbound access to image registries, Dogecoin/L2 peers, Ethereum
RPC and DA sources; snapshot/bootstrap downloads also require HTTPS access.

## Quick Start

These steps are for a **new testnet node**. For an existing node, first read
[Upgrading](#upgrading) or [Snapshots and Recovery](docs/snapshots.md);
restoring a snapshot stops services and can replace data.

### 1. Configure `.env` and Storage

From the repository root, enter `testnet/` once. If already there, omit `cd`:

```bash
cd testnet
if [ ! -e .env ]; then cp env.example .env; fi
chmod 600 .env
```

Open `.env` in your editor and set:

| Setting | What to choose |
|---------|----------------|
| `DATA_ROOT` | An absolute path on your mounted SSD, outside the repository; replace `/path/to/...` |
| `L2RETH_MEM_LIMIT` | Review the default `16g` for your host, together with the other service limits above |
| `INTERNAL_BIND_ADDR` | Set `127.0.0.1` unless another trusted host needs Dogecoin/L1 RPC |
| `DOGECOIN_RPC_USER`, `DOGECOIN_RPC_PASSWORD` | Set your own credentials for a new deployment; existing deployments must coordinate credential changes with their consumers |

The template preserves the earlier public `doge`/`password` credentials and
publishes internal ports on all interfaces unless you set the bind address.
Before starting, review [Network Security](docs/operations.md#network-security)
and restrict L2 HTTP/WebSocket access to your gateway or trusted clients.

**There are two data locations on testnet:**

| Data | Location |
|------|----------|
| L2Reth, L1 Interface, snapshot download cache and restore journal | Under `DATA_ROOT` |
| Dogecoin | Docker named volume, default `dogeos-rpc-package_dogecoin_data`, stored in Docker's data directory |

Changing `DATA_ROOT` does **not** move Dogecoin data. Ensure both filesystems
have enough space. A restore needs space for compressed downloads, extracted
data and any old data kept as backups, plus room for chain growth. Check the
actual mount and free space, substituting your chosen data path:

```bash
findmnt -T /your/mounted/data/path
df -h /your/mounted/data/path
DOCKER_DATA_DIR=$(docker info --format '{{.DockerRootDir}}')
df -h "$DOCKER_DATA_DIR"
# Validate .env and package configuration without starting services:
docker compose config --quiet
```

If Docker's data directory requires root access, run that `df` with `sudo`.
For an existing volume, `docker volume inspect VOLUME_NAME` shows its mount
location. Keep existing project/volume names: changing them can create a new,
empty Dogecoin volume. See [Data Storage](docs/operations.md#data-storage).

### Initialize P2P Identity

Before any snapshot restore or startup, generate a persistent key or migrate
an existing node's key:

```bash
python3 scripts/p2p-identity.py init
```

The key lives at `${DATA_ROOT}/l2reth-identity/discovery-secret`, outside
replaceable chain data; `L2RETH_P2P_KEY_FILE` can select a different private
file. Back it up securely. Existing nodes must migrate their original identity
before replacing any data. See [P2P Identity](docs/p2p-identity.md) for import
and migration instructions.

To request allowlisting before the first sync, follow
[Collect Information for Operations](docs/p2p-identity.md#collect-information-for-operations):
use Geth's standard `devp2p key to-enode` command to read the public key, confirm
fixed outbound IPs/CIDRs from your host and NAT configuration, and submit the
public key/CIDRs to DogeOS operations. A single fixed IPv4 is submitted as `/32`.
The guide includes the exact commands and an alternative using the running
node's native log/IPC API. Outbound CIDRs are not node settings in `.env`;
a public inbound endpoint is optional and separate from outbound allowlisting.

### 2. Check the Ethereum RPC

The default upstream is Ethereum **Sepolia**, chain ID `11155111`, at
`https://ethereum-sepolia-rpc.publicnode.com`. It supplies L1 Interface's DA
reads; it is different from the DogeOS RPC that you will serve.
To change it, set `DOGEOS_ETHEREUM_RPC_URL` in `.env` and follow
[Custom Ethereum RPC](docs/operations.md#custom-ethereum-rpc). The provider must
support execution methods including `eth_getBlockByHash`, and the historical
data required by this network.

### 3. Choose Snapshots or Sync from Scratch

**Without snapshots:** skip directly to step 4. This does not access the
snapshot catalog. All three services can start without runtime snapshots;
L1 Interface still downloads the package's pinned testnet history bootstrap.
Initial synchronization can take a long time.

**With snapshots:** first list the available groups:

```bash
python3 scripts/snapshot-group.py list
```

Each group shows its components (or `absent`), capture times, checkpoint
heights, download/extracted sizes and compatibility with your `.env` and
package configuration. Choose a group marked `MATCH`, preferably with all
three components for a fresh node. `MATCH` checks release identity, images and
upstream configuration; it does not guarantee sufficient disk space or that
existing data can be replaced. Heights belong to different chains and cannot
be compared across services.

Replace `GROUP_ID` with the selected ID:

```bash
python3 scripts/snapshot-group.py restore GROUP_ID --no-start
```

A group may omit any component; the omitted service uses eligible existing
data or initializes normally. Nothing is borrowed from another group. If
retaining an existing populated Dogecoin volume, choose a group **without a
Dogecoin snapshot**. Do not use `--force` as part of a fresh installation.
The catalog must use schema 2; an empty/unavailable catalog does not prevent
an intentional no-snapshot startup. A failed restore, checksum error or
incompatible group must be resolved; do not bypass it by deleting the restore
journal. See [restore failure recovery](docs/snapshots.md#restore-order-and-service-dependencies).

### 4. Start Services and Follow Progress

Keep this foreground command running, preferably in a persistent terminal
session such as tmux on a remote host:

```bash
python3 scripts/snapshot-group.py start
```

The helper starts Dogecoin and waits for initial sync, then starts L1 Interface
and waits for historical sync and replay readiness, then starts L2Reth. It
also verifies upstream checkpoints saved by a snapshot restore. **Returning
success means L2Reth was started, not that L2 has caught up.**

In a second terminal, enter `testnet/` and watch progress:

```bash
docker compose ps -a
docker compose logs --tail=100 -f dogecoin-node l1-interface l2reth-node
```

`Waiting for ...` and retries every five seconds are expected while an
upstream service catches up; this may take hours or longer. L1/L2 being stopped
while their upstream catches up is expected. If the same error persists with
no progress, follow [Check Synchronization Progress](docs/operations.md#check-synchronization-progress)
for Dogecoin height/IBD queries, L1 indexing/replay indicators and failure clues.

Ctrl-C interrupts the helper but leaves already-started containers running;
downstream services are not automatically started. Run the same `start`
command to resume. It first stops L1 and L2, so **do not use it merely to check
status** on a serving node. A failed restore must first be retried with its
saved group ID as described in the recovery guide.

Use this helper for cold startup and recovery. Plain `docker compose up -d`
and Docker daemon auto-restart do not run its host-side checkpoint sequence.

Once L2Reth has initialized P2P, verify its identity against the public key
you submitted (or collect it now if you skipped the offline query):

```bash
docker compose logs --no-color l2reth-node | grep 'P2P networking initialized'
```

The 128 hex characters between `enode://` and `@` are the P2P public key to
submit to DogeOS operations, together with your confirmed outbound CIDRs.
The enode IP is not proof of the outbound source IP. Wait for IP/public-key
allowlisting before expecting peers and completing RPC verification.
See [Collect Information for Operations](docs/p2p-identity.md#collect-information-for-operations)
for CIDR confirmation, log availability and the local API alternative.

### 5. Verify Services

Check L1 startup and replay readiness (adjust the host if you changed its bind
address; these health ports are fixed by the package):

```bash
curl --fail http://localhost:9090/health
curl --fail http://localhost:9090/api/v1/health/ready
```

Both should return HTTP 200: `/health` should report `status=ready` and
`historical_sync=completed`; the readiness endpoint should report `ready=true`.
A growing L2 block height alone is not proof that the node is ready for users.
Follow [Verify Your RPC Node](docs/verify-node.md) to check the chain ID, sync
status, peers, head lag and a common block hash against a trusted DogeOS
reference RPC **before routing traffic**. The default reference is
`https://rpc.testnet.dogeos.com`; run `python3 scripts/verify-rpc.py` for three
checks over at least one minute. Keep monitoring head lag afterwards.

## Everyday Operations

Run these in `testnet/` with the same `.env`:

```bash
# Status and recent logs (does not restart anything)
docker compose ps -a
docker compose logs --tail=100 l2reth-node
# Stop the stack, keeping its data
docker compose stop l2reth-node l1-interface dogecoin-node
# Start again with dependency checks
python3 scripts/snapshot-group.py start
```

After editing `.env`, use `start` during a maintenance window to apply changes;
`docker compose restart` does not reload the configuration.

## Upgrading

Follow the [changelog](CHANGELOG.md): each entry states the commands to run.
Keep your `.env`, project name, Dogecoin volume, and RPC credentials. Nodes set
up before the per-network directories (with `.env.testnet` in the repository
root) move once, as the changelog describes. Nodes still on the v0.2.x package
start with the archived [v0.3.0 upgrade guide](docs/history/upgrade-v0.3.0.md).

## Documentation

- [Verify Your RPC Node](docs/verify-node.md) — checks before serving traffic
- [P2P Identity and Allowlisting](docs/p2p-identity.md) — setup, migration and public information for operations
- [Operations](docs/operations.md) — configuration, security, endpoints,
  maintenance, troubleshooting, data storage
- [Snapshots and Recovery](docs/snapshots.md) — restoring snapshots, resetting
  and recovering data
- [Snapshot Publishing](docs/snapshot-publishing.md) — index format and
  publishing process (for the team that publishes snapshots)
- [Changelog](CHANGELOG.md)

For package contributors, `./scripts/check.sh` checks shell scripts, Compose
configuration, fixed L1 data layout, documentation
links and offline snapshot/restore behavior. CI runs it on every pull request.

## Components

| Service | Image | Source |
|---------|-------|--------|
| `dogecoin-node` | `dogeos69/dogecoin:1.14.9` | Dogecoin Core 1.14.9 |
| `l1-interface` | `dogeos69/l1-interface:v0.3.0-beta.3d` | DogeOS L1 Interface v0.3.0-beta.3d |
| `l2reth-node` | `dogeos69/rollup-node:v0.3.0-beta.1c` | DogeOS69/dogeos-rollup-node `d3260afe` |

Service behavior described in this documentation (health endpoints, startup
ordering, L1 reorg handling) was checked against these versions.

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Services, images, ports, data layout, and the one-time download of the pre-v0.3.0 testnet history for L1 Interface |
| `env.example` | Template for your `.env` |
| `config/` | Chain and service configuration, maintained by the package: `dogecoin.conf`, `l2reth-genesis.json`, `protocol_context.json`, `l2reth.env` (peers, P2P network ID, L1 endpoint, blob archive), `l1-interface.env` |
| `scripts/` | Service entrypoints (including the L2Reth flags for this version), `snapshot-group.py` (group selection, restore and ordered startup), `restore-snapshot.sh`, `reset-chain-data.sh`, `add-l2reth-peer.sh`, `check.sh` |
| `docs/` | Operations, snapshots and recovery, snapshot publishing, history |
| `CHANGELOG.md` | What changed and what operators must do |
