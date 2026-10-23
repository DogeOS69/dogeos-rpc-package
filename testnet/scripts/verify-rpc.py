#!/usr/bin/env python3
"""Read-only L2 RPC comparison against a same-network reference (Python 3.9+)."""
import argparse
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REFERENCE = "https://rpc.testnet.dogeos.com"


class CheckError(Exception):
    """Operator-facing error containing no provider URL or response body."""


def rpc(url, label, method, params=None):
    prefix = label + " " + method
    try:
        parsed = urllib.parse.urlsplit(url)
        valid_url = parsed.scheme in ("http", "https") and parsed.hostname
    except ValueError:
        valid_url = False
    if not valid_url:
        raise CheckError(label + ": configure an HTTP(S) RPC URL")
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or []}).encode()
    try:
        request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=15) as response:
            reply = json.load(response)
    except urllib.error.HTTPError as error:
        raise CheckError(f"{prefix}: HTTP {error.code}; check provider access/rate limits") from None
    except (urllib.error.URLError, OSError, ValueError):
        raise CheckError(prefix + ": connection, timeout or invalid JSON; check endpoint availability") from None
    if not isinstance(reply, dict) or reply.get("error") or reply.get("result") is None:
        raise CheckError(prefix + ": JSON-RPC error or missing result; check method support")
    return reply["result"]


def quantity(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", value):
        raise CheckError(label + ": expected a hexadecimal RPC quantity")
    return int(value, 16)


def sample(local, reference, expected, max_lag, block_number=None):
    heights = []
    for label, url in (("local", local), ("reference", reference)):
        chain = quantity(rpc(url, label, "eth_chainId"), label + " chain ID")
        if chain != expected:
            raise CheckError(f"{label}: chain ID {chain}, expected {expected}; check network/URL")
        if rpc(url, label, "eth_syncing") is not False:
            raise CheckError(label + ": reports syncing; wait for catch-up or use a healthy reference")
        heights.append(quantity(rpc(url, label, "eth_blockNumber"), label + " height"))
    lag = heights[1] - heights[0]
    print(f"local={heights[0]} reference={heights[1]} reference-minus-local={lag} blocks", flush=True)
    if abs(lag) > max_lag:
        raise CheckError(f"head difference exceeds {max_lag} blocks; wait for local catch-up or check a lagging reference")
    height = block_number if block_number is not None else max(0, min(heights) - 20)
    if not 0 <= height <= min(heights):
        raise CheckError("selected block is outside the shared history; choose a lower block")
    hashes = []
    for label, url in (("local", local), ("reference", reference)):
        block = rpc(url, label, "eth_getBlockByNumber", [hex(height), False])
        value = block.get("hash") if isinstance(block, dict) else None
        if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
            raise CheckError(f"{label}: missing/invalid block hash at {height}")
        hashes.append(value.lower())
    if hashes[0] != hashes[1]:
        raise CheckError(f"block hash mismatch at {height}; keep node out of service and investigate reorg/network/reference")
    print(f"PASS sample: chain ID, sync status, head difference and block {height} hash match", flush=True)
    return tuple(heights)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-url", default="http://127.0.0.1:8545")
    parser.add_argument("--reference-url", default=DEFAULT_REFERENCE)
    parser.add_argument("--max-lag", type=int, default=5, help="maximum absolute head difference (default: 5)")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--interval", type=float, default=30, help="seconds between samples")
    parser.add_argument("--block-number", type=int, help="optional known block to compare, in decimal")
    args = parser.parse_args()
    if not args.reference_url:
        raise CheckError("mainnet reference RPC is not published; supply --reference-url after release")
    if args.max_lag < 0 or args.samples < 1 or not 0 <= args.interval < float("inf"):
        raise CheckError("max-lag/interval must be nonnegative and samples must be positive")
    try:
        expected = json.loads((ROOT / "config/l2reth-genesis.json").read_text())["config"]["chainId"]
    except (OSError, ValueError, KeyError, TypeError):
        raise CheckError("package genesis is missing or invalid; complete release configuration first") from None
    first = last = None
    for i in range(args.samples):
        if i:
            time.sleep(args.interval)
        last = sample(args.local_url, args.reference_url, expected, args.max_lag, args.block_number)
        if first is None:
            first = last
    if args.samples > 1 and (last[0] <= first[0] or last[1] <= first[1]):
        raise CheckError("head advancement was not observed on both nodes; extend the observation window and check reference/network activity")
    print(f"PASS: {args.samples} sample(s). This checks observed sync, not finality or ongoing availability.")


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        raise SystemExit("FAIL: " + str(error))
    except KeyboardInterrupt:
        raise SystemExit("Interrupted; verification did not complete.")
