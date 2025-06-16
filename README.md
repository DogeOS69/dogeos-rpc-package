# DogeOS RPC Package (Testnet)

Docker Compose setup for DogeOS testnet external RPC node.

## Components

- **dogecoin-node** - Dogecoin testnet full node
- **l2geth-node** - DogeOS L2 RPC service (connects to external L1)
- **celestia-light-node** - Celestia light node for data availability

## Configuration

The setup is pre-configured with DogeOS testnet settings. **You need to update the L1 endpoint** to point to your L1 RPC:

**Chain Configuration:**
- Chain ID: `221122` (DogeOS testnet)
- L1 Endpoint: Connects to external L1 testnet
- L2 Peer List: Official DogeOS sequencer nodes
- Dogecoin: Testnet mode enabled

**Key Environment Variables:**
```yaml
- CHAIN_ID=221122
- L2GETH_L1_ENDPOINT=http://your-l1-host:8545  # Update with actual L1 endpoint
- L2GETH_PEER_LIST=["enode://c2255661e4748315900587a74332f996d5e0473461ec4d551297806d4c473cbc98c5e9ce7ae6aca191eb7ec70e0c9e0117a0d52a4a7748cb51a740697dfdfcca@l2-sequencer-0:30303","enode://810fba559a288e072fed7bb3056326502ced3d78370d75460bebe109b099eef114fafc2d481d7f495148aab79f21e24922fe3f6ca7c73439ee9ccfe394503e76@l2-sequencer-1:30303"]
- L2GETH_CCC_NUMWORKERS=5
```

## File Structure

```
├── docker-compose.yml          # Main orchestration file
├── dogecoin/
│   └── dogecoin.conf          # Dogecoin node configuration
├── l2geth/
│   ├── genesis.json           # L2 genesis configuration
│   └── entrypoint.sh          # L2geth startup script
└── README.md
```

## Usage

1. **Start all services:**
```bash
docker-compose up -d
```

2. **Check service status:**
```bash
docker-compose ps
```

3. **View logs:**
```bash
# L2 RPC logs
docker logs -f l2geth-node

# Dogecoin testnet node logs
docker logs -f dogecoin-node

# Celestia light node logs
docker logs -f celestia-light-node
```

4. **Stop services:**
```bash
docker-compose down
```

## Endpoints

- **L2 HTTP RPC:** `http://localhost:8545`
- **L2 WebSocket:** `ws://localhost:8546`
- **Dogecoin Testnet RPC:** `http://localhost:22555`
- **Celestia Gateway:** `http://localhost:26659`
- **Celestia RPC:** `http://localhost:26658`

> **Note:** The L1 endpoint is external and needs to be configured.

## Service Dependencies

- `l2geth-node` connects to external L1 RPC
- `dogecoin-node` runs independently (testnet)
- `celestia-light-node` runs independently
- All services use persistent volumes for data storage

## Network Configuration

- **DogeOS Chain ID:** 221122
- **L1 Network:** External testnet
- **Celestia Network:** mocha testnet
- **Dogecoin Network:** testnet
- **Peer Discovery:** Uses official DogeOS sequencer nodes

## Troubleshooting

1. **Check if all containers are running:**
```bash
docker-compose ps
```

2. **Verify Dogecoin sync status:**
```bash
docker logs dogecoin-node | tail -20
```

3. **Check L2 connection to L1:**
```bash
docker logs l2geth-node | grep -i "l1"
```

4. **Monitor Celestia data availability:**
```bash
docker logs celestia-light-node | grep -i "sampled"
``` 