#!/usr/bin/env python3
"""Initialize a persistent P2P identity and print public allowlist information."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NETWORK = "mainnet"
KEY_TARGET = "/run/dogeos/l2reth-p2p.key"
ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
SPKI_PREFIX = bytes.fromhex("3056301006072a8648ce3d020106052b8104000a03420004")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def settings(config):
    service = config["services"]["l2reth-node"]
    mounts = service.get("volumes", [])
    data = next(v for v in mounts if v["target"] == "/l2reth" and v["type"] == "bind")
    key = next((v for v in mounts if v["target"] == KEY_TARGET), None)
    # Compose JSON omits create_host_path when false (but emits true for short mounts).
    require(key and key["type"] == "bind" and key.get("read_only") is True
            and key.get("bind", {}).get("create_host_path", False) is False,
            "P2P key must use the package's read-only file mount (create_host_path: false)")
    data_path = Path(data["source"]).resolve()
    path = Path(key["source"])
    require(path.is_absolute() and not path.is_symlink(), "P2P key path must be absolute and not a symlink")
    path = path.resolve()
    require(not path.is_relative_to(ROOT.parent.resolve()) and not str(path).startswith("/path/to/"),
            "P2P key must be outside the repository; replace placeholder paths")
    # Reset/restore replaces these trees. Never put the identity in one of them.
    for name in ("l2reth", "l1-interface", "dogecoin", ".snapshot-cache"):
        require(not path.is_relative_to(data_path.parent / name),
                "P2P key must be outside chain data and snapshot cache directories")
    env = service.get("environment", {})
    for flag in env.get("L2RETH_EXTRA_ARGS", "").split():
        require(not (flag.startswith("--p2p-secret-key") or flag.split("=")[0] in
                     ("--nat", "--port", "--discovery.port", "--instance", "--with-unused-ports")),
                "remove P2P identity/NAT/port overrides from L2RETH_EXTRA_ARGS; use the dedicated settings")
    return path, data_path, env


def read_key(path, importing=False):
    require(not path.is_symlink() and path.is_file(), "P2P key is missing/not a regular file; run p2p-identity.py init first")
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_size <= 128, "invalid P2P key file")
    if not importing:
        require(stat.S_IMODE(info.st_mode) in (0o600, 0o400), "P2P key permissions must be 0600 (or 0400)")
    raw = path.read_bytes()
    if importing:
        raw = raw.strip()
        if raw.startswith(b"0x"):
            raw = raw[2:]
    require(re.fullmatch(rb"[0-9a-fA-F]{64}", raw) is not None,
            "P2P key must contain exactly 64 hex characters without a prefix/newline; import existing keys with init --import-key")
    require(0 < int(raw, 16) < ORDER, "P2P key is not a valid secp256k1 scalar")
    return raw.lower()


def public_key(raw):
    # SEC1 DER is passed through stdin, never via argv or a temporary PEM file.
    der = bytes.fromhex("302e0201010420") + bytes.fromhex(raw.decode()) + bytes.fromhex("a00706052b8104000a")
    result = subprocess.run(["openssl", "ec", "-inform", "DER", "-pubout", "-conv_form", "uncompressed",
                             "-outform", "DER"], input=der, capture_output=True)
    require(result.returncode == 0 and result.stdout.startswith(SPKI_PREFIX) and len(result.stdout) == len(SPKI_PREFIX) + 64,
            "OpenSSL could not derive a secp256k1 public key")
    return result.stdout[len(SPKI_PREFIX):].hex()


def initialize(path, data, import_key=None):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (path.parent / ".p2p-identity.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.exists() or path.is_symlink():
            raw = read_key(path)
            if import_key:
                require(raw == read_key(import_key, True), "existing P2P identity differs; refusing to overwrite it")
            return raw, "Existing identity retained"
        legacy = data / "discovery-secret"
        if import_key:
            raw, note = read_key(import_key, True), "Imported identity"
        elif legacy.exists() or legacy.is_symlink():
            raw, note = read_key(legacy, True), "Copied existing Reth identity; original retained"
        else:
            require(not data.exists() or not any(p.name != "genesis" for p in data.iterdir()),
                    "existing L2 data has no discovery-secret; locate the original key and use init --import-key (no automatic rotation)")
            raw = f"{secrets.randbelow(ORDER - 1) + 1:064x}".encode()
            note = "Generated new identity"
        # Validate/derive before persisting so missing OpenSSL leaves no half-initialized key.
        public_key(raw)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".p2p-key-", delete=False) as stream:
                temporary = Path(stream.name)
                os.fchmod(stream.fileno(), 0o600)
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, path)  # Atomic no-clobber publication.
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        return raw, note


def report(raw, env, service):
    public_ip = env.get("L2RETH_P2P_PUBLIC_IP", "")
    require(public_ip, "set L2RETH_P2P_PUBLIC_IP to the reachable static IPv4 address before exporting an enode")
    try:
        address = ipaddress.IPv4Address(public_ip)
        port = int(env.get("L2RETH_P2P_PORT", "30303"))
        cidrs = [str(ipaddress.ip_network(x.strip(), strict=True)) for x in
                 env.get("L2RETH_P2P_SOURCE_CIDRS", "").split(",") if x.strip()]
    except ValueError:
        raise ValueError("invalid public IPv4, P2P port or source CIDR; use network CIDRs (for one IPv4, /32)") from None
    require(not address.is_unspecified and not address.is_multicast and not address.is_loopback,
            "P2P public IP must be a reachable unicast address")
    require(1 <= port <= 65535 and cidrs, "set a valid P2P port and L2RETH_P2P_SOURCE_CIDRS (actual outbound public source ranges)")
    for protocol in ("tcp", "udp"):
        require(any(int(p["target"]) == port and int(p["published"]) == port
                    and p.get("protocol", "tcp") == protocol for p in service.get("ports", [])),
                "P2P host and container ports must match the advertised port for TCP and UDP")
    node_id = public_key(raw)
    return {"network": NETWORK, "node_id": node_id, "enode": f"enode://{node_id}@{address}:{port}",
            "source_cidrs": cidrs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "check", "show"))
    parser.add_argument("--env-file")
    parser.add_argument("--import-key", type=Path, help="init only: copy an existing private-key file; never pass the key itself")
    args = parser.parse_args()
    require(not args.import_key or args.action == "init", "--import-key is only valid with init")
    env_file = Path(args.env_file or ROOT / ".env").resolve()
    command = ["docker", "compose", "-f", str(ROOT / "docker-compose.yml"), "--project-directory", str(ROOT),
               "--env-file", str(env_file), "config", "--format", "json"]
    config = json.loads(subprocess.check_output(command, text=True))
    path, data, env = settings(config)
    if args.action == "init":
        raw, note = initialize(path, data, args.import_key)
        print(note + "; private key is not displayed")
        print("Node ID: " + public_key(raw))
        print("Back up the private key securely; run show after configuring public IP and source CIDRs.")
    elif args.action == "check":
        read_key(path)
        print("Persistent P2P identity valid")
    else:
        print(json.dumps(report(read_key(path), env, config["services"]["l2reth-node"]), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, StopIteration, TypeError, subprocess.SubprocessError) as error:
        # Never print a subprocess command, private key bytes or provider response.
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else type(error).__name__
        raise SystemExit("ERROR: " + message)
