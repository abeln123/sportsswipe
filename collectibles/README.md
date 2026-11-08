# Sports Swipe Diamond editions (Solana devnet)

This is a browser-wallet hackathon prototype using Metaplex Core. It refuses a
non-devnet genesis hash. There is no mainnet configuration, cash redemption,
platform commission, promised buyer, or promised resale price.

The 31,250-coin Diamond finish remains a cosmetic. A collectible requires 400
**correct free, unstaked single predictions** on an athlete. Paid pack entries,
parlays, cosmetic purchases, and check-in coins do not count. Progress carries
across seasons. Claims are unique for an account and athlete for their lifetime.
The original earner and issuance season are preserved when ownership changes.
Claims currently accept only explicitly marked fictional demo athletes.

## Run locally

Use Node 22+, the existing Rust API and worker, and a disposable PostgreSQL DB.
Run the API once to apply migration `0006_devnet_collectibles.sql`.

```sh
cd collectibles
npm ci
npm run build
npm run issuer
```

The issuer command creates `.keys/issuer.json` with restrictive permissions.
Keep this key: it pays mint rent and derives stable asset addresses for retries.
Never commit or use a real user's key. Fund its **public** address with devnet
SOL at <https://faucet.solana.com/>. The RPC faucet may return `410 Gone`.

Configure both services with the same `DATABASE_URL`, `PUBLIC_BASE_URL`, and a
random `COLLECTIBLES_SERVICE_KEY` (at least 32 characters). Set these for the API:

```sh
COLLECTIBLES_SERVICE_URL=http://127.0.0.1:8091
COLLECTIBLES_SERVICE_KEY=<same-random-secret>
```

For the private Node service:

```sh
SOLANA_ISSUER_KEYPAIR=/absolute/path/to/collectibles/.keys/issuer.json
SOLANA_DEVNET_RPC=https://api.devnet.solana.com
PUBLIC_BASE_URL=http://localhost:8080
COLLECTIBLES_SERVICE_KEY=<same-random-secret>
DATABASE_URL=postgres://...
node src/server.mjs
```

`SOLANA_ISSUER_KEYPAIR_JSON` is an alternative secret for container deployments.
Keep the Node service private; only the Rust API should reach it. Rust injects
the authenticated user identity and internal secret. Metadata and art have a
separate public read path. Use a stable public HTTPS `PUBLIC_BASE_URL` for a
hosted demo: Explorer and wallets cannot retrieve metadata from your localhost.
This prototype serves metadata from the app; it does not upload to Arweave/IPFS.
The root Docker build bundles the wallet page; `collectibles/Dockerfile` builds
the private Node service. In Docker Compose, use service name `collectibles`.
A public deployment needs both services, the shared secret, and the issuer secret.

Collection → **Open devnet collection** opens a separate wallet page. Native
clients pass a one-use, two-minute ticket in the URL fragment; the page exchanges
it and removes it from the URL. Sessions expire after 30 minutes. Use Phantom or
Solflare on desktop (or their browser with injected wallet support). Wallet
linking proves possession using a nonce, origin, account identity, and signature.
An account is bound to its first verified demo wallet. Native Wallet Adapter and
mobile deep-link signing are not implemented.

## 90-second judging flow

1. Seed a **new fictional demo** at 399 in a disposable localhost database:
   `DATABASE_URL=... DEMO_API_URL=http://localhost:8080 node collectibles/src/demo.mjs`.
   This prints separate Maya and Jordan demo logins and the final pending market.
   The 399 historical records are explicitly synthetic; the 400th uses real grading.
2. Run the normal worker. With `ENABLE_DIAMOND_DEMO=true` on the Node service,
   the local wallet page offers **DEMO · Settle final fictional pick**. This queues
   the final result for the normal grader. The control is disabled for remote DBs
   and non-demo users/athletes. Alternatively use
   `DATABASE_URL=... python3 scripts/settle_diamond_demo.py MARKET_ID`, then
   `cargo run --manifest-path backend/Cargo.toml --bin worker -- grade-jobs`.
3. Log Maya and Jordan into separate browser profiles. Link two different devnet
   wallets. Give Jordan at least 0.101 devnet SOL, plus network fee headroom.
4. Maya claims her numbered Diamond. The issuer pays mint rent. Retrying reuses
   the same reservation, asset address and signed transaction until expiry.
5. Maya lists at **0.1 devnet SOL**. Jordan agrees to the price, then signs.
   Maya signs the same sale in her browser before the blockhash expires.
6. Refresh. Payment and Core transfer execute together. Follow the confirmed
   Explorer link. Jordan owns the collectible; Maya still has 400 qualifying calls.

Buyer is the fee payer. The seller's transfer authority and buyer's SOL authority
must both sign identical bytes. The server verifies each signature and rejects
any changed message. It saves fully signed bytes and the transaction signature
before broadcasting, so a lost response can be retried without a second sale.
Unsigned listings may be cancelled; signed transactions remain live until expiry.
An expired sale requires a fresh listing and fresh signatures from both fans.
Ownership is read from Core on devnet, never inferred from a successful HTTP call.

## Checks and limits

- `npm test --prefix collectibles`: SDK mint serialization, atomic two-instruction
  sale, two-signature requirement, changed-message rejection, exact SOL parsing.
- `test/demo-flow.mjs before|after`: local 399→400 qualifying history; buying a
  Diamond cosmetic has no effect on eligibility.
- `test/service-integration.mjs`: authenticated one-use handoff, wallet signature
  proof, replay/wallet mismatch rejection, and unearned claim rejection.
- `test/live-devnet.mjs`: opt-in live devnet mint and 0.1 SOL sale. It creates its
  own ignored test-wallet keys, funds the buyer with issuer test SOL, verifies
  the confirmed transaction and on-chain owner, and checks Maya retains mastery.
  Requires `DEMO_API_URL`, `DIAMOND_FIXTURE_FILE`, and `SOLANA_ISSUER_KEYPAIR`.

The claim key, issuer, database, and RPC are trusted prototype infrastructure.
The seller must approve each sale online; this is not a deployed escrow program.
Public RPC rate limits may interrupt the demo: use a dedicated **devnet** RPC if
needed. Dependency audit currently reports moderate upstream advisories through
`@solana/web3.js`/`jayson` (`uuid` and `stream-json`); do not enable real-value use.
Real athlete licensing, production wallet recovery, immutable metadata hosting,
mobile wallet adapters, and store-policy review are outside this devnet prototype.

## Admin presentation pack and in-app sale

An authenticated admin opens **Play → Presentation Pack**. The API creates five
fixed fictional cards once, equips the first with Diamond, and records an explicit
`admin_presentation` entitlement at 400/400. This is a disclosed demo grant, not
400 claimed real predictions. Reopening uses the same cards and does not debit
coins. Non-admins cannot open the endpoint or obtain its grant; the five demo
lines are excluded from ordinary decks and packs.

Open **Collection → the presentation Diamond → Sell presentation Diamond**.
The Flutter web page connects the browser wallet, verifies its signature, claims
one numbered edition if needed, and shows the sale timeline. The signer remains
inside Sports Swipe while Phantom/Solflare shows its wallet approval popup.

For the one-click judging flow, configure `PRESENTATION_BUYER_KEYPAIR` (or
`PRESENTATION_BUYER_KEYPAIR_JSON`) on the private Node service with a **dedicated
devnet test wallet**, funded with at least 0.101 test SOL. The endpoint requires
an admin and that admin's explicitly granted presentation edition. It prepares a
0.1 devnet SOL sale, collects the configured buyer's signature, then waits for
the presenting admin's browser-wallet signature. Ordinary sellers cannot use this
buyer. No sale is marked complete until chain confirmation and ownership checks
pass. The issuer and buyer keys are separate; neither goes into Flutter or Git.

The screen shows connection, wallet verification, claim issuance, buyer approval,
seller approval, submission, confirmation, Explorer transaction, current owner,
and retained mastery. Transactions can expire while awaiting approval; both
parties must approve a fresh transaction after expiry. A completed edition is not
reminted when the presenter opens the pack again. Rehearsal sales use their own
admin demo account so the actual presenter's edition remains unsold for judging.

`test/presentation-sale.mjs` exercises the real devnet flow with generated test
wallets. `presentation-proof.json` records the confirmed test sale. Its keys stay
in ignored `.keys/` files. Native apps can view the page, but wallet signing for
this hackathon path requires the web app with an injected Phantom/Solflare wallet.

The root app image also includes the private Node service. With
`COLLECTIBLES_ENABLED=true`, its API entrypoint starts Node on loopback port 8091.
Set the service secret and issuer/buyer key JSON secrets on that API process;
workers do not start a chain service. Existing deployments can therefore use one
image without exposing an additional public port. The service remains optional.

Presentation resets now reverse the rehearsal sale on devnet: the seller approves
refunding the test-SOL payment while the dedicated buyer signs returning the same
Core asset. Both instructions execute atomically. Original sales, collectible IDs,
metadata, edition numbers, and mastery are preserved. Confirmed resets are recorded
in `presentation_sale_resets`; the active sell screen then offers the same edition
for another sale. Reset retries reuse the pending transaction until it confirms or
expires. Both reset routes require admin access; ordinary trades cannot be reset.

`test/presentation-reset-live.mjs` exercises reset → resale → reset against the
isolated local database using the dedicated rehearsal wallets and real devnet
transactions. `reset-proof.json` records the verified Explorer receipts.
