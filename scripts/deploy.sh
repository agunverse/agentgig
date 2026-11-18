#!/usr/bin/env bash
# Deploy AgentGig to BNB Chain mainnet from Wallet Testnet (WT).
#   Needs: env TESTNET_WALLET_PK (never printed), foundry in PATH.
#   Usage: scripts/deploy.sh            -> preflight only (no tx)
#          scripts/deploy.sh --broadcast -> preflight, then deploy + Sourcify verify
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

RPC="${BSC_RPC_URL:-https://bsc-dataseed.bnbchain.org}"
EXPECTED_DEPLOYER="0x152C2ed122A696987441E3929c7663444100493A"
REGISTRY="0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F"
DEPLOY_GAS=2400000          # measured 2,338,981 (forge gas report) + margin

[ -n "${TESTNET_WALLET_PK:-}" ] || { echo "TESTNET_WALLET_PK not set"; exit 1; }
FROM=$(cast wallet address --private-key "$TESTNET_WALLET_PK")
[ "${FROM,,}" = "${EXPECTED_DEPLOYER,,}" ] || { echo "key is for $FROM, expected $EXPECTED_DEPLOYER"; exit 1; }

CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN" = "56" ] || { echo "RPC chain id $CHAIN != 56"; exit 1; }
[ "$(cast code $REGISTRY --rpc-url "$RPC")" != "0x" ] || { echo "Agent ID registry not found"; exit 1; }

GP=$(cast gas-price --rpc-url "$RPC")
NEED=$(python3 -c "print(int($DEPLOY_GAS*$GP*1.5))")   # 50% buffer
BAL=$(cast balance "$FROM" --rpc-url "$RPC")
echo "deployer   $FROM"
echo "gas price  $(cast from-wei $GP gwei) gwei"
echo "need       $(cast from-wei $NEED) BNB (deploy gas $DEPLOY_GAS x1.5)"
echo "balance    $(cast from-wei $BAL) BNB"
python3 -c "import sys; sys.exit(0 if $BAL >= $NEED else 1)" || { echo "INSUFFICIENT BNB: top up WT, nothing sent."; exit 2; }
echo "preflight OK"

forge build --force >/dev/null
forge test --no-match-path 'test/*fork*' -q >/dev/null && echo "tests OK"

if [ -f deployments/bsc.json ] && [ "${FORCE_REDEPLOY:-}" != "1" ]; then echo "already deployed: $(cat deployments/bsc.json | tr -d "\n ")"; echo "set FORCE_REDEPLOY=1 to deploy again"; exit 3; fi
if [ "${1:-}" != "--broadcast" ]; then echo "dry run only (pass --broadcast to deploy)"; exit 0; fi

NONCE0=$(cast nonce "$FROM" --rpc-url "$RPC")
# forge create (forge 1.9 `script --broadcast` trips on its own recovery lock here)
OUT=$(forge create src/AgentGig.sol:AgentGig --rpc-url "$RPC" --private-key "$TESTNET_WALLET_PK" \
      --broadcast --json --constructor-args "$REGISTRY") || true
# forge sometimes reports "contract was not deployed" when the RPC lags; fall back to the nonce-derived address
NONCE_ADDR=$(cast compute-address "$FROM" --nonce "$NONCE0" | awk '{print $NF}')
ADDR=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['deployedTo'])" "$OUT" 2>/dev/null || echo "$NONCE_ADDR")
sleep 3; [ "$(cast code "$ADDR" --rpc-url "$RPC")" != "0x" ] || { echo "no code at $ADDR yet; check WT on bscscan before retrying"; exit 1; }
TX=$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['transactionHash'])" "$OUT" 2>/dev/null || echo "see https://bscscan.com/address/$FROM")
echo "tx: $TX  address: $ADDR"
[ "$(cast call "$ADDR" 'AGENT_ID()(address)' --rpc-url "$RPC")" = "$REGISTRY" ] || { echo "wiring check failed"; exit 1; }
echo "AgentGig: $ADDR"
mkdir -p deployments
python3 - "$ADDR" <<PY
import json,sys,time
json.dump({"chainId":56,"AgentGig":sys.argv[1],"deployTx":"$TX","AgentID":"$REGISTRY","deployer":"$FROM","deployedAt":int(time.time())},open("deployments/bsc.json","w"),indent=2)
PY
scripts/verify.sh "$ADDR" || echo "verification step failed; rerun scripts/verify.sh $ADDR"
