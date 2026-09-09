# Upgrade an Existing Testnet Node to v0.3.0

Use this guide **after v0.3.0 is merged into `main`**. It upgrades the old
v0.2.x package, whether it used L2Geth or older L2Reth. Allow a maintenance
window; the complete mainnet stack is not supported by this release.

**Stop the old services before `git pull`, using the old Compose file.** The
new version removes Geth and Celestia services; follow the order below.

**Keep the old Compose project name, Dogecoin volume, and RPC credentials.**
Dogecoin keeps its existing chain data. Only L2Reth and L1 Interface use new
data directories. Do not run `down -v`, volume prune, or a data-reset script.

Run the commands from the repository root, stopping if any command fails.
The examples assume the old default installation: `.env` and project
`dogeos-rpc-package`.

**Custom deployments:** before updating, save your existing env file and any
modified configuration outside the repository, especially the Dogecoin RPC
credentials in `configs/testnet/dogecoin.conf`. Keep your actual project and
Dogecoin volume names. Use your existing env file and any `-p` / `-f` options
when stopping the old services below.

## 1. Stop the Old Services

Run this **before updating Git**, while the old Compose file is still present:

```bash
docker compose --env-file .env --profile '*' down --remove-orphans
```

Wait for the command to finish successfully. Do not add `-v`; the data volumes
must stay in place.

## 2. Update the Code and Prepare the Env File

Pull the merged release:

```bash
git switch main
git pull --ff-only origin main
```

If Git reports local changes or conflicts, preserve and reconcile your custom
settings before continuing. Do not force-reset the checkout or overwrite the new
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
| `COMPOSE_PROJECT_NAME` | Keep the old name. The default remains `dogeos-rpc-package`. |
| `DOGECOIN_VOLUME_NAME` | Keep the existing volume. The default remains `dogeos-rpc-package_dogecoin_data`. |
| `DATA_ROOT` | A fresh path on your mounted data disk, e.g. `/data/dogeos-data/testnet-v0.3.0`. Its `l2reth` and `l1-interface` subdirectories must not exist yet. |
| `DOGECOIN_RPC_USER` | Keep your existing Dogecoin RPC user. The old default is `doge`. |
| `DOGECOIN_RPC_PASSWORD` | Keep your existing Dogecoin RPC password. The old default is `password`; preserve any custom value. |

Keep `NETWORK=testnet`. Remove the old `COMPOSE_PROFILES` setting and retain
any custom L2 ports or memory limits. If you changed Dogecoin ports, preserve
the matching listen ports in `configs/testnet/dogecoin.conf` as well.
Confirm the data disk is mounted and has space for the snapshot, extracted
data, and continued growth. `DATA_ROOT` does not change where Docker stores
the existing Dogecoin volume.

Check the configuration and confirm that the Dogecoin volume already exists.
If you used a custom volume name, substitute that exact name below. Do not
start if the volume is missing; correct the name instead of creating a new one.

```bash
docker compose --env-file .env.testnet config --quiet
docker volume inspect dogeos-rpc-package_dogecoin_data
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
