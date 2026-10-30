#!/usr/bin/env bash
# Task 6 end-to-end: submit -> anchor -> notarize against a live anvil node.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=http://127.0.0.1:8545
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil #0
AUTHOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d # anvil #1
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

mkdir -p /tmp/opencode
anvil --silent --port 8545 >/tmp/opencode/anvil.log 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
cast chain-id --rpc-url "$RPC" >/dev/null
echo "== anvil up"

# foundry 1.5: forge create dry-runs unless --broadcast is passed.
MOCK_OUT=$(forge create test/mocks/MockRouter.sol:MockRouter --rpc-url "$RPC" --private-key "$PK" --broadcast 2>&1)
MOCK=$(printf '%s\n' "$MOCK_OUT" | grep -oE "Deployed to: 0x[0-9a-fA-F]{40}" | head -1 | cut -d' ' -f3)
[ -n "$MOCK" ] || { echo "FAIL: mock deploy"; printf '%s\n' "$MOCK_OUT"; exit 1; }
echo "== mock router $MOCK"

HUB_OUT=$(HUB_ADMIN=$ADMIN HUB_ROUTER=$MOCK HUB_ETH_CHAIN_SELECTOR=8453 \
  forge script script/DeployHub.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast 2>&1)
PROXY=$(printf '%s\n' "$HUB_OUT" | grep -A3 HUB_PROXY | grep -oE "0x[0-9a-fA-F]{40}" | head -1)
[ -n "$PROXY" ] || { echo "FAIL: hub proxy not found"; printf '%s\n' "$HUB_OUT"; exit 1; }
echo "== hub proxy $PROXY"

HUB_ADDRESS=$PROXY ARTICLE_AUTHOR_KEY=$AUTHOR_KEY \
  forge script script/E2ESubmit.s.sol --rpc-url "$RPC" --broadcast
J=$(cast call "$PROXY" "journalLength()(uint256)" --rpc-url "$RPC")
echo "== journalLength=$J"
[ "$J" = "1" ] || { echo "FAIL: journal"; exit 1; }

# One article < MIN_BATCH(10): close via the BATCH_DEADLINE lane (6h), the
# path a solo author's batch actually takes on a quiet chain.
cast rpc --rpc-url "$RPC" evm_increaseTime 21601 >/dev/null
cast rpc --rpc-url "$RPC" evm_mine >/dev/null
HUB_ADDRESS=$PROXY forge script script/Anchor.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast
ROOT=$(cast call "$PROXY" "rootAt(uint256)(bytes32)" 0 --rpc-url "$RPC")
echo "== rootAt(0)=$ROOT"
[ "$ROOT" != "0x0000000000000000000000000000000000000000000000000000000000000000" ] || { echo "FAIL: root"; exit 1; }

if ! cast rpc --rpc-url "$RPC" anvil_mine 0x50 >/dev/null 2>&1; then
  for _ in $(seq 1 80); do cast rpc --rpc-url "$RPC" evm_mine >/dev/null; done
fi
echo "== mined past K"

HUB_ADDRESS=$PROXY NOTARY_BATCH_START=0 NOTARY_FEE_WEI=100000000000000000 \
  forge script script/Notarize.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast

# cast appends a human-readable form ("100000000000000000 [1e17]") — keep the raw value.
MV=$(cast call "$MOCK" "lastValue()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
DEST=$(cast call "$MOCK" "lastDest()(uint64)" --rpc-url "$RPC")
echo "== mock.lastValue=$MV lastDest=$DEST"
[ "$MV" = "100000000000000000" ] || { echo "FAIL: fee forwarded"; exit 1; }
[ "$DEST" = "8453" ] || { echo "FAIL: destination"; exit 1; }

echo "E2E OK: submit -> anchor -> notarize"
