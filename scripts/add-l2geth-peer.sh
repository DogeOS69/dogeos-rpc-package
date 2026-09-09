#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_ENODE='enode://49a8ef3983f09b5b27290b05e64cef28118b0e8d4ffdfdd14e879eefb09d7c52cb7a2852d20d5efebbe3686dc17b556fbeece0e477410871ed9c0a8e88538202@dogeos-testnet-cluster-b-0-68dc9c36e8602723.elb.us-west-2.amazonaws.com:30303'

usage() {
  cat <<'EOF'
Hot-add or replace a static/trusted peer on a running dogeos-rpc-package Geth
node.

The script does not restart the container and does not modify the database. It
resolves the enode hostname to a reachable IPv4 address, removes any old static
or trusted endpoint with the same node ID, adds the replacement through Geth's
local IPC admin API, and waits briefly for a P2P connection.

Usage:
  ./scripts/add-l2geth-peer.sh [ENODE]

The current l2-bootnode-0 public enode is used when ENODE is omitted. You can
also set NEW_ENODE instead of passing an argument.

Optional environment variables:
  L2GETH_CONTAINER        Docker container name (default: l2geth-node)
  L2GETH_IPC_PATH         IPC path inside the container
                          (default: /l2geth/data/geth.ipc)
  L2GETH_BINARY           Geth binary inside the container (default: geth)
  PEER_CONNECT_TIMEOUT    TCP probe timeout in seconds (default: 3)
  PEER_VERIFY_TIMEOUT     P2P verification timeout in seconds (default: 30)
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

container="${L2GETH_CONTAINER:-l2geth-node}"
container_ipc="${L2GETH_IPC_PATH:-/l2geth/data/geth.ipc}"
geth_binary="${L2GETH_BINARY:-geth}"
requested_enode="${1:-${NEW_ENODE:-$DEFAULT_ENODE}}"
connect_timeout="${PEER_CONNECT_TIMEOUT:-3}"
verify_timeout="${PEER_VERIFY_TIMEOUT:-30}"

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is required" >&2
  exit 1
}

command -v getent >/dev/null 2>&1 || {
  echo "ERROR: getent is required on the Docker host" >&2
  exit 1
}

command -v timeout >/dev/null 2>&1 || {
  echo "ERROR: timeout is required on the Docker host" >&2
  exit 1
}

if [[ "$requested_enode" =~ [[:space:]] ]]; then
  echo "ERROR: the enode contains whitespace or an embedded line break" >&2
  printf 'Value: %q\n' "$requested_enode" >&2
  exit 2
fi

enode_pattern='^enode://([[:xdigit:]]{128})@([A-Za-z0-9.-]+):([0-9]{1,5})$'
if [[ ! "$requested_enode" =~ $enode_pattern ]]; then
  echo "ERROR: invalid enode; expected enode://<128 hex chars>@<host>:<port>" >&2
  exit 2
fi

node_id="${BASH_REMATCH[1]}"
peer_host="${BASH_REMATCH[2]}"
peer_port="${BASH_REMATCH[3]}"

if (( 10#$peer_port < 1 || 10#$peer_port > 65535 )); then
  echo "ERROR: invalid enode port: $peer_port" >&2
  exit 2
fi

if [[ ! "$connect_timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "ERROR: PEER_CONNECT_TIMEOUT must be a positive number" >&2
  exit 2
fi

if [[ ! "$verify_timeout" =~ ^[0-9]+$ || "$verify_timeout" == "0" ]]; then
  echo "ERROR: PEER_VERIFY_TIMEOUT must be a positive integer" >&2
  exit 2
fi

running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
if [[ "$running" != "true" ]]; then
  echo "ERROR: container '$container' does not exist or is not running" >&2
  exit 1
fi

if ! docker exec "$container" test -S "$container_ipc"; then
  echo "ERROR: Geth IPC socket not found at $container_ipc in '$container'" >&2
  exit 1
fi

mapfile -t resolved_ips < <(
  getent ahostsv4 "$peer_host" |
    awk '$2 == "STREAM" && !seen[$1]++ { print $1 }'
)

if (( ${#resolved_ips[@]} == 0 )); then
  echo "ERROR: cannot resolve $peer_host to an IPv4 address" >&2
  exit 1
fi

selected_ip=""
for candidate in "${resolved_ips[@]}"; do
  if timeout "$connect_timeout" \
    bash -c ">/dev/tcp/${candidate}/${peer_port}" 2>/dev/null; then
    selected_ip="$candidate"
    break
  fi
done

if [[ -z "$selected_ip" ]]; then
  echo "ERROR: none of the resolved P2P endpoints is reachable" >&2
  for candidate in "${resolved_ips[@]}"; do
    printf '  %s:%s\n' "$candidate" "$peer_port" >&2
  done
  exit 1
fi

# The runtime API accepts IP-based enodes consistently across Geth forks. The
# configured DNS name is resolved immediately before injection, so the selected
# IP still points at the current NLB rather than a Kubernetes Pod.
runtime_enode="enode://${node_id}@${selected_ip}:${peer_port}"

echo "Container:       $container"
echo "IPC socket:      $container_ipc"
echo "Requested enode: $requested_enode"
echo "Resolved IPv4:   ${resolved_ips[*]}"
echo "Reachable IP:    ${selected_ip}:${peer_port}"
echo "Runtime enode:   $runtime_enode"

admin_result="$(
  docker exec "$container" "$geth_binary" attach \
    --exec "var e='$runtime_enode'; var removed=admin.removePeer(e); var untrusted=(typeof admin.removeTrustedPeer === 'function' ? admin.removeTrustedPeer(e) : null); var added=admin.addPeer(e); var trusted=(typeof admin.addTrustedPeer === 'function' ? admin.addTrustedPeer(e) : null); ({removed:removed, untrusted:untrusted, added:added, trusted:trusted})" \
    "$container_ipc"
)"

echo "Admin update result:"
echo "$admin_result"

deadline=$((SECONDS + verify_timeout))
while (( SECONDS <= deadline )); do
  matching_count="$(
    docker exec "$container" "$geth_binary" attach \
      --exec "admin.peers.filter(function(p) { return p.enode.toLowerCase().indexOf('${node_id,,}') >= 0; }).length" \
      "$container_ipc" |
      tail -n 1 |
      tr -d '\r[:space:]'
  )"

  if [[ "$matching_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Connected peer:"
    docker exec "$container" "$geth_binary" attach \
      --exec "admin.peers.filter(function(p) { return p.enode.toLowerCase().indexOf('${node_id,,}') >= 0; })" \
      "$container_ipc"
    echo "SUCCESS: the Geth node is connected to the replacement peer"
    cat <<'EOF'

NOTE: this is a runtime update. Also update L2GETH_PEER_LIST on disk so that a
future container restart does not restore the obsolete peer.
EOF
    exit 0
  fi

  sleep 2
done

echo "Peer was injected but did not connect before the verification timeout." >&2
echo "Current node/peer status:" >&2
docker exec "$container" "$geth_binary" attach \
  --exec 'JSON.stringify({network:net.version, peerCount:net.peerCount, eth:admin.nodeInfo.protocols.eth})' \
  "$container_ipc" >&2 || true

cat >&2 <<EOF

Enable detailed P2P diagnostics without restarting:
  docker exec $container $geth_binary attach --exec 'debug.verbosity(5)' $container_ipc
  sleep 15
  docker logs $container --since 30s 2>&1 | grep -Ei 'dial|peer|handshake|genesis|network|disconnect|timeout'
  docker exec $container $geth_binary attach --exec 'debug.verbosity(3)' $container_ipc
EOF

exit 3
