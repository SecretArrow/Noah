---
name: binance-agentic-wallet
title: Binance Agentic Wallet
description: Drive the official Binance wallet flow — connect/login via Binance's own pages, read balances and transactions, and gate every asset-moving action behind the user's explicit confirmation card. Companion in-app module /aw keeps per-chat policy (pairing note, daily limit, token registry, EIP-55 checks, spend intents + history).
version: "1.1"
wallet: true
permissions:
  - network
  - files
---

# Binance Agentic Wallet

You drive Binance wallet workflows from inside ZAgents. The ONLY trusted
entry points are Binance's official domains (binance.com and its country
sites). Anything else is a phishing target — abort immediately.

## Security rules (absolute)

1. NEVER request, repeat, or store seed phrases, private keys, API
   secrets, 2FA codes or passwords in chat. Binance login happens ONLY on
   Binance's own page. If the user pastes a credential, refuse it and
   tell them to use the official page.
2. Login/connection is NOT transaction permission: every send, swap,
   transfer, withdrawal, token approval or order MUST call
   `request_confirmation` and wait for the user's explicit approval.
3. Read-only data (balances, transaction history, prices) needs no
   confirmation card.
4. Report failures as failures. Never fabricate balances, addresses or
   transaction hashes.

## The in-app companion module — `/aw` (Agentic Wallet)

The app ships a policy/bookkeeping sample module for exactly this
workflow. It holds NO keys, does NO signing and makes NO network calls —
it only records policy per chat. Route the user there with `/aw help`.

- `/aw pair` + `/aw pair confirm` — record (bookkeeping only) that a
  wallet is attached to THIS chat. The REAL pairing still happens in the
  official Binance App / web wallet, by the user.
- `/aw limit <amount>` — per-token daily spend cap the user wants you to
  respect when drafting spends (`0` blocks all spending).
- `/aw network <bsc|eth|arbitrum|base>` — the chain the user intends to
  operate on (aliases `bnb`, `ethereum`); `/aw tokens` lists the
  registered mainnet tokens (EIP-55 canonical addresses, decimals).
- `/aw checksum <address> [network]` — validate shape + EIP-55 checksum
  of any address before you use it anywhere.
- `/aw spend <token> <amount> <to>` — policy-checked spend DRAFT. When
  the user asks to move value, build it this way, then call
  `request_confirmation` with EXACTLY the draft's facts (network, token,
  amount, destination) and wait for approval. Record the approved spend
  with `/aw spend confirm <id>`; drop it with `/aw spend cancel <id>`.
- `/aw history` — the chat's recorded spends; `/aw status` shows pairing,
  limit, today's book and any pending intent.

Always check the module's output before drafting a spend: if the draft
was rejected (over limit, unknown token, checksum mismatch), fix the
parameters or tell the user — never bypass the policy layer.

## Workflow 1 — connect / login

1. Confirm with the user: which Binance surface (Binance Web3 Wallet,
   Binance.com account) and which network they intend to use.
2. `browser_navigate` to the official entry (https://www.binance.com —
   the user's regional official site if they prefer) and locate the
   Wallet / Web3 Wallet area.
3. `browser_screenshot` the login state; instruct the user to complete
   the login THEMSELVES on the opened page (2FA included).
4. After login, `browser_extract_text` the portfolio page and report the
   connected wallet address (if shown) plus nothing else sensitive.
5. The login lives in THIS chat's isolated browser context only. Other
   chats cannot see it — never try to reuse another chat's session.

## Workflow 2 — balances & history (read-only)

1. On the official portfolio / transaction-history pages, use
   `browser_extract_text` (or `web_fetch` on public explorer pages such
   as bscscan.com for a BEP-20 address).
2. Summarize assets with chain and amounts; cite the URL of the page you
   read. Do not guess numbers the page does not show.

## Workflow 3 — send / swap / withdrawal (gated)

1. Collect the exact parameters from the user: action, network (e.g.
   bnb-beacon-chain, bsc, ethereum), asset (BNB, USDT...), amount,
   destination address. Validate the address with `/aw checksum` first.
2. On the official withdrawal/swap page, fill NOTHING until the user has
   confirmed the parameters in chat. Read the provider's fee quote with
   `browser_extract_text`.
3. Call `request_confirmation` with a summary naming action, network,
   destination, asset, amount and fee. The call blocks until the user
   approves or declines the ZAgents card.
4. On approval: complete the flow on the official page — the final
   signature/2FA confirmation happens on Binance's own UI by the user.
   Report the REAL outcome (transaction id or the exact error).
5. On decline/timeout: stop immediately. No retries.

## Limits on this device (be honest)

- ZAgents cannot sign transactions itself and cannot hold keys. Actions
  the Binance web UI does not offer on mobile web are UNSUPPORTED here —
  say so and suggest the official Binance app for those steps.
- The OFFICIAL agentic-wallet skill package
  (`npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet`,
  docs: https://www.binance.com/en/web3wallet) ships a `baw` CLI that
  needs real Node.js: it is NOT runnable in this on-device runtime. Do
  not pretend to run it — the companion `/aw` module covers only policy
  and bookkeeping, and every actual transfer is executed by the user in
  the Binance App / web wallet after a `request_confirmation` approval.
- Smart-contract interactions beyond what the official web UI exposes are
  out of scope for this skill. Be explicit about that limitation.
