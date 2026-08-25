#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_ENODE='enode://49a8ef3983f09b5b27290b05e64cef28118b0e8d4ffdfdd14e879eefb09d7c52cb7a2852d20d5efebbe3686dc17b556fbeece0e477410871ed9c0a8e88538202@dogeos-testnet-cluster-b-0-68dc9c36e8602723.elb.us-west-2.amazonaws.com:30303'

usage() {
  cat <<'EOF'
Hot-add or replace a trusted peer on a running dogeos-rpc-package Reth node.

The script does not restart the container and does not modify the database. It
uses Reth's local IPC admin API, resolves the enode hostname to a reachable IPv4
address, removes any old endpoint with the same node ID, adds the new endpoint,
and waits briefly for a P2P connection.

Usage:
  sudo ./scripts/add-l2reth-peer.sh [ENODE]

The current l2-bootnode-0 public enode is used when ENODE is omitted. You can
also set NEW_ENODE instead of passing an argument.

Optional environment variables:
  L2RETH_CONTAINER       Docker container name (default: l2reth-node)
  L2RETH_IPC_PATH        IPC path inside the container (default: /tmp/reth.ipc)
  PEER_CONNECT_TIMEOUT   TCP probe timeout in seconds (default: 3)
  PEER_VERIFY_TIMEOUT    P2P verification timeout in seconds (default: 30)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

container="${L2RETH_CONTAINER:-l2reth-node}"
container_ipc="${L2RETH_IPC_PATH:-/tmp/reth.ipc}"
requested_enode="${1:-${NEW_ENODE:-$DEFAULT_ENODE}}"
connect_timeout="${PEER_CONNECT_TIMEOUT:-3}"
verify_timeout="${PEER_VERIFY_TIMEOUT:-30}"

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is required" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required on the Docker host" >&2
  exit 1
}

if [[ "$requested_enode" =~ [[:space:]] ]]; then
  echo "ERROR: the enode contains whitespace or an embedded line break" >&2
  printf 'Value: %q\n' "$requested_enode" >&2
  exit 2
fi

running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
if [[ "$running" != "true" ]]; then
  echo "ERROR: container '$container' does not exist or is not running" >&2
  exit 1
fi

container_pid="$(docker inspect -f '{{.State.Pid}}' "$container")"
host_ipc="/proc/${container_pid}/root${container_ipc}"

if [[ ! -S "$host_ipc" ]]; then
  echo "ERROR: Reth IPC socket not found at $host_ipc" >&2
  echo "Run this script as root/sudo, or override L2RETH_IPC_PATH if needed." >&2
  exit 1
fi

echo "Container:       $container"
echo "Container PID:   $container_pid"
echo "IPC socket:      $host_ipc"
echo "Requested enode: $requested_enode"

python3 - "$host_ipc" "$requested_enode" "$connect_timeout" "$verify_timeout" <<'PY'
import json
import re
import socket
import sys
import time
from urllib.parse import urlsplit


ipc_path = sys.argv[1]
requested_enode = sys.argv[2]
connect_timeout = float(sys.argv[3])
verify_timeout = float(sys.argv[4])


def fail(message, code=1):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


parsed = urlsplit(requested_enode)
if parsed.scheme != "enode":
    fail("peer URL must use the enode:// scheme", 2)

node_id = parsed.username or ""
if not re.fullmatch(r"[0-9a-fA-F]{128}", node_id):
    fail("enode node ID must contain exactly 128 hexadecimal characters", 2)

try:
    host = parsed.hostname
    port = parsed.port
except ValueError as error:
    fail(f"invalid enode endpoint: {error}", 2)

if not host or port is None:
    fail("enode must contain a hostname/IP and port", 2)

try:
    address_info = socket.getaddrinfo(
        host,
        port,
        family=socket.AF_INET,
        type=socket.SOCK_STREAM,
    )
except socket.gaierror as error:
    fail(f"cannot resolve {host}: {error}")

addresses = []
for item in address_info:
    ip = item[4][0]
    if ip not in addresses:
        addresses.append(ip)

print(f"Resolved IPv4:   {', '.join(addresses)}")

selected_ip = None
errors = []
for ip in addresses:
    try:
        with socket.create_connection((ip, port), timeout=connect_timeout):
            selected_ip = ip
            break
    except OSError as error:
        errors.append(f"{ip}:{port}: {error}")

if selected_ip is None:
    fail(
        "none of the resolved P2P endpoints is reachable:\n  "
        + "\n  ".join(errors)
    )

# Reth versions differ in their support for DNS names in admin_* peer methods.
# Use the verified NLB frontend IP for the runtime IPC update.
runtime_enode = f"enode://{node_id}@{selected_ip}:{port}"
print(f"Reachable IP:    {selected_ip}:{port}")
print(f"Runtime enode:   {runtime_enode}")

request_id = 0


def rpc(method, params):
    global request_id
    request_id += 1
    request = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params,
    }
    payload = json.dumps(request, separators=(",", ":")).encode() + b"\n"

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(15)
    try:
        client.connect(ipc_path)
        client.sendall(payload)
        response_data = b""
        while len(response_data) < 16 * 1024 * 1024:
            chunk = client.recv(1024 * 1024)
            if not chunk:
                break
            response_data += chunk
            try:
                return json.loads(response_data.decode().strip())
            except json.JSONDecodeError:
                continue
    finally:
        client.close()

    fail(f"IPC returned no complete JSON response for {method}")


def call(method, params, required=False):
    response = rpc(method, params)
    if "error" in response:
        level = "ERROR" if required else "WARNING"
        print(f"{level}: {method}: {json.dumps(response['error'])}")
        if required:
            raise SystemExit(1)
    else:
        print(f"{method}: {response.get('result')!r}")
    return response


# Removal is keyed by node identity, so the reachable replacement endpoint can
# remove an older DNS/IP entry carrying the same public key.
call("admin_removePeer", [runtime_enode])
call("admin_removeTrustedPeer", [runtime_enode])
call("admin_addPeer", [runtime_enode], required=True)
call("admin_addTrustedPeer", [runtime_enode], required=True)

deadline = time.monotonic() + verify_timeout
while True:
    peers_response = rpc("admin_peers", [])
    if "error" in peers_response:
        fail(f"admin_peers failed: {json.dumps(peers_response['error'])}")

    peers = peers_response.get("result") or []
    matching = [
        peer
        for peer in peers
        if node_id.lower() in str(peer.get("enode", "")).lower()
    ]
    if matching:
        print("Connected peer:")
        print(json.dumps(matching, indent=2))
        print("SUCCESS: the Reth node is connected to the replacement peer")
        break

    if time.monotonic() >= deadline:
        peer_count = rpc("net_peerCount", [])
        print(f"Current net_peerCount response: {json.dumps(peer_count)}")
        fail(
            "the peer was injected but did not connect before the verification "
            "timeout; check client logs for genesis/network/handshake errors",
            3,
        )

    time.sleep(2)
PY

cat <<'EOF'

NOTE: this is a runtime update. Also update L2GETH_PEER_LIST/L2RETH_PEER_LIST
on disk so that a future container restart does not restore the obsolete peer.
EOF
