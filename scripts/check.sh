#!/usr/bin/env bash
set -euo pipefail

# Repository checks run by CI (.github/workflows/check.yml); also runnable
# locally. Needs bash, git, docker with Compose, python3, and shellcheck
# (or Docker, which runs the shellcheck image instead).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$REPO_ROOT"
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.10.0"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
failures=0

step() { printf '\n== %s\n' "$*"; }
failed() { echo "FAILED: $*" >&2; failures=$((failures + 1)); }

step "shellcheck"
scripts=()
while IFS= read -r f; do scripts+=("$f"); done < <(git ls-files '*.sh')
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "${scripts[@]}" || failed "shellcheck"
else
  docker run --rm -v "$REPO_ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" \
    -S warning "${scripts[@]}" || failed "shellcheck"
fi

# Resolve the Compose configuration of every network from its env template.
# Files a network does not ship yet (see networks/<network>/README.md) are
# stubbed in a temporary copy so the rest of its configuration is still
# checked; the repository itself is not modified.
REQUIRED_FILES="compose.yml env.example dogecoin.conf l2reth.env l2reth-genesis.json protocol_context.json l1-interface.env l1-interface-bootstrap.env"
for network_dir in networks/*/; do
  network="$(basename "$network_dir")"
  step "docker compose config: $network"
  copy="$WORK_DIR/$network-repo"
  mkdir -p "$copy"
  git ls-files -z | (cd "$REPO_ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$copy"
  stubbed=""
  for f in $REQUIRED_FILES; do
    if [ ! -e "$copy/networks/$network/$f" ]; then
      case "$f" in
        compose.yml|env.example) failed "$network: networks/$network/$f is missing"; continue 2 ;;
        *.json) echo '{}' >"$copy/networks/$network/$f" ;;
        *) : >"$copy/networks/$network/$f" ;;
      esac
      stubbed="$stubbed $f"
    fi
  done
  [ -z "$stubbed" ] || echo "stubbed (not shipped yet):$stubbed"
  env_file="$WORK_DIR/$network.env"
  sed -e "s|^DATA_ROOT=.*|DATA_ROOT=$WORK_DIR/data-$network|" \
      -e "s|^DOGECOIN_RPC_PASSWORD=\$|DOGECOIN_RPC_PASSWORD=check|" \
      "$copy/networks/$network/env.example" >"$env_file"
  grep -qx "NETWORK=$network" "$env_file" ||
    failed "$network: env.example must set NETWORK=$network"
  if config="$(cd "$copy" && docker compose --env-file "$env_file" config --format json)"; then
    printf '%s' "$config" | python3 -c '
import json, sys
network = sys.argv[1]
services = json.load(sys.stdin)["services"]
expected = {"dogecoin-node", "l1-interface", "l2reth-node", "l1-interface-init-fetch-sqlite"}
missing = expected - set(services)
if missing:
    sys.exit(f"{network}: missing services {sorted(missing)}")
for name in sorted(expected):
    image = services[name].get("image", "")
    if not image or image.endswith(":latest") or ":" not in image:
        sys.exit(f"{network}: {name} must pin an image tag, got {image!r}")
    print(f"  {name:32} {image}")
if not services["l2reth-node"].get("environment", {}).get("L2RETH_NETWORK_ARGS"):
    sys.exit(f"{network}: l2reth-node needs L2RETH_NETWORK_ARGS")
' "$network" || failed "$network: configuration checks"
  else
    failed "$network: docker compose config"
  fi
done

step "Markdown links"
python3 - <<'EOF' || failed "Markdown links"
import os, re, subprocess, sys
files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True).stdout.split()

def anchors(path):
    found = set()
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^#+\s+(.*)", line)
        if m:
            slug = re.sub(r"[^\w\- ]", "", m.group(1).strip().lower()).replace(" ", "-")
            found.add(slug)
    return found

broken = 0
for f in files:
    for m in re.finditer(r"\]\(([^)\s]+)\)", open(f, encoding="utf-8").read()):
        link = m.group(1)
        if link.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, anchor = link.partition("#")
        target = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if not os.path.exists(target):
            print(f"{f}: missing target {link}")
            broken += 1
        elif anchor and target.endswith(".md") and anchor not in anchors(target):
            print(f"{f}: missing anchor {link}")
            broken += 1
print(f"{len(files)} files checked, {broken} broken links")
sys.exit(1 if broken else 0)
EOF

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All checks passed."
