#!/usr/bin/env bash
set -euo pipefail

# Checks for this network directory, run by CI (.github/workflows/check.yml)
# and runnable locally: shellcheck on its scripts, its Compose configuration
# resolved the way an operator runs it, and its documentation links. Needs
# bash, git, docker with Compose, python3, and shellcheck (or Docker, which
# runs the shellcheck image instead).

NETWORK=mainnet
NETWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="$(cd "$NETWORK_DIR/.." && pwd -P)"
cd "$REPO_ROOT"
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.10.0"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
failures=0

step() { printf '\n== %s: %s\n' "$NETWORK" "$*"; }
failed() { echo "FAILED: $*" >&2; failures=$((failures + 1)); }

step "shellcheck"
scripts=()
# Tracked and new (untracked, not ignored) files, so new work is checked too.
while IFS= read -r f; do scripts+=("$f"); done < <(git ls-files -co --exclude-standard "$NETWORK/*.sh")
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning -x "${scripts[@]}" || failed "shellcheck"
else
  docker run --rm -v "$REPO_ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" \
    -S warning -x "${scripts[@]}" || failed "shellcheck"
fi

# Resolve the Compose configuration the way an operator runs it: env.example
# copied to .env, plain `docker compose` in this directory. Configuration files
# not shipped yet (see README.md) are stubbed in a temporary copy so the rest
# is still checked; the repository is not modified.
step "docker compose config"
copy="$WORK_DIR/$NETWORK"
mkdir -p "$copy"
git ls-files -z -co --exclude-standard "$NETWORK" | tar --null -T - -cf - | tar -xf - -C "$WORK_DIR"
for f in docker-compose.yml env.example README.md CHANGELOG.md \
    scripts/dogecoin_entrypoint.sh scripts/l1-interface_entrypoint.sh \
    scripts/l2reth_entrypoint.sh scripts/restore-snapshot.sh \
    scripts/reset-chain-data.sh scripts/lib/env.sh; do
  [ -e "$copy/$f" ] || failed "$NETWORK/$f is missing"
done
stubbed=""
for f in dogecoin.conf l2reth.env l2reth-genesis.json protocol_context.json l1-interface.env; do
  if [ ! -e "$copy/config/$f" ]; then
    case "$f" in
      *.json) echo '{}' >"$copy/config/$f" ;;
      *) : >"$copy/config/$f" ;;
    esac
    stubbed="$stubbed $f"
  fi
done
[ -z "$stubbed" ] || echo "stubbed (not shipped yet):$stubbed"
sed -e "s|^DATA_ROOT=.*|DATA_ROOT=$WORK_DIR/data|" \
    -e "s|^DOGECOIN_RPC_PASSWORD=\$|DOGECOIN_RPC_PASSWORD=check|" \
    "$copy/env.example" >"$copy/.env"
if config="$(cd "$copy" && docker compose config --format json)"; then
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
' "$NETWORK" || failed "configuration checks"
else
  failed "docker compose config"
fi

step "Markdown links"
python3 - "$NETWORK" <<'EOF' || failed "Markdown links"
import os, re, subprocess, sys
network = sys.argv[1]
files = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", f"{network}/*.md"],
                       capture_output=True, text=True, check=True).stdout.split()

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
  echo "$NETWORK: $failures check(s) failed" >&2
  exit 1
fi
echo "$NETWORK: all checks passed."
