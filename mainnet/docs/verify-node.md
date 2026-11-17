# Verify Your RPC Node

**Mainnet is not released.** These checks apply after the release configuration
and initialization procedure are available.

Run these checks from this network's directory after the staged `start`
command completes. Keep the node out of your serving pool until the checks
agree. L1 readiness allows L2Reth to start; it does not certify L2 sync.

## Local Health and RPC

```bash
docker compose ps -a
curl --fail http://localhost:9090/health
curl --fail http://localhost:9090/api/v1/health/ready

# Change this URL if you changed L2_HTTP_PORT or the host.
export LOCAL_RPC_URL=http://127.0.0.1:8545
for method in eth_chainId eth_syncing eth_blockNumber net_peerCount; do
  printf '\n%s\n' "$method"
  curl --fail --silent --show-error --max-time 15 \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}" \
    "$LOCAL_RPC_URL" | jq .
done
```

An HTTP 200 with a JSON-RPC `error` is a failed query, not a successful check.
Review the results:

- `/health`: HTTP 200, `status=ready`, `historical_sync=completed`.
- `/api/v1/health/ready`: HTTP 200 and `ready=true`.
- `eth_chainId`: must equal `config/l2reth-genesis.json`'s `config.chainId`.
  RPC returns a hexadecimal string; the genesis file uses a decimal number.
- `eth_syncing`: an object means the node reports sync in progress. `false`
  still needs a reference-height comparison; a stalled/isolated node may
  report `false`.
- `eth_blockNumber`: inspect repeatedly for progress and compare with the
  reference below. A slowly advancing node may still be far behind.
- `net_peerCount`: hexadecimal connected peer count. Zero is a reason to
  inspect peer configuration, reachability and logs; peer count alone neither
  proves nor disproves that the node has caught up through its other sources.

## Compare with a Trusted Reference

**The mainnet reference RPC has not been published yet.** There is no default
address. After mainnet release, supply the announced reference with
`--reference-url`; do not substitute the testnet RPC. Until then, this acceptance
step cannot be completed using a package-provided mainnet reference.

Run in this network's directory:

```bash
python3 scripts/verify-rpc.py --reference-url https://YOUR-MAINNET-REFERENCE
```

The helper only reads RPC data. It checks both chain IDs against package genesis,
requires both nodes to report `eth_syncing=false`, prints decimal head heights,
and compares a shared historical block hash. No settings or chain data change.

The package's suggested pre-service check is **three successful samples, 30
seconds apart, no more than five blocks of head difference, and head advancement
on both nodes over the observation window**. The command applies these defaults,
takes at least one minute and exits nonzero at the first failed check. A final
`PASS: 3 sample(s)` means these observed checks passed. Combine that with both L1
health checks above and no persistent service errors before routing traffic.

These are operational defaults, not protocol confirmation/finality rules or a
service-level guarantee. If the chain is quiet, no observed advancement is an
inconclusive check: extend the window, for example `--interval 60`. Check a
stale reference before assuming the local node is wrong. Adjust `--max-lag`
only to match your service's accepted lag, not merely to silence a failure.

If you changed the local HTTP port, pass `--local-url http://127.0.0.1:PORT`.
`--samples 1` is a quick diagnostic without an advancement check, not the full
pre-service check. For a separately verified block, optionally pass
`--block-number DECIMAL_HEIGHT`; it must be present on both nodes. By default,
the sampled block is 20 blocks behind the lower head (or genesis at low heights).
This sample reduces sensitivity to moving tips; it does not prove finality.

| Failure | Next action |
|---------|-------------|
| Chain ID differs from package genesis | Check the network and the local/reference URLs |
| Local reports syncing or head difference exceeds the limit | Keep it out of service, inspect progress and retry after catch-up |
| Reference reports syncing, is behind, or does not advance | Check reference/network activity; retry later or use another trusted same-network reference |
| Block hash mismatch | Keep the node out of service; investigate reorgs, configuration and the reference before replacing data |
| HTTP, connection, JSON-RPC or invalid response error | The message identifies local/reference and the method; check access, rate limits and method support |
| Package genesis missing/invalid | Complete the release configuration; mainnet is currently unreleased |

Errors identify the check without printing provider URLs or response bodies
that might contain credentials. Continue monitoring head lag after admission;
see [Load Balancer Health](operations.md#load-balancer-health) and apply
[Network Security](operations.md#network-security) before allowing traffic.
