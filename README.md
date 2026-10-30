# EulerPhi — onchain article publishing with Merkle-committed batches

Publish an article with nothing but an EIP-712 signature and a transaction.
No platform account, no backend, no indexer you have to trust: the medium is a
contract, the record is an append-only journal, and every batch of articles is
frozen as a Merkle root you can verify a proof against — on the L2 where it was
written, or notarized over CCIP to Ethereum for an audit-grade copy.

The whole product is **Solidity**: contracts, deployment, keeper loops and the
end-to-end test all run through `forge`/`cast`. There is no JS/TS/npm anywhere
(see [Why 100% Solidity](#why-100-solidity-no-jsnpm)).

> **Assessment build.** Written for the EulerPhi benchmark, aimed at the
> capability class of Paragraph/Mirror (sign → publish → read) but with the
> platform layer replaced by onchain state. **Not audited** — see
> [Known limitations](#known-limitations).

---

## Quickstart

```bash
git clone <this-repo> && cd <this-repo>
forge soldeer install        # forge-std 1.17.0 + solady 0.1.26, from soldeer.lock
forge build
forge test                   # 55 tests, 8 suites
forge snapshot               # regenerates .gas-snapshot
bash script/e2e-anvil.sh     # live end-to-end on anvil: submit → anchor → notarize
```

Dependencies are **Soldeer-managed only** (no git submodules, no npm):

| Dependency | Version | Why |
|---|---|---|
| [Solady](https://github.com/Vectorized/solady) | `v0.1.26` (git tag) | `EIP712`, `ECDSA`, `MerkleTreeLib`, `MerkleProofLib` — audited-by-adoption, gas-first, no external deps |
| [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) `contracts-upgradeable` | `v5.7.0` (git tag) | `UUPSUpgradeable` (proxy utils) — the import prefix for upgradeable components; note its `UUPSUpgradeable.sol` is a 5-line forwarder into the plain package |
| [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) | `v5.7.0` (git tag) | the real `UUPSUpgradeable` + `ERC1967Proxy` (deploy path), and the transitive target of the forwarder above |
| forge-std | `v1.17.0` (git tag) | tests + scripts |
| Chainlink CCIP interfaces | vendored subset of `smartcontractkit/ccip @ 171f9f0` | only `Client`, `IRouterClient`, `IAny2EVMMessageReceiver` — re-verify against upstream before a real lane |

---

## Architecture

```
                     Ethereum (L1)                                Base (L2)
┌───────────────────────────────────────────┐   ┌─────────────────────────────────────────────┐
│  SubmissionGateway  (plain, immutable)    │   │  ArticleAnchor  (UUPS proxy)               │
│                                           │   │                                             │
│  submitArticle(leaf, sig, payload)        │   │  submitArticle(leaf, sig, payload)          │
│    payable · digest check only            │   │    public · EIP-712 authorship check        │
│         │                                 │   │         │                                   │
│         └──────── CCIP ───────────────────┼──▶│  consumeSubmittedArticle  (pinned source)   │
│                                           │   │         │                                   │
│  receiveRoot(batchIndex, root)  ◀─────────┼───┼── notarize(i)  (payable, K = 64 blocks)     │
│    router-gated · strictly monotonic      │   │         │                                   │
│                                           │   │  journal[] ── anchorNextBatch() ── rootAt[] │
└───────────────────────────────────────────┘   └─────────────────────────────────────────────┘
                                                                        │
                                       readers: verifyAgainstBatch(i, leaf, proof) → bool
                                       keepers: script/Anchor.s.sol · script/Notarize.s.sol
```

**One contract owns every security-relevant decision** (`ArticleAnchor`): digest
and signature verification, the journal, root construction, batch policy and
the K-confirmation gate. The L1 `SubmissionGateway` deliberately does *no*
`ecrecover` (design decision 1a): EIP-712 domains are chain-bound, so the hub
is the single signature authority, and one authority is easier to reason about
than two. The gateway quotes the CCIP fee, forwards bytes unchanged and
records notarized roots in order.

### Lifecycle of one article

1. **Author signs** the 7-field `ArticleSubmission` struct against the hub's
   EIP-712 domain `("EulerPhiArticle", "1")` — readable typed data, bound to
   `(chainId, verifyingContract)`.
2. **Anyone submits it.** The caller pays gas; third-party relaying is normal
   operation, not a special path. Checks in order: `deadline` → leaf/payload
   digest → 65-byte canonical low-s signature → recovered signer == `author`
   -> per-author 1h rate limit -> unused `(author, uuid)`.
3. **Leaf is journaled**: `journal.push(keccak256(abi.encode(payload)))`.
   Content stays off-chain; only the commitment travels.
4. **Anyone closes the batch**: `anchorNextBatch()` when ≥ `MIN_BATCH(10)`
   leaves are pending or `BATCH_DEADLINE(6h)` has elapsed, capped at
   `MAX_BATCH(200)`. The root is computed **inside** the contract from the
   journal — the function takes no root argument, so a malicious root cannot
   exist. The range `[start, end)` freezes forever.
5. **Anyone notarizes upward** once `block.number ≥ anchoredAtBlock + K(64)`:
   `notarize(i)` sends `(batchIndex, root)` to the L1 gateway over CCIP, funded
   by the caller.
6. **Readers verify**: `verifyAgainstBatch(i, leaf, proof)` against the frozen
   root — or against the L1 copy's `notarizedRoot(i)` for a belt-and-braces
   audit trail.

### Lanes and fees: **no fees — you pay gas, and gas is cents**

There is **no protocol fee, no token, no subscription, no take rate.** The
protocol never charges; you pay the network for the transaction you send.

| Lane | Chain | What you pay | When to use |
|---|---|---|---|
| **Direct** (cheap) | Base (L2) | one L2 tx — a few cents, often less | default: writers, relayers, keepers |
| **Paid entry** (one hop) | Ethereum (L1) | L1 gas + the CCIP fee quoted by `getFee`, excess refunded | you are on L1 and want one transaction to land it on the hub |

Because the gateway checks only chain-agnostic state (digest + deadline) and
**no signature** (decision 1a), a payload the hub will later reject — rate
limited, duplicate uuid — still passes L1 and **burns the CCIP fee** on the
hub-side revert. Check `lastSubmit[author] + RATE_LIMIT` and
`usedUuid[author][uuid]` off-chain before paying for the L1 lane; the direct
L2 lane has no such downside (the revert only costs your own gas).

`SubmissionGateway.submitArticle` is `payable` for exactly one reason: on L1 a
transaction must also buy the cross-chain message. The fee is **Chainlink's,
not ours** — the gateway forwards `fee` to the router, refunds any excess to
the caller, and retains nothing (`address(gw).balance == 0` is asserted).

There is also **no protocol income at all**, which has a consequence worth
saying out loud: keepers are unpaid — see
[Unpaid-keeper liveness](#unpaid-keeper-liveness).

---

## Trust ladder: hub ≥ notary ≥ mirror

Trust decreases as you go down this ladder; each level inherits correctness
from the one above and adds an assumption.

**1. Hub (L2 canonical record) — strongest.**
You trust: this code, the author's key (for their own bylines), the admin key
(upgrade path), and Chainlink only for the cross-chain legs. Roots are derived
by the contract from the journal, so a compromised *keeper* gains nothing — it
can withhold a call (delay), never lie about content.

**2. Notary (L1 root record) — middle.**
`SubmissionGateway.notarizedRoot(i)` inherits the hub's correctness **plus**
CCIP delivery **plus** `K = 64` confirmations and a strictly monotonic cursor.
It can lag or stall; forging it requires compromising CCIP *and* reorganizing
64 L2 blocks — and even then the L2 hub still holds the original, so the two
copies are cross-checkable rather than one being authoritative.

**3. Mirror (any republication / reader) — weakest.**
Anyone can re-host articles and hand out proofs. A mirror can *omit* you
(censorship) and can *lie about which root is canonical*, but it cannot forge
an inclusion proof for a leaf that was never in a batch: `verifyAgainstBatch`
against a root you pinned yourself (from `RootAnchored` on the hub, or
`notarizedRoot` on L1) makes a lying mirror detectable. **Pin the root, then
the proof is self-sufficient.**

---

## Cost table

Measured by `test/Gas.t.sol` as a `gasleft()` delta around a single call,
taken from a **cold access list** (`vm.cool` first) — the state a real,
separate transaction starts from, not the warm state a test fixture leaves
behind — with the mock router's forensics disabled so the number is *our*
contract's work, not the test double's. Every hub call goes **through the
ERC-1967 proxy** (delegatecall): since the bare implementation is
constructor-locked, that is the only deployable shape — so these are
production-shaped numbers, not direct-call ones.

| Operation | Who pays | Gas (marginal) | Notes |
|---|---|---:|---|
| `submitArticle` — first leaf (cold slots) | relayer / writer | **130,075** | opens the batch window |
| `submitArticle` — steady state | relayer / writer | **88,062** | 1h per-author rate limit applies |
| `anchorNextBatch` — 10 leaves (`MIN_BATCH`) | keeper | **126,472** | ≈98k fixed window/tree overhead |
| `anchorNextBatch` — 200 leaves (`MAX_BATCH`) | keeper | **675,342** | ≈**2.9k gas per leaf** (2.1k of it the cold journal read) |
| `verifyAgainstBatch` — 10-leaf root | reader | **14,995** | an `eth_call` costs you nothing |
| `notarize` — our side (K-gated) | keeper | **38,598** | + CCIP fee + the router's own execution |
| gateway `submitArticle` — our side | writer | **37,148** | + L1 gas + CCIP fee (router's execution on top) |

Contract sizes: `ArticleAnchor` 13,298 B runtime, `SubmissionGateway` 5,622 B
(limits: 24,576 B).

**Turning gas into money.** L2 execution cost ≈ gas × gas price, plus the
rollup's L1 data component. At 88,062 gas: 0.01 gwei ≈ 0.88 µETH, 0.1 gwei ≈
8.8 µETH — i.e. **fractions of a cent to a few cents per article** at an ETH
price of $3k, before the (small, calldata-based) rollup data fee. Numbers are
examples, not promises: prices move, and the two CCIP rows above are *our*
side only — the router's execution and Chainlink's message fee are extra and
must be calibrated on a real testnet.

The two rows worth internalizing: **verification is ~15k gas** (free for
readers — it is a view call) and **anchoring scales gently** (~2.9k/leaf, of
which ~2.1k is one cold journal read), which is what makes a Merkle journal
affordable where per-article onchain storage would not be.

---

## Attack matrix ↔ tests

55 tests in 8 suites. `forge test` is the gate; `.gas-snapshot` pins costs.

| # | Threat | Defense | Test(s) |
|---|---|---|---|
| 1 | Publish under someone else's name | digest re-derived from payload, then EIP-712 recovery must equal `payload.author` | `Submit.t.sol::test_forgedByAuthorSigReverts`, `ArticleLib.t.sol::test_forgedByAuthorSigReverts` |
| 2 | Tamper payload after signing | `keccak256(abi.encode(payload)) == leaf` | `Submit.t.sol::test_digestMismatchReverts`, `Gateway.t.sol::test_gatewayDigestMismatchReverts` |
| 3 | Signature malleability (high-`s` twin of a valid sig) | explicit low-`s` gate — Solady's `recover` deliberately does **not** check | `Submit.t.sol::test_lowSEnforced` |
| 4 | Reuse one signed payload | `usedUuid` keyed by `(author, uuid)` | `Submit.t.sol::test_duplicateUuidReverts` |
| 4b | **Squat a victim's predictable uuid** with your own payload to block their article | dedup is author-scoped, so a foreign author's uuid never collides | `Submit.t.sol::test_uuidSquatDoesNotBlockVictim`, `test_sameAuthorSameUuidStillDeduped` |
| 5 | Reuse it across lanes (direct **and** gateway-CCIP) | same `uuid` check sees both lanes | `CCIP.t.sol::test_replayAcrossLanesReverts` |
| 6 | Replay on another hub instance or another chain | EIP-712 domain `(chainId, verifyingContract)` | `Submit.t.sol::test_payloadSignedForAnotherDomainReverts` |
| 7 | Bypass the router to inject into `consumeSubmittedArticle` | `msg.sender == router` | `CCIP.t.sol::test_directConsumeRejected` |
| 8 | Message from a foreign chain | `sourceChainSelector` pin | `CCIP.t.sol::test_wrongChainSelectorReverts` |
| 9 | Message from a foreign sender on the right chain | `sender == gateway` pin | `CCIP.t.sol::test_wrongSenderReverts` |
| 10 | Notarize a root that could still reorg | `block.number ≥ anchoredAtBlock + K(64)` | `CCIP.t.sol::test_notarizeRevertsBeforeK`, `CCIP.t.sol::test_notarizeUnanchoredBatchReverts` |
| 11 | Push an arbitrary root into the hub | `anchorNextBatch()` takes **no root argument** — root is computed from the journal | `Batch.t.sol::test_permissionlessAnchor`, `Batch.t.sol::test_rangeFreezeAfterAppend` (root re-derived from journal, byte-identical) |
| 12 | Alter an anchored root by appending later | range freeze on `[start, end)` | `Batch.t.sol::test_rangeFreezeAfterAppend` *(Review Focus 5)* |
| 13 | Grief batches (early/late/empty closes) | `MIN_BATCH`/`MAX_BATCH`/`BATCH_DEADLINE`/`pending > 0` | `Batch.t.sol::test_anchorRequiresMinOrDeadline`, `Batch.t.sol::test_anchorAtMaxBatch`, `Batch.t.sol::test_emptyAnchorReverts` |
| 14 | Forge, skip or reorder L1 notarized roots | router gate + `batchIndex == nextBatch` | `Gateway.t.sol::test_receiveRootMonotonicPrevRoot`, `Gateway.t.sol::test_receiveRootDirectCallReverts`, `Gateway.t.sol::test_receiveRootWrongSourceReverts` |
| 14b | Deliver bytes the hub never produced (wrong length / wrong function selector) so the decoder reinterprets them as `(batchIndex, root)` | payload is `abi.encodeCall(receiveRoot, …)`; length **and** selector checked before decoding — proven by a hub-encode → gateway-decode round trip | `Gateway.t.sol::test_notarizeRoundTripIntoGateway`, `test_receiveRootRejectsWrongWireFormat` |
| 15 | Prove a leaf that isn't in the batch (or is from another batch) | `MerkleProofLib` against the frozen root | `Batch.t.sol::test_verifyAgainstBatchFalse`, `Batch.t.sol::test_verifyAgainstBatchTrue` |
| 16 | Merkle builder/verifier disagree (implementation bug) | differential vs hand-written `NaiveMerkle` + fuzz | `MerkleDifferential.t.sol::test_matchesNaiveReference` (256 runs), `test_oddLeafCounts`, `test_singleLeafRoot` |
| 17 | Upgrade by anyone, or a second upgrade authority hiding beside the UUPS path | `_authorizeUpgrade` admin-only; the OZ `ERC1967Proxy` has **no admin entry at all** (ERC-1967 admin slot stays `0`); OZ `onlyProxy` blocks any attempt on the bare implementation | `Upgrade.t.sol::test_nonAdminUpgradeReverts`, `test_proxyHasNoAdminSlot`, `test_bareImplementationUpgradeReverts` |
| 18 | Re-initialize (proxy *or* bare implementation), hijack gateway wiring, corrupt storage on upgrade | OZ `initializer` lock (bare impl `_disableInitializers()`-locked at construction) + zero-admin rejection, `setGateway` admin-only, append-only layout | `Upgrade.t.sol::test_initializeTwiceReverts`, `test_bareImplementationCannotBeInitialized`, `test_initializeRejectsZeroAdmin`, `test_setGatewayOnlyAdmin`, `test_journalPreservedAcrossUpgrade` |
| 19 | Spam one author's journal | `RATE_LIMIT = 1h` | `Submit.t.sol::test_rateLimit1hReverts` |
| 20 | Submit an expired article | `block.timestamp ≤ deadline`, checked first on both lanes | `Submit.t.sol::test_expiredDeadlineReverts` |
| 21 | Run off with / overcharge the gateway fee | `getFee` quote, `msg.value ≥ fee`, refund excess, gateway retains 0 | `Gateway.t.sol::test_insufficientFeeReverts`, `test_excessRefunded` |
| 22 | Bytes garbled between gateway and hub | byte-identical encode/decode round trip | `Gateway.t.sol::test_gatewayForwardsByteIdenticalCalldata`, `test_gatewayPayloadLandsInHub` |
| 23 | Silent cost regression | smoke bounds on every marginal measurement | `Gas.t.sol::test_gasSubmit` / `test_gasAnchor` / `test_gasVerify` / `test_gasNotarize` / `test_gasGatewaySubmit` |

Struct-hash pinning (`ArticleLib.t.sol::test_hashStructIsPinned`) uses vectors
computed with `cast` — an *independent tool*, not the contract's own code — so
an accidental typehash or field-order change cannot pass review quietly.

**Review Focus items** (the five questions the spec singled out) map to:
forged authorship → #1; cross-lane replay → #5; non-whitelisted CCIP source →
#7/#8/#9; notary reorg exposure → #10; post-anchor append → #12.

### End-to-end (live node, not mocks)

`script/e2e-anvil.sh` boots anvil, deploys `MockRouter` → `ArticleAnchor`
(UUPS), signs and submits a real EIP-712 article, warps past the batch
deadline, anchors, mines past `K`, notarizes, and asserts the fee and
destination the router received. It is the acceptance check for the keeper
scripts (`Anchor.s.sol`, `Notarize.s.sol`) — they are permissionless and
assume nothing the contract does not enforce.

---

## Why 100% Solidity (no JS/TS/npm)

An article platform's tempting split is "chain for writes, server for
everything else" — and that server quietly becomes the product. Going
all-in on Solidity is a deliberate constraint with three payoffs:

1. **The only trusted logic is EVM logic.** Signing, validation, batching,
   verification and deployment are one compiler invocation away from a
   reproducible `forge test`. Nothing in the trust model depends on a runtime
   I cannot review in this repository.
2. **The differential test gets better, not worse.** The one place hand-rolled
   code would be scarcest — the Merkle tree — is checked by
   `test/MerkleDifferential.t.sol`, which pits Solady's optimized assembly
   `MerkleTreeLib` against `test/lib/NaiveMerkle.sol`, an independent,
   assembly-free reimplementation of the exact heap layout (leaf `k` sits at
   `2L-2-k`; node `i` is the pair-sorted hash of children `2i+1`/`2i+2`, so a
   leftover leaf ends up paired with an *internal* node instead of being
   promoted a level), across fuzzed leaf counts up to `MAX_BATCH`, odd counts
   and single leaves. A JS harness could also
   cross-check roots — but it would run *outside* the EVM, catching encoding
   mistakes rather than semantic ones, and would drag an npm tree into a repo
   whose whole point is that it has none.
3. **End-to-end without a frontend.** `forge script` signs with the same
   EIP-712 math the tests use (`E2ESubmit.s.sol` reads the hub's EIP-5267
   domain and derives the digest in Solidity), and `cast` does the
   assertions. The e2e is a test, not a demo.

**What this costs, honestly:** no UI (a wallet must craft the typed data or
call the contract), no indexer, no IPFS pinning automation. Those are product
gaps, not technical ones — and adding them later cannot weaken the onchain
guarantees, because they are not in the trust model.

**Disclosed residual.** Solady's `build` lays nodes out as a heap, which is
*not* the textbook level-wise tree (they diverge at 5 leaves) — so
`NaiveMerkle` implements Solady's layout rather than its own convention.
Honest residual: the differential therefore checks that Solady's **assembly**
computes the documented **layout** correctly, it does not independently re-
derive the layout choice. It also means any proof generator must use the same
convention: a textbook level-wise builder produces a different root for the
same leaves. Both facts are why the differential exists in the first place —
and why `NaiveMerkle` stays assembly-free and separately written.

---

## Design decisions and alternatives considered

**Mapping vs Merkle journal.** `mapping(bytes32 => bool) published` would be
the cheapest possible "is this article known" (one SSTORE, O(1)), but it buys
nothing anyone else can use: no inclusion proof for readers, no composable
batch root, no notarizable artifact for L1. The Merkle route costs a fixed
≈98k per batch plus ≈2.9k per leaf — call it **~3k gas per article to make
every article provable to a third party** (the batch's fixed overhead is paid
once, amortized over up to 200 articles) — and returns proofs that survive
mirrors, cross-chain copies and independent re-hosting. For a *publishing*
product the proof is the point, so the journal wins. The rate limit, `uuid`
dedup and batch window live in mappings precisely because those are
*bookkeeping*, not *claims*.

**Roles / allowlist publishing — deliberately not implemented.** The spec
scoped role-based publishing to a comment + README extension point. The code
carries the comment (`ArticleAnchor`, contract-level docstring): gate
`_submit` on an `isAuthor[author]` registry and you have a curated magazine;
leave it open and you have Paragraph/Mirror-class permissionless publishing.
That is a product decision, not a security one, so v1 ships open. A future
roles gate would *narrow* the accepted set — it cannot invalidate anything
already journaled.

**Meta-transactions / sponsored gas — future.** Third-party relaying already
works (`test_thirdPartySubmitWithAuthorSigPasses`): authorship comes from the
signature, never from `msg.sender`. A forwarder would only spare the relayer's
gas plumbing; ERC-2771-style forwarders would additionally require trusting
`msg.sender` to be *rewritten* — which this design has no use for, since
nothing critical reads it. When a sponsorship UX is needed, add a forwarder as
a *relay*, not as an authority.

**ZK — deferred privacy, not part of v1.** Content is already hidden behind
`bodyHash` commitments; what a ZK layer would add is hiding *metadata* (author,
title) while still proving a valid signature — i.e. anonymous publishing. That
costs the author proof generation plus verification gas, and v1's value
proposition is attribution and auditability. **No ZK is demonstrated here on
purpose:** a demonstration that makes every article more expensive to publish
would be theatre. It remains the obvious v2 privacy layer, and the leaf format
would not change to accommodate it.

**Inline events counterfactual (why not just emit the article?).** Emitting
full bodies as logs would be cheaper per byte than storage and trivially
indexable — but logs are not state: no other contract can read them, so an
onchain verifier, a payment gate or a cross-chain mirror would still have to
trust the indexer that replayed them. Logs also have no natural "commit once,
prove forever" shape (no root, no batch, no proof), they are unbounded cost
with no dedup/rate discipline, and they live only in the execution client's
history. Journaling 32-byte commitments onchain plus content offchain keeps
the *integrity* onchain and the *bytes* cheap — and any indexer can still be
caught lying, because the journal settles what it may claim.

---

## Security notes

### UUPS trust note and renounce plan

The admin key is the trust floor of the hub: it can upgrade the implementation
and therefore control the journal. Mitigations in place, all tested:

- **Single upgrade path**: the hub sits behind OpenZeppelin's `ERC1967Proxy`,
  which has **no admin/authority entry of its own** — the ERC-1967 admin slot
  is `0` and stays there (`test_proxyHasNoAdminSlot`), so there is no factory
  key, guardian or fallback route to disable. `upgradeToAndCall` gated by
  `_authorizeUpgrade` (admin-only, `test_nonAdminUpgradeReverts`) is the only
  way up, and OZ's `onlyProxy` kills any attempt made against the bare
  implementation (`test_bareImplementationUpgradeReverts`).
- **No half-deployed hub can exist**: OZ's proxy refuses construction with
  empty init data (`ERC1967ProxyUninitialized`) and a botched
  `initialize(admin_ = 0)` bubbles out of the constructor
  (`test_zeroAdminProxyCannotBeConstructed`) — a failed deploy leaves nothing
  on chain to strand users.
- **`initialize` runs exactly once**, via OpenZeppelin's `initializer`
  modifier. The constructor writes **no variable at all** — OZ's documented
  best practice for proxied contracts: its only job is to call
  `_disableInitializers()`, which locks the bare implementation forever so no
  stranger can ever own it (`test_bareImplementationCannotBeInitialized`;
  a second call on the proxy reverts `InvalidInitialization()` —
  `test_initializeTwiceReverts`). The body still rejects `admin_ = address(0)`
  (`test_initializeRejectsZeroAdmin`). **Storage survives upgrades**
  (`test_journalPreservedAcrossUpgrade`).
- **`admin` is written exactly once** — by `initialize`, on the proxy (the
  constructor writes no configuration) — and has **no transfer function**. It cannot be rotated after deployment. That is
  a deliberate trade: no transfer means no transfer-hijack, and the price is
  that you must **deploy with a multisig/timelock as `HUB_ADMIN` from day one**;
  there is no later correction.
- **Renounce plan**: OpenZeppelin's `UUPSUpgradeable` exposes no renounce
  function either (only `upgradeToAndCall`, `proxiableUUID`,
  `_authorizeUpgrade`, plus the read-only `UPGRADE_INTERFACE_VERSION`), so
  renouncing means **one final upgrade to an implementation whose
  `_authorizeUpgrade` unconditionally reverts**, then discarding the admin
  key. It must **not** be done by zeroing `admin`: initialization is gated by
  OpenZeppelin's `Initializable` version slot (not by the admin value), so
  zeroing admin would *not* re-open `initialize` — it would instead
  permanently brick
  `setGateway` and every `admin only` path. Nothing can write `admin` after
  init today (it is set exactly once by `initialize`), so zeroing it is not an
  open hole but it is a wrong renounce mechanism: upgrade to a locked
  implementation first, then discard the key.

### Chain selectors are sourced, never guessed

Both directions pin a Chainlink **chain selector** (`HUB_ETH_CHAIN_SELECTOR`,
`GW_BASE_CHAIN_SELECTOR`), injected at deploy time and never hardcoded in
source. Get them from Chainlink's official CCIP directory for the exact lane
you deploy (docs.chain.link → CCIP → directory), not from memory or a
third-party list. A wrong selector fails **closed**: the lane simply never
delivers. Selectors are *not* chain ids — they are Chainlink's own namespace.

### Signatures

65-byte `(r, s, v)` canonical form only; **low-`s` is enforced by us** because
Solady's `ECDSA.recover` intentionally accepts malleable `s` (its own header
warns about this). The digest is `keccak256(abi.encode(payload))` *and* the
EIP-712 typed digest — both are checked, so a payload cannot be reinterpreted.

### Unpaid-keeper liveness

`anchorNextBatch` and `notarize` are permissionless but **incentive-free**, and
the protocol has no treasury to pay from (that is what "no fees" means).
Consequence: if nobody runs the keepers, writes are unaffected — articles keep
journaling — but batches do not freeze and the L1 record lags. The scripts are
one command each and cost ≈124k gas (anchor) and ≈36k gas + one CCIP fee
(notarize); any author, reader or competitor can run them, which is the point
of permissionlessness. What it does not buy is *guaranteed* cadence. A future
bounty or an operator cron is the honest fix; the current design optimizes for
"nobody can be corrupted by a role that doesn't exist" over "fixed schedule".

### CCIP assumptions

Chainlink CCIP is trusted for liveness of both lanes and, for the notary
record, for authenticity. Message fees are Chainlink's; the receiver gas limits
(`NOTARY_GAS_LIMIT = 200k`, `SUBMIT_GAS_LIMIT = 400k`) are set to the upstream
default and generous headroom respectively, and must be calibrated on a real
testnet before a real lane. The vendored interfaces are a **minimal subset**, taken from
`smartcontractkit/ccip` at commit `171f9f0` (the `ccip-develop` head at
vendoring time; struct layouts and signatures re-checked against that
commit) — re-verify them against current upstream when you deploy.

---

## IPFS caveat

`cidHash` commits to the content's address and `bodyHash` to its bytes, so
**integrity and existence at publish time are onchain-provable**. Availability
is not, and cannot be: IPFS content that nobody pins can be garbage-collected
and vanish. The chain guarantees *what was published*, never *that the bytes
are still online*. Practical stance: pin redundantly (author + a pinning
service + readers who care), and remember that content addressing works in
your favour — if you have the bytes from anywhere, `keccak256` matching the
journal (via the batch proof) is enough to trust them. This project makes no
IPFS node calls from Solidity; it is commitments only.

---

## Deployment

```bash
# 1. Hub (Base) — OZ ERC1967 proxy (no admin entry at all); admin = your multisig/timelock
HUB_ADMIN=<multisig> \
HUB_ROUTER=<chainlink router on Base> \
HUB_ETH_CHAIN_SELECTOR=<Chainlink selector for the Base→Ethereum lane> \
  forge script script/DeployHub.s.sol --rpc-url $BASE_RPC --broadcast

# 2. Gateway (Ethereum) — plain, immutable
GW_ROUTER=<chainlink router on Ethereum> \
GW_HUB=<hub proxy address> \
GW_BASE_CHAIN_SELECTOR=<Chainlink selector for the Ethereum→Base lane> \
  forge script script/DeployGateway.s.sol --rpc-url $ETH_RPC --broadcast

# 3. Wire them (admin only)
cast send $HUB "setGateway(address)" $GATEWAY --private-key $ADMIN_KEY --rpc-url $BASE_RPC

# Keepers (permissionless — anyone can run)
HUB_ADDRESS=$HUB forge script script/Anchor.s.sol    --rpc-url $BASE_RPC --broadcast
HUB_ADDRESS=$HUB NOTARY_BATCH_START=0 NOTARY_FEE_WEI=<exact getFee quote> \
  forge script script/Notarize.s.sol --rpc-url $BASE_RPC --broadcast
```

Send the **exact** fee quote to `notarize` — the upstream router keeps any
overpayment (the gateway refunds excess on its own lane; the hub does not
need to).

---

## Repository layout

```
src/
  ArticleAnchor.sol        hub: submit, journal, batching, roots, CCIP both ways, UUPS
  SubmissionGateway.sol    L1: payable entry lane (no ecrecover) + monotonic notary receiver
  ArticleLib.sol           EIP-712 struct + typehash
  interfaces/
    IArticleAnchor.sol     hub's full public ABI (functions, getters, constants,
                           events) + all 15 custom errors + every API NatSpec —
                           ArticleAnchor inherits it, so the compiler keeps docs
                           and ABI in lockstep. Every failure is a typed error
                           declared here, never a revert string
    ISubmissionGateway.sol same for SubmissionGateway (10 typed errors; it also
                           fixes the 68-byte `receiveRoot` wire format the hub
                           encodes against)
    Client.sol, IRouterClient.sol, IAny2EVMMessageReceiver.sol
                           vendored CCIP subset @ commit 171f9f0
script/
  DeployHub.s.sol DeployGateway.s.sol     deployment (single upgrade path)
  Anchor.s.sol Notarize.s.sol             permissionless keeper loops
  E2ESubmit.s.sol                         signs + submits against the live domain
  e2e-anvil.sh                            live end-to-end driver
test/
  ArticleLib.t.sol Submit.t.sol Batch.t.sol MerkleDifferential.t.sol
  CCIP.t.sol Gateway.t.sol Upgrade.t.sol Gas.t.sol
  lib/NaiveMerkle.sol   independent reference Merkle (differential)
  mocks/                MockRouter, ArticleAnchorV2Stub
.gas-snapshot            forge snapshot output (regenerate with `forge snapshot`)
soldeer.lock             dependency pins (solady v0.1.26, forge-std v1.17.0)
```

## Known limitations

- **Not audited.** Treat as assessment code until a review says otherwise.
- **Admin key is irrecoverable if lost, un-rotatable if stolen** — deploy with
  a multisig, plan the renounce upgrade (see above).
- **No keeper incentive** → no guaranteed batch/notarization cadence.
- **No frontend, no indexer, no IPFS pinning** — by the 100%-Solidity rule.
- **No roles, no fees, no ZK** in v1 — extension points documented above.
- **CCIP fees, receiver gas limits and chain selectors must be re-verified**
  against live Chainlink documentation at deployment time.
- **Rate limit / batch constants are policy, not security**: `MIN_BATCH=10`,
  `MAX_BATCH=200`, `BATCH_DEADLINE=6h`, `RATE_LIMIT=1h`, `K=64` are chosen for
  a quiet chain and are trivially re-tuned before launch.

## License

MIT
