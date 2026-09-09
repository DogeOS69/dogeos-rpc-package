# Upgrade an Existing Testnet Node to v0.3.0

Use this guide **after v0.3.0 is merged into `main`**. It upgrades the old
v0.2.x package, whether it used L2Geth or older L2Reth. Allow a maintenance
window; the complete mainnet stack is not supported by this release.

**Stop the old services before `git pull`, using the old Compose file.** The
new version removes Geth and Celestia services; follow the order below.

**Keep the old Compose project name, Dogecoin volume, and RPC credentials.**
Dogecoin keeps its existing chain data. Only L2Reth and L1 Interface use new
data directories. Do not run `down -v`, volume prune, or a data-reset script.

Run the four steps below in Bash, from the repository root, in the **same
shell**. Stop if a command fails. For custom deployments, see the notes below.

## 1. Stop the Old Services

First record the old names and back up configuration before removing the
containers. The old defaults are `.env` and the container `dogecoin-node`;
replace these two values if your deployment used others.

```bash
set -eo pipefail
OLD_ENV_FILE=.env
OLD_DOGECOIN_CONTAINER=dogecoin-node
OLD_PROJECT=$(docker inspect "$OLD_DOGECOIN_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}')
OLD_DOGECOIN_VOLUME=$(docker inspect "$OLD_DOGECOIN_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}')
test -n "$OLD_PROJECT"
test -n "$OLD_DOGECOIN_VOLUME"

umask 077
UPGRADE_BACKUP=$(mktemp -d "$(dirname "$PWD")/dogeos-upgrade-XXXXXXXX")
cp -a "$OLD_ENV_FILE" docker-compose.yml configs envs scripts "$UPGRADE_BACKUP/"
if [ -f .env.testnet ]; then cp -a .env.testnet "$UPGRADE_BACKUP/"; fi
if [ -d secrets ]; then cp -a secrets "$UPGRADE_BACKUP/"; fi
git rev-parse HEAD > "$UPGRADE_BACKUP/old-commit.txt"
git diff HEAD --binary > "$UPGRADE_BACKUP/local-changes.patch"
printf 'Project: %s\nDogecoin volume: %s\n' "$OLD_PROJECT" "$OLD_DOGECOIN_VOLUME" |
  tee "$UPGRADE_BACKUP/old-names.txt"
printf 'Configuration backup: %s\n' "$UPGRADE_BACKUP"
```

Keep the backup private; it contains credentials. It backs up configuration,
not chain databases. The original data volumes will stay in place.

Stop the services with the old configuration:

```bash
docker compose --env-file "$OLD_ENV_FILE" -p "$OLD_PROJECT" --profile '*' down --remove-orphans
test -z "$(docker ps -q --filter "label=com.docker.compose.project=$OLD_PROJECT")"
docker volume inspect "$OLD_DOGECOIN_VOLUME" >/dev/null
```

## 2. Update the Code and Prepare the Env File

Pull the merged release:

```bash
git switch main
git pull --ff-only origin main
test -f upgrade_v0.3.0.md
```

If Git reports local changes or conflicts, reconcile them against your backup
before continuing. Do not force-reset the checkout or overwrite the new
runtime files with old versions.

Create the new env file only if it is absent:

```bash
if [ ! -e .env.testnet ]; then cp .env.example.testnet .env.testnet; fi
chmod 600 .env.testnet
```

Edit `.env.testnet` and check these settings. **Replace the `/path/to/...`
placeholder in `DATA_ROOT` with your own data disk path before continuing.**

| Setting | Value for this upgrade |
|---------|------------------------|
| `COMPOSE_PROJECT_NAME` | The `Project` recorded in step 1. The template keeps the old default: `dogeos-rpc-package`. |
| `DOGECOIN_VOLUME_NAME` | The exact `Dogecoin volume` recorded in step 1. Default: `dogeos-rpc-package_dogecoin_data`. |
| `DATA_ROOT` | A fresh path on your mounted data disk, e.g. `/data/dogeos-data/testnet-v0.3.0`. Its `l2reth` and `l1-interface` subdirectories must not exist yet. |
| `DOGECOIN_RPC_USER` | Your existing Dogecoin RPC user; check the backed-up Dogecoin configuration. |
| `DOGECOIN_RPC_PASSWORD` | Your existing Dogecoin RPC password; do not replace a custom password with the template default. |

Keep `NETWORK=testnet`. Remove the old `COMPOSE_PROFILES` setting and retain
any custom ports or memory limits. Confirm the data disk is mounted and has
space for the snapshot, extracted data, and continued growth. `DATA_ROOT`
does not change where Docker stores the existing Dogecoin volume.

Check the configuration before starting anything:

```bash
docker compose --env-file .env.testnet config --quiet
(
  . ./.env.testnet
  test "$NETWORK" = testnet
  test "$COMPOSE_PROJECT_NAME" = "$OLD_PROJECT"
  test "$DOGECOIN_VOLUME_NAME" = "$OLD_DOGECOIN_VOLUME"
  docker volume inspect "$DOGECOIN_VOLUME_NAME" >/dev/null
  : "${DATA_ROOT:?Set a fresh absolute DATA_ROOT on the data disk}"
  case "$DATA_ROOT" in
    /path/to|/path/to/*) echo 'Replace the DATA_ROOT placeholder first' >&2; exit 1 ;;
  esac
  test ! -e "$DATA_ROOT/l2reth"
  test ! -e "$DATA_ROOT/l1-interface"
)
```

## 3. Download and Restore the L2Reth Snapshot

```bash
docker compose --env-file .env.testnet pull
./scripts/restore-l2reth-snapshot.sh --no-start .env.testnet
```

The script downloads, verifies, and extracts the snapshot into the new directory.
`--no-start` leaves services stopped until the next step. **Do not restore the
Dogecoin snapshot during a normal upgrade.**

## 4. Start the Services

```bash
docker compose --env-file .env.testnet up -d
```

Compose reuses the original Dogecoin volume and initializes fresh L1 Interface
data automatically from its verified bootstrap files.

Allow startup and catch-up to finish. Dogecoin can spend more than ten minutes
loading its large index. Inspect status and logs:

```bash
docker compose --env-file .env.testnet ps -a
docker compose --env-file .env.testnet logs --tail 100 dogecoin-node l1-interface-init-fetch-sqlite l1-interface l2reth-node
```

Before returning RPC traffic, the init container must have exited with code
`0`, L1 health must return HTTP `200` with `status=ready`, and L2 must follow
the current chain. Initial HTTP `503` or unavailable RPC during startup means
wait and check the logs again. Use your configured ports if they differ:

```bash
curl --fail --silent --show-error http://localhost:9090/health
for method in eth_chainId eth_blockNumber net_peerCount; do
  curl --fail --silent --show-error -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":[]}" \
    http://localhost:8545
  echo
done
```

Confirm the chain ID matches the bundled genesis, peers are present, and the
block number advances. Compare a recent block hash with a trusted testnet
node before accepting the upgrade. Keep all old data volumes.

<details>
<summary>Custom deployments and volume warnings</summary>

- If the old containers were already removed, recover their project and volume
  names from deployment records. Do not guess a Dogecoin volume name.
- If you used extra Compose files, include their `-f` options in old-stack
  commands, back them up, and adapt them for the new stack. Ensure exported
  variables such as `COMPOSE_PROJECT_NAME`, `COMPOSE_PROFILES`, `COMPOSE_FILE`,
  and `DATA_ROOT` do not override your intended env file.
- Keep provider endpoints and external Dogecoin overrides in
  `envs/testnet/l1-interface.local.env`, following its example file. The bundled
  node gets shared credentials from `.env.testnet`. Supported credential
  characters are letters, digits, and `._~:@%+=,-`.
- If Compose rejects optional env files or environment-backed secrets, update
  the Docker Compose v2 plugin. Do not remove those settings.
- Keeping the old project name avoids a project ownership warning. If you
  already started the new stack under another name, stop it with that current
  configuration using `down` without `-v`, restore the old project name in
  `.env.testnet`, and start again. Keep the same data paths and volume name;
  another snapshot restore is unnecessary.
- A warning that a volume "was created for project ... (expected ...)" does
  not delete or replace its data. Do not delete the volume to silence it.
  Confirm the actual Dogecoin mount with:

```bash
docker inspect "$(docker compose --env-file .env.testnet ps -q dogecoin-node)" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Type}} {{.Name}}{{end}}{{end}}'
```

</details>

<details>
<summary>Existing installations of earlier v0.3.0 revisions</summary>

Before updating, back up `.env.testnet` outside the repository and restore it
if the update removes it. Review `DATA_ROOT` and keep your existing project
name and Dogecoin volume.

If your installation uses `secrets/testnet/dogecoin_rpc_user` and
`secrets/testnet/dogecoin_rpc_password`, copy those existing values into
`DOGECOIN_RPC_USER` and `DOGECOIN_RPC_PASSWORD` in your local `.env.testnet`
before recreating containers. Keep the credentials unchanged for the Dogecoin
node, L1 Interface, and other RPC consumers.

</details>

<details>
<summary>Old databases, recovery, and alternative L2 sync</summary>

L2Geth databases cannot be used by Reth. Direct reuse of the older Reth database
is not validated for this release. L1 Interface v0.2.x storage is incompatible
with v0.3.0. Keep those old volumes and the old Celestia volume; the new stack
uses fresh L1/L2 directories and does not run Celestia or Geth.

To sync L2Reth from genesis instead, skip the restore command in step 3 and
start with the same fresh directories. For snapshot requirements and recovery,
see the [testnet snapshot guide](snapshot_testnet.md).

If the upgrade fails, stop the new stack with
`docker compose --env-file .env.testnet down`, inspect logs, and retain your
backup and old volumes. Do not run `reset-chain-data.sh` as an upgrade step.
Do not point old binaries at databases written by the new stack.

Reverting Git alone is not a guaranteed network rollback: old software uses
the previous DA/protocol configuration. Confirm network compatibility before
attempting to restart it. Independent chain backups require storage snapshots
or cold backups after stopping writers. **The original Dogecoin volume remains
live data for v0.3.0 and must be retained.**

</details>
