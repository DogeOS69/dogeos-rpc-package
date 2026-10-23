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

# Each network directory is self-contained: check its own files and resolve its
# Compose configuration the way an operator runs it (env.example copied to
# .env in that directory, plain `docker compose`). Configuration files a
# network does not ship yet (see <network>/README.md) are stubbed in a
# temporary copy so the rest is still checked; the repository is not modified.
NETWORK_FILES="docker-compose.yml env.example README.md scripts/dogecoin_entrypoint.sh scripts/l1-interface_entrypoint.sh scripts/l2reth_entrypoint.sh scripts/restore-snapshot.sh scripts/reset-chain-data.sh scripts/lib/env.sh"
CONFIG_FILES="dogecoin.conf l2reth.env l2reth-genesis.json protocol_context.json l1-interface.env"
for network in testnet mainnet; do
  step "docker compose config: $network"
  copy="$WORK_DIR/$network-repo"
  mkdir -p "$copy"
  git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$copy"
  dir="$copy/$network"
  for f in $NETWORK_FILES; do
    [ -e "$dir/$f" ] || failed "$network: $network/$f is missing"
  done
  stubbed=""
  for f in $CONFIG_FILES; do
    if [ ! -e "$dir/config/$f" ]; then
      case "$f" in
        *.json) echo '{}' >"$dir/config/$f" ;;
        *) : >"$dir/config/$f" ;;
      esac
      stubbed="$stubbed $f"
    fi
  done
  [ -z "$stubbed" ] || echo "stubbed (not shipped yet):$stubbed"
  sed -e "s|^DATA_ROOT=.*|DATA_ROOT=$WORK_DIR/data-$network|" \
      -e "s|^DOGECOIN_RPC_PASSWORD=\$|DOGECOIN_RPC_PASSWORD=check|" \
      "$dir/env.example" >"$dir/.env"
  if config="$(cd "$dir" && docker compose config --format json)"; then
    printf '%s' "$config" | python3 -c '
import json, sys
network = sys.argv[1]
services = json.load(sys.stdin)["services"]
expected = {"dogecoin-node", "l1-interface", "l2reth-node"}
if network == "testnet":
    expected.add("l1-interface-init-fetch-sqlite")
problems = []
if set(services) != expected:
    problems.append(f"services {sorted(services)}, expected {sorted(expected)}")
for name in sorted(set(services) & expected):
    svc = services[name]
    image = svc.get("image", "")
    if not image or image.endswith(":latest") or ":" not in image:
        problems.append(f"{name} must pin an image tag, got {image!r}")
    entrypoint = svc.get("entrypoint")
    if name != "l1-interface-init-fetch-sqlite" and entrypoint != ["/bin/sh", "/entrypoint.sh"]:
        problems.append(f"{name} must run its scripts/ entrypoint, got {entrypoint}")
    print(f"  {name:32} {image}")
if problems:
    sys.exit("\n".join(f"{network}: {p}" for p in problems))
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
