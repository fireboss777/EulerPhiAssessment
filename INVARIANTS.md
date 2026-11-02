# Primitive invariants

Four properties of the hub (`ArticleAnchor`), plus three for the source-chain
gateway (`SubmissionGateway`) that feeds it. "Primitive" is a hard bar: a
violation leaves the system **broken, not degraded**. Everything else — gas
bounds, rate limits, uuid dedup, the fee *level*, upgrade authority — is
policy layered on top of these.

Dependency chain: **INV-1** (the data) → **INV-3** (the commitment to the data)
→ **INV-2** (who may add to it) → **INV-4** (what additions are made of).

---

## INV-1 — Journal: append-only, write-once

**Statement.** In every reachable state, `journalLength` never decreases; every
`journal(i)` for `i < journalLength` is immutable forever; the only journal
write in the system is a terminal `push`.

**Predicate.**

- *Monotonicity* — for every state transition `s → s'`:
  `journalLength(s') >= journalLength(s)`.
- *Immutability* — for every `i < journalLength(s)`:
  `journal(s')(i) == journal(s)(i)` in all future states `s'`.
- *Terminality* — the `push` in `_submit` is the last operation on `journal`;
  no in-place write, pop, or resize exists anywhere in `src/`.

**Threat surface.** `_submit` (the sole push site); any future function
touching `$.journal`.

**Why primitive.** The journal is the system of record: every root,
`verifyAgainstBatch`, and off-chain relay derives from it. If an element can
change or the length recede, all already-published roots and proofs become
meaningless — total loss of trust, not a degradation.

Pinned by `test_validSubmitAppendsJournal`, `test_rangeFreezeAfterAppend`,
`test_journalPreservedAcrossUpgrade`.

---

## INV-2 — Lane: fail-closed, strictly paired

**Statement.** A CCIP delivery may extend the journal only if it arrives
through the configured router and, at that moment,
`gatewayAt[message.sourceChainSelector] != 0` **and**
`message.sender == gatewayAt[that chain]`. `gatewayAt` cells are written only
by the current owner. A chain absent from the mapping (never registered or
revoked to `0`) can never journal anything, from any sender.

**Predicate.**

- *Router pin* — the delivery path requires `msg.sender == router`
  (`NotRouter`).
- *Fail-closed* — `gatewayAt[c] == 0` implies every `ccipReceive` announcing
  chain `c` reverts `BadChain()`.
- *Strict pairing* — acceptance of a delivery implies
  `message.sender == gatewayAt[message.sourceChainSelector]` exactly:
  membership in the registered set is not enough (a chain-B sender under
  chain A's entry reverts `BadSender()`).
- *Owner-only writes* — every transition modifying `gatewayAt` **or `router`**
  has `msg.sender == owner` (`setGateway`, `setRouter`, both `onlyOwner`;
  `initialize` writes the router once at construction and never the mapping).
  The router is the lane's first gate — whoever can repoint it owns the lane
  outright — so it gets the same owner discipline as the registry.

**Threat surface.** `_consumeSubmittedArticle` (router check, mapping lookup,
sender check — these three checks are the lane's entire security);
`setGateway`, `setRouter`.

**Why primitive.** This is the whole trust boundary of the multi-chain
design: the mapping *is* the whitelist, and a registered gateway's address
*is* the capability to inject from its chain. Violation = any chain or
address in the world can write the journal.

Pinned by `test_whitelistedSourceSubmits`, `test_wrongChainSelectorReverts`,
`test_wrongSenderReverts`, `test_revokedChainReverts`,
`test_secondChainGatewayAccepted`, `test_crossChainSenderRejected`,
`test_setGatewayOnlyOwner`, `test_setRouterOnlyOwner`,
`test_routerRotationRewiresTheLane`.

---

## INV-3 — Anchor: roots derived from the journal, frozen forever

**Statement.** For every `batchIndex < anchoredBatches`, `rootAt[batchIndex]`
is exactly the Merkle root the contract computed over the contiguous range
`journal[start..end)`, with `start_0 = 0`, `start_{b+1} == end_b`, and
`end_b <= journalLength`; each `rootAt[b]` is written exactly once.
Consequently, for `b < anchoredBatches` and a **non-empty** `proof`,
`verifyAgainstBatch(b, leaf, proof) == true` implies `leaf` is an element of
that journal range (modulo second-preimage resistance of keccak). With an
**empty** `proof` the call passes only when `leaf == rootAt[b]`: for a
single-leaf batch that equality *is* `journal[start_b]` (the honest path —
`leafProof` of a one-leaf tree is empty), for a multi-leaf batch or an
unwritten index (`rootAt[b] == 0`, `leaf == 0`) it is vacuous and
unexploitable — producing a payload whose digest equals a published root is a
preimage attack.

**Predicate.**

- *Derivation* — `rootAt[b] == MerkleRoot(journal[start_b..end_b))`: a root is
  a function of journal content only, never of outside input.
- *Contiguous coverage* — batch ranges touch without overlap and cover
  exactly `[0, lastAnchoredIndex)`.
- *Freeze* — `rootAt[b]` is never rewritten: `anchoredBatches` is sequential,
  so a published index is never reused.
- *Consequence* — `verify == true` implies
  `leaf ∈ journal[start_b..end_b)`, resting on INV-1 (frozen data), the
  freeze above, and hash collision resistance.

**Threat surface.** `anchorNextBatch` (range math, publishing a root not
derived from the journal, overwriting a root), `_buildRoot`.

**Why primitive.** Verification (~15k gas) *is* the product: a proof of
inclusion must be a proof of inclusion **in the journal**. Violation = the
anchor lies — external verifiers accept statements the system never
journaled.

Pinned by `test_permissionlessAnchor`, `test_anchorRequiresMinOrDeadline`,
`test_anchorAtMaxBatch`, `test_emptyAnchorReverts`,
`test_rangeFreezeAfterAppend`, `test_verifyAgainstBatchTrue`,
`test_verifyAgainstBatchFalse`, `test_crossBatchProofsBoundToTheirOwnRoot`,
`test_storageLivesAtErc7201Slot`.

---

## INV-4 — Provenance: every entry is signed under the hub's domain

**Statement.** Every `journal(i)` equals `keccak256(abi.encode(p))` for a
payload `p` such that `ECDSA.recover(digest, sig) == p.author`, where `digest`
is the EIP-712 hash bound to the hub's domain `(name, version, chainId,
verifyingContract = hub proxy)`, and `block.timestamp <= p.deadline` at entry
time. Both lanes (direct and CCIP) pass through `_submit` — the hub is the
single signature authority (design decision 1a: the gateway performs a digest
check only).

**Predicate.**

- *Digest binding* — `keccak256(abi.encode(p)) == leafDigest` before the
  push: the journaled leaf *is* the signed content.
- *Domain binding* — the digest embeds `chainid()` and `address()` (the proxy)
  through Solady's domain separator; a signature made for another chain or
  another contract recovers a different address and reverts `NotAuthor()`.
- *Authorship* — recovered signer `== p.author`, over canonical 65-byte
  low-s signatures only.

**Threat surface.** `_submit` (digest check, low-s gate, recovery, deadline);
Solady `EIP712` / `ECDSA`.

**Why primitive.** Content authenticity: the journal holds commitments to
articles an identified author vouched for. Violation = anyone can journal
anything under any name.

The domain is caller-provided data end to end — viem, MetaMask's
`eth_signTypedData_v4`, and eth-sig-util never substitute the connected
chain's id — so signing for the hub's domain while sitting on a source chain
is a supported flow requiring no protocol concession.

Pinned by `test_genuineAuthorSigAccepted`,
`test_payloadSignedForAnotherDomainReverts` (foreign chainId **and** foreign
verifyingContract → `NotAuthor`), `test_forgedByAuthorSigReverts`,
`test_digestMismatchReverts`, `test_expiredDeadlineReverts`,
`test_lowSEnforced`, `test_signatureLengthGateRejectsNon65`,
`test_eip712DomainNameAndVersionPinned`, `test_hashStructIsPinned`.

---

## GW-1 — Gateway: faithful forwarding of bytes, fee, and destination

**Statement.** Every successful `submitArticle` hands the router exactly:
destination `baseChainSelector`, receiver `abi.encode(hub)`, value equal to
the quoted fee, and `data == abi.encode(leafDigest, sig, payload)`
byte-for-byte. The gateway retains nothing of `msg.value`; the caller is
charged exactly the fee (the excess comes back).

**Predicate.**

- *Faithful forwarding* — the `ccipSend(destinationChainSelector, message,
  value)` the gateway dispatches carries, on success:
  `destinationChainSelector == baseChainSelector`,
  `abi.decode(message.receiver) == hub`,
  `value == getFee(baseChainSelector, message)`, and
  `message.data == abi.encode(leaf, sig, payload)`. (MockRouter's captures
  record exactly these on the Foundry side — `test_gatewayForwardsByteIdenticalCalldata`
  asserts them; CVL pins them at the call boundary itself.)
- *Value honesty* — the gateway's balance is unchanged by the call, and the
  caller's decreases by exactly `fee`.

**Threat surface.** `submitArticle` (message construction, fee quote,
`ccipSend` value, refund transfer).

**Why primitive.** `Forwarded(leaf, messageId)` is the source chain's
attestation that *this* payload went to *that* hub. If bytes, destination, or
value can diverge from what the caller supplied, the transit layer lies while
appearing to confirm — the journal would then hold content the source chain
never attested. Violation = end-to-end integrity loss, not a mispriced hop.

Pinned by `test_gatewayForwardsByteIdenticalCalldata`, `test_excessRefunded`,
`test_refundToRejectingCallerReverts`, `test_gatewayPayloadLandsInHub`.

---

## GW-2 — Gateway: fail-closed before any fee moves

**Statement.** A submission with a past deadline, a leaf that is not
`keccak256(abi.encode(payload))`, or `msg.value` below the router's quote
reverts (`Expired()`, `DigestMismatch()`, `InsufficientFee()`); a rejected
submission never reaches `ccipSend`.

**Predicate.**

- *Deadline gate* — `block.timestamp > payload.deadline` implies
  `submitArticle` reverts `Expired()`.
- *Digest gate* — `leafDigest != keccak256(abi.encode(payload))` implies
  revert `DigestMismatch()`.
- *Fee gate* — `msg.value < getFee(baseChainSelector, message)` implies
  revert `InsufficientFee()`: a shortfall is never subsidised out of the
  gateway's own balance.

**Threat surface.** `submitArticle` (the three `require`s — presence and
order relative to the dispatch).

**Why primitive.** The mirror image of INV-2's fail-closed posture, on the
sending side: every check that gates money must reject rather than degrade.
Violation = an expired or forged envelope, or an unfunded caller, gets a
message dispatched — the lane no longer distinguishes valid from invalid at
its entry.

Pinned by `test_gatewayExpiredDeadlineReverts`,
`test_gatewayDigestMismatchReverts`, `test_insufficientFeeReverts` — one
Foundry test per gate now; the CVL rules `expiredSubmissionsFailClosed`,
`digestMismatchFailsClosed` and `underpaymentFailsClosed` pin the same three
predicates on the prover side (the hub-side deadline twin is
`test_expiredDeadlineReverts`).

---

## GW-3 — Gateway: configuration written only by initialize

**Statement.** The gateway's entire configuration — `router`, `hub`,
`baseChainSelector` (the ERC-7201 `Storage` struct) — changes only through
`initialize`; no other entry point, including `submitArticle` and the OZ
ownership/upgrade surface, writes it.

**Predicate.** For every state transition not performed by `initialize`:
`router`, `hub`, and `baseChainSelector` are unchanged.

**Threat surface.** `submitArticle` (reads only); any future setter; the
ownership surface (which gates upgrades, never configuration).

**Why primitive.** These three values define the lane: which router quotes
and carries the fee, which hub the bytes are addressed to, which selector
routes them. Violation = submissions are quoted by, or addressed to, an
attacker-chosen target while the gateway still reports the honest
configuration.

Pinned by `test_gatewayConfigPreservedAcrossUpgrade`,
`test_gatewayInitializeTwiceReverts`.

---

## Deliberately not invariants

- **Policy** — gas bounds, rate limits, uuid dedup, the fee *level* (what a
  quote amounts to), the batch window (`MIN_BATCH` / `BATCH_DEADLINE`,
  pinned by `test_batchWindowRecordsOpensAndGates`): real guarantees, but
  tunable rules layered on top. That the gateway forwards exactly its quote
  and retains nothing is GW-1 — the honesty of transit, not the price.
- **Upgrade authority** — `_authorizeUpgrade` and setter gating are OZ
  `Ownable2StepUpgradeable`'s mechanically enforced behavior; restating them
  would duplicate what the framework already guarantees.
- **Transport identity** — the journal records no source chain (by scope);
  "which chain an entry arrived from" is intentionally not system state.

## Formalization

These statements are the source of truth for the Certora rules: every CVL
rule or invariant must trace back to a predicate above by name.
