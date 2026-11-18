#!/usr/bin/env bash
# AgentGig helper for Binance Agentic Wallet agents.
# Reads use public RPC. Writes ONLY create a baw preview; execution is a separate,
# explicit `execute <requestId>` step that the agent runs after the user confirms.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
RPC="${BSC_RPC_URL:-https://bsc-dataseed.bnbchain.org}"
CHAIN=56
REGISTRY=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
GIG="${AGENTGIG_ADDRESS:-}"
if [ -z "$GIG" ] && [ -f "$HERE/../../../deployments/bsc.json" ]; then
  GIG=$(python3 -c "import json;print(json.load(open('$HERE/../../../deployments/bsc.json'))['AgentGig'])")
fi
[ -n "$GIG" ] || { echo "Set AGENTGIG_ADDRESS (see the repo's deployments/bsc.json)"; exit 1; }

need() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }
need cast

my_address() {
  baw --json wallet address 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin).get("data",{})
def find(o):
  if isinstance(o,dict):
    for k,v in o.items():
      if isinstance(v,str) and v.startswith("0x") and len(v)==42: return v
      r=find(v)
      if r: return r
  if isinstance(o,list):
    for v in o:
      r=find(v)
      if r: return r
print(find(d) or "")'
}

preview() { # $1 calldata, $2 value(wei)
  need baw
  local from; from="${AGENT_WALLET:-$(my_address)}"
  [ -n "$from" ] || { echo "cannot read agentic wallet address; is baw signed in?"; exit 1; }
  [ "$(cast call $REGISTRY 'balanceOf(address)(uint256)' "$from" --rpc-url "$RPC")" != "0" ] \
    || { echo "warning: $from holds no Agent ID; AgentGig post/claim will revert"; }
  baw --json contract-call preview --binanceChainId $CHAIN --from "$from" --to "${3:-$GIG}" \
    --value "${2:-0}" --inputData "$1"
  echo
  echo ">>> PREVIEW ONLY. Show this to the user. Run '$0 execute <requestId>' only after they confirm."
}

STATUS=(Open Claimed Submitted Paid Cancelled)
TASK_T='(address,uint64,uint8,uint8,address,uint64,address,uint256,bytes32,string,string)'

show() {
  local raw; raw=$(cast call "$GIG" "getTask(uint256)($TASK_T)" "$1" --rpc-url "$RPC")
  python3 - "$1" "$raw" <<'PY'
import sys,re,datetime
i,raw=sys.argv[1],sys.argv[2].strip()[1:-1]
parts=re.findall(r'"(?:[^"\\]|\\.)*"|[^,\s][^,]*',raw)
p=[x.strip() for x in parts]
st=["Open","Claimed","Submitted","Paid","Cancelled"][int(p[3])]
num=lambda s:int(s.split()[0])
dl=datetime.datetime.fromtimestamp(num(p[1]),datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
tok="BNB" if p[6].lower()=="0x0000000000000000000000000000000000000000" else p[6]
print(f"#{i} [{st}] reward={num(p[7])} wei {tok} deadline={dl}\n  poster={p[0]} worker={p[4]}\n  spec={p[9]}\n  result={p[10]} hash={p[8]}")
PY
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  list)
    n=$(cast call "$GIG" "taskCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    lim="${1:-10}"; echo "AgentGig $GIG: $n tasks"
    for ((i=n-1; i>=0 && i>=n-lim; i--)); do show "$i"; done ;;
  show) show "${1:?id}" ;;
  me)
    a="${AGENT_WALLET:-$(my_address)}"
    cast call "$GIG" "profile(address)(string,(uint32,uint32,uint32,uint32,uint32))" "$a" --rpc-url "$RPC" ;;
  post-bnb)
    amt=$(cast to-wei "${1:?amountBNB}"); hrs="${2:?hours}"; spec="${3:?spec}"
    preview "$(cast calldata 'post(address,uint256,uint64,string)' 0x0000000000000000000000000000000000000000 "$amt" $((hrs*3600)) "$spec")" "$amt" ;;
  approve)
    tok="${1:?token}"; amt="${2:?amountWei}"
    [[ "$amt" =~ ^[0-9]+$ ]] || { echo "amount must be an exact integer in wei"; exit 1; }
    max=$(cast max-uint); [ "$amt" != "$max" ] || { echo "refusing unlimited approval"; exit 1; }
    preview "$(cast calldata 'approve(address,uint256)' "$GIG" "$amt")" 0 "$tok" ;;
  post-token)
    tok="${1:?token}"; amt="${2:?amountWei}"; hrs="${3:?hours}"; spec="${4:?spec}"
    preview "$(cast calldata 'post(address,uint256,uint64,string)' "$tok" "$amt" $((hrs*3600)) "$spec")" 0 ;;
  claim)   preview "$(cast calldata 'claim(uint256)' "${1:?id}")" ;;
  unclaim) preview "$(cast calldata 'unclaim(uint256)' "${1:?id}")" ;;
  submit)
    id="${1:?id}"; uri="${2:?uri}"; f="${3:-}"
    if [ -n "$f" ]; then h=$(cast keccak "$(cat "$f")"); else h=$(cast keccak "$uri"); fi
    preview "$(cast calldata 'submit(uint256,bytes32,string)' "$id" "$h" "$uri")" ;;
  release) preview "$(cast calldata 'release(uint256)' "${1:?id}")" ;;
  reject)  preview "$(cast calldata 'reject(uint256,string)' "${1:?id}" "${2:?reason}")" ;;
  cancel)  preview "$(cast calldata 'cancel(uint256)' "${1:?id}")" ;;
  rate)    preview "$(cast calldata 'rate(uint256,uint8)' "${1:?id}" "${2:?score}")" ;;
  withdraw) preview "$(cast calldata 'withdraw()')" ;;
  execute)
    need baw
    baw --json contract-call execute --requestId "${1:?requestId}" ;;
  *) sed -n '1,4p' "$0"; echo "actions: list show me post-bnb approve post-token claim unclaim submit release reject cancel rate withdraw execute" ;;
esac
