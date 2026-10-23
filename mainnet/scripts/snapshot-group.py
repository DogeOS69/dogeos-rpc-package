#!/usr/bin/env python3
"""Pinned snapshot groups and dependency-ordered startup; Python standard library only."""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

COMPONENTS = ("dogecoin", "l1-interface", "l2reth")
SERVICES = dict(zip(COMPONENTS, ("dogecoin-node", "l1-interface", "l2reth-node")))
ROOT = Path(__file__).resolve().parents[1]
NETWORK = "mainnet"
INDEX_BASE = "https://dogeos-rpc-snapshots.s3.us-west-2.amazonaws.com"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hexhash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def timestamp(value):
    require(isinstance(value, str) and value.endswith("Z"), "timestamps must be UTC with Z suffix")
    return dt.datetime.fromisoformat(value[:-1] + "+00:00")


def checkpoint(value):
    require(isinstance(value, dict), "checkpoint must be an object")
    require(type(value.get("height")) is int and value["height"] >= 0, "invalid checkpoint height")
    require(hexhash(value.get("hash")), "checkpoint hash must be 64 lowercase hex characters (no 0x)")


def validate_manifest(group, network):
    require(isinstance(group, dict), "manifest must be an object")
    require(group.get("schema_version") == 2, "group manifest requires schema_version 2")
    require(group.get("network") == network, "group network does not match this package")
    require(isinstance(group.get("group_id"), str) and
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", group["group_id"]), "invalid group_id")
    published = timestamp(group.get("published_at"))
    identity = group.get("identity", {})
    require(isinstance(identity, dict), "identity must be an object")
    for key in ("genesis_sha256", "protocol_context_sha256"):
        require(hexhash(identity.get(key)), "missing/invalid identity." + key)
    components = group.get("components")
    require(isinstance(components, dict) and set(components) == set(COMPONENTS),
            "components must explicitly contain all three names; use null for missing snapshots")
    for name, entry in components.items():
        if entry is None:
            continue
        require(isinstance(entry, dict), "component must be an object or null")
        require(isinstance(entry.get("id"), str) and entry["id"], "component id is required")
        require(timestamp(entry.get("captured_at")) <= published, "capture must precede publication")
        require(isinstance(entry.get("source_revision"), str) and entry["source_revision"],
                "source_revision is required")
        images = entry.get("compatible_images")
        require(isinstance(images, list) and images and all(isinstance(x, str) and x for x in images),
                "compatible_images must be a nonempty list")
        checkpoint(entry.get("checkpoint"))
        upstream = entry.get("requires")
        expected = {} if name == "dogecoin" else {"dogecoin" if name == "l1-interface" else "l1-interface": None}
        require(isinstance(upstream, dict) and set(upstream) == set(expected), "invalid requires for " + name)
        for point in upstream.values():
            checkpoint(point)
        archive = entry.get("archive", {})
        require(isinstance(archive, dict), "archive must be an object")
        url = urllib.parse.urlsplit(archive.get("url", ""))
        require(url.scheme == "https" and url.hostname and not url.username and not url.password
                and url.path.endswith(".tar.gz") and not url.fragment, "archive must be an HTTPS .tar.gz URL without credentials")
        require(hexhash(archive.get("sha256")), "archive sha256 is required")
        for key in ("size_bytes", "uncompressed_bytes"):
            require(type(archive.get(key)) is int and archive[key] > 0, "positive archive." + key + " required")
        if name == "l1-interface":
            replay = entry.get("replay", {})
            require(isinstance(replay, dict), "replay must be an object")
            for key in ("validated_up_to", "discovered_up_to"):
                require(type(replay.get(key)) is int and replay[key] >= 0, "replay progress is required")
            require(replay["validated_up_to"] <= replay["discovered_up_to"], "invalid replay progress")
            require(hexhash(replay.get("state_hash")), "replay state_hash is required")
    # Older upstream data is allowed; checkpoint gates handle catch-up. A known
    # hash conflict at the exact same height is never a catch-up problem.
    for entry in components.values():
        if entry:
            for upstream, point in entry["requires"].items():
                other = components[upstream]
                if other and other["checkpoint"]["height"] == point["height"]:
                    require(other["checkpoint"]["hash"] == point["hash"], "conflicting group checkpoint hashes")
    return group


def validate_index(index, network):
    require(isinstance(index, dict), "index must be an object")
    require(index.get("schema_version") == 2 and index.get("network") == network,
            "expected a schema_version 2 index for " + network + "; legacy indexes have no groups")
    timestamp(index.get("published_at"))
    groups = index.get("groups")
    require(isinstance(groups, list), "groups must be a list")
    seen = set()
    for item in groups:
        require(isinstance(item, dict) and isinstance(item.get("id"), str), "invalid group descriptor")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", item["id"]) and item["id"] not in seen,
                "invalid or duplicate group id")
        seen.add(item["id"])
        timestamp(item.get("published_at"))
        manifest = item.get("manifest", {})
        require(isinstance(manifest, dict), "manifest descriptor must be an object")
        url = urllib.parse.urlsplit(manifest.get("url", ""))
        require(url.scheme == "https" and url.hostname and not url.username and not url.password,
                "manifest URL must use HTTPS without credentials")
        require(hexhash(manifest.get("sha256")), "manifest checksum is required")
    return groups


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def download_json(url, path):
    require(urllib.parse.urlsplit(url).scheme == "https", "metadata URL must use HTTPS")
    subprocess.run(["curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https",
                    "--max-filesize", "20971520", "--retry", "3", "-o", str(path), url], check=True)
    return json.loads(path.read_text())


def fetch_manifest(selected, directory):
    group_path = directory / "group.json"
    group = download_json(selected["manifest"]["url"], group_path)
    require(sha(group_path) == selected["manifest"]["sha256"], "group manifest checksum mismatch")
    validate_manifest(group, NETWORK)
    require(group["group_id"] == selected["id"] and group["published_at"] == selected["published_at"],
            "group descriptor does not match manifest")
    return group


def size_label(value):
    return f"{value:,} B" if value < 1024 ** 2 else f"{value / 1024 ** 3:.3f} GiB"


def print_group(group, stack=None):
    print(f"\n{group['group_id']}  published={group['published_at']}")
    if stack is None:
        print("  Compatibility: NOT CHECKED (create .env, then run list again)")
    else:
        try:
            stack.preflight(group)
        except ValueError as error:
            print("  Compatibility: INCOMPATIBLE - " + str(error))
        else:
            print("  Compatibility: MATCH (release identity, images and upstream configuration)")
    download_size = extracted_size = 0
    for name in COMPONENTS:
        entry = group["components"][name]
        if entry is None:
            print(f"  {name}: absent; keep eligible local data or initialize/sync")
            continue
        archive = entry["archive"]
        download_size += archive["size_bytes"]
        extracted_size += archive["uncompressed_bytes"]
        print(f"  {name}: height={entry['checkpoint']['height']} captured={entry['captured_at']}")
        print(f"    download={size_label(archive['size_bytes'])} extracted={size_label(archive['uncompressed_bytes'])}")
        print("    compatible images: " + ", ".join(entry["compatible_images"]))
        for upstream, point in entry["requires"].items():
            print(f"    requires {upstream}: height={point['height']} hash={point['hash']}")
    print(f"  Total: download={size_label(download_size)} extracted={size_label(extracted_size)}")


def load_group(index_url, group_id, directory, stack=None):
    path = directory / "index.json"
    index = download_json(index_url, path)
    signers = ROOT / "snapshots/allowed_signers"
    if signers.exists():
        subprocess.run(["curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https",
                        "-o", str(path) + ".sig", index_url + ".sig"], check=True)
        with path.open("rb") as stream:
            subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "dogeos-snapshots",
                            "-n", "dogeos-snapshot-index", "-s", str(path) + ".sig"], stdin=stream, check=True)
    groups = validate_index(index, NETWORK)
    if group_id is None:
        manifests = [fetch_manifest(item, directory) for item in
                     sorted(groups, key=lambda x: timestamp(x["published_at"]), reverse=True)]
        if not manifests:
            print("No snapshot groups published; use start for a node without snapshots.")
        for group in manifests:
            print_group(group, stack)
        if manifests:
            print("\nHeights belong to each component's chain (L1 Interface uses its synthetic chain).")
            print("MATCH does not check existing data, free disk space or live node readiness; restore checks still apply.")
        return None
    candidates = groups if group_id == "latest" else [item for item in groups if item["id"] == group_id]
    require(candidates, "no such group; use start for a node without snapshots")
    selected = max(candidates, key=lambda x: timestamp(x["published_at"]))
    return fetch_manifest(selected, directory)


class Stack:
    def __init__(self, env_file):
        env_file = Path(env_file or ROOT / ".env").resolve()
        self.command = ["docker", "compose", "-f", str(ROOT / "docker-compose.yml"),
                        "--project-directory", str(ROOT), "--env-file", str(env_file)]
        self.env_file = env_file
        self.config = json.loads(subprocess.check_output(self.command + ["config", "--format", "json"], text=True))
        validator_spec = importlib.util.spec_from_file_location("l1_layout", ROOT / "scripts/validate-l1-snapshot.py")
        validator = importlib.util.module_from_spec(validator_spec)
        validator_spec.loader.exec_module(validator)
        validator.validate_config(self.config, NETWORK)
        services = self.config["services"]
        mounts = services["l2reth-node"]["volumes"]
        self.data = Path(next(v["source"] for v in mounts if v["target"] == "/l2reth" and v["type"] == "bind")).parent.resolve()
        require(self.data.is_absolute() and self.data not in (Path("/"), Path("/tmp").resolve(), Path("/var/tmp").resolve()) and
                not self.data.is_relative_to(ROOT.parent) and not str(self.data).startswith("/path/to/"),
                "DATA_ROOT must be a real external data directory")
        self.state = self.data / ".snapshot-group-state.json"
        self.l1env = services["l1-interface"].get("environment", {})
        self.external_doge = self.l1env.get("DOGEOS_RPC_PACKAGE_EXTERNAL_DOGECOIN_RPC_URL") or ""
        self.external_doge = self.external_doge or self.l1env.get("DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL", "")
        if urllib.parse.urlsplit(self.external_doge).hostname == "dogecoin-node":
            self.external_doge = ""
        require(self.l1env.get("L1_INTERFACE_SKIP_DOGE_SYNC") != "true", "L1 historical sync bypass is forbidden")
        l2env = services["l2reth-node"].get("environment", {})
        require(l2env.get("L2RETH_L1_ENDPOINT", "http://l1-interface:8545") == "http://l1-interface:8545",
                "staged startup requires L2Reth to use the bundled L1 Interface")
        require(l2env.get("L2RETH_L1_READY_URL", "http://l1-interface:9090/api/v1/health/ready") ==
                "http://l1-interface:9090/api/v1/health/ready", "readiness must target the bundled L1 Interface")

    def compose(self, *args):
        subprocess.run(self.command + list(args), check=True)

    def identity(self):
        env = self.l1env
        values = {}
        targets = {"genesis_sha256": ("l2reth-node", "/l2reth/genesis/genesis.json"),
                   "protocol_context_sha256": ("l1-interface", env.get("DOGEOS_L1_INTERFACE_REPLAY_READ__PROTOCOL_CONTEXT_JSON", "/app/protocol_context.json"))}
        for key, (service, target) in targets.items():
            mounts = self.config["services"][service]["volumes"]
            source = next((v["source"] for v in mounts if v["target"] == target and v["type"] == "bind"), None)
            require(source and Path(source).is_file(), "missing release identity file: " + target)
            values[key] = sha(source)
        return values

    def preflight(self, group):
        require(group["identity"] == self.identity(), "group genesis/protocol identity does not match package")
        for component, entry in group["components"].items():
            if entry:
                image = self.config["services"][SERVICES[component]]["image"]
                require(image in entry["compatible_images"], "group component image incompatible: " + component)
        require(not (self.external_doge and group["components"]["dogecoin"]),
                "cannot restore bundled Dogecoin while L1 is configured to use an external node")

    def endpoint(self, target):
        ports = self.config["services"]["l1-interface"].get("ports", [])
        match = next((p for p in ports if int(p["target"]) == target), None)
        require(match is not None, "L1 port must be published for host startup checks: " + str(target))
        host = match.get("host_ip") or "127.0.0.1"
        if host in ("0.0.0.0", "::"):
            host = "127.0.0.1"
        if ":" in host:
            host = "[" + host + "]"
        return "http://" + host + ":" + str(match["published"])

    def doge(self, method, params=None):
        if self.external_doge:
            if self.l1env.get("DOGEOS_RPC_PACKAGE_EXTERNAL_DOGECOIN_RPC_URL"):
                user = self.l1env.get("DOGEOS_RPC_PACKAGE_EXTERNAL_DOGECOIN_RPC_USER") or ""
                password = self.l1env.get("DOGEOS_RPC_PACKAGE_EXTERNAL_DOGECOIN_RPC_PASSWORD") or ""
            else:
                user = self.l1env.get("DOGEOS_L1_INTERFACE_DOGECOIN_RPC__USER", "")
                password = self.l1env.get("DOGEOS_L1_INTERFACE_DOGECOIN_RPC__PASS", "")
            return rpc(self.external_doge, method, params, user, password)
        result = subprocess.run(self.command + ["exec", "-T", "dogecoin-node", "/dogecoin/bin/dogecoin-cli",
                                "-conf=/run/dogeos/dogecoin.conf", "-datadir=/data", method] +
                                [str(x) for x in (params or [])], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise Pending("Dogecoin RPC unavailable or warming up")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return result.stdout.strip()  # dogecoin-cli prints block hashes without JSON quotes


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http_json(url, payload=None, user="", password=""):
    headers = {"Content-Type": "application/json"}
    parsed = urllib.parse.urlsplit(url)
    if parsed.username:
        user, password = urllib.parse.unquote(parsed.username), urllib.parse.unquote(parsed.password or "")
        url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc.rsplit("@", 1)[1], parsed.path, parsed.query, parsed.fragment))
    if user or password:
        headers["Authorization"] = "Basic " + base64.b64encode((user + ":" + password).encode()).decode()
    request = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
            if response.status != 200:
                raise Pending("RPC/health did not return HTTP 200")
            return json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise Pending("RPC/health unavailable") from exc


def rpc(url, method, params=None, user="", password=""):
    reply = http_json(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}, user, password)
    if not isinstance(reply, dict) or reply.get("error") or reply.get("result") is None:
        raise Pending("RPC result unavailable: " + method)
    return reply["result"]


class Pending(Exception):
    pass


def wait_for(label, action):
    print("Waiting for " + label, flush=True)
    while True:
        try:
            action()
            return
        except (Pending, subprocess.TimeoutExpired) as exc:
            print("  " + str(exc) + "; retrying in 5 seconds", flush=True)
            time.sleep(5)


def requirements(group, upstream):
    entries = (group or {}).get("components", {})
    points = []
    own = entries.get(upstream)
    if own:
        points.append(own["checkpoint"])
    for entry in entries.values():
        if entry and upstream in entry["requires"]:
            points.append(entry["requires"][upstream])
    return points


def check_points(points, height, get_hash):
    for point in points:
        if height < point["height"]:
            raise Pending("upstream has not reached required height " + str(point["height"]))
        actual = get_hash(point["height"])
        if actual is None:
            raise Pending("required checkpoint is not served yet")
        require(actual.removeprefix("0x").lower() == point["hash"],
                "checkpoint hash mismatch at height " + str(point["height"]) + "; downstream remains stopped")


def start(stack, group=None):
    if group is None and stack.state.exists():
        state = json.loads(stack.state.read_text())
        require(state.get("status") == "complete", "interrupted group restore; finish the restore before starting")
        group = validate_manifest(state["effective_manifest"], NETWORK)
    if group:
        stack.preflight(group)
    # Prevent existing downstream containers from running while an upstream
    # restored from older data catches up. This is an explicit maintenance start.
    stack.compose("stop", "l2reth-node", "l1-interface")
    if not stack.external_doge:
        stack.compose("up", "-d", "dogecoin-node")

    def doge_ready():
        info = stack.doge("getblockchaininfo")
        require(info.get("chain") == ("test" if NETWORK == "testnet" else "main"), "Dogecoin RPC is on the wrong network")
        require(info.get("pruned") is False, "Dogecoin must be unpruned")
        if info.get("initialblockdownload") is not False or info.get("blocks", -1) < info.get("headers", 0):
            raise Pending("Dogecoin initial synchronization is incomplete")
        check_points(requirements(group, "dogecoin"), info["blocks"], lambda h: stack.doge("getblockhash", [h]))
    wait_for("Dogecoin sync and checkpoints", doge_ready)
    if "l1-interface-init-fetch-sqlite" in stack.config["services"]:
        stack.compose("up", "-d", "--force-recreate", "l1-interface-init-fetch-sqlite")
    stack.compose("up", "-d", "l1-interface")
    health, l1 = stack.endpoint(9090), stack.endpoint(8545)

    def l1_ready():
        if http_json(health + "/health").get("historical_sync") != "completed":
            raise Pending("L1 historical indexing is incomplete")
        if http_json(health + "/api/v1/health/ready").get("ready") is not True:
            raise Pending("L1 replay is not ready")
        height = int(rpc(l1, "eth_blockNumber"), 16)
        check_points(requirements(group, "l1-interface"), height,
                     lambda h: (rpc(l1, "eth_getBlockByNumber", [hex(h), False]) or {}).get("hash"))
    wait_for("L1 historical sync, replay readiness and checkpoints", l1_ready)
    stack.compose("up", "-d", "--no-deps", "l2reth-node")
    print("L2Reth started; verify L2 sync before serving RPC traffic.")


def restore(stack, group, force, no_start):
    stack.preflight(group)
    effective = json.loads(json.dumps(group))
    previous = json.loads(stack.state.read_text()) if stack.state.exists() else {}
    # Missing snapshots retain local data and any recorded lower-bound requirements. Never
    # silently borrow an archive from another group or erase retained data.
    if previous.get("status") == "restoring":
        require(previous.get("selected_manifest") == group,
                "interrupted restore: retry the same immutable group with --force")
        old = previous.get("retained_manifest", {})
    else:
        old = previous.get("effective_manifest", {})
    receipt = stack.data / ".snapshot-groups" / (group["group_id"] + ".json")
    if receipt.exists():
        require(json.loads(receipt.read_text()) == group, "group id was republished with different contents")
    completed = previous.get("applied", []) if previous.get("status") == "restoring" else []
    require(isinstance(completed, list) and all(c in COMPONENTS and group["components"][c] for c in completed),
            "invalid restore journal")
    # Preflight replacements before stopping services or marking a restore pending.
    if not force:
        for component, entry in group["components"].items():
            path = stack.data / component
            if entry and component not in completed and path.exists() and any(path.iterdir()):
                raise ValueError(component + " data exists; use --force to preserve it as a backup")
    for component, entry in group["components"].items():
        if entry is not None:
            continue
        # A saved snapshot receipt is only a lower bound once a retained node
        # has run. Never assume it captures the current downstream dependency.
        upstreams = COMPONENTS[:COMPONENTS.index(component)]
        path = stack.data / component
        if component != "dogecoin" and path.exists() and any(path.iterdir()) and any(
                group["components"][upstream] is not None for upstream in upstreams):
            raise ValueError("cannot replace upstream while retaining live " + component +
                             " data with unknown current dependencies; include its snapshot in the group")
        old_entry = old.get("components", {}).get(component)
        if old_entry:
            require(old.get("identity") == group["identity"], "retained data has different protocol identity")
            effective["components"][component] = old_entry
            effective["published_at"] = max((effective["published_at"], old["published_at"]), key=timestamp)
        print(component + ": no snapshot in this group; retain known data or initialize and sync")
    # Preserved entries may be older than this group's publication. Do not use
    # the selection timestamp to pretend they belong to the new capture run.
    validate_manifest(effective, NETWORK)
    stack.preflight(effective)
    atomic_json(receipt, group)
    state = {"status": "restoring", "selected_manifest": group, "effective_manifest": effective,
             "retained_manifest": old, "applied": list(completed)}
    atomic_json(stack.state, state)
    stack.compose("stop", "l2reth-node", "l1-interface", "dogecoin-node")
    env = dict(os.environ, DOGEOS_GROUP_RESTORE="1")
    # Raw legacy overrides must never change a pinned selection.
    for key in list(env):
        if key.startswith("L2RETH_SNAPSHOT_") or key.startswith("SNAPSHOT_"):
            env.pop(key)
    for component in COMPONENTS:
        entry = group["components"][component]
        if entry is None:
            continue
        if component in completed:
            print(component + ": already restored by this interrupted group; keeping its data")
            continue
        archive = entry["archive"]
        command = ["bash", str(ROOT / "scripts/restore-snapshot.sh"), "--no-start",
                   "--snapshot-url", archive["url"], "--sha256", archive["sha256"]]
        if force:
            command.append("--force")
        # Pass the already validated pinned entry to the component worker,
        # including compressed/extracted sizes for its disk-space checks.
        env["DOGEOS_GROUP_ENTRY"] = json.dumps(entry)
        subprocess.run(command + [component, str(stack.env_file)], env=env, check=True)
        state["applied"].append(component)
        atomic_json(stack.state, state)
    state["status"] = "complete"
    atomic_json(stack.state, state)
    print("Group restored: " + group["group_id"])
    if not no_start:
        start(stack, effective)
    else:
        print("Services remain stopped. Run: python3 scripts/snapshot-group.py start")


def resolve_restore_group(stack, group_id, index_url, directory):
    if stack.state.exists():
        state = json.loads(stack.state.read_text())
        if state.get("status") == "restoring":
            pinned = state["selected_manifest"]
            require(group_id == pinned["group_id"], "interrupted restore: retry pinned group " + pinned["group_id"])
            # This exact manifest was authenticated before the interrupted run.
            # Resume remains possible even if the remote catalog changed.
            return validate_manifest(pinned, NETWORK)
    return load_group(index_url, group_id, directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "restore", "start", "validate", "validate-index"))
    parser.add_argument("group", nargs="?", help="group id, latest, or local manifest path for validate")
    parser.add_argument("--index-url", default=os.environ.get("SNAPSHOT_INDEX_URL", INDEX_BASE + "/" + NETWORK + "/index.json"))
    parser.add_argument("--env-file")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--no-start", action="store_true")
    args = parser.parse_args()
    if args.action in ("validate", "validate-index"):
        require(args.group, "validate requires a manifest filename")
        (validate_manifest if args.action == "validate" else validate_index)(json.loads(Path(args.group).read_text()), NETWORK)
        print("Snapshot metadata valid")
        return
    if args.action == "list":
        # Listing only reads configuration and metadata; it never creates a
        # data directory, locks the stack, stops containers or downloads archives.
        env_file = Path(args.env_file or ROOT / ".env")
        stack = Stack(args.env_file) if args.env_file or env_file.exists() else None
        with tempfile.TemporaryDirectory() as tmp:
            load_group(args.index_url, None, Path(tmp), stack)
        return
    stack = Stack(args.env_file)
    stack.data.mkdir(parents=True, exist_ok=True)
    # Serializes group restores and staged starts. Single-component restore
    # refuses to modify data managed by a group.
    with (stack.data / ".snapshot-group.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == "start":
            start(stack)
        else:
            require(args.group, "restore requires an explicit group id or latest")
            with tempfile.TemporaryDirectory() as tmp:
                group = resolve_restore_group(stack, args.group, args.index_url, Path(tmp))
                restore(stack, group, args.force, args.no_start)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        # Do not print subprocess argv or provider URLs: they can contain credentials.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        sys.exit("ERROR: " + message)
    except KeyboardInterrupt:
        sys.exit("Interrupted; downstream services are not automatically started.")
