#!/usr/bin/env bash
set -euo pipefail

# Kept for existing commands and documentation links. Snapshots are now
# selected from the published index; see scripts/restore-snapshot.sh --help.
# Options and the L2RETH_SNAPSHOT_* environment overrides are unchanged.
exec bash "$(dirname "${BASH_SOURCE[0]}")/restore-snapshot.sh" l2reth "$@"
