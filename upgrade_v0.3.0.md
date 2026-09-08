# Upgrading from v0.2.x to v0.3.0

This guide upgrades an existing **testnet** deployment from the old `main`
package (L1 Interface `0.2.0-rc.7`, with L2Geth or older L2Reth) to v0.3.0.
Use it after v0.3.0 has been merged into `main`. Mainnet full-stack upgrades
are not supported by this release; see [mainnet status](README.md#mainnet-status).

Plan an RPC maintenance window for shutdown, snapshot download/extraction,
and catch-up. Completion time depends on disk, network, and chain progress.
For continuous RPC service, upgrade a separate host and verify it before
switching traffic. Do not attach a running node's database to a second writer.

Run the commands in Bash from the repository root, in the same shell, and
stop if any command fails. Use the Docker context and account that manage the
existing deployment. The examples assume the old package's `.env`; if you
used another file, set `OLD_ENV_FILE` to that file in step 1. If you deployed
with additional Compose files, include those same `-f` options in old-stack
commands and review their changes separately.

## What Happens to Existing Data

| Component | Old location | Upgrade action |
|-----------|--------------|----------------|
| Dogecoin | `<old-project>_dogecoin_data` named volume | Reuse the exact existing volume and RPC credentials; no snapshot or full resync is required merely for this upgrade. |
| L2Geth | `<old-project>_l2geth_data` named volume | Keep the old volume. Switch to L2Reth using the published L2Reth snapshot or sync it from genesis. Do not copy a Geth database into Reth. |
| Older L2Reth | `<old-project>_l2reth_data` named volume | Keep the old volume. This guide restores the published snapshot into a new host directory, or starts a fresh sync. |
| L1 Interface | `<old-project>_l1_interface_data` named volume | Keep the old volume. Start with a fresh `${DATA_ROOT}/l1-interface`; Compose downloads and verifies the new historical/bootstrap files. Do not copy the old database. |
| Celestia | `<old-project>_celestia_data` named volume | Stop the old service and retain its data until the upgrade is accepted. The new stack does not run Celestia. |

Actual volume names may differ; inspect them below. The new L2Reth bind mount
does not discover or copy the old volume automatically. Chain continuity does
not prove on-disk compatibility between `scrolltech/rollup-node:v0.0.1-rc63`
and `dogeos69/rollup-node:0.3.0-beta.0`. Direct reuse of that old Reth database
is not a validated procedure in this package, so this guide uses a fresh
snapshot or sync for both old L2 clients.

## 1. Record the Old Deployment and Back Up Configuration

Do this **before updating the checkout or replacing any env file**:

```bash
# Abort this upgrade shell on a failed command or pipeline.
set -eo pipefail
OLD_ENV_FILE=.env
test -f "$OLD_ENV_FILE"
docker compose version
docker compose --env-file "$OLD_ENV_FILE" ps -a

# The old package used this fixed container name. If customized, replace it.
OLD_DOGECOIN_CONTAINER=dogecoin-node
OLD_PROJECT=$(docker inspect "$OLD_DOGECOIN_CONTAINER" \
  --format '{{index .Config.Labels "com.docker.compose.project"}}')
OLD_DOGECOIN_VOLUME=$(docker inspect "$OLD_DOGECOIN_CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}')
test -n "$OLD_PROJECT"
test -n "$OLD_DOGECOIN_VOLUME"
docker volume inspect "$OLD_DOGECOIN_VOLUME"

umask 077
UPGRADE_BACKUP=$(mktemp -d "$(dirname "$PWD")/dogeos-upgrade-XXXXXXXX")
git rev-parse HEAD > "$UPGRADE_BACKUP/old-commit.txt"
printf '%s\n' "$OLD_PROJECT" > "$UPGRADE_BACKUP/old-project.txt"
printf '%s\n' "$OLD_DOGECOIN_VOLUME" > "$UPGRADE_BACKUP/dogecoin-volume.txt"
git status --short > "$UPGRADE_BACKUP/git-status.txt"
git diff HEAD --binary > "$UPGRADE_BACKUP/local-changes.patch"
git archive HEAD > "$UPGRADE_BACKUP/old-checkout.tar"
cp -a docker-compose.yml configs envs scripts "$UPGRADE_BACKUP/"
cp -a "$OLD_ENV_FILE" "$UPGRADE_BACKUP/old-compose.env"
for local_file in .env .env.testnet .env.mainnet; do
  if [ -f "$local_file" ]; then
    cp -a "$local_file" "$UPGRADE_BACKUP/"
  fi
done
if [ -d secrets ]; then
  cp -a secrets "$UPGRADE_BACKUP/"
fi
docker ps -a --filter "label=com.docker.compose.project=$OLD_PROJECT" \
  --format '{{.Names}}\t{{.Image}}\t{{.Status}}' \
  > "$UPGRADE_BACKUP/old-containers.txt"
docker ps -aq --filter "label=com.docker.compose.project=$OLD_PROJECT" |
  xargs -r docker inspect --format '{{.Name}} {{json .Mounts}}' \
  > "$UPGRADE_BACKUP/old-mounts.txt"
printf 'Configuration backup: %s\nOld project: %s\nDogecoin volume: %s\n' \
  "$UPGRADE_BACKUP" "$OLD_PROJECT" "$OLD_DOGECOIN_VOLUME"
```

Keep this backup private: it includes local credentials and provider endpoints.
Copy any extra Compose override files or configuration outside these paths as
well. If the old containers were already removed, retrieve the project and
volume names from deployment records and `docker volume ls`; do not guess or
allow Docker to create a replacement Dogecoin volume.

Record which L2 client was running from `old-containers.txt`. Privately review
the old `configs/testnet/dogecoin.conf` and any deployment overrides for the
actual Dogecoin RPC user/password. Preserve custom values when configuring
the new shared credentials; do not reset them to the public template defaults.
Older intermediate v0.3.0 deployments may instead have credentials in
`secrets/testnet/dogecoin_rpc_user` and `dogecoin_rpc_password`.

## 2. Stop the Old Stack Using Its Old Configuration

The old Compose file still needs to be checked out for this command. Enabling
all profiles includes either old L2 client. The explicit project name also
handles installations that used `docker compose -p`.

```bash
docker compose --env-file "$OLD_ENV_FILE" -p "$OLD_PROJECT" \
  --profile '*' down --remove-orphans

# This should list no remaining containers for the old project.
docker ps -a --filter "label=com.docker.compose.project=$OLD_PROJECT"
docker volume inspect "$OLD_DOGECOIN_VOLUME"
```

**Do not add `-v` / `--volumes`, run a volume prune, or run the old README's
data-deletion command.** These volumes are your retained chain data. If you
need independent database backups, take storage snapshots or cold volume
backups now that all writers have stopped. The configuration backup in step 1
does not contain chain databases, and retaining a volume is not an independent
backup.

The new template changes the default project from `dogeos-rpc-package` to
`dogeos-testnet`. Starting that new project does not stop the old one, and
`--remove-orphans` cannot remove another project's containers. Complete this
shutdown even if you plan to keep the old project name.

## 3. Update to the Merged Release

```bash
git status --short
# Resolve any local tracked changes after backing them up, before continuing.
# Do not blindly reapply old generated config or the old Compose file.
git switch main
git pull --ff-only origin main
test -f upgrade_v0.3.0.md
```

If Git reports local changes, conflicts, or diverged history, stop and resolve
them without discarding the backup. Review local customizations against the
new files. Do not use a hard reset or `git clean` as an upgrade step. A
previously tracked `.env.testnet` can disappear when updating; recover its
operator settings from the backup, not from another host's configuration.

## 4. Prepare the New Local Configuration

Create `.env.testnet` from the new template **only if it does not already
exist**. Otherwise edit the existing local file using the template as a
reference, adding the new required settings.

```bash
if [ ! -e .env.testnet ]; then
  cp .env.example.testnet .env.testnet
fi
chmod 600 .env.testnet
```

Edit `.env.testnet` before continuing:

| Setting | Required upgrade value |
|---------|------------------------|
| `NETWORK` | `testnet` |
| `COMPOSE_PROJECT_NAME` | Prefer the recorded `OLD_PROJECT` to preserve project identity. A new name is also possible after the old stack has been stopped. |
| `DOGECOIN_VOLUME_NAME` | The exact recorded `OLD_DOGECOIN_VOLUME`, even when using a different new project name. |
| `DATA_ROOT` | A new absolute directory on the host's mounted data disk, outside the repository, e.g. `/data/dogeos-data/testnet-v0.3.0`. Its `l2reth` and `l1-interface` subdirectories must be empty or absent for this procedure. |
| `DOGECOIN_RPC_USER`, `DOGECOIN_RPC_PASSWORD` | The existing bundled node's credentials. Supported characters: letters, digits, and `._~:@%+=,-`. If old values cannot be represented, coordinate a credential change with external consumers before starting. |
| Ports and memory limits | Preserve deployment-specific values, including reverse-proxy expectations. Map old L2 ports to `L2_HTTP_PORT`, `L2_WS_PORT`, and `L2_P2P_PORT`; review `L2RETH_MEM_LIMIT` for the new client. |
| `COMPOSE_PROFILES` | Remove the old `l2geth` / `l2reth` selection. L2Reth now starts by default. Remove obsolete L2Geth and Celestia-only settings. |

Use shell-compatible `KEY=value` assignments because the snapshot helper
sources this file with Bash. Quote values where needed. Ensure exported shell
variables such as `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, `NETWORK`, or
`DATA_ROOT` do not override the intended Compose configuration. All new-stack
commands below explicitly select `.env.testnet`; the old `.env` is no longer
the file to edit for those commands.

Verify the actual data disk mount, for example with `findmnt -T /data` when
using `/data`. Confirm it shows the intended device and filesystem. Allow
space for the compressed snapshot cache, extracted database, future growth,
and retained old data. If the disk is not mounted, Docker can create the
directory on the root filesystem instead.

For the bundled Dogecoin node, configure credentials only in `.env.testnet`.
Use the new generated files as shipped; do not restore the old
`envs/common/l1-interface.env`, old genesis, or Celestia configuration over
them. The default Ethereum endpoint is public Sepolia. If you need a dedicated
provider or previously used an external Dogecoin RPC, adapt your overrides
using [the current local env template](envs/testnet/l1-interface.local.env.example).
Keep provider secrets in `envs/testnet/l1-interface.local.env`. Review any
existing local override for stale URLs or bundled-node credentials that would
override the new shared values.

Validate configuration and confirm the existing Dogecoin volume before
allowing Compose to create containers:

```bash
docker compose --env-file .env.testnet config --quiet
(
  . ./.env.testnet
  test "$NETWORK" = testnet
  test "$DOGECOIN_VOLUME_NAME" = "$OLD_DOGECOIN_VOLUME"
  docker volume inspect "$DOGECOIN_VOLUME_NAME"
  : "${DATA_ROOT:?DATA_ROOT must be set}"
  for data_dir in "$DATA_ROOT/l2reth" "$DATA_ROOT/l1-interface"; do
    if [ -e "$data_dir" ]; then
      test -d "$data_dir" || exit 1
      test -z "$(ls -A "$data_dir")" || {
        printf 'Use a fresh DATA_ROOT; existing data found: %s\n' "$data_dir" >&2
        exit 1
      }
    fi
  done
)
docker compose --env-file .env.testnet pull
```

If `config --quiet` rejects optional `env_file` entries or environment-backed
secrets, update the Docker Compose v2 plugin before proceeding. Do not remove
those settings to work around an older Compose installation.

## 5. Prepare L2Reth and Start the New Stack

Choose one path, regardless of whether the old client was L2Geth or L2Reth.
Keep all old L2 volumes untouched.

**Recommended: restore the published L2Reth snapshot.** The helper verifies the
pinned SHA-256 and restores into the new `${DATA_ROOT}/l2reth`. Separate
restoration from startup so failures can be addressed before launching:

```bash
./scripts/restore-l2reth-snapshot.sh --no-start .env.testnet
docker compose --env-file .env.testnet up -d
```

The helper needs `curl`, Docker, `sha256sum`, GNU `tar` with gzip support, and
permission to create/write `DATA_ROOT`. If it reports a non-empty destination,
review your selected path; do not add `--force` to an initial migration without
understanding which existing directory it would replace. See the
[snapshot guide](snapshot_testnet.md#l2reth-snapshot-recommended) for details.

**Alternative: sync L2Reth from genesis.** Leave the new L2Reth directory empty
and run:

```bash
docker compose --env-file .env.testnet up -d
```

In both paths, Compose starts the bundled Dogecoin node on its existing
volume. The L1 init job downloads the historical artifact and replay bootstrap
into the fresh L1 directory, then L1 Interface starts. L2Reth waits for L1 RPC
before starting its node process. No Celestia service or L2Geth profile is
required. The snapshot helper only manages the selected new project; it does
not replace step 2's old-stack shutdown.

## 6. Verify Before Returning RPC Traffic

```bash
docker compose --env-file .env.testnet ps -a
docker compose --env-file .env.testnet logs --tail 100 \
  dogecoin-node l1-interface-init-fetch-sqlite l1-interface l2reth-node

# Confirm that the new Dogecoin container uses the recorded old volume.
docker inspect "$(docker compose --env-file .env.testnet ps -q dogecoin-node)" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}'

# Keep the body visible while L1 may still be catching up with HTTP 503.
curl --silent --show-error --include http://localhost:9090/health
```

The init container should finish with exit code 0. L1 health can initially
return HTTP 503 with `historical_sync=in_progress`; wait for HTTP 200 and
`status=ready`. Check Dogecoin logs for normal chain progress and successful
RPC access from L1 Interface. Resolve restarts, authentication errors, or
database errors before returning traffic.

Check L2 RPC using your configured HTTP port (`8545` below is the default):

```bash
curl --fail -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://localhost:8545
curl --fail -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
curl --fail -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://localhost:8545
```

Confirm responses contain results rather than JSON-RPC errors, the chain ID
matches `configs/testnet/l2reth-genesis.json`, and established peers are
present. Repeat the block-number check to confirm advancement; compare a
recent block number and hash with a trusted testnet node to establish that
this node has caught up on the expected chain. A listening port or nonzero
block number alone does not establish readiness. Validate your reverse proxy,
WebSocket consumers, and any client behavior affected by switching from Geth
to Reth before restoring production traffic.

## Recovery and Retained Data

If startup fails, retain the configuration backup and all old volumes. Inspect
logs and use the [testnet recovery guide](snapshot_testnet.md) to repair the
new deployment. To stop it, use its new configuration:

```bash
docker compose --env-file .env.testnet down
```

Do not run `reset-chain-data.sh` as a routine upgrade step: it resets both new
L2Reth and L1 Interface directories. Do not point an old binary at a database
written by the new stack.

The recorded commit, old config, and retained volumes support recovery
planning, but **reverting the repository is not a guaranteed network
rollback**. The old software uses the previous DA/protocol configuration and
may no longer follow the upgraded network. Confirm network compatibility with
the release operators before attempting to run the old stack. Stop the new
stack first to release ports and the shared Dogecoin volume; recover old
configuration in a separate checkout and reconnect only the recorded old
volumes. Dogecoin's volume is reused by the new deployment, so a true
pre-upgrade copy requires the cold backup described in step 2.

Only consider removing old L2Geth/L2Reth, L1 Interface, or Celestia volumes
after the new node is verified and your recovery retention period has passed.
Inspect exact names and mounts individually. **The original Dogecoin volume
is still live data for v0.3.0 and must be retained.**
