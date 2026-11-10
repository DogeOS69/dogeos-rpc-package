# Snapshot Publishing

P2P identities are operator-owned and never part of a snapshot group. Initialize
or migrate yours **before restoring/replacing L2 data**; see
[P2P Identity](p2p-identity.md). Publishers must exclude `discovery-secret`,
`nodekey`, `p2p-secret-key`, `l2reth-p2p.key`, `l2reth-identity/` and keystores.
Restore validation rejects them; restore/reset preserves the separate identity.

This is the contract for testnet snapshot groups and
`scripts/snapshot-group.py`. Groups contain independently downloadable
Dogecoin, L1 Interface and L2Reth archives; a component may explicitly be
missing. Service images remain pinned by Compose. A group never selects or
changes images.

## S3 Layout

```text
s3://dogeos-rpc-snapshots/testnet/
  group-index.json                    # mutable group catalog, schema 2 (snapshot-group.py)
  group-index.json.sig                # when index signing is enabled
  index.json                          # mutable component index, schema 1 (restore-snapshot.sh)
  index.json.sig                      # when index signing is enabled
  groups/<group-id>.json              # immutable group manifest
  dogecoin/<archive>.tar.gz           # immutable, shared by both catalogs
  l1-interface/<archive>.tar.gz       # immutable, shared by both catalogs
  l2reth/<archive>.tar.gz             # immutable, shared by both catalogs
```

The default group catalog URL is
`https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/group-index.json`
(override with `--index-url` or `SNAPSHOT_GROUP_INDEX_URL`). The schema-1
component index stays at `testnet/index.json` for `restore-snapshot.sh`
(override with `--index-url` or `SNAPSHOT_INDEX_URL`). The two files are
independent: publishing a group never rewrites `index.json`, and the same
archives may be listed in both.

A local package does not prove that a catalog has been published. Until
`group-index.json` exists, `snapshot-group.py list` reports that it cannot
download the catalog. Publish it before directing operators to group restore;
a catalog with an empty `groups` list is valid. New uploads need no package
release unless the schema, archive rules or trusted signers change.

## Group Catalog Format (schema version 2)

```json
{
  "schema_version": 2,
  "network": "testnet",
  "published_at": "2026-10-23T02:00:00Z",
  "groups": [
    {
      "id": "20261023-0100",
      "published_at": "2026-10-23T02:00:00Z",
      "manifest": {
        "url": "https://YOUR-BUCKET/testnet/groups/20261023-0100.json",
        "sha256": "REPLACE_WITH_MANIFEST_SHA256"
      }
    }
  ]
}
```

Group IDs are unique and must never be reused with different contents.
`latest` selects the most recently published group once, without independently
selecting newer components. An incompatible selected group is an error; the
client does not silently switch groups or borrow components. An explicit ID
pins the choice across commands. The descriptor pins the exact manifest bytes
by SHA-256; the manifest pins each archive. Set `Content-Type: application/json`
and `Cache-Control: no-cache` on the mutable catalog.

The schema-1 component index (`index.json`) keeps its format and is read only
by `restore-snapshot.sh`, which rejects a schema-2 catalog; `snapshot-group.py`
rejects a schema-1 index. Keep each schema in its own file: never add groups to
`index.json` or component entries to `group-index.json`. Listing an archive in
`index.json` as well is optional and only serves component restores, which
have no dependency checkpoints.

## Group Manifest

See the complete, syntactically valid
[group manifest example](group-manifest.example.json). Its URLs, checksums,
heights and image references are illustrative and must be replaced by values
from the frozen source data.

| Field | Requirement |
|-------|-------------|
| `schema_version` | `2` |
| `group_id`, `network`, `published_at` | Match the catalog descriptor and network; timestamp is UTC with `Z` |
| `identity.genesis_sha256` | SHA-256 of the exact package L2 genesis file bytes |
| `identity.protocol_context_sha256` | SHA-256 of the exact package protocol-context file bytes |
| `components` | All three keys: `dogecoin`, `l1-interface`, `l2reth`; use JSON `null` for no snapshot |

Each non-null component requires:

| Field | Requirement |
|-------|-------------|
| `id`, `source_revision` | Identify the artifact and the producing source revision |
| `captured_at` | UTC time the data stopped changing, not compression/upload completion |
| `compatible_images` | Nonempty list of exact image references that can open the data, as `docker compose config --images` prints them (including any `@sha256:` digest) |
| `checkpoint.height`, `checkpoint.hash` | Data tip: Dogecoin, synthetic L1, or L2 height and block hash |
| `requires` | Dogecoin: `{}`; L1 Interface: `{"dogecoin": <checkpoint>}`; L2Reth: `{"l1-interface": <checkpoint>}` |
| `archive.url`, `archive.sha256` | HTTPS `.tar.gz` URL and lowercase SHA-256 |
| `archive.size_bytes`, `archive.uncompressed_bytes` | Positive download and extracted-size values for disk checks |
| `replay` | L1 only: `validated_up_to`, `discovered_up_to`, and `state_hash` |

Heights are nonnegative JSON integers. Hashes are 64 lowercase hex characters
without `0x`. All present components inherit the group network and protocol
identity. A standalone publication is a group with one entry and two explicit
nulls. An all-null group is valid; operators can also use `start` without any
snapshot catalog.

The group manifest replaces optional per-component human-readable manifests
as the machine-readable dependency contract. Keep additional provenance,
bootstrap identity and restore-test results alongside it. The client validates
metadata and file integrity; it cannot prove that a producer truthfully
reported the database contents. Restore/start tests remain mandatory.

## Image Compatibility

Before activation, every present component must list the exact image from the
resolved Compose configuration. Genesis and protocol-context file checksums
must also match. Archive compatibility does not establish compatibility of
arbitrary service versions: publishers must test the whole intended stack.
Do not change Compose images automatically to fit a snapshot.

## Component Dependencies

Services depend on each other as Dogecoin -> L1 Interface -> L2Reth.
Freeze source data in the reverse order: **L2Reth, L1 Interface, Dogecoin**.
For example, L2Reth at 01:00, L1 Interface at 01:02 and Dogecoin at 01:05 is
normal: the downstream nodes catch up using newer upstream data. Keep a
component stopped until its data has been copied to an immutable capture;
compression/upload of that copy can finish later.

Capture checkpoint hashes from the frozen data, or from a restored clone of
that exact capture. For an upstream requirement, use the dependency recorded
in the frozen downstream state, or a verified upper bound sampled after the
downstream has stopped. Sampling before stopping the downstream is not a
reliable upper bound. Verify that checkpoints belong to the same canonical
history. Time ordering alone is not proof of that relationship.

Older upstream snapshots are allowed. Startup waits for their heights to
cover downstream requirements, then verifies hashes. A known hash conflict
at the same height is rejected; a runtime hash mismatch stops startup for
investigation. Readiness alone is not proof of a required checkpoint.

## Archive Layout

All archives contain a single component root. The validators reject absolute
paths, parent traversal, links, special files, duplicate normalized paths and
forbidden names before extraction. Forbidden directory trees are rejected
even when the tar has no explicit directory headers.

**l2reth** — `l2reth/` containing regular `db/mdbx.dat`, `db/scroll.db`, and a
`static_files/` directory. Exclude `jwt.hex`, `reth.toml`, the entire `genesis/`
and `lost+found/` trees, `protocol_context.json`, node keys and keystores.

**dogecoin** — `dogecoin/` containing `dogecoin/testnet3/blocks/` and `dogecoin/testnet3/chainstate/`. Required LevelDB files are
`dogecoin/testnet3/blocks/index/CURRENT` and `dogecoin/testnet3/chainstate/CURRENT`. Exclude wallets, `*.conf`, `.cookie`, `peers.dat`, `banlist.dat`
and `.lock`. Take a consistent, unpruned database with its transaction index.

**l1-interface** — fixed directory layout:

```text
l1-interface/
  l1-interface.sqlite
  replay.sqlite
  replay.artifacts/
    eth_da_artifacts.sqlite
    eth_da_artifacts/                  # include even if empty
    ...
  l1-interface-historical-artifact.sqlite  # when configured
```

Take every L1 file from the same stopped instance. Preserve the full artifact
tree. Checkpoint and close every mutable SQLite database after all writers
stop. Never delete WAL files to make an archive pass validation. Exclude
`-wal`, `-shm`, `-journal`, configuration, credentials and keys. The optional
`replay.sqlite.bootstrap-source.json` provenance file may be included.

Restore checks fixed runtime paths and mounts, required archive files, and
read-only SQLite `quick_check` before activating L1 data. Testnet also verifies the historical artifact against the checksum in its pinned bootstrap URL.
These checks do not establish semantic consistency between the databases,
replay and DA artifacts. Test actual historical RPC and DA reads after restore.

### L1 Interface Publication Metadata

The L1 component's `checkpoint` identifies the synthetic L1 tip and `requires`
identifies its Dogecoin dependency. Include replay progress and state hash.
Record bootstrap identity, source image/revision, and the results of clean
shutdown, integrity checks and restore/start testing in publication records.
All three component checkpoints and dependency hashes must come from the
actual captured data; do not copy them from a previous group.

## Publishing Steps

1. Freeze/capture L2Reth, then L1 Interface, then Dogecoin. Omitted components
   remain explicit nulls. Checkpoint databases and validate each archive.
2. Restore the captures with the intended images and release configuration;
   check checkpoint hashes, readiness, continued sync, historical RPC and DA.
3. Upload every planned archive under a new immutable name. Download and
   verify its SHA-256 and size once from S3.
4. Build the immutable group manifest with all metadata. Validate locally:
   `python3 scripts/snapshot-group.py validate group.json`.
5. Upload `groups/<group-id>.json`, then download it and compute the checksum
   used in the catalog. Do not expose an unfinished group as a partial group.
6. Build and validate the new catalog with
   `python3 scripts/snapshot-group.py validate-index group-index.json`. Update its
   timestamp. Publish the signature first when enabled, then the catalog last.
   Readers racing those two writes may fail signature verification and must
   retry; they never bypass verification.
7. Run `python3 scripts/snapshot-group.py list` and verify the chosen group's
   restore on a disposable node before announcing availability.
8. Retain groups as units (at least three recent groups is a reasonable
   default). Delete a manifest/archive only after **no retained group refers
   to it**, plus a grace period long enough for in-flight restores. Do not use
   per-component "keep newest three" deletion or an age-only lifecycle rule.

## Bucket Protection

Restrict writes to the publication pipeline, enable versioning, and audit
unexpected writes. Without signatures this write boundary is the trust root.
Checksums detect mismatched artifacts; they do not authenticate a maliciously
replaced unsigned catalog.

## Optional: Signed Index

When `testnet/snapshots/allowed_signers` exists, both index clients require
verification using identity `dogeos-snapshots` and namespace
`dogeos-snapshot-index`. Ship the Ed25519 public key as:

```text
dogeos-snapshots <public key>
```

Keep the private key in the publishing pipeline. Sign each catalog you
publish; each client verifies the `.sig` next to the catalog it reads:

```bash
ssh-keygen -Y sign -f snapshot-signing-key -n dogeos-snapshot-index group-index.json
ssh-keygen -Y sign -f snapshot-signing-key -n dogeos-snapshot-index index.json
```

Publish signatures before releasing a package that requires them. The signed
catalog authenticates the manifest checksum, which authenticates archive
checksums and checkpoint metadata.
