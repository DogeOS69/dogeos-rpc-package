# DogeOS RPC Package

A Docker-based deployment of the DogeOS RPC stack for node and RPC operators. It runs a Dogecoin node, the L1 Interface, and an L2Reth client.

## What's New in v0.3.0

v0.3.0 is a major upgrade from the v0.2.x line. Key changes for operators:

- **Data Availability moved from Celestia to Ethereum.** The DA layer is now Ethereum-based. L2Reth reads blobs directly from the public S3 archive; L1 Interface uses the bundled public Ethereum Sepolia execution RPC for replay unless the operator overrides it. No Celestia node is run.
- **L1 Interface storage format is not backward compatible with v0.2.x.** The pre-v0.3.0 history is supplied as S3 archive files, which an init step downloads automatically on first start, so the upgrade is seamless.
- **No L2 history break.** From L2Reth's perspective the block history is continuous across the upgrade. A brand-new L2Reth node syncing from genesis will sync through and catch up to the chain head normally.

> [!NOTE]
> Because the L1 Interface storage format changed, v0.3.0 uses fresh `l1-interface` data (the S3 archive supplies the historical data automatically). L2 client data is unaffected by the format change.

## Architecture

The project follows a modular configuration approach with support for multiple networks. The tracked, end-to-end runtime configuration is currently complete for **testnet only**. Mainnet templates are retained for operators upgrading existing Dogecoin data, but the repository does not currently include the generated mainnet L2Reth files or mainnet L1 Interface bootstrap artifacts required to start the full stack.

```
├── .env.example.mainnet        # Mainnet environment template
├── .env.example.testnet        # Testnet environment template
├── docker-compose.yml          # Main Docker Compose configuration
├── snapshot_mainnet.md         # Mainnet snapshot support status
├── snapshot_testnet.md         # Testnet snapshot and recovery guide
├── configs                     # Network-specific configuration files
│   ├── mainnet
│   │   └── dogecoin.conf        # Full mainnet stack is not shipped in this release
│   └── testnet
│       ├── dogecoin.conf
│       ├── l2reth-genesis.json
│       └── protocol_context.json
├── envs                        # Environment variables (per network)
│   ├── mainnet
│   │   ├── dogecoin.env
│   │   └── l1-interface.env     # Legacy/incomplete; do not start the full stack as-is
│   └── testnet
│       ├── dogecoin.env
│       ├── l1-interface.env
│       ├── l1-interface.local.env.example  # Template for operator overrides
│       └── l2reth.env
├── README.md
└── scripts                     # Utility scripts
    ├── dogecoin_entrypoint.sh          # Build Dogecoin config from Docker secrets
    ├── l1-interface_entrypoint.sh      # Inject bundled-node secrets into L1 Interface
    ├── prepare-data-dir.sh             # Validate local settings and prepare data directories
    ├── restore-l2reth-snapshot.sh      # One-command L2Reth snapshot restore
    └── l2reth_entrypoint.sh            # L2Reth entrypoint
```

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

To override any limit, set the corresponding environment variable in your env file, for example `.env.testnet`:

```bash
# Example: reduce the Dogecoin limit for a 32 GB host
DOGECOIN_MEM_LIMIT=16g
```

Available variables: `DOGECOIN_MEM_LIMIT`, `L2RETH_MEM_LIMIT`, `L1_INTERFACE_MEM_LIMIT`.

Swap is disabled for all containers (`memswap_limit` == `mem_limit`), so containers will be OOM-killed rather than swapping to disk. This provides more predictable performance.

## Quick Start

The commands below are for testnet. Do not substitute `.env.mainnet`: the
current release does not ship a complete full-stack mainnet configuration.
See [Mainnet status](#mainnet-status) before using the mainnet templates.

> [!IMPORTANT]
> Older revisions accidentally tracked a host-specific `.env.testnet`. Before
> upgrading an existing checkout across the fix that removed it from Git, copy
> that file outside the repository. Restore it as the local `.env.testnet`
> after updating, review `DATA_ROOT`, and never reuse another host's data path.
>
> Older v0.3.0 revisions stored bundled Dogecoin credentials in
> `secrets/testnet/dogecoin_rpc_user` and `dogecoin_rpc_password`. Before
> recreating containers after an upgrade, copy those existing values into
> `DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD` in the local `.env.testnet`.
> Keeping the values unchanged avoids an unplanned credential rotation for the
> Dogecoin node, L1 Interface, and any external RPC consumers.

### 1. Configure the Compose Environment

Copy the testnet template and review the stable Dogecoin RPC credentials,
`DATA_ROOT`, ports, memory limits, and the Dogecoin volume name:

```bash
cp .env.example.testnet .env.testnet
# review DATA_ROOT, DOGECOIN_RPC_PASSWORD, and any port/memory overrides
chmod 600 .env.testnet
```

`DATA_ROOT` must be an absolute path on a dedicated data disk and must not be
inside this repository. The example assumes that disk is mounted at `/data`;
verify the mount on the target host instead of reusing a path from another
machine.

For compatibility with the earlier testnet package, `DOGECOIN_RPC_USER`
defaults to `doge` and `DOGECOIN_RPC_PASSWORD` defaults to `password`. Change
them once in the local `.env.testnet` if desired and keep them stable. Compose
supplies the same values to both `dogecoin-node` and L1 Interface as secrets,
so the credentials are configured only once. Supported characters are letters,
digits, and `._~:@%+=,-`. The defaults are public knowledge: never expose the
Dogecoin RPC port to an untrusted network while using them.

### 2. Optionally Override the Ethereum RPC

The tracked testnet configuration uses this public Ethereum Sepolia execution
RPC by default:

```text
https://ethereum-sepolia-rpc.publicnode.com
```

No `l1-interface.local.env` file is required to use that default. To use a
private or dedicated provider instead, copy the tracked operator template:

```bash
cp envs/testnet/l1-interface.local.env.example \
  envs/testnet/l1-interface.local.env
```

Then uncomment and replace the override in the new, gitignored file:

```bash
DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL=https://your-sepolia-execution-rpc
```

An override endpoint must support Sepolia (`chainId` `11155111`) and standard
execution methods including `eth_getBlockByHash`. Confirm that the provider
plan permits Sepolia access. Keep API keys only in `l1-interface.local.env`;
never put them in the tracked generated env file.

The RPC package points L1 Interface at the user's own Compose `dogecoin-node`
by default. Its RPC credentials come from shared Docker secrets and do not
belong in this local env file. Only for temporary/debug use, uncomment the
Dogecoin override and supply the external node's URL and authentication.

### 3. Prepare the Data Directory

L2Reth and L1 Interface follow the same operational model as Arbitrum Nitro:
chain databases live in an explicit host directory, not in anonymous Docker
volumes. `DATA_ROOT` must be set in the local `.env.testnet`; a typical Linux
host with a dedicated `/data` mount can use `/data/dogeos-data/testnet`.

Dogecoin is the exception: its data stays in the named Docker volume used by earlier releases (`DOGECOIN_VOLUME_NAME` in the env file), so nodes upgrading from pre-v0.3.0 keep their synced chain without migration. If you changed `COMPOSE_PROJECT_NAME` in an earlier release, set `DOGECOIN_VOLUME_NAME=<your-old-project-name>_dogecoin_data` (check with `docker volume ls | grep dogecoin_data`).

```bash
./scripts/prepare-data-dir.sh .env.testnet
```

The script validates the configured Dogecoin RPC credentials without printing
or changing them, then creates the data directories:

```text
${DATA_ROOT}/l2reth
${DATA_ROOT}/l1-interface
```

The Git-ignored `.env.testnet` is the single source of truth. Compose mounts its
`DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD` values into both
`dogecoin-node` and L1 Interface as secrets. Keep this local env file private
and include it in the operator's encrypted backup or secret-management
workflow.

Do not set `DATA_ROOT` to a path inside this repository.

If Docker cannot write to the prepared directories, fix ownership or permissions on the data disk before starting the stack. Prefer assigning the directory to the operator user/group or the container UID used by your runtime; avoid blanket `chmod 777` unless it is a deliberate emergency workaround.

### 4. Restore the L2Reth Snapshot (Recommended for New Nodes)

For a new testnet RPC node, restore the published L2Reth database instead of
syncing from genesis:

```bash
./scripts/restore-l2reth-snapshot.sh .env.testnet
```

The script downloads the current snapshot from the built-in public HTTPS URL,
verifies its built-in SHA-256, validates the archive layout, restores it to
`${DATA_ROOT}/l2reth`, and starts the complete testnet stack. Downloads
are resumable and cached under `${DATA_ROOT}/.snapshot-cache`.

Before running it, validate the local settings and prepare the data directories
in step 3. If the bundled public Ethereum RPC is not suitable for the
deployment, configure an override in step 2. To restore the files without
starting containers, pass `--no-start`.

The snapshot contains chain data only. The current genesis, hardfork schedule,
peer list, and runtime configuration continue to come from this repository.
See [the testnet snapshot guide](snapshot_testnet.md#l2reth-snapshot-recommended)
for replacement and recovery options.

### 5. Start Services

Start the complete testnet stack, including the bundled Dogecoin node:

```bash
docker compose --env-file .env.testnet up -d
```

For temporary/debug use, L2Reth and L1 Interface can run against an explicitly
configured external Dogecoin RPC without starting the user's Compose node:

```bash
docker compose --env-file .env.testnet up -d l2reth-node
```

Compose starts the required SQLite initialization job and L1 Interface before
L2Reth. To start only L1 Interface, use:

```bash
docker compose --env-file .env.testnet up -d l1-interface
```

Neither targeted command starts `dogecoin-node`, but they do not stop an
already-running Dogecoin container. Stop it explicitly when switching to an
external RPC:

```bash
docker compose --env-file .env.testnet stop dogecoin-node
```

Ensure the configured Dogecoin RPC and Ethereum RPC are reachable before
starting. Changes to an env file require container recreation;
`docker compose restart` reuses the old container environment. Apply changed
variables with:

```bash
docker compose --env-file .env.testnet up -d --force-recreate l1-interface
```

L1 Interface can temporarily report `503 not_ready` while historical sync and
replay catch-up run. This is expected during startup.

### 6. Verify Services

Check container state and L1 Interface readiness:

```bash
docker compose --env-file .env.testnet ps
curl --fail http://localhost:9090/health
```

The ready response reports `"status":"ready"`. If it reports
`historical_sync":"in_progress"`, wait and check again. Then verify L2Reth:

```bash
curl --fail \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

For snapshot recovery and replacement procedures, see the
[testnet snapshot guide](snapshot_testnet.md). Mainnet snapshot automation is
not available in this release; see [mainnet snapshot status](snapshot_mainnet.md).

## Mainnet Status

The repository currently supports the complete DogeOS RPC stack on testnet.
Do not start the full stack with `.env.mainnet` as shipped. Mainnet is missing
the generated `envs/mainnet/l2reth.env`, L2Reth genesis, protocol context, and
mainnet-specific L1 Interface bootstrap artifacts. The init job in the current
Compose file is pinned to testnet artifacts.

The mainnet env template and named Dogecoin volume remain useful for preserving
an existing mainnet Dogecoin node during upgrades. Full mainnet enablement
requires a deployment-specific package generated by the Scroll SDK CLI and
mainnet bootstrap URLs; do not reuse testnet files or snapshots.

## Service Endpoints

- **Dogecoin RPC**: `http://localhost:44555` (testnet; the mainnet template reserves `22555` but the full mainnet stack is not shipped)
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

## Services Overview

### L1 Interface
The L1 Interface provides the Ethereum-compatible L1 RPC consumed by L2Reth
through `L2RETH_L1_ENDPOINT` and bridges the Dogecoin chain into L2. It uses the
bundled public Ethereum Sepolia execution RPC for Ethereum DA replay unless an
operator override is configured. Pre-v0.3.0 history comes from the verified
SQLite files downloaded by
`l1-interface-init-fetch-sqlite` on first start. L2Reth does not download blobs
from L1 Interface; it reads the public S3 archive configured by
`L2RETH_BLOB_S3_URL` directly.

### L2Reth
L2Reth is the only supported L2 client in this package. It starts by default
when you run `docker compose --env-file .env.testnet up -d`; no Compose profile
selection is required. Its entrypoint script lives at
`scripts/l2reth_entrypoint.sh`. Before startup, replace unresolved peer
placeholders in `envs/testnet/l2reth.env`; otherwise those peers cannot be
dialed. `net_peerCount` reports established devp2p sessions, not merely the
number of configured enodes.


## Configuration

### Environment Variables

The project uses an explicit env file for Compose configuration:
- `.env.example.testnet` - Template for Testnet
- `.env.example.mainnet` - Mainnet planning/volume-preservation template; not a complete full-stack configuration

The env file contains:
- `NETWORK` - Selects network-specific paths; only testnet is complete in this release
- `COMPOSE_PROJECT_NAME` - Docker Compose project name (for container and network isolation)
- `DATA_ROOT` - Host path for persistent L2Reth and L1 Interface data
- `DOGECOIN_VOLUME_NAME` - Named Docker volume holding Dogecoin chain data (kept compatible with pre-v0.3.0 releases)
- `DOGECOIN_RPC_USER` / `DOGECOIN_RPC_PASSWORD` - Stable credentials shared by the bundled Dogecoin node and L1 Interface
- Port configurations

Recommended filenames are `.env.testnet` and `.env.mainnet`, and both are gitignored to prevent accidental commits of local configurations.

### Layered Configuration

L1 Interface configuration is layered:

1. **Generated network settings** (`envs/{network}/l1-interface.env`) - Deterministic chain addresses, heights, IDs, and feature settings produced by the CLI. This file is overwritten when configuration is regenerated; do not edit it.
2. **Shared bundled-node credentials** (`DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD` in the Git-ignored local Compose env) - One credential source mounted into both Dogecoin and L1 Interface as Compose Secrets.
3. **Operator-owned settings** (`envs/{network}/l1-interface.local.env`) - Optional Ethereum RPC and temporary/debug Dogecoin RPC overrides. It is loaded last, so it wins, and the CLI never overwrites it.

The tracked testnet package works without a local override file by using
`https://ethereum-sepolia-rpc.publicnode.com`. To override it, create the local
file from the template. The real file is gitignored so credentials stay out of
version control:

```bash
cp envs/testnet/l1-interface.local.env.example envs/testnet/l1-interface.local.env
# Optional: configure the Ethereum RPC override
# Optional: configure the Dogecoin section only for temporary/debug use
```

The generated env contains chain/runtime settings but no deployment-specific
Dogecoin URL or credentials. Compose owns the default internal URL and creates
shared Secrets from the values in `.env.testnet`. The generated
testnet env also contains the public Ethereum RPC default; private Ethereum
endpoints and temporary/debug Dogecoin overrides remain operator-owned.

### Generating Configuration Files (Internal DogeOS Developers Only)

You can automatically generate configuration files using the Scroll SDK CLI:

```bash
# Generate configuration files from a Scroll SDK deployment

# Install scroll-sdk-cli
git clone https://github.com/DogeOS69/scroll-sdk-cli.git
cd scroll-sdk-cli && yarn install && yarn build && npm install -g .

# Generate configuration
cd /path/to/scroll-setup-repo
scrollsdk setup gen-rpc-package -d /path/to/dogeos-rpc-package
```

This command will:
- Generate `l2reth.env` with the public S3 blob URL, updated peer list, network settings, and tuning defaults
- Generate deterministic `l1-interface.env` network settings and scaffold the operator-owned `l1-interface.local.env`
- Extract `genesis.json` and `protocol_context.json` from your deployment
- Never overwrite operator values in `*.local.env`

The generated testnet package includes the public Ethereum Sepolia RPC default.
Operators may override `DOGEOS_L1_INTERFACE_ETHEREUM_DA__L1_RPC_URL` in
`l1-interface.local.env`. Generation may also leave unresolved peer host
placeholders when public LoadBalancer domains are unavailable; resolve them
before distributing the package.

### Manual Configuration

1. Create network-specific generated settings in `envs/{network}/`.
2. Create network-specific genesis and protocol files in `configs/{network}/`.
3. Define the user's Compose Dogecoin URL in the RPC package topology, outside generated `l1-interface.env`.
4. Optionally create `envs/{network}/l1-interface.local.env` to override the default Ethereum RPC or add a Dogecoin override for temporary/debug use.
5. Resolve every external P2P peer hostname in `l2reth.env`.
6. Copy the appropriate `.env.example.*` to `.env.<network>` and set a dedicated `DATA_ROOT`.
7. Validate the local credentials, prepare the host data directory, and start services.

```bash
./scripts/prepare-data-dir.sh .env.testnet
docker compose --env-file .env.testnet up -d
```

The commands above are valid for the tracked testnet package. Mainnet also
requires mainnet-specific bootstrap artifact URLs in Compose; do not obtain a
mainnet deployment by changing only `NETWORK`.


### Customizing Configuration

Edit the appropriate environment files in `envs/` directory:
- `envs/{network}/l1-interface.local.env` - optional Ethereum RPC and temporary/debug Dogecoin RPC overrides
- `envs/{network}/*.env` - generated per-network config (regenerated by the CLI)

Bundled Dogecoin credentials live only in the Git-ignored local Compose env as
`DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD`, not in tracked generated env
files or `dogecoin.conf`.

If you need to decide which APIs to enable, you can modify them in `scripts/l2reth_entrypoint.sh`.

## Development

### Adding Services

1. Add service definition to `docker-compose.yml`
2. Create common and network-specific environment files
3. Add any required configuration files to `configs/`

### Environment Management

- Keep provider secrets in Git-ignored `*.local.env` files or an external secret store; bundled Dogecoin credentials belong in the Git-ignored local Compose env
- Treat `envs/{network}/*.env` as generated network configuration unless the file is explicitly named `*.local.env`
- Environment variables are loaded through Compose `env_file`; bundled Dogecoin credentials are mounted through Compose `secrets`

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

### Clean Up

L2Reth and L1 Interface data live under `DATA_ROOT`; Dogecoin data lives in the
named volume `DOGECOIN_VOLUME_NAME`. Prefer moving data to a recoverable backup
before deleting anything:

Use the reset helper to stop the stack, move both data directories to
timestamped backups, and recreate empty directories. It leaves the Dogecoin
named volume and snapshot cache intact:

```bash
./scripts/reset-chain-data.sh .env.testnet
```

To permanently delete both directories instead, explicit confirmation is
required:

```bash
./scripts/reset-chain-data.sh --delete --yes .env.testnet
```

The equivalent manual backup procedure is:

```bash
docker compose --env-file .env.testnet down

set -a
. ./.env.testnet
set +a

printf 'DATA_ROOT=%s\nDOGECOIN_VOLUME_NAME=%s\n' \
  "$DATA_ROOT" "$DOGECOIN_VOLUME_NAME"

case "$DATA_ROOT" in
  /*) ;;
  *) echo "DATA_ROOT must be absolute" >&2; exit 1 ;;
esac
case "$DATA_ROOT" in
  /|/tmp|/var/tmp) echo "Refusing unsafe DATA_ROOT: $DATA_ROOT" >&2; exit 1 ;;
esac

# After verifying the printed absolute path, preserve bind-mounted data:
mv "$DATA_ROOT" "${DATA_ROOT}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
```

The Dogecoin volume is deliberately left intact because it can take days to
resync. If you intentionally want to remove it, inspect the exact volume first
and then pass that explicit name to `docker volume rm`.

## Data Isolation

- **Data root**: `DATA_ROOT` controls where L2Reth and L1 Interface data is stored. Use a dedicated data disk path, not a path inside this repository.
  - Testnet example: `/data/dogeos-data/testnet`
  - Mainnet example: `/data/dogeos-data/mainnet`
- **Directory layout**: Docker bind-mounts `${DATA_ROOT}/l2reth` and `${DATA_ROOT}/l1-interface` into the corresponding containers. Dogecoin uses the named Docker volume `DOGECOIN_VOLUME_NAME`; use different volume names for mainnet and testnet (the defaults already differ).
- **Project naming**: `COMPOSE_PROJECT_NAME` controls Compose container and network names. Use different values for mainnet and testnet.
- **Ports**: Use different `L2_HTTP_PORT`, `L2_WS_PORT`, and `L2_P2P_PORT` values when running multiple environments. L1 Interface ports `8547`, `5052`, and `9090` are currently fixed in Compose, and the init container has a fixed `container_name`; those must also be parameterized before two full stacks can run on one host.
- **Switching networks**: Stop the current environment with `docker compose --env-file <env-file> down`, then start the target environment with its own env file. Do not reuse the same `DATA_ROOT` across networks.
