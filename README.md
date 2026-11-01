# EulerPhi — onchain article publishing with Merkle-committed batches

Publish an article with nothing but an EIP-712 signature and a transaction.
No platform account, no backend, no indexer you have to trust: the medium is a
contract, the record is an append-only journal, and every batch of articles is
frozen as a Merkle root you can verify a proof against on the L2 where it was
written.

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
forge test                   # 66 tests, 8 suites
forge snapshot               # regenerates .gas-snapshot
bash script/e2e-anvil.sh     # live end-to-end on anvil: submit → anchor
```

Dependencies are **Soldeer-managed only** (no git submodules, no npm):

| Dependency | Version | Why |
|---|---|---|
| [Solady](https://github.com/Vectorized/solady) | `v0.1.26` (git tag) | `EIP712`, `ECDSA`, `MerkleTreeLib`, `MerkleProofLib` — audited-by-adoption, gas-first, no external deps |
| [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) `contracts-upgradeable` | `v5.7.0` (git tag) | `UUPSUpgradeable` (proxy utils) — the import prefix for upgradeable components; note its `UUPSUpgradeable.sol` is a 5-line forwarder into the plain package |
| [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) | `v5.7.0` (git tag) | the real `UUPSUpgradeable` + `ERC1967Proxy` (deploy path), and the transitive target of the forwarder above |
| forge-std | `v1.17.0` (git tag) | tests + scripts |
| Solidity compiler | floor `^0.8.27` (compiled with `0.8.33`) | `require(condition, CustomError())` only joined the **legacy** pipeline in `0.8.27` — in `0.8.26` it existed for via-IR only, so `^0.8.26` would not compile this code |
| Chainlink CCIP interfaces | vendored subset of `smartcontractkit/ccip @ 171f9f0` | only `Client`, `IRouterClient`, `IAny2EVMMessageReceiver` — re-verify against upstream before a real lane |

---

## Architecture

```
                     Ethereum (L1)                                Base (L2)
┌───────────────────────────────────────────┐   ┌─────────────────────────────────────────────┐
│  SubmissionGateway  (UUPS proxy)          │   │  ArticleAnchor  (UUPS proxy)                │
│                                           │   │                                             │
│  submitArticle(leaf, sig, payload)        │   │  submitArticle(leaf, sig, payload)          │
│    payable · digest check only            │   │    public · EIP-712 authorship check        │
│         │                                 │   │         │                                   │
│         └──────── CCIP ───────────────────┼──▶│  ccipReceive  (pinned inbound lane)         │
│                                           │   │         │                                   │
│                                           │   │  journal[] ── anchorNextBatch() ── rootAt[] │
└───────────────────────────────────────────┘   └─────────────────────────────────────────────┘
                                                                        │
                                       readers: verifyAgainstBatch(i, leaf, proof) → bool
                                       keepers: script/Anchor.s.sol
```

**One contract owns every security-relevant decision** (`ArticleAnchor`): digest
and signature verification, the journal, root construction and batch policy.
The `SubmissionGateway` deliberately does *no*
`ecrecover` (design decision 1a): EIP-712 domains are chain-bound, so the hub
is the single signature authority, and one authority is easier to reason about
than two. The gateway quotes the CCIP fee and forwards bytes unchanged.

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
5. **Readers verify**: `verifyAgainstBatch(i, leaf, proof)` against the frozen
   root — the contract derived it from the journal, so the proof checks against
   the canonical record itself.

### Lanes and fees: **no fees — you pay gas, and gas is cents**

There is **no protocol fee, no token, no subscription, no take rate.** The
protocol never charges; you pay the network for the transaction you send.

| Lane | Chain | What you pay | When to use |
|---|---|---|---|
| **Direct** (cheap) | Base (L2) | one L2 tx — a few cents, often less | default: writers, relayers, keepers |
| **Paid entry** (one hop) | any source chain (e.g. Ethereum) | source-chain gas + the CCIP fee quoted by `getFee`, excess refunded | you're on a source chain and want one transaction to land it on the hub |

Because the gateway checks only chain-agnostic state (digest + deadline) and
**no signature** (decision 1a), a payload the hub will later reject — rate
limited, duplicate uuid — still passes the gateway and **burns the CCIP fee** on the
hub-side revert. Check `lastSubmit[author] + RATE_LIMIT` and
`usedUuid[author][uuid]` off-chain before paying for the paid lane; the direct
L2 lane has no such downside (the revert only costs your own gas).

`SubmissionGateway.submitArticle` is `payable` for exactly one reason: on the gateway's chain a
transaction must also buy the cross-chain message. The fee is **Chainlink's,
not ours** — the gateway forwards `fee` to the router, refunds any excess to
the caller, and retains nothing (`address(gw).balance == 0` is asserted).

There is also **no protocol income at all**, which has a consequence worth
saying out loud: keepers are unpaid — see
[Unpaid-keeper liveness](#unpaid-keeper-liveness).

---

## Trust ladder: hub ≥ mirror

Trust decreases as you go down this ladder; each level inherits correctness
from the one above and adds an assumption.

**1. Hub (L2 canonical record) — strongest.**
You trust: this code, the author's key (for their own bylines), the OZ
`owner` keys — the hub's owner on L2 (owns the journal) and one `GW_OWNER` per
source-chain gateway (each owns its paid lane only: a compromised gateway
owner reroutes messages and fees, never the journal), each rotatable by
two-step transfer — and Chainlink
only for the cross-chain legs. Roots are derived
by the contract from the journal, so a compromised *keeper* gains nothing — it
can withhold a call (delay), never lie about content.

**2. Mirror (any republication / reader) — weakest.**
Anyone can re-host articles and hand out proofs. A mirror can *omit* you
(censorship) and can *lie about which root is canonical*, but it cannot forge
an inclusion proof for a leaf that was never in a batch: `verifyAgainstBatch`
against a root you pinned yourself (from `RootAnchored` on the hub) makes a
lying mirror detectable. **Pin the root, then
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
| `submitArticle` — first leaf (cold slots) | relayer / writer | **129,415** | opens the batch window |
| `submitArticle` — steady state | relayer / writer | **87,396** | 1h per-author rate limit applies |
| `anchorNextBatch` — 10 leaves (`MIN_BATCH`) | keeper | **104,493** | ≈75k fixed window/tree overhead |
| `anchorNextBatch` — 200 leaves (`MAX_BATCH`) | keeper | **654,503** | ≈**2.9k gas per leaf** (2.1k of it the cold journal read) |
| `verifyAgainstBatch` — 10-leaf root | reader | **15,042** | an `eth_call` costs you nothing |
| gateway `submitArticle` — our side | writer | **46,531** | + source-chain gas + CCIP fee (router's execution on top) |

Contract sizes: `ArticleAnchor` 12,493 B runtime, `SubmissionGateway` 8,284 B
(limits: 24,576 B).

**Turning gas into money.** L2 execution cost ≈ gas × gas price, plus the
rollup's L1 data component. At 87,396 gas: 0.01 gwei ≈ 0.87 µETH, 0.1 gwei ≈
8.7 µETH — i.e. **fractions of a cent to a few cents per article** at an ETH
price of $3k, before the (small, calldata-based) rollup data fee. Numbers are
examples, not promises: prices move, and the CCIP row above is *our*
side only — the router's execution and Chainlink's message fee are extra and
must be calibrated on a real testnet.

The two rows worth internalizing: **verification is ~15k gas** (free for
readers — it is a view call) and **anchoring scales gently** (~2.9k/leaf, of
which ~2.1k is one cold journal read), which is what makes a Merkle journal
affordable where per-article onchain storage would not be.

---

## Attack matrix ↔ tests

66 tests in 8 suites. `forge test` is the gate; `.gas-snapshot` pins costs.

| # | Threat | Defense | Test(s) |
|---|---|---|---|
| 1 | Publish under someone else's name | digest re-derived from payload, then EIP-712 recovery must equal `payload.author` | `Submit.t.sol::test_forgedByAuthorSigReverts`, `ArticleLib.t.sol::test_forgedByAuthorSigReverts` |
| 2 | Tamper payload after signing | `keccak256(abi.encode(payload)) == leaf` | `Submit.t.sol::test_digestMismatchReverts`, `Gateway.t.sol::test_gatewayDigestMismatchReverts` |
| 3 | Signature malleability (high-`s` twin of a valid sig) | explicit low-`s` gate — Solady's `recover` deliberately does **not** check | `Submit.t.sol::test_lowSEnforced` |
| 4 | Reuse one signed payload | `usedUuid` keyed by `(author, uuid)` | `Submit.t.sol::test_duplicateUuidReverts` |
| 4b | **Squat a victim's predictable uuid** with your own payload to block their article | dedup is author-scoped, so a foreign author's uuid never collides | `Submit.t.sol::test_uuidSquatDoesNotBlockVictim`, `test_sameAuthorSameUuidStillDeduped` |
| 5 | Reuse it across lanes (direct **and** gateway-CCIP) | same `uuid` check sees both lanes | `CCIP.t.sol::test_replayAcrossLanesReverts` |
| 6 | Replay on another hub instance or another chain | EIP-712 domain `(chainId, verifyingContract)` | `Submit.t.sol::test_payloadSignedForAnotherDomainReverts` |
| 7 | Bypass the router to inject through `ccipReceive` (the entry itself checks nothing) | `msg.sender == router`, checked in the lane handler | `CCIP.t.sol::test_directConsumeRejected` |
| 8 | Message from a foreign chain | `gatewayAt[sourceChainSelector]` registration pin (unregistered = `BadChain`) | `CCIP.t.sol::test_wrongChainSelectorReverts`, `test_revokedChainReverts`, `test_secondChainGatewayAccepted` (the pin accepts exactly the registered set) |
| 9 | Message from a foreign sender on the right chain | `sender == gatewayAt[chain]` pin | `CCIP.t.sol::test_wrongSenderReverts` |
| 10 | Push an arbitrary root into the hub | `anchorNextBatch()` takes **no root argument** — root is computed from the journal | `Batch.t.sol::test_permissionlessAnchor`, `Batch.t.sol::test_rangeFreezeAfterAppend` (root re-derived from journal, byte-identical) |
| 11 | Alter an anchored root by appending later | range freeze on `[start, end)` | `Batch.t.sol::test_rangeFreezeAfterAppend` *(Review Focus 5)* |
| 12 | Grief batches (early/late/empty closes) | `MIN_BATCH`/`MAX_BATCH`/`BATCH_DEADLINE`/`pending > 0` | `Batch.t.sol::test_anchorRequiresMinOrDeadline`, `Batch.t.sol::test_anchorAtMaxBatch`, `Batch.t.sol::test_emptyAnchorReverts` |
| 13 | Prove a leaf that isn't in the batch (or is from another batch) | `MerkleProofLib` against the frozen root | `Batch.t.sol::test_verifyAgainstBatchFalse`, `Batch.t.sol::test_verifyAgainstBatchTrue` |
| 14 | Merkle builder/verifier disagree (implementation bug) | differential vs hand-written `NaiveMerkle` + fuzz | `MerkleDifferential.t.sol::test_matchesNaiveReference` (256 runs), `test_oddLeafCounts`, `test_singleLeafRoot` |
| 15 | Upgrade by anyone, or a second upgrade authority hiding beside the UUPS path | `_authorizeUpgrade` is `onlyOwner` on both contracts (OZ Ownable — a `pendingOwner` has no power until `acceptOwnership`); each contract's OZ `ERC1967Proxy` has **no admin entry at all** (ERC-1967 admin slot stays `0`); OZ `onlyProxy` blocks any attempt on either bare implementation | `Upgrade.t.sol::test_nonOwnerUpgradeReverts`, `test_gatewayNonOwnerUpgradeReverts`, `test_proxyHasNoAdminSlot`, `test_bareImplementationUpgradeReverts`, `test_gatewayBareImplementationUpgradeReverts`, `test_transferOwnershipStartsTwoStep`, `test_acceptOwnershipCompletesTransfer`, `test_acceptOwnershipRejectsNonPending`, `test_transferOwnershipOnlyOwner`, `test_transferToZeroCancelsPending`, `test_gatewayTransferOwnershipTwoStep`, `test_renounceOwnershipDisablesUpgrades` |
| 16 | Re-initialize (proxy *or* bare implementation), hijack gateway wiring, corrupt storage on upgrade | OZ `initializer` lock (bare impl `_disableInitializers()`-locked at construction) + zero-owner rejection (`OwnableInvalidOwner`), `setGateway` owner-only, ERC-7201 namespaced layout, append-only journal | `Upgrade.t.sol::test_initializeTwiceReverts`, `test_gatewayInitializeTwiceReverts`, `test_bareImplementationCannotBeInitialized`, `test_gatewayBareImplementationCannotBeInitialized`, `test_initializeRejectsZeroOwner`, `test_gatewayInitializeRejectsZeroOwner`, `test_zeroOwnerProxyCannotBeConstructed`, `test_gatewayZeroOwnerProxyCannotBeConstructed`, `test_setGatewayOnlyOwner`, `test_journalPreservedAcrossUpgrade`, `test_gatewayConfigPreservedAcrossUpgrade` |
| 17 | Spam one author's journal | `RATE_LIMIT = 1h` | `Submit.t.sol::test_rateLimit1hReverts` |
| 18 | Submit an expired article | `block.timestamp ≤ deadline`, checked first on both lanes | `Submit.t.sol::test_expiredDeadlineReverts` |
| 19 | Run off with / overcharge the gateway fee | `getFee` quote, `msg.value ≥ fee`, refund excess, gateway retains 0 | `Gateway.t.sol::test_insufficientFeeReverts`, `test_excessRefunded` |
| 20 | Bytes garbled between gateway and hub | byte-identical encode/decode round trip | `Gateway.t.sol::test_gatewayForwardsByteIdenticalCalldata`, `test_gatewayPayloadLandsInHub` |
| 21 | Silent cost regression | smoke bounds on every marginal measurement | `Gas.t.sol::test_gasSubmit` / `test_gasAnchor` / `test_gasVerify` / `test_gasGatewaySubmit` |

Struct-hash pinning (`ArticleLib.t.sol::test_hashStructIsPinned`) uses vectors
computed with `cast` — an *independent tool*, not the contract's own code — so
an accidental typehash or field-order change cannot pass review quietly. Those
vectors are also what made `ArticleLib.hashStruct` safe to rewrite as hand-rolled
assembly (Solady's pattern, `forge lint: asm-keccak256`): seven contiguous words
instead of `keccak256(abi.encode(...))`, byte-identical output, **−837 gas on
every submission** — the two `submitArticle` rows above are post-refactor.

**Review Focus items** (the five questions the spec singled out) map to:
forged authorship → #1; cross-lane replay → #5; non-whitelisted CCIP source →
#7/#8/#9; post-anchor append → #11.

### End-to-end (live node, not mocks)

`script/e2e-anvil.sh` boots anvil, deploys `MockRouter` → `ArticleAnchor`
(UUPS), signs and submits a real EIP-712 article, warps past the batch
deadline, anchors and asserts the frozen root. It is the acceptance check for
the keeper script (`Anchor.s.sol`) — permissionless and assuming nothing the
contract does not enforce.

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
batch root, no provable artifact for a third party. The Merkle route costs a fixed
≈98k per batch plus ≈2.9k per leaf — call it **~3k gas per article to make
every article provable to a third party** (the batch's fixed overhead is paid
once, amortized over up to 200 articles) — and returns proofs that survive
mirrors, cross-chain copies and independent re-hosting. For a *publishing*
product the proof is the point, so the journal wins. The rate limit, `uuid`
dedup and batch window live in mappings precisely because those are
*bookkeeping*, not *claims*.

**ERC-7201 namespaced storage.** Neither contract declares a state variable:
each one's whole layout is a `Storage` struct on its interface, addressed at
its own namespace — `eulerphi.storage.ArticleAnchor` or
`eulerphi.storage.SubmissionGateway` — by the standard formula
`keccak256(abi.encode(uint256(keccak256("<id>")) - 1)) & ~bytes32(uint256(0xff))`
and reached through a single pointer whose slot constant sits beside it
(`ArticleLib.STORAGE_SLOT`, `GatewayLib.STORAGE_SLOT`): one pointer and one
literal per namespace, living in a library instead of a `virtual`/`override`
pair spread over two contracts
(assembly takes only number constants, hence the local copy inside the
pointer). `test_storageLivesAtErc7201Slot` recomputes the formula from each
namespace id, compares it against those constants and reads the raw slots —
for both contracts, constant, id and contents must all agree. Payoffs: a future
base contract or a field reordering cannot collide with this layout, because a
namespace owns its own region of the slot space; the layout is auditable as one
commented block instead of being implied by declaration order across the file;
and `router` sits alone at the namespace base (bytes 0..20 — the multi-chain
mapping took its old selector pin away), with `gatewayAt`'s
mapping base at slot 1, while the gateway still packs
`router` + `baseChainSelector` into its base word because `submitArticle`
reads both. This is breaking for a proxy deployed at the old
linear slots; no such deployment exists for either namespace (the gateway's
notary-era layout never shipped a proxy either), and there is deliberately no
dual-read migration.
The namespace state is readable on chain only THROUGH the contract that owns
it: the EVM has no opcode for reading another account's storage, so every getter
is an `sload` inside the owner, living in a getter contract the owner inherits —
`ArticleAnchorGetters` inside `ArticleAnchor` (behind `IArticleAnchorGetters`)
and `SubmissionGatewayGetters` inside `SubmissionGateway` (behind
`ISubmissionGatewayGetters`) — each getter declared once, implemented once,
inherited by exactly one contract. There is deliberately NO
wrapper contract around them — a facade could only `staticcall` the owner back,
adding a second copy of every function (plus a second chain to deploy on) to
read the same words. Reading ANOTHER account's raw slots is an off-chain
capability instead (`cast`, `eth_getStorageAt`, `vm.load`), and the project's
own tooling uses it: `test_storageLivesAtErc7201Slot` and
`test_proxyHasNoAdminSlot` both read foreign slots with `vm.load`.

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

The owner keys are the trust floor of the system: the hub's OZ `owner` can
upgrade the implementation and therefore control the journal, and each
`GW_OWNER` can upgrade its gateway — enough to reroute or halt that paid lane
(an upgrade rewrites `router`/`hub`/`baseChainSelector`), never to touch the
journal, whose every check runs on the hub, out of the gateways' reach.
Mitigations in place, all tested, and each applies to **every** contract:

- **Single upgrade path**: each contract sits behind its own OpenZeppelin `ERC1967Proxy`,
  which has **no admin/authority entry of its own** — the ERC-1967 admin slot
  is `0` and stays there (`test_proxyHasNoAdminSlot`), so there is no factory
  key, guardian or fallback route to disable. `upgradeToAndCall` gated by
  `_authorizeUpgrade` (`onlyOwner`, OZ Ownable) is the only way up — `test_nonOwnerUpgradeReverts`,
  `test_gatewayNonOwnerUpgradeReverts` — and OZ's `onlyProxy` kills any attempt
  made against either bare implementation (`test_bareImplementationUpgradeReverts`,
  `test_gatewayBareImplementationUpgradeReverts`).
- **No half-deployed hub or gateway can exist**: OZ's proxy refuses
  construction with empty init data (`ERC1967ProxyUninitialized`) and a botched
  `initialize(initialOwner = 0)` bubbles out of the constructor
  (`test_zeroOwnerProxyCannotBeConstructed`,
  `test_gatewayZeroOwnerProxyCannotBeConstructed`) — a failed deploy leaves
  nothing on chain to strand users.
- **`initialize` runs exactly once**, via OpenZeppelin's `initializer`
  modifier. The constructor writes **no variable at all** — OZ's documented
  best practice for proxied contracts: its only job is to call
  `_disableInitializers()`, which locks the bare implementation forever so no
  stranger can ever own it (`test_bareImplementationCannotBeInitialized`,
  `test_gatewayBareImplementationCannotBeInitialized`; a second call on the
  proxy reverts `InvalidInitialization()` — `test_initializeTwiceReverts`,
  `test_gatewayInitializeTwiceReverts`). The body still rejects
  `initialOwner = address(0)` through `__Ownable_init`
  (`OwnableInvalidOwner(address(0))`) (`test_initializeRejectsZeroOwner`,
  `test_gatewayInitializeRejectsZeroOwner`). **Storage survives upgrades**
  (`test_journalPreservedAcrossUpgrade`,
  `test_gatewayConfigPreservedAcrossUpgrade`).
  No base `__X_init()` is called, and none exists to call: `UUPSUpgradeable`
  is flagged `@custom:stateless` (no storage, no init function — it does not
  even extend `Initializable`, which is why the hub inherits it explicitly),
  Solady's `EIP712` caches its domain separator in `immutable`s and invalidates
  the cache whenever `address()` differs, so the separator is rebuilt over the
  proxy address, and `Initializable`'s own state is an ERC-7201 slot. Those
  two configuration words on the hub (three on the gateway) are the entire
  bootstrap.
- **Ownership is OZ `Ownable2Step`, written exactly once** — `__Ownable_init`
  runs inside `initialize` on the proxy (the constructor writes no
  configuration) and rejects `address(0)` (`OwnableInvalidOwner`). Rotation is
  a **two-step transfer**: `transferOwnership(new)` only sets `pendingOwner`
  (no power until the new key calls `acceptOwnership()`), and
  `transferOwnership(address(0))` cancels a pending transfer — a pending
  address gains nothing until it accepts, and the owner can cancel before
  that: no silent transfer-hijack. The price is that you
  must **deploy with a multisig/timelock as `HUB_OWNER` from day one** — and
  the same rule for every `GW_OWNER`.
- **Renounce plan**: each proxy's owner calls **`renounceOwnership()`** — OZ's
  function, one step by OZ's design (the two-step rule protects transfers, not
  renouncing) — which sets `owner` to `address(0)` and makes every `onlyOwner`
  path (`_authorizeUpgrade`, `setGateway`) unreachable forever. One call per
  proxy — the hub, then every gateway — and `OwnershipTransferred(old, 0)` is
  the on-chain record. Ownership lives in OZ's ERC-7201 slots, not in the app
  namespace, so renouncing changes no initialization state: `Initializable`'s
  version slot still gates `initialize`, which stays closed.

### Chain selectors are sourced, never guessed

Both directions pin a Chainlink **chain selector**: each authorized source
chain is a key of the hub's `gatewayAt` mapping (set via `setGateway`, one per
lane), and `GW_BASE_CHAIN_SELECTOR` is injected at deploy time — never
hardcoded in source. Get them from Chainlink's official CCIP directory for the exact lane
you deploy (docs.chain.link → CCIP → directory), not from memory or a
third-party list. A wrong selector fails **closed**: the lane simply never
delivers. Selectors are *not* chain ids — they are Chainlink's own namespace.

### Signatures

65-byte `(r, s, v)` canonical form only; **low-`s` is enforced by us** because
Solady's `ECDSA.recover` intentionally accepts malleable `s` (its own header
warns about this). The digest is `keccak256(abi.encode(payload))` *and* the
EIP-712 typed digest — both are checked, so a payload cannot be reinterpreted.

### Unpaid-keeper liveness

`anchorNextBatch` is permissionless but **incentive-free**, and the protocol
has no treasury to pay from (that is what "no fees" means). Consequence: if
nobody runs the keeper, writes are unaffected — articles keep journaling — but
batches do not freeze. The script is one command and costs ≈104k gas; any
author, reader or competitor can run it, which is the point
of permissionlessness. What it does not buy is *guaranteed* cadence. A future
bounty or an operator cron is the honest fix; the current design optimizes for
"nobody can be corrupted by a role that doesn't exist" over "fixed schedule".

### CCIP assumptions

Chainlink CCIP is trusted for liveness of the single lane (gateway → hub);
integrity on that lane is the hub's own business — every payload is re-verified
at the destination. Message fees are Chainlink's; the gas limit
(`SUBMIT_GAS_LIMIT = 400k`) carries generous headroom and must be calibrated on
a real testnet before a real lane. The vendored interfaces are a **minimal subset**, taken from
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
# 1. Hub (Base) — OZ ERC1967 proxy (no admin entry at all); owner = your multisig/timelock
HUB_OWNER=<multisig> \
HUB_ROUTER=<chainlink router on Base> \
  forge script script/DeployHub.s.sol --rpc-url $BASE_RPC --broadcast

# 2. Gateway (Ethereum) — OZ ERC1967 proxy (same single upgrade path as the
#    hub); GW_OWNER is the gateway's upgrade key — multisig/timelock
GW_OWNER=<multisig> \
GW_ROUTER=<chainlink router on Ethereum> \
GW_HUB=<hub proxy address> \
GW_BASE_CHAIN_SELECTOR=<Chainlink selector for the Ethereum→Base lane> \
  forge script script/DeployGateway.s.sol --rpc-url $ETH_RPC --broadcast

# 3. Wire them (owner only) — one call per source chain: $SOURCE_SELECTOR is
#    that chain's Chainlink selector, $GATEWAY its GATEWAY_PROXY address.
#    Revocation is the same call with address(0): inbound from that chain then
#    fails closed to BadChain.
cast send $HUB "setGateway(uint64,address)" $SOURCE_SELECTOR $GATEWAY --private-key $OWNER_KEY --rpc-url $BASE_RPC

# Keepers (permissionless — anyone can run)
HUB_ADDRESS=$HUB forge script script/Anchor.s.sol    --rpc-url $BASE_RPC --broadcast
```

---

## Repository layout

```
src/
  ArticleAnchor.sol        hub: submit, journal, batching, roots, CCIP inbound, UUPS
  SubmissionGateway.sol    source chain: payable entry lane (no ecrecover), UUPS proxy
  ArticleAnchorGetters.sol the hub's 11 read getters, implemented once (abstract)
  SubmissionGatewayGetters.sol
                           the gateway's 3 read getters, implemented once
                           (abstract)
  libraries/
    ArticleLib.sol         EIP-712 typehash + `hashStruct`, the hub's ERC-7201 slot +
                           namespace pointer (`getStorage()`), and every hub
                           policy constant as `public`: MIN_BATCH, MAX_BATCH,
                           BATCH_DEADLINE, RATE_LIMIT, HIGH_S_MAX — the
                           contract holds none of them
    GatewayLib.sol         the gateway's ERC-7201 slot + pointer and its
                           `public SUBMIT_GAS_LIMIT`; contract holds none
  interfaces/
    IArticleAnchor.sol     hub's own public ABI, laid out in style-guide order
                           (type declarations, then events, then errors, then
                           functions: actions first, `view` last) + all 11
                           custom errors + every API NatSpec; the 11 read
                           getters are NOT here — they live in
                           `IArticleAnchorGetters` — and ArticleAnchor inherits
                           both, so the compiler keeps docs and ABI in
                           lockstep. Owns both type declarations: the
                           `ArticleSubmission` envelope (what writers sign, what
                           the journal stores as a leaf) and the ERC-7201
                           `Storage` struct — the hub's ENTIRE state layout,
                           documented field by field. Every failure is a typed
                           error declared here, never a revert string: each
                           guard is written `require(condition, Err())`
    IArticleAnchorGetters.sol
                           the hub's 11 read getters — declared in ONE place,
                           implemented in ONE contract (`ArticleAnchorGetters`),
                           an `sload` in the account that owns the namespace.
                           No wrapper copies them anywhere
    ISubmissionGateway.sol same for SubmissionGateway (4 typed errors + its
                           ERC-7201 `Storage` struct — router/hub/selector,
                           documented field by field)
    ISubmissionGatewayGetters.sol
                           the gateway's 3 state reads — declared once,
                           implemented once in `SubmissionGatewayGetters`
    Client.sol, IRouterClient.sol, IAny2EVMMessageReceiver.sol
                           vendored CCIP subset @ commit 171f9f0
script/
  DeployHub.s.sol DeployGateway.s.sol     deployment (single upgrade path)
  Anchor.s.sol                            permissionless keeper loop
  E2ESubmit.s.sol                         signs + submits against the live domain
  e2e-anvil.sh                            live end-to-end driver
test/
  ArticleLib.t.sol Submit.t.sol Batch.t.sol MerkleDifferential.t.sol
  CCIP.t.sol Gateway.t.sol Upgrade.t.sol Gas.t.sol
  lib/NaiveMerkle.sol   independent reference Merkle (differential)
  mocks/                MockRouter, ArticleAnchorV2Stub, SubmissionGatewayV2Stub, AuthorGate
.gas-snapshot            forge snapshot output (regenerate with `forge snapshot`)
soldeer.lock             dependency pins (solady v0.1.26, forge-std v1.17.0,
                         openzeppelin-contracts + -upgradeable v5.7.0)
```

## Code style

Contracts follow the [official Solidity style
guide](https://docs.soliditylang.org/en/v0.8.38/style-guide.html). The work is
split in two: `forge fmt` owns whitespace, indentation and line wrapping (hard
gate: `forge fmt --check`), and the style guide itself owns the ordering rules a
formatter cannot express — those are held by review against the guide, which is
the single reference. The formatter's own knobs live in `foundry.toml`
(`[profile.default.fmt]`): `line_length = 120`, `bracket_spacing` (spaces
inside `{ … }`), `sort_imports`, `wrap_comments`, `number_underscore =
"thousands"` — so imports arrive sorted, comments reflow to the same width as
code, and big decimals read `1_700_000_000`.

| Rule | Where you see it |
|---|---|
| **Order of functions** — `constructor` → `receive` → `fallback` → `external` → `public` → `internal` → `private`, with `view`/`pure` last inside each group | `ArticleAnchor`: `initialize` … `anchorNextBatch`, then the external `view` `verifyAgainstBatch`, then `_consumeSubmittedArticle` … `_domainNameAndVersion` |
| **Order of layout** — type declarations → state variables → events → errors → modifiers → functions | interfaces open with their events, then the typed errors, then the ABI; contracts open with `constructor`, then functions (no declared state or modifiers — they live in the ERC-7201 namespace and OZ) |
| **Modifier order** — visibility → mutability → `virtual` → `override` → custom | `_authorizeUpgrade(address) internal view override onlyOwner` |
| **≤ 120 characters per line** | enforced by `forge fmt` (see exception 3) |

Naming follows the guide: `CapWords` for contracts, structs and events,
`mixedCase` for functions and variables, `UPPER_CASE_WITH_UNDERSCORES` for
constants (`TYPEHASH`, `SUBMIT_GAS_LIMIT`, `STORAGE_SLOT`); first-party `src/`
holds no immutable at all anymore (the gateway's three became storage when it
went UUPS), so nothing else takes the SCREAMING shape. State-variable getters
stay `mixedCase` (`owner`, `router`, `hub` — storage, not bytecode). Then a
leading `_` on every non-external **function** (`_submit`, `_buildRoot`,
`_deployHub`, `_signedLeaf`). Two deliberate calls where the
guide leaves room:

- **library functions keep bare names** (`ArticleLib.hashStruct`) — the
  library namespace already says "non-external", and that is what Solady's and
  OpenZeppelin's libraries do;
- **constants keep bare `UPPER_CASE`, and every one in `src/` is `public`
  on its library** (`ArticleLib.TYPEHASH`, `ArticleLib.STORAGE_SLOT`,
  `ArticleLib.MIN_BATCH`, `ArticleLib.HIGH_S_MAX`,
  `GatewayLib.SUBMIT_GAS_LIMIT`) — prefixing them yields `_TYPEHASH`, which
  reads as collision avoidance rather than visibility, and a contract-level
  copy would need a getter nobody asked for. No contract in `src/` declares a
  constant at all; `ArticleTestBase.FORGER_KEY`, in tests, stays `internal`.

Three exceptions, each leaning on the guide's own preamble: *"In the event of
conflicts, project specific style guides take precedence"* and *"know when to
be inconsistent"*.

1. **One blank line between top-level declarations, not two.** `forge fmt`
   collapses runs of blank lines to one, and `forge fmt --check` is a hard
   gate — a whitespace rule that fights the formatter cannot be kept.
2. **The vendored CCIP files are never reordered.** `Client.sol`,
   `IRouterClient.sol` and `IAny2EVMMessageReceiver.sol` stay byte-comparable
   with upstream (`smartcontractkit/ccip @ 171f9f0`), so the "re-verify against
   upstream before a real lane" promise stays a `diff` instead of an
   archaeology project. They keep Chainlink's own order (`getFee` is `view`
   and sits before `ccipSend`).
3. **One 121-character line**: the declaration of
   `IArticleAnchor.verifyAgainstBatch`. `forge fmt`'s limit excludes the
   trailing `;`, so that line is exactly 120 characters of code, and the only
   way to shorten it would be renaming an ABI parameter to gain one character.

## Known limitations

- **Not audited.** Treat as assessment code until a review says otherwise.
- **Owner key is irrecoverable if lost** — Ownable has no recovery path;
  deploy with a multisig. A stolen owner key completes a two-step transfer to
  the thief themselves — timelock/multisig from day one (see above).
- **No keeper incentive** → no guaranteed batch cadence.
- **No frontend, no indexer, no IPFS pinning** — by the 100%-Solidity rule.
- **No roles, no fees, no ZK** in v1 — extension points documented above.
- **CCIP fees, receiver gas limits and chain selectors must be re-verified**
  against live Chainlink documentation at deployment time.
- **Rate limit / batch constants are policy, not security**: `MIN_BATCH=10`,
  `MAX_BATCH=200`, `BATCH_DEADLINE=6h`, `RATE_LIMIT=1h` are chosen for
  a quiet chain and are trivially re-tuned before launch.

## License

MIT
