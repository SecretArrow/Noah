# EVM Wallet — per-chat sample module (permissions: `storage`, `network`, `chat`)

A complete EVM wallet as a ZAgents chat module, driven entirely by
**`/wallet` slash commands** (manifest `commands: ["wallet"]` — messages
route to the module instead of the LLM, so wallet operations never
consume an AI turn). Zero npm dependencies: Keccak-256, secp256k1,
RFC 6979 deterministic nonces (HMAC-SHA256), RLP and EIP-55 are
implemented inline in `main.js`.

## Security model (read this first)

- **GENERATE-ONLY.** `/wallet create` derives a fresh random account for
  THIS chat from the sandbox RNG (WebCrypto `getRandomValues`, with a
  keccak-whitened entropy fallback). There is deliberately **no import
  command**: an existing private key pasted into a chat would land in
  the transcript and the LLM context. The app-wide rule stands — never
  ask for, accept, or repeat a seed phrase or an existing private key.
- **Per-chat isolation.** The account, the selected network and the
  pending transaction live in THIS chat's `zagents.storage` only. Two
  chats are two wallets; nothing is shared, by design.
- **Testnet first.** The default network is **Sepolia**. Mainnets are
  one `/wallet network <name>` away, and the module labels them
  `MAINNET — real funds!` in every report.
- **Two-step transfers.** `/wallet send` / `/wallet token send` only
  BUILD the transaction and print the full summary (from, to, amount,
  fee cap, max total cost, nonce, chain id). `/wallet confirm` signs
  and broadcasts; `/wallet cancel` discards. Pending offers expire
  after 10 minutes, are re-validated (nonce, balance, network) before
  signing, and never survive a network switch.
- **Allowlisted network access.** Every RPC call rides `zagents.http`
  (permission `network`) restricted by the manifest `allowedHosts` —
  only the public endpoints listed in `module.json` are reachable.
- **Checksum-protected addresses.** EIP-55 everywhere; mixed-case input
  with a broken checksum is rejected instead of silently accepted.
- **Sample quality.** This is a demonstration module: use testnets and
  small amounts. `/wallet export confirm` reveals the key into the chat
  transcript on purpose — read the warning first.

## Commands

| Command | What it does |
|---|---|
| `/wallet` | command list + safety notes |
| `/wallet create` | fresh random account for THIS chat (idempotent) |
| `/wallet info` | address, network, native balance, explorer link |
| `/wallet balance [contract]` | native balance, or ERC-20 balance with symbol/decimals |
| `/wallet network` | current network + the full list (chain ids, mainnet/testnet) |
| `/wallet network <name>` | switch network (drops any pending transaction) |
| `/wallet gas` | current gas price (+ latest block base fee when available) |
| `/wallet send <to> <amount>` | build a native transfer → full summary → `/wallet confirm` |
| `/wallet token <contract>` | token symbol, decimals, balance |
| `/wallet token send <c> <to> <a>` | build an ERC-20 transfer → summary → confirm |
| `/wallet confirm` | sign (RFC 6979 + EIP-155) and broadcast the pending tx |
| `/wallet cancel` | discard the pending tx |
| `/wallet tx <hash>` | receipt lookup (SUCCESS/FAILED, block, gas used) |
| `/wallet export confirm` | reveal THIS chat's private key (two-step, loud warning) |
| `/wallet reset confirm` | wipe THIS chat's wallet state (two-step) |
| `/wallet faucets` | testnet faucet links |

## Networks (all endpoints verified live before shipping)

| Key | Chain | Chain id | Kind |
|---|---|---|---|
| `ethereum` | Ethereum | 1 | mainnet |
| `sepolia` | Sepolia | 11155111 | testnet (default) |
| `bsc` | BNB Smart Chain | 56 | mainnet |
| `bsc-testnet` | BSC Testnet | 97 | testnet |
| `polygon` | Polygon PoS | 137 | mainnet |
| `arbitrum` | Arbitrum One | 42161 | mainnet |
| `base` | Base | 8453 | mainnet |
| `optimism` | OP Mainnet | 10 | mainnet |
| `base-sepolia` | Base Sepolia | 84532 | testnet |
| `optimism-sepolia` | OP Sepolia | 11155420 | testnet |

RPCs: `*.publicnode.com` (manifest wildcard) plus `arb1.arbitrum.io`,
`mainnet.base.org`, `mainnet.optimism.io`, `cloudflare-eth.com`.

## Example session

```text
/wallet create
  → New wallet created for THIS chat …
  → Address: 0x9F3B…C21 (EIP-55 checksummed)
  → Network: sepolia (TESTNET) — fund it from a faucet (/wallet faucets)

/wallet info
  → Address / Network / Native balance / Explorer link

/wallet send 0x0000…dEaD 0.05
  → TRANSACTION SUMMARY — REVIEW BEFORE CONFIRMING
  → Network, From, To, Amount, Fee cap, Max total cost, Nonce
  → Nothing is signed or sent yet. /wallet confirm | /wallet cancel

/wallet confirm
  → Signing with THIS chat key (RFC 6979 + EIP-155, chain id 11155111) …
  → Transaction BROADCAST: 0xabc…  Explorer: https://sepolia.etherscan.io/tx/0xabc…

/wallet tx 0xabc…
  → Status: SUCCESS · Block: 5 431 210 · Gas used: 21 000
```

## What the sample demonstrates

- `zagents.http` with a manifest `allowedHosts` allowlist (JSON-RPC over
  POST, `timeoutMs` per call, error propagation from the RPC payload)
- `zagents.storage` as a per-chat state machine (account + network +
  pending transaction + history tail, surviving activations)
- `zagents.chat.emit` for progressive multi-line reports and
  `zagents.log` for diagnostics
- Manifest `commands` routing (the module runs instead of the LLM) and
  `timeoutSeconds` for slower RPC chains
- Pure-JS crypto with BigInt: Keccak-256, SHA-256, HMAC, RFC 6979,
  secp256k1 scalar mult + ECDSA (low-s), RLP, EIP-155, EIP-55, ERC-20
  ABI calls — validated against the canonical EIP-155 spec vector
  (byte-identical signature) and cross-checked against OpenSSL

## Install

Download `evm-wallet.zip` (next to this folder), then
**Settings → Modules → Install module** in ZAgents, approve the
`storage` + `network` + `chat` permissions, and type `/wallet` in a
chat. See `../README.md` for the general install/packaging flow.
