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

if [ "${1:-}" != "--broadcast" ]; then echo "dry run only (pass --broadcast to deploy)"; exit 0; fi

forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --private-key "$TESTNET_WALLET_PK" --broadcast --slow
ADDR=$(python3 -c "import json;d=json.load(open('broadcast/Deploy.s.sol/56/run-latest.json'));print([t for t in d['transactions'] if t['transactionType']=='CREATE'][0]['contractAddress'])")
echo "AgentGig: $ADDR"
mkdir -p deployments
python3 - "$ADDR" <<PY
import json,sys,time
json.dump({"chainId":56,"AgentGig":sys.argv[1],"AgentID":"$REGISTRY","deployer":"$FROM","deployedAt":int(time.time())},open("deployments/bsc.json","w"),indent=2)
PY
scripts/verify.sh "$ADDR" || echo "verification step failed; rerun scripts/verify.sh $ADDR"
