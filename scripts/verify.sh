#!/usr/bin/env bash
# Verify AgentGig without any API key:
#   1) Sourcify (keyless, full match) via forge
#   2) Write the Standard-JSON input for BscScan's web form
#      (bscscan.com/verifyContract -> Compiler Type "Solidity (Standard-Json-Input)").
#   If ETHERSCAN_API_KEY (a free Etherscan v2 key) is set, also verifies on BscScan directly.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
ADDR="${1:?usage: scripts/verify.sh <AgentGig address>}"
REGISTRY="0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F"
ARGS=$(cast abi-encode "constructor(address)" $REGISTRY)

forge verify-contract "$ADDR" src/AgentGig.sol:AgentGig --chain 56 --verifier sourcify \
  --constructor-args "$ARGS" --watch || true

mkdir -p verify
forge verify-contract "$ADDR" src/AgentGig.sol:AgentGig --chain 56 --constructor-args "$ARGS" \
  --show-standard-json-input > verify/AgentGig.standard-input.json
echo "${ARGS#0x}" > verify/constructor-args.txt
cat > verify/BSCSCAN.md <<MD
BscScan manual verification (no API key):
1. Open https://bscscan.com/verifyContract?a=$ADDR
2. Compiler type: Solidity (Standard-Json-Input); compiler: v0.8.24+commit.e11b9ed9; license: MIT
3. Upload verify/AgentGig.standard-input.json
4. Contract name: src/AgentGig.sol:AgentGig
5. Constructor arguments (ABI-encoded): $(cat verify/constructor-args.txt)
MD
echo "wrote verify/ (standard json + constructor args + steps)"

if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  forge verify-contract "$ADDR" src/AgentGig.sol:AgentGig --chain 56 --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" --constructor-args "$ARGS" --watch
fi
