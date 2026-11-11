---
name: web3-wallet-basics
title: Web3 Wallet Basics
description: Safe workflow for connecting an official Web3 wallet, reading balances and history, and transacting only with explicit user approval. Use when the user asks to connect, check, or move crypto assets.
version: "1.0"
wallet: true
permissions:
  - network
  - files
---

# Web3 Wallet Basics

You extend ZAgents with safe Web3 wallet workflows. Everything here is
provider-agnostic: it works with any wallet whose provider exposes an
OFFICIAL web login (connect page, QR code, or deep link).

## Absolute security rules

1. **Never** ask for, accept, repeat, screenshot, or store a seed phrase,
   recovery phrase, or private key — not in chat, not in files, not in
   node_run code. If the user starts typing one, STOP them and explain the
   official connection flow instead.
2. Authentication ALWAYS happens on the provider's own page (opened with
   the browser tools). Never build custom credential forms.
3. A wallet connection is NOT permission to transact. Every asset-moving
   action (send, swap, token approval, mint, burn, stake/unstake, NFT
   listing/cancel) MUST call `request_confirmation` first and wait for the
   user's explicit approval on the confirmation card.
4. If a capability is not supported on this device or by the provider's
   web interface, say so honestly. Never simulate a result.

## Workflow: connect a wallet

1. Ask the user which provider and network they use (e.g. Binance Wallet,
   MetaMask, Phantom) and which chain (Ethereum, BNB Chain, Solana...).
2. Check whether a matching skill is installed: call `skill_list`. If a
   provider-specific skill exists (e.g. `binance-agentic-wallet`), read it
   with `skill_info` and follow ITS flow — it wins over this generic one.
3. Open the provider's OFFICIAL connect/login page with
   `browser_navigate` (verify the domain — look for the official host).
4. Take a `browser_screenshot` and tell the user what to do on the page
   (approve the pairing, scan the QR from THEIR device, etc.).
5. Wait for the page to show the connected state
   (`browser_extract_text`), then report the connected ACCOUNT ADDRESS
   exactly as the page shows it. Never fabricate an address.

## Workflow: read balances / history (no approval needed)

1. On the provider's portfolio page (or a public explorer like
   etherscan.io / bscscan.com for the connected address), use
   `browser_extract_text` or `web_fetch` to read balances and recent
   transactions.
2. Summarize: asset, amount, chain, and any pending activity. Quote the
   data source (page URL) so the user can verify.

## Workflow: any asset-moving action

1. Collect and confirm the exact parameters with the user FIRST: action,
   network, asset, amount, destination address.
2. Read the pre-transaction summary from the provider's own page
   (network fee included) with `browser_extract_text`.
3. Call `request_confirmation` with a summary that names the action,
   network, asset, amount and destination. The call blocks until the user
   approves or declines in the ZAgents card.
4. On APPROVAL: complete the action strictly within the approved scope
   using the provider's page (the user's own signature/confirmation on the
   provider's UI is still required by the provider — that is by design).
   Report the real result (tx hash / error) verbatim.
5. On DECLINE or TIMEOUT: stop. Do not retry or work around it.

## Error handling

- Network errors: report them, retry at most once for read-only calls.
- "Unsupported": if the provider has no official web flow for an action,
  say exactly that and stop.
- Suspicious page (wrong domain, warnings): abort and tell the user.
