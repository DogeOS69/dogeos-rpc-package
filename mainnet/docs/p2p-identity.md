# Persistent L2 P2P Identity and Allowlisting

Run commands from this network directory using the same `.env` as deployment.
The host needs Python 3.9+, OpenSSL with secp256k1 support, and Docker Compose.
These commands resolve Compose configuration but do not need a running node.
Mainnet commands require the release configuration, which is not yet shipped.

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

`init` generates a secp256k1 key once; subsequent runs retain it. It prints
only the public node ID. To import your own key from a private file instead:

```bash
python3 scripts/p2p-identity.py init --import-key /your/private/existing-key
```

Import accepts a 32-byte hex private key, optionally prefixed with `0x` or
followed by a newline, and writes the canonical 64 hex characters Reth expects.
It copies the source and refuses to overwrite a different existing identity.
Never put the private key in `.env`, command-line arguments, tickets or chat.
An existing canonical key at `L2RETH_P2P_KEY_FILE` can be reused directly.
All three commands (`init`, `check`, `show`) accept `--env-file /path/to/.env`.

## Existing Node Migration

Run `init` while the old chain directory is still present, **before** a restore,
reset or first restart with this package. If the destination does not exist,
`init` copies `${DATA_ROOT}/l2reth/discovery-secret`, preserving the old node ID
and leaving the original in place. Existing chain data without that file
causes an error; locate and explicitly import the original key. If your old
setup passed a P2P key via `L2RETH_EXTRA_ARGS`, remove that override and import
its key before continuing. The script will not silently rotate an identity.

After verifying the public ID, use the staged startup during a maintenance
window to recreate containers with the new mount:

```bash
python3 scripts/p2p-identity.py check
python3 scripts/snapshot-group.py start
```

Keep `DATA_ROOT` and `L2RETH_P2P_KEY_FILE` stable. Moving to another disk or host
requires transferring the identity securely before `init`; never run two nodes
with the same private key at the same time.

## Send Public Information to Operations

Set these values in `.env` using your real network configuration:

```dotenv
L2RETH_P2P_PUBLIC_IP=203.0.113.10
L2_P2P_PORT=30303
L2RETH_P2P_SOURCE_CIDRS=198.51.100.20/32
```

These are documentation addresses, not working endpoints. `PUBLIC_IP` is the
stable, reachable IPv4 advertised in your enode. Permit/forward TCP and UDP
on `L2_P2P_PORT` to this host. The container listens on that same port, and
`--nat extip:...` advertises the configured address. If you leave `PUBLIC_IP`
unset, Reth uses its default NAT discovery; the node ID remains stable but
the endpoint may change, and `show` refuses to export an incomplete address.

`SOURCE_CIDRS` is a comma-separated list of the **actual public egress CIDRs**
seen by upstream peers, such as a NAT gateway's public IPv4 with `/32`. Confirm
these with your network administrator. They may differ from the advertised
inbound address. This value is reporting metadata; it does not configure a
local firewall or restrict which peers this node accepts.

```bash
python3 scripts/p2p-identity.py show
```

Send the resulting JSON to operations. It contains only:

- `network`: which network to allowlist.
- `node_id`: the 128-hex-character secp256k1 public key (without `04` or `0x`).
- `enode`: `enode://<node_id>@<public-ip>:<p2p-port>`.
- `source_cidrs`: the outbound ranges that need IP allowlisting.

Operations must add **both** the public-key and IP allowlists. Wait for their
confirmation before expecting L2 peer connections; zero peers can mean the
allowlists are still pending. No command here sends data to operations or
changes their allowlists. No `admin` RPC namespace is needed to derive the ID.
After startup, follow [RPC verification](verify-node.md) to check peers and sync.

Do not override identity, NAT, P2P ports or instance port offsets through
`L2RETH_EXTRA_ARGS`; the scripts reject these overrides to keep the exported
address consistent with the node. After IP/port/CIDR changes, send updated
information to operations and apply configuration using the staged `start`
command in a maintenance window. `docker compose restart` does not reload `.env`.
A stable private key fixes the node ID; keeping the entire enode stable also
requires a stable advertised IP and port.

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
