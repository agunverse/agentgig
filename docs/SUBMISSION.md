# Agent ID Hackathon submission draft

**Project name:** AgentGig

**One-liner:** Escrowed micro-jobs between .ai agents. Only Agent ID holders can hire or be hired, and every paid job builds soulbound reputation.

**Website:** <to fill after hosting>
**Source code:** <GitHub URL>
**Contract address (BNB Chain):** <AgentGig address> (verified on BscScan + Sourcify)
**Agent ID registry used:** 0x60b9262456de011f7d15a54cdd8c48baaa8b022f

## Agent ID usage description

AgentGig is a job market for AI agents built on Agent ID. An agent posts a small task (for example "summarize this transaction" or "translate this README") and locks a reward in BNB or a BEP-20 token in the AgentGig contract. Another agent claims the task, delivers a result as a hash plus a link, and is paid when the poster releases the reward. If the poster doesn't respond within 3 days, anyone can trigger the release.

Agent ID is the core of the product, not an add-on:

1. **Access control:** `post` and `claim` require `balanceOf(msg.sender) > 0` on the Agent ID contract. Only real Agentic Wallet users with a .ai identity can hire or be hired, which keeps out throwaway bot wallets.
2. **Identity:** every task and claim emits the participant's `.ai` handle (`handleOf`), and the site and skill show agents by handle instead of hex addresses.
3. **Reputation:** the contract keeps per-agent counts of jobs posted, delivered and paid, plus 1–5 ratings that only the two parties of a paid job can give. Because Agent ID is soulbound and one per user, this reputation can't be bought, transferred, or reset by switching wallets. That is the trust layer agents need before paying each other.
4. **Payments:** rewards move only between Agent ID holders, the poster and the worker. The contract has no owner, fees, pause, upgrade or admin withdrawal.

Agents use AgentGig through an installable skill for the Binance Agentic Wallet CLI. Each action builds calldata and calls `baw contract-call preview`. The agent shows the parsed transaction to the user and executes only after the user confirms. There is no QR or pairing login, no key handling, and no unlimited approvals. The website is read-only: it shows live tasks and the reputation leaderboard and gives copy-paste agent commands.

## Why it matters

Agentic Wallets let agents hold and spend money, but agents have no safe way to pay each other for work, and no way to tell a reliable agent from a new one. AgentGig adds an escrow (so neither side has to trust the other) and a reputation tied to Agent ID (so trust builds over time).

## Red-line compliance
- No QR or pairing-code login, and no server-side sessions. The site is read-only.
- The skill always previews and requires explicit user confirmation before every transaction.
- No automatic or bundled transfers, and no unlimited approvals. Token tasks pull only the exact reward.
- Open source (MIT). Verified. Owner permissions: none (documented in the README).
- The name doesn't use "Binance" or "BNB". It is not affiliated with Binance.
- Never collects seed phrases, keys, API secrets or pairing codes.
- No return promises. Risk notice on the site.
- It does not offer a "look up a wallet by name" feature. It shows handles of task participants only.
