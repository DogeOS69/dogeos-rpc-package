#!/usr/bin/env python3
"""Validate Dogecoin/L2Reth tar member types, paths and required data trees."""
import argparse
from pathlib import PurePosixPath
import tarfile


def validate(archive, component, network):
    files, directories, seen = set(), set(), set()
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != component:
                raise ValueError("unsafe archive path: " + member.name)
            if not (member.isfile() or member.isdir()):
                raise ValueError("links and special files are forbidden: " + member.name)
            normalized = str(path)
            if normalized in seen:
                raise ValueError("duplicate archive member: " + member.name)
            seen.add(normalized)
            if len(path.parts) == 1 and not member.isdir():
                raise ValueError("archive root must be a directory")
            relative = path.parts[1:]
            if component == "l2reth":
                if relative and relative[0] in {"jwt.hex", "reth.toml", "genesis", "lost+found", "protocol_context.json"}:
                    raise ValueError("forbidden L2Reth tree: " + member.name)
                if any(x in {"nodekey", "discovery-secret", "p2p-secret-key", "l2reth-p2p.key", "l2reth-identity"} or x.startswith("keystore") for x in relative):
                    raise ValueError("node key/keystore: " + member.name)
            elif any(x in {"wallet.dat", "wallets", ".cookie", "peers.dat", "banlist.dat", ".lock"}
                     or x.endswith(".conf") for x in relative):
                raise ValueError("forbidden Dogecoin data: " + member.name)
            directories.update(str(p) for p in path.parents if str(p) != ".")
            (directories if member.isdir() else files).add(normalized)
    if component == "l2reth":
        required = {"l2reth/db/mdbx.dat", "l2reth/db/scroll.db"}
        if "l2reth/static_files" not in directories:
            raise ValueError("static_files must be a directory")
    else:
        prefix = "dogecoin/" + ("testnet3/" if network == "testnet" else "")
        required = {prefix + "blocks/index/CURRENT", prefix + "chainstate/CURRENT"}
    if not required <= files:
        raise ValueError("missing required regular data files: " + ", ".join(sorted(required - files)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--component", choices=("dogecoin", "l2reth"), required=True)
    parser.add_argument("--network", choices=("mainnet", "testnet"), required=True)
    args = parser.parse_args()
    try:
        validate(args.archive, args.component, args.network)
    except (ValueError, tarfile.TarError, OSError) as error:
        parser.exit(1, "ERROR: " + str(error) + "\n")
