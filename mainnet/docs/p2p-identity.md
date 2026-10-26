# Persistent L2 P2P Identity and Allowlisting

Run commands from this network directory using the same `.env` as deployment.
The key helper needs Python 3.9+ and Docker Compose.
Initialization and checks resolve Compose configuration without a running node.
Mainnet commands require the release configuration, which is not yet shipped.

The onboarding sequence is: persist one private key, obtain its public key with
standard client tools, confirm fixed egress CIDRs with your network operator,
submit the public key/CIDRs to DogeOS operations, then verify the running node.
The offline public-key step allows allowlisting before the first chain sync.

## Initialize Before Restore or Startup

After setting `DATA_ROOT`, initialize the identity **before restoring any
snapshot, resetting chain data or starting services**:

```bash
python3 scripts/p2p-identity.py init
```

The default private-key file is `${DATA_ROOT}/l2reth-identity/discovery-secret`.
To choose another location, first set `L2RETH_P2P_KEY_FILE` in `.env` to an
absolute path outside this repository, the chain data directories and snapshot
cache. The file is mounted read-only at `/run/dogeos/l2reth-p2p.key`, and the
node uses `--p2p-secret-key` explicitly. The host parent directory must be
writable by the user running `init`. Keep the key mode `0600` (or `0400`).

`init` generates a secp256k1 key once; subsequent runs retain it. It reports
status without printing the key. To import your own key from a private file instead:

```bash
python3 scripts/p2p-identity.py init --import-key /your/private/existing-key
```

Import accepts a 32-byte hex private key, optionally prefixed with `0x` or
followed by a newline, and writes the canonical 64 hex characters Reth expects.
It copies the source and refuses to overwrite a different existing identity.
Never put the private key in `.env`, command-line arguments, tickets or chat.
An existing canonical key at `L2RETH_P2P_KEY_FILE` can be reused directly.
Both commands (`init`, `check`) accept `--env-file /path/to/.env`.

### Using a Standard Tool to Generate a New Key

If your operations workflow already uses Geth's `devp2p` tool, it can generate
the same 32-byte hex key format. Install the developer tools from the
[official Geth distribution](https://geth.ethereum.org/docs/getting-started/installing-geth)
and check `devp2p key --help`. This tool is optional for running the stack.
For a **new node only**, choose an unused private file path, then run:

```bash
NEW_P2P_KEY=/your/private/new-p2p.key
umask 077
if [ -e "$NEW_P2P_KEY" ] || [ -L "$NEW_P2P_KEY" ]; then
  echo "Key path already exists; not generating or replacing it."
else
  devp2p key generate "$NEW_P2P_KEY"
fi
python3 scripts/p2p-identity.py init --import-key "$NEW_P2P_KEY"
```

Create the private parent directory first. `devp2p key generate` can overwrite
an existing file, so retain the guard above. The package helper copies the key
to the configured persistent path and refuses to replace a different identity.
Alternatively, set `L2RETH_P2P_KEY_FILE` to an existing canonical private file
and run `python3 scripts/p2p-identity.py check` to validate the mount and key.
For an existing node, preserve its original key using the migration below.

## Existing Node Migration

Run `init` while the old chain directory is still present, **before** a restore,
reset or first restart with this package. If the destination does not exist,
`init` copies `${DATA_ROOT}/l2reth/discovery-secret`, preserving the old node ID
and leaving the original in place. Existing chain data without that file
causes an error; locate and explicitly import the original key. If your old
setup passed a P2P key via `L2RETH_EXTRA_ARGS`, remove that override and import
its key before continuing. The script will not silently rotate an identity.

After migrating and checking the key, use staged startup during a maintenance
window to recreate containers with the new mount. Then verify the public key
from native node information against your existing allowlist record:

```bash
python3 scripts/p2p-identity.py check
python3 scripts/snapshot-group.py start
```

Keep `DATA_ROOT` and `L2RETH_P2P_KEY_FILE` stable. Moving to another disk or host
requires transferring the identity securely before `init`; never run two nodes
with the same private key at the same time.

## Collect Information for Operations

### 1. View the Public Key Before Startup

Use Geth's standard `devp2p` utility from its official developer-tools bundle
(the `key` commands are verified against Geth v1.16.5). These commands read the
key file without starting a node or contacting peers. Geth and Reth use the same
secp256k1 raw-hex key format. After initialization/migration, resolve the file
actually mounted by Compose, including any custom `L2RETH_P2P_KEY_FILE`:

```bash
python3 scripts/p2p-identity.py check
P2P_KEY_FILE=$(docker compose config --format json | jq -er '
  .services["l2reth-node"].volumes[] |
  select(.target == "/run/dogeos/l2reth-p2p.key") | .source')
devp2p key to-enode --ip 127.0.0.1 "$P2P_KEY_FILE"
```

Use the same `.env` for both commands; when using a custom file, pass
`--env-file /path/to/.env` to both the helper and `docker compose`.
The output is `enode://<128-hex-public-key>@127.0.0.1:30303`. Copy only the
public key between `enode://` and `@` for the public-key allowlist. The loopback
address is deliberately a placeholder for this offline query, **not** a public
endpoint to submit to operations. This neither displays nor changes the private
key. Do not use `devp2p key to-id`: it returns a hash rather than the full public
key. See the [upstream key commands](https://github.com/ethereum/go-ethereum/blob/v1.16.5/cmd/devp2p/keycmd.go).

If you do not install `devp2p`, the running node's log or local IPC API provides
the same public key as described in [Verify Identity After Startup](#verify-identity-after-startup).
This fallback becomes available after the staged startup reaches L2Reth.

### 2. Confirm the Outbound IPs and CIDRs

Your network operator must separately confirm the public egress addresses used
when this node connects to DogeOS peers. Check the instance routing and the NAT
or firewall SNAT configuration, including all possible failover/egress pool IPs.
For one fixed IPv4, submit `IP/32`; for several fixed addresses, submit each
`IP/32`. Do not substitute the Docker/VPC private subnet or an ISP's whole range.
For example, a public AWS NAT gateway uses its [Elastic IP for internet egress](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html).

Before startup, run a simple cross-check on the actual deployment host:

```bash
curl -q -4 --noproxy '*' --fail --silent --show-error \
  --max-time 10 https://api.ipify.org
```

Once L2Reth is running, repeat from its network environment:

```bash
docker compose exec -T l2reth-node \
  curl -q -4 --noproxy '*' --fail --silent --show-error \
  --max-time 10 https://api.ipify.org
```

This only observes the source of that HTTPS request. It cannot discover the
complete egress pool or prove that traffic to DogeOS takes the same route.
Use fixed, controlled egress addresses; Google Cloud explicitly recommends
[manual NAT IP assignment for allowlisting](https://docs.cloud.google.com/nat/docs/ports-and-addresses).
CIDRs are network-operator information, not a node setting in `.env`. The package
does not detect/export CIDRs, derive/export public keys, or assemble enode URLs.
The key helper only initializes, migrates and checks the private-key file.

### 3. Request Allowlisting

Send DogeOS operations the network name, P2P public key and confirmed egress
CIDRs. Supply an inbound enode only if operations also needs to dial your node.
Wait for both public-key and IP allowlisting before expecting peer connections;
zero peers can be normal while the request is pending. Coordinate a real P2P
connection so DogeOS operations can confirm the source IP at their ingress and
the peer identity after handshake. Then follow [RPC verification](verify-node.md)
before serving traffic. No command here sends an allowlist request to operations.

## Verify Identity After Startup

Use `python3 scripts/snapshot-group.py start` for normal ordered startup.
L2Reth can initialize its network identity before it has connected to a peer. Upstream synchronization must finish before
this staged workflow launches L2Reth. Use the offline method above if you need
the public key earlier; do not bypass dependency checks. Wait for the P2P
initialization message, then read it:

```bash
docker compose logs --no-color l2reth-node | grep 'P2P networking initialized'
```

The pinned rollup-node version [logs its native enode when networking starts](https://github.com/DogeOS69/dogeos-rollup-node/blob/d3260afef9ae729a073fd70a43ae4f3832b482f7/crates/node/src/builder/network.rs).
From `enode://<public-key>@<address>:<port>`, copy the 128 hex characters between
`enode://` and `@`. This is the secp256k1 P2P public key, without `04` or `0x`;
it is not an Ethereum account address. Never send the private-key file.

If the startup log has rotated out, use the node's local `admin_nodeInfo` JSON-RPC
method over IPC. On the Linux Docker host, an operator with Docker and root
access can use standard `socat` and `jq` tools (install them if needed):

```bash
NODE_CONTAINER=$(docker compose ps -q l2reth-node)
NODE_PID=$(docker inspect --format '{{.State.Pid}}' "$NODE_CONTAINER")
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"admin_nodeInfo","params":[]}' |
  sudo socat -T 5 - "UNIX-CONNECT:/proc/${NODE_PID}/root/tmp/reth.ipc" |
  jq -r '.result.enode'
```

This accesses the container's existing IPC socket, as the peer-management helper
does. Adjust the socket path only if you deliberately changed Reth's IPC setting.
Do not enable `admin` on the public HTTP/WebSocket API for this query.
Use the public-key portion of `result.enode`: in this pinned Reth version,
[`result.id` is a hash](https://github.com/DogeOS69/reth/blob/972366a0bfc11cf6a0d5dc79d5e779cd81e32232/crates/rpc/rpc/src/admin.rs),
not the 128-character public key required for the allowlist.

## Optional Inbound Address

An enode advertises where peers can dial the node. This is distinct from the
source IP used by the node's outbound connections. Public inbound connectivity
is not required merely to submit a public key and egress CIDRs for allowlisting.

If your deployment needs a fixed reachable inbound endpoint, set these in `.env`
using your actual address (the address below is only a documentation example):

```dotenv
L2RETH_P2P_PUBLIC_IP=203.0.113.10
L2_P2P_PORT=30303
```

Permit/forward TCP and UDP on `L2_P2P_PORT` to the host. The container listens
on that same port, and `--nat extip:...` advertises the configured IPv4. If left
unset, Reth uses its default NAT discovery. The native enode's address may be
private, unspecified or outdated until discovery completes; it is not evidence
of public reachability or the source address seen by DogeOS. The public-key
portion still identifies the node.

Do not override identity, NAT, P2P ports or instance port offsets through
`L2RETH_EXTRA_ARGS`; use the dedicated settings. Apply changes with staged
`start` in a maintenance window; `docker compose restart` does not reload `.env`.
Coordinate egress changes with operations before switching addresses. A stable
private key fixes the public key; the whole enode also needs a stable inbound
IP and port.

## Backup and Recovery

Back up the private key securely and separately from chain snapshots. Losing
it requires a new identity and a new public-key allowlist entry. Treat a leaked
key as compromised and coordinate replacement with operations.

Snapshot groups contain chain data, never operator identities. Restoring a
complete or partial group, or running `reset-chain-data.sh`, retains the
external identity. L2 archives containing `discovery-secret`, `nodekey`,
`p2p-secret-key`, `l2reth-p2p.key`, `l2reth-identity` or keystores are rejected.
Startup and destructive L2 data operations require an initialized valid key;
there is no automatic key generation at container startup. A missing file
fails the Compose bind mount instead of creating a directory or a new identity.
