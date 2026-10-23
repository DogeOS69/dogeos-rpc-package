#!/usr/bin/env python3
"""Validate the package's fixed L1 data layout before activating a snapshot.

This checks packaging and SQLite integrity, not protocol compatibility or
completeness of replay references. Publishers must also perform a restore/start
test with the compatible service image and its network configuration.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sqlite3
import sys
import tarfile


DATABASES = (
    "l1-interface.sqlite",
    "replay.sqlite",
    "replay.artifacts/eth_da_artifacts.sqlite",
)
HISTORY = "l1-interface-historical-artifact.sqlite"
FIXED_ENV = {
    "DOGEOS_L1_INTERFACE_DATABASE_URL": "sqlite:///data/l1-interface.sqlite",
    "DOGEOS_L1_INTERFACE_REPLAY_READ__SQLITE_PATH": "/data/replay.sqlite",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_config(config, network):
    service = config["services"]["l1-interface"]
    env = service.get("environment", {})
    for key, value in FIXED_ENV.items():
        require(env.get(key) == value, f"{key} must be {value}; remove custom data paths")
    history = env.get("DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH") or ""
    require(history in ("", f"/data/{HISTORY}"), "historical artifact must use /data/" + HISTORY)
    require(network != "testnet" or history, "testnet requires its historical artifact")
    l2_mounts = config["services"]["l2reth-node"]["volumes"]
    l2 = [m for m in l2_mounts if m["target"] == "/l2reth"]
    require(len(l2) == 1 and l2[0]["type"] == "bind", "L2Reth must bind-mount DATA_ROOT/l2reth")
    require(Path(l2[0]["source"]).name == "l2reth", "L2Reth data directory must be named l2reth")
    expected = Path(l2[0]["source"]).parent / "l1-interface"
    mounts = service.get("volumes", [])
    data = [m for m in mounts if m["target"] == "/data"]
    require(
        len(data) == 1 and data[0]["type"] == "bind"
        and Path(data[0]["source"]).resolve() == expected.resolve()
        and not data[0].get("read_only", False),
        "L1 Interface must bind-mount DATA_ROOT/l1-interface read-write at /data",
    )
    require(not any(m["target"].startswith("/data/") for m in mounts),
            "nested /data mounts would hide restored files")
    if network == "testnet":
        init = config["services"]["l1-interface-init-fetch-sqlite"]
        init_env = init.get("environment", {})
        require(init_env.get("DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH") == history,
                "bootstrap and L1 Interface historical paths differ")
        require(init_env.get("DOGEOS_L1_INTERFACE_REPLAY_READ__SQLITE_PATH") == "/data/replay.sqlite",
                "bootstrap must write /data/replay.sqlite")
        init_data = [m for m in init.get("volumes", []) if m["target"] == "/data"]
        require(len(init_data) == 1 and init_data[0]["type"] == "bind"
                and Path(init_data[0]["source"]).resolve() == expected.resolve()
                and not init_data[0].get("read_only", False),
                "bootstrap must use the same DATA_ROOT/l1-interface mount")
        require(not any(m["target"].startswith("/data/") for m in init.get("volumes", [])),
                "nested bootstrap /data mounts would hide restored files")
        url = init_env.get("ARTIFACT_URL", "").split("?", 1)[0].split("#", 1)[0]
        match = re.search(r"-([0-9a-fA-F]{64})\.sqlite$", url)
        require(match, "bootstrap historical artifact URL must contain its SHA-256")
        return match[1].lower()
    return "required" if history else "none"


def validate_archive(archive, historical):
    files = set()
    directories = set()
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            name = member.name.rstrip("/")
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts,
                    f"unsafe archive path: {name}")
            require(path.parts and path.parts[0] == "l1-interface",
                    f"unexpected archive root: {name}")
            require(member.isfile() or member.isdir(), f"links/special files are forbidden: {name}")
            require(str(path) not in seen, f"duplicate archive member: {name}")
            seen.add(str(path))
            relative = path.relative_to("l1-interface")
            if not relative.parts:
                require(member.isdir(), "l1-interface must be a directory")
                continue
            top = relative.parts[0]
            allowed_files = {"l1-interface.sqlite", "replay.sqlite", HISTORY,
                             "replay.sqlite.bootstrap-source.json"}
            require(top == "replay.artifacts" or
                    (len(relative.parts) == 1 and top in allowed_files and member.isfile()),
                    f"file outside the fixed L1 layout: {name}")
            require(not any(part.endswith((".env", ".conf", ".toml", "-wal", "-shm", "-journal"))
                            or part in {"nodekey", "jwt.hex", "wallet.dat", "wallets"}
                            or part.startswith("keystore") for part in relative.parts),
                    f"configuration, key, or uncheckpointed database file: {name}")
            directories.update(str(parent) for parent in relative.parents if str(parent) != ".")
            if member.isdir():
                directories.add(str(relative))
            else:
                require(relative.as_posix() != "replay.artifacts", "replay.artifacts must be a directory")
                files.add(str(relative))
    for name in DATABASES:
        require(name in files, f"snapshot is missing {name}")
    require("replay.artifacts/eth_da_artifacts" in directories,
            "snapshot is missing replay.artifacts/eth_da_artifacts/")
    if historical != "none":
        require(HISTORY in files, f"snapshot is missing {HISTORY}")


def validate_extracted(directory, historical):
    root = Path(directory)
    for name in DATABASES:
        require((root / name).is_file(), f"snapshot is missing {name}")
    require((root / "replay.artifacts/eth_da_artifacts").is_dir(), "missing DA artifact directory")
    if historical != "none":
        require((root / HISTORY).is_file(), f"snapshot is missing {HISTORY}")
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"symlink in extracted data: {path}")
        require(not path.name.endswith(("-wal", "-shm", "-journal")), f"uncheckpointed SQLite: {path}")
        if path.is_file() and path.suffix == ".sqlite":
            with path.open("rb") as stream:
                require(stream.read(16) == b"SQLite format 3\x00", f"invalid SQLite header: {path}")
            # Immutable/read-only: validation must not create WAL/SHM or migrate data.
            conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
            try:
                require(conn.execute("PRAGMA quick_check").fetchall() == [("ok",)],
                        f"SQLite quick_check failed: {path}")
            finally:
                conn.close()
    if historical not in ("none", "required"):
        digest = hashlib.sha256()
        with (root / HISTORY).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        require(digest.hexdigest() == historical, "historical artifact does not match package bootstrap")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("config", "archive", "extracted"))
    parser.add_argument("path", nargs="?")
    parser.add_argument("--network", choices=("testnet", "mainnet"), required=True)
    parser.add_argument("--historical", default="none", help="none, required, or expected SHA-256")
    args = parser.parse_args()
    try:
        if args.mode == "config":
            print(validate_config(json.load(sys.stdin), args.network))
        else:
            require(args.path, "a path is required")
            require(args.historical in ("none", "required") or
                    re.fullmatch(r"[0-9a-f]{64}", args.historical), "invalid historical checksum")
            if args.mode == "archive":
                validate_archive(args.path, args.historical)
            else:
                validate_extracted(args.path, args.historical)
    except (ValueError, KeyError, OSError, sqlite3.Error, tarfile.TarError) as error:
        parser.exit(1, f"ERROR: {error}\n")


if __name__ == "__main__":
    main()
