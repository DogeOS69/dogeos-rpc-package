#!/usr/bin/env bash
set -euo pipefail

# Deprecated: kept for one release so existing commands keep working. Use
# scripts/restore-snapshot.sh l2reth <env-file>. Options and the
# L2RETH_SNAPSHOT_* environment overrides are unchanged.
echo "NOTE: restore-l2reth-snapshot.sh is deprecated and will be removed;" >&2
echo "      use: scripts/restore-snapshot.sh l2reth <env-file>" >&2
exec bash "$(dirname "${BASH_SOURCE[0]}")/restore-snapshot.sh" l2reth "$@"
