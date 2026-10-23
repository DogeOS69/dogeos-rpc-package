# Snapshot Publishing

This is the contract between the testnet snapshot publishing pipeline and
`testnet/scripts/restore-snapshot.sh`. Publishing a new snapshot is an S3
upload and an index update; it does not need a package release.

A package release is needed only to change the index URL, the archive layout
rules enforced by the script, or the signer list
(`testnet/snapshots/allowed_signers`).

## S3 Layout

```text
s3://dogeos-rpc-snapshots/
  testnet/
    index.json                       # the only object that is overwritten
    index.json.sig                   # only once signing is enabled
    dogecoin/<archive>.tar.gz
    dogecoin/<archive>.manifest.json # optional, recommended
    l1-interface/<archive>.tar.gz
    l1-interface/<archive>.manifest.json
    l2reth/<archive>.tar.gz
    l2reth/<archive>.manifest.json
```

- Archives and manifests are immutable. Never overwrite one; publish a new
  name, for example `dogeos-l2reth-testnet-<UTC timestamp>.tar.gz`.
- Serve `index.json` with `Content-Type: application/json` and
  `Cache-Control: no-cache` so a CDN or proxy does not keep an old index.
- The restore script reads `https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/index.json`.

## Index Format (schema version 1)

```json
{
  "schema_version": 1,
  "network": "testnet",
  "published_at": "2026-10-20T00:00:00Z",
  "components": {
    "dogecoin": [ <entry>, ... ],
    "l1-interface": [ <entry>, ... ],
    "l2reth": [ <entry>, ... ]
  }
}
```

Each entry:

| Field | Required | Meaning |
|-------|----------|---------|
| `id` | yes | Unique within the component. Users pass it to `--snapshot-id`. |
| `created_at` | yes | ISO 8601 UTC time of the source data. The newest compatible entry is selected. |
| `height` | no | Block height of the data (Dogecoin, L1 Interface synthetic L1, or L2), shown by `--list`. |
| `dogecoin_height` | no | `l1-interface` only: Dogecoin height the data was indexed against. |
| `l1_height` | no | `l2reth` only: L1 Interface block the data was derived against. |
| `compatible_images` | yes | Image references that can open this data, written exactly as in `testnet/docker-compose.yml` (for example `dogeos69/rollup-node:v0.3.0-beta.1c`). |
| `archive.url` | yes | HTTPS URL of a `.tar.gz` archive. |
| `archive.sha256` | yes | Lowercase hex SHA-256 of the archive. |
| `archive.size_bytes` | no | Archive size; used for the free-space check. |
| `archive.uncompressed_bytes` | no | Extracted size; used for the free-space check. |
| `manifest_url` | no | Human-readable manifest; printed when the snapshot is selected. |

A component with no entries can be omitted. Clients ignore unknown fields, so
fields can be added without a schema change.
Change `schema_version` only for an incompatible change; older scripts then
refuse the index instead of misreading it.

## Image Compatibility

The script restores only a snapshot whose `compatible_images` contains the
image in `testnet/docker-compose.yml`. Mainnet has its own index and may run
other versions. Before releasing a package that changes testnet's
`dogecoin-node`, `l1-interface`, or `l2reth-node` image, update the testnet
index:

- If the new image opens existing data unchanged, add the new image reference
  to the `compatible_images` of the current entries.
- If it needs a new database format, publish a snapshot produced by the new
  image first.

Otherwise operators of the new release see "no published snapshot is
compatible". Keep the old image listed while operators of the previous release
still restore snapshots.

## Component Dependencies

Services depend on each other as Dogecoin -> L1 Interface -> L2Reth. Snapshots
of different components may be published at different times, so a restore can
combine data of different ages:

- **Downstream older than upstream** is the normal case: the restored service
  catches up.
- **Downstream newer than upstream** requires upstream catch-up. Start services
  in dependency order and verify the required checkpoints before starting the
  downstream service. The restore script can warn about height differences;
  it does not enforce checkpoint compatibility.
- **Upstream moving backwards under a running downstream** is the case to
  avoid: rollup-node treats a lower L1 Interface head as an L1 reorg and
  unwinds L2 state. The restore script therefore stops the component and every
  service downstream of it before activating restored data.

Record `dogecoin_height` and `l1_height` so the script can warn about the
second case. Upper bounds are enough:

- `l1_height`: the L1 Interface `eth_blockNumber` the source L2Reth node was
  following, read just before the L2Reth snapshot.
- `dogecoin_height`: the source Dogecoin node's `getblockcount`, read just
  before the L1 Interface snapshot.

When one pipeline run publishes several components, snapshot them in the
order **L2Reth, then L1 Interface, then Dogecoin**. Freeze each component before
capturing it, and verify dependency heights and hashes afterwards. Capture
order alone does not prove canonical compatibility if a chain reorganization
or source mismatch occurs. Components may also be published on their own
schedules, for example L2Reth weekly and Dogecoin monthly.

## Archive Layout

Publishers must enforce the following archive rules. The restore script checks
member paths, required database files, and specific forbidden names; it is not
a complete validator of these rules. In particular, the L2Reth checks match
`genesis/` and `lost+found/` directory entries but do not reject their children
when the archive omits those directory entries. Publishers must exclude the
entire directory trees, even if the script accepts an archive.

**l2reth** — a single `l2reth/` root containing `db/mdbx.dat`, `db/scroll.db`,
and `static_files/`. It must not contain `jwt.hex`, `reth.toml`, `genesis/`,
`protocol_context.json`, `lost+found`, node keys, or keystores.

**l1-interface** — one `l1-interface/` root with this fixed layout:

```text
l1-interface/
  l1-interface.sqlite
  replay.sqlite
  replay.artifacts/
    eth_da_artifacts.sqlite
    eth_da_artifacts/
    ...
  l1-interface-historical-artifact.sqlite  # required when configured
```

Take all files from one stopped L1 Interface instance. Preserve the complete
`replay.artifacts/` tree, including empty DA artifact directories. Normalize
source deployment paths into this layout before packaging. Do not store host
absolute paths or another nested `l1-interface/` root. Testnet requires the
historical artifact matching the package's bootstrap checksum; mainnet only
requires it if its release configuration explicitly uses one.

Checkpoint every mutable SQLite database after all writers have stopped,
including the metadata DB inside `replay.artifacts/`. Checkpoint/close must
succeed; never delete an outstanding WAL to make the archive pass. Published
archives must not contain `-wal`, `-shm`, or `-journal` sidecars, configuration,
credentials, keys, links, special files, or duplicate members. The optional
`replay.sqlite.bootstrap-source.json` provenance file may be included.

The restore validates the resolved data mount and runtime paths, checks the
archive structure, then runs SQLite `quick_check` on the staged databases
and verifies the testnet historical artifact checksum before stopping services.
It does not validate every replay reference or protocol state. The publisher
must restore/start the full archive with the declared compatible image and
network configuration, check readiness and replay progress, and exercise
historical RPC and DA artifact reads before publishing it.

**dogecoin** — a single `dogecoin/` root containing
`dogecoin/testnet3/blocks/` and `dogecoin/testnet3/chainstate/`. The required LevelDB
files are `dogecoin/testnet3/blocks/index/CURRENT` and
`dogecoin/testnet3/chainstate/CURRENT`. It must not contain wallets, `*.conf`, `.cookie`, `peers.dat`,
`banlist.dat`, or `.lock`.

No archive may contain absolute paths or `..` components.


### L1 Interface Publication Metadata

For each new L1 Interface entry, supply `height` (synthetic L1 height),
`dogecoin_height`, `archive.size_bytes`, `archive.uncompressed_bytes`, and a
`manifest_url`, even though the generic index schema allows these fields to be
omitted for older snapshots. The manifest must record the image and source
revision, network/protocol identity, genesis/protocol-context checksums,
Dogecoin and synthetic L1 checkpoint heights and hashes, replay progress and
state hash, historical-bootstrap identity when applicable, and the results of
checkpoint, database-integrity, and restore/start validation. Publish manifests
beside archives; configuration and credentials never go inside the data archive.

Components may be published on separate schedules. Do not require matching
snapshot dates or change Compose images when selecting a snapshot. There is
no image-set or snapshot-set selection mechanism in the package.

## Publishing Steps

1. Produce and validate the archive (clean shutdown, checkpoint check, layout
   rules above).
2. Upload the archive and manifest under new names.
3. Download the uploaded archive once and verify its SHA-256 from S3.
4. Build the new index: add the entry, keep the newest entries per component
   (3 is recommended), and set `published_at`.
5. Upload `index.json` (and `index.json.sig` first, once signing is enabled).
6. Run `./scripts/restore-snapshot.sh --list` in `testnet/` against the
   published index.
7. Delete archives no longer listed after a grace period of a few days, so a
   restore that started from the previous index can finish. An S3 lifecycle
   rule on the archive prefixes can do this.

Never delete an archive that the current index still lists.

## Bucket Protection

Without signatures, the index and archives are trusted because only the
publishing pipeline can write to the bucket:

- Grant write access only to the publishing pipeline's role; everyone else
  reads.
- Enable bucket versioning so an overwritten or deleted index can be restored.
- Alert on writes from any other principal (for example with CloudTrail).

## Optional: Signed Index

The script verifies `index.json.sig` whenever the package contains
`testnet/snapshots/allowed_signers`. To enable signing:

1. Create an Ed25519 key for the pipeline; keep the private key in the
   pipeline's secret store.
2. Release a package containing `testnet/snapshots/allowed_signers` with the line
   `dogeos-snapshots <public key>`. Several lines allow key rotation.
3. Sign every index before uploading it:

   ```bash
   ssh-keygen -Y sign -f snapshot-signing-key -n dogeos-snapshot-index index.json
   ```

   This writes `index.json.sig`. Upload it immediately before `index.json`.

Start signing before releasing the package that ships the signer list, so the
signature is already in place when operators update.

## Initial Testnet Index

The index for the snapshots already published before this mechanism existed.
It was uploaded as `testnet/index.json`; later indexes replace it:

```json
{
  "schema_version": 1,
  "network": "testnet",
  "published_at": "2026-10-20T00:00:00Z",
  "components": {
    "l2reth": [
      {
        "id": "20260828014612",
        "created_at": "2026-08-28T01:46:12Z",
        "compatible_images": ["dogeos69/rollup-node:v0.3.0-beta.1c"],
        "archive": {
          "url": "https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/l2reth/dogeos-l2reth-testnet-20260828014612.tar.gz",
          "sha256": "20bd404a9e1fdfd38a75e7a2d8cd8d5ebdf272fdea7ed45ede82c1c07548c48a",
          "size_bytes": 4114303515
        }
      }
    ],
    "dogecoin": [
      {
        "id": "20260908194510",
        "created_at": "2026-09-08T19:45:12Z",
        "height": 67878838,
        "compatible_images": ["dogeos69/dogecoin:1.14.9"],
        "archive": {
          "url": "https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/dogecoin/dogeos-dogecoin-testnet-20260908194510.tar.gz",
          "sha256": "639b8ed83bad78795d3cc06c9f528e2e6ed604dd76b077ebdbd17b3477549320",
          "size_bytes": 25313829142,
          "uncompressed_bytes": 43590952769
        },
        "manifest_url": "https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com/testnet/dogecoin/dogeos-dogecoin-testnet-20260908194510.manifest.json"
      }
    ]
  }
}
```

The L2Reth entry has no height or extracted size because the earlier snapshot
did not record them; the free-space check then covers only the download.
