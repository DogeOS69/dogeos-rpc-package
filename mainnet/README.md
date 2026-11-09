# DogeOS RPC Package: Mainnet

**Mainnet is not released and cannot currently be deployed from this directory.**
The chain configuration, production image selection and L1 initialization
procedure are not complete. Do not copy testnet configuration or snapshots
here. See the [maintainer release checklist](docs/release-readiness.md) for the
missing artifacts and validation work.

This directory is self-contained. Mainnet and testnet are intended to run on
separate hosts; if you run both on one host, resolve host port conflicts yourself.

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 16 GB | 32 GB |
| CPU | 4 cores | 8 cores |
| Disk | 500 GB SSD | 1 TB NVMe SSD |

Memory per service (`docker-compose.yml` defaults, adjustable in `.env`):

| Service | Typical use | Limit | Notes |
|---------|-------------|-------|-------|
| `dogecoin-node` | about 3–4 GB (4 GB reserved) | 8 GB | Block index for every block (~1.6 GB at 6.5M blocks), dbcache 450 MB, mempool up to 300 MB; the limit covers startup and catch-up peaks |
| `l2reth-node` | grows with RPC traffic | 16 GB | Set `L2RETH_MEM_LIMIT` in `.env` to suit your machine and RPC workload; tracing calls use the most |
| `l1-interface` | small; more during startup | 2 GB | |

Set `L2RETH_MEM_LIMIT` in `.env` according to your machine's available memory
and RPC workload. The 16 GB default is a cap, not a reservation. Leave memory
for Dogecoin, L1 Interface, the operating system, and other services. On a
16 GB host, lower the limits before starting: the default service caps total
26 GB. A service that exceeds its limit can be OOM-killed (swap is disabled).

Disk: the Dogecoin mainnet chain alone is about 170 GiB of blocks (October
2026), roughly 200–250 GB with undo data, chain state, and the transaction
index, and it keeps growing. L2Reth and L1 Interface data start small. A
snapshot restore needs room for the downloaded archive and the extracted data
at the same time. Keep `DATA_ROOT` on an SSD.

## Deployment Workflow After Release

The following is the intended workflow **after the release checklist is
complete**. It is not a runnable mainnet installation today.

### Prerequisites

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

### Configure and Check Storage

From the repository root, enter `mainnet/` once (omit `cd` if already there):

```bash
cd mainnet
if [ ! -e .env ]; then cp env.example .env; fi
chmod 600 .env
```

Edit `.env`: set `DATA_ROOT` to an absolute directory on your mounted SSD,
set a nonempty `DOGECOIN_RPC_PASSWORD`, review all memory limits for your host,
and configure the Ethereum RPC required by the mainnet release.
Keep `INTERNAL_BIND_ADDR=127.0.0.1` unless trusted remote consumers need access.
Review [Network Security](docs/operations.md#network-security) before starting.

All three services use bind data under `DATA_ROOT`: `dogecoin/`,
`l1-interface/`, and `l2reth/`. Snapshot cache and restore metadata also live
there. Docker still needs space for images and logs in its own data directory.
Check your chosen data mount and free space before restoring:

```bash
findmnt -T /your/mounted/data/path
df -h /your/mounted/data/path
docker info --format '{{.DockerRootDir}}'
docker compose config --quiet
```

Allow room for downloaded archives, extracted data, retained backups and chain
growth. The configuration check must pass before continuing; it fails in the
current unreleased checkout because release configuration files are missing.

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

### Choose a Recovery Source

For a new node, prefer a compatible group containing all three components:

```bash
python3 scripts/snapshot-group.py list
# Replace GROUP_ID with a group marked MATCH after reviewing components/sizes.
python3 scripts/snapshot-group.py restore GROUP_ID --no-start
```

Groups can omit any component. The list checks metadata and, when `.env`
exists, local release identity/images/upstream configuration; `MATCH` does not
check disk space or whether existing data can be replaced. Without `.env`,
compatibility is `NOT CHECKED`.

To use **no runtime snapshots**, skip both commands and follow the mainnet
fresh-genesis initialization procedure supplied with the release. That procedure
is still a release blocker in this checkout: the placeholder L1 image needs
an existing replay DB. Never substitute testnet bootstrap data. A chosen
snapshot that fails validation is an error, not a reason to bypass recovery
state. See [Snapshots and Recovery](docs/snapshots.md).

### Start, Observe and Verify

```bash
python3 scripts/snapshot-group.py start
```

Keep this foreground process alive, preferably using tmux. It stops L1/L2,
waits for Dogecoin sync, then L1 historical sync/replay readiness, checks saved
checkpoints and finally starts L2Reth. Initial sync can take hours or longer.
Returning success means L2Reth has started; it does not mean L2 is caught up.
In another terminal in `mainnet/`, inspect progress without restarting:

```bash
docker compose ps -a
docker compose logs --tail=100 -f dogecoin-node l1-interface l2reth-node
```

Use [Check Synchronization Progress](docs/operations.md#check-synchronization-progress)
to inspect Dogecoin height/IBD and L1 indexing/replay progress.

After Ctrl-C, already-started containers keep running; re-run `start` to resume.
It stops downstream services again, so do not use it as a status command.
If restore failed, first [retry the saved group](docs/snapshots.md#restore-order-and-service-dependencies).
Plain Compose startup and daemon auto-restart do not run the helper's host-side
checkpoint sequence.

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

Follow [Verify Your RPC Node](docs/verify-node.md) before routing traffic.
The mainnet reference RPC is not published yet; no default is configured.
Default L2 host ports are HTTP `8545`, WebSocket `8546`, P2P `30303`;
Dogecoin P2P is `22556`, RPC `22555`.

### Stop and Upgrade

```bash
docker compose stop l2reth-node l1-interface dogecoin-node
# Start again, preserving data and using dependency checks:
python3 scripts/snapshot-group.py start
```

Follow the [changelog](CHANGELOG.md) for upgrades. Preserve `.env` and data.
Apply `.env` changes with `start` in a maintenance window;
`docker compose restart` does not reload settings.

## Documentation

- [Release Readiness](docs/release-readiness.md) — maintainer checklist
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
configuration (with missing release files stubbed), fixed L1 data layout, documentation
links and offline snapshot/restore behavior. CI runs it on every pull request.
