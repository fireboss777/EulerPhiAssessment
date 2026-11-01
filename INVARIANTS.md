# Primitive invariants

Four properties of the hub (`ArticleAnchor`). "Primitive" is a hard bar: a
violation leaves the system **broken, not degraded**. Everything else — gas
bounds, rate limits, uuid dedup, fee quoting/refunds, upgrade authority — is
policy layered on top of these four.

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
- *Owner-only writes* — every transition modifying `gatewayAt` has
  `msg.sender == owner` (`setGateway`, `onlyOwner`; `initialize` never touches
  the mapping).

**Threat surface.** `_consumeSubmittedArticle` (router check, mapping lookup,
sender check — these three checks are the lane's entire security);
`setGateway`.

**Why primitive.** This is the whole trust boundary of the multi-chain
design: the mapping *is* the whitelist, and a registered gateway's address
*is* the capability to inject from its chain. Violation = any chain or
address in the world can write the journal.

Pinned by `test_whitelistedSourceSubmits`, `test_wrongChainSelectorReverts`,
`test_wrongSenderReverts`, `test_revokedChainReverts`,
`test_secondChainGatewayAccepted`, `test_crossChainSenderRejected`,
`test_setGatewayOnlyOwner`.

---

## INV-3 — Anchor: roots derived from the journal, frozen forever

**Statement.** For every `batchIndex < anchoredBatches`, `rootAt[batchIndex]`
is exactly the Merkle root the contract computed over the contiguous range
`journal[start..end)`, with `start_0 = 0`, `start_{b+1} == end_b`, and
`end_b <= journalLength`; each `rootAt[b]` is written exactly once.
Consequently `verifyAgainstBatch(b, leaf, proof) == true` implies `leaf` is an
element of that journal range.

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
`test_verifyAgainstBatchFalse`, `test_storageLivesAtErc7201Slot`.

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
`test_lowSEnforced`, `test_hashStructIsPinned`.

---

## Deliberately not invariants

- **Policy** — gas bounds, rate limits, uuid dedup, fee quoting/refunds: real
  guarantees, but tunable rules layered on top of the four.
- **Upgrade authority** — `_authorizeUpgrade` and setter gating are OZ
  `Ownable2StepUpgradeable`'s mechanically enforced behavior; restating them
  would duplicate what the framework already guarantees.
- **Transport identity** — the journal records no source chain (by scope);
  "which chain an entry arrived from" is intentionally not system state.

## Formalization

These statements are the source of truth for the Certora rules: every CVL
rule or invariant must trace back to a predicate above by name.
