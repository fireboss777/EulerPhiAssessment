//
// * CVL specifications for the four primitive invariants — INVARIANTS.md.
// * Every rule / invariant below names the INV-1..INV-4 predicate it
// * discharges; INVARIANTS.md is the source of truth, this file is its
// * formal transcription.
// *
// * Harness assumptions:
// *  - solc: resolved from PATH (the confs deliberately carry NO `solc`
// *    field — an absolute compiler path is machine-local and breaks any
// *    other machine/CI). The PATH `solc` shim is managed by solc-select
// *    (pinned 0.8.28, the same commit the hardcoded hardhat path pointed
// *    to); Foundry uses its own solc inventory, so this pin is Certora-only.
// *  - Target is ArticleAnchor (implementation-level). Production runs behind
// *    the ERC1967 proxy; proxy-specific guarantees (empty admin slot,
// *    re-initialization) are pinned by test/Upgrade.t.sol, not here.
// *  - Owner-gated rules require an initialized hub (`hub.owner() != 0`);
// *    an uninitialized implementation (owner == 0) is out of scope.
// *  - Revert semantics: CVL ignores reverting paths by default (@norevert),
// *    so plain calls below only constrain successful executions; rules that
// *    assert rejection use @withrevert and capture `lastReverted` into a
// *    local IMMEDIATELY (any later call would overwrite the flag).
// *
// * Prover-run notes (not observable at lint time):
// *  - `senderMustBeTheRegisteredGateway` uses congruence of keccak256 instead
// *    of abi.encode (CVL has no abi encoder): content == abi.encode(gw) forces
// *    equal hashes, so requiring hash inequality soundly excludes the only
// *    accepted sender — no injectivity assumption needed in that direction.
// *  - INV-4's ECDSA/domain halves run through Solady assembly and a domain
// *    separator containing `chainid` (not exposed to CVL). The prover
// *    therefore checks the digest-binding asserts below; the
// *    recover==author and foreign-domain halves are pinned by
// *    test_payloadSignedForAnotherDomainReverts and friends. Add the
// *    published ecrecover axiom set if running ecrecover-level rules.
// *  - INV-3's hash-level membership consequence (leaf in journal range) rests
// *    on keccak collision/second-preimage resistance — see INVARIANTS.md;
// *    the specs pin the structural halves (freeze, cursor, empty-proof
// *    degeneracy).
//

using ArticleAnchor as hub;

methods {
    function router() external returns (address) envfree;
    function gatewayAt(uint64) external returns (address) envfree;
    function journal(uint256) external returns (bytes32) envfree;
    function journalLength() external returns (uint256) envfree;
    function lastAnchoredIndex() external returns (uint256) envfree;
    function anchoredBatches() external returns (uint256) envfree;
    function rootAt(uint256) external returns (bytes32) envfree;
    function owner() external returns (address) envfree;
}

// ===========================================================================
// INV-1 — Journal: append-only, write-once
// ===========================================================================

/// INV-1 · Monotonicity + Immutability (+ Terminality by implication: any
/// in-place write breaks immutability, any pop/resize breaks monotonicity).
/// Reverting f's are ignored by default — a reverted call changes nothing.
rule journalAppendOnly(env e, method f, calldataarg args, uint256 i)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    // Reachability precondition: raw harness storage can hold an absurd
    // length word (2^256-1) whose push wraps to 0 in the model — such a
    // state is not reachable from initialize (physical bound: gas).
    require hub.journalLength() < max_uint;
    require i < hub.journalLength();
    uint256 lenBefore = hub.journalLength();
    bytes32 elemBefore = hub.journal(i);

    hub.f(e, args);

    assert hub.journalLength() >= lenBefore,
        "INV-1 · Monotonicity: journalLength never decreases";
    assert hub.journal(i) == elemBefore,
        "INV-1 · Immutability: journal(i) is written once, never rewritten";
}

// ===========================================================================
// INV-2 — Lane: fail-closed, strictly paired
// ===========================================================================

/// INV-2 · Router pin: only the configured router may enter the lane.
rule ccipOnlyThroughTheRouter(env e, Client.Any2EVMMessage message)
{
    require e.msg.sender != hub.router();

    hub.ccipReceive@withrevert(e, message);
    bool rejected = lastReverted;

    assert rejected, "INV-2 · Router pin: a non-router sender reverts (NotRouter)";
}

/// INV-2 · Fail-closed: a chain absent from the mapping (never registered
/// or revoked to 0) can never journal, whatever the sender.
rule unregisteredChainFailsClosed(env e, uint64 c, Client.Any2EVMMessage message)
{
    require hub.gatewayAt(c) == 0;
    require message.sourceChainSelector == c;
    require e.msg.sender == hub.router();

    hub.ccipReceive@withrevert(e, message);
    bool rejected = lastReverted;

    assert rejected, "INV-2 · Fail-closed: gatewayAt[c] == 0 rejects the delivery (BadChain)";
}

/// INV-2 · Strict pairing: once chain c is registered to gw, ANY sender whose
/// content differs from abi.encode(gw) is rejected — membership in the
/// registered set (another chain's gateway, a foreign contract) is not
/// enough. Excludes the accepted encoding by keccak congruence (see header).
rule senderMustBeTheRegisteredGateway(
    env eOwner,
    env eRouter,
    uint64 c,
    address gw,
    Client.Any2EVMMessage message
)
{
    require gw != 0;
    require hub.owner() != 0;             // initialized hub (see header)
    require eOwner.msg.sender == hub.owner();
    hub.setGateway(eOwner, c, gw);

    require message.sourceChainSelector == c;
    // CCIP's Any2EVMMessage.sender is abi.encode(address): exactly 32 bytes.
    // The bound keeps the keccak-congruence exclusion exact — abi.decode
    // reads only the first word, so a padded tail (43 bytes in the run-4
    // counterexample) would hash differently yet decode to gw. Honest CCIP
    // never pads; padded senders are excluded here so the rule states
    // decode-level pairing precisely.
    require message.sender.length == 32;
    require keccak256(message.sender) != keccak256(gw);   // sender != abi.encode(gw)
    require eRouter.msg.sender == hub.router();

    hub.ccipReceive@withrevert(eRouter, message);
    bool rejected = lastReverted;

    assert rejected, "INV-2 · Strict pairing: sender must be THE gateway of the announced chain (BadSender)";
}

/// INV-2 · Owner-only writes: a non-owner can never mutate the mapping.
rule setGatewayOnlyOwner(env e, uint64 c, address g)
{
    require hub.owner() != 0;
    require e.msg.sender != hub.owner();

    hub.setGateway@withrevert(e, c, g);
    bool rejected = lastReverted;

    assert rejected, "INV-2 · Owner-only writes: setGateway reverts for a non-owner";
}

/// INV-2 · Owner-only writes (router): rotating the inbound lane's first gate
/// is owner work. `setRouter` is the hub's ONLY post-initialize writer for
/// `router` — it was added because the per-chain registry already had a setter
/// while rotating a deprecated Chainlink router needed a full UUPS upgrade
/// (the operational gap the adversarial review flagged).
rule setRouterOnlyOwner(env e, address r)
{
    require hub.owner() != 0;
    require e.msg.sender != hub.owner();

    hub.setRouter@withrevert(e, r);
    bool rejected = lastReverted;

    assert rejected, "INV-2 · Owner-only writes: setRouter reverts for a non-owner";
}

/// INV-2 · Owner-only writes (the parametric half): NO entry point other than
/// `initialize` (the legitimate writer at construction) and `setRouter`
/// (owner-gated above) may change the router. Without this companion, the
/// predicate would claim "only the owner writes the router" while pinning one
/// setter — a hypothetical second writer inside any other method would pass
/// silently. Mirrors the gateway's `configurationWrittenOnlyByInitialize`;
/// `upgradeToAndCall` is filtered like every other parametric rule here (its
/// delegatecall has no proxy in this implementation-level scene).
rule routerWrittenOnlyByInitializeOrSetRouter(env e, method f, calldataarg args)
    filtered {
        f -> f.selector != sig:initialize(address,address).selector
          && f.selector != sig:setRouter(address).selector
          && f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    require hub.owner() != 0; // initialized hub (an uninitialized impl is out of scope)
    address r = hub.router();

    hub.f(e, args);

    assert hub.router() == r,
        "INV-2 · Owner-only writes: router changes only through initialize or setRouter";
}

/// INV-2 · initialize never touches gatewayAt (mapping is owner-written only,
/// post-construction).
rule initializeNeverTouchesGatewayAt(env e, address o, address r, uint64 c)
{
    require hub.owner() == 0;             // uninitialized (fresh proxy/impl)
    address gatewayBefore = hub.gatewayAt(c);

    hub.initialize@withrevert(e, o, r);

    assert hub.gatewayAt(c) == gatewayBefore,
        "INV-2 · initialize does not write gatewayAt";
}

// ===========================================================================
// INV-3 — Anchor: roots derived from the journal, frozen forever
// ===========================================================================

/// INV-3 · Freeze: once anchoredBatches covers b, rootAt[b] never changes.
rule publishedRootsAreFrozen(env e, method f, calldataarg args, uint256 b)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    // upgradeToAndCall is filtered: its low-level delegatecall is an
    // unresolved external call in this implementation-level scene (no
    // proxy), which pessimistically havocs state — upgrade semantics are
    // pinned by test/Upgrade.t.sol instead.
    require b < hub.anchoredBatches();
    bytes32 rootBefore = hub.rootAt(b);

    hub.f(e, args);

    assert hub.rootAt(b) == rootBefore,
        "INV-3 · Freeze: a published root is written exactly once";
}

/// INV-3 · Contiguous coverage (bound half): the anchoring cursor lives
/// inside the journal at all times. start_{b+1} == end_b follows
/// structurally: `start` is always read from lastAnchoredIndex, which the
/// successful path sets to its own `end` exactly once (rule below).
/// Written as a parametric rule, not an `invariant`: invariants are assumed
/// globally (requireInvariants), so one whose induction base touches
/// unconstrained raw-storage states poisons unrelated rules with
/// "assert weak invariant in post-state" failures.
rule anchoredPrefixPreserved(env e, method f, calldataarg args)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    require hub.journalLength() < max_uint;
    require hub.lastAnchoredIndex() <= hub.journalLength();

    hub.f(e, args);

    assert hub.lastAnchoredIndex() <= hub.journalLength(),
        "INV-3 · Contiguous coverage: the cursor stays inside the journal";
}

/// INV-3 · Cursor discipline: one batch per successful call, strictly
/// forward, never past the journal; the value frozen at the fresh index is
/// the root the call derived and returned.
rule anchorAdvancesTheCursorOnce(env e)
{
    uint256 start = hub.lastAnchoredIndex();
    uint256 batches = hub.anchoredBatches();

    bytes32 root = hub.anchorNextBatch@withrevert(e);
    bool rejected = lastReverted;

    assert !rejected => hub.anchoredBatches() == batches + 1,
        "INV-3 · Exactly one index is published per successful call";
    assert !rejected => hub.lastAnchoredIndex() > start
        && hub.lastAnchoredIndex() <= hub.journalLength(),
        "INV-3 · The cursor advances strictly, never past the journal";
    assert !rejected => hub.rootAt(batches) == root,
        "INV-3 · The frozen root IS the computed (returned) root";
}

/// INV-3 · Consequence, empty-proof degeneracy (INVARIANTS.md): an empty
/// proof passes only when leaf equals the stored root — for a single-leaf
/// batch that IS journal[start]; for a multi-leaf batch or an unwritten
/// index it is vacuous and preimage-bound. Non-empty-proof membership
/// modulo keccak resistance is out of the prover's structural reach.
rule emptyProofPassesOnlyAgainstTheRoot(
    env e,
    uint256 b,
    bytes32 leaf,
    bytes32[] proof
)
{
    require proof.length == 0;

    bool ok = hub.verifyAgainstBatch@withrevert(e, b, leaf, proof);
    bool rejected = lastReverted;

    assert !rejected => (ok => leaf == hub.rootAt(b)),
        "INV-3 · Empty proof: verify passes iff leaf == rootAt[b]";
}

// ===========================================================================
// INV-4 — Provenance: every entry is signed under the hub's domain
// ===========================================================================

/// INV-4 · Structural half: the journal can only grow through the two entry
/// points that run `_submit`'s checks (digest match, low-s, EIP-712 recovery
/// against the hub domain, deadline) — everything else, views included,
/// leaves the journal untouched. Reverting attempts change nothing.
rule journalGrowsOnlyThroughSubmissions(env e, method f, calldataarg args)
    filtered {
        f -> f.selector != sig:submitArticle(bytes32,bytes,IArticleAnchor.ArticleSubmission).selector
          && f.selector != sig:ccipReceive(Client.Any2EVMMessage).selector
          && f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    uint256 lenBefore = hub.journalLength();

    hub.f(e, args);

    assert hub.journalLength() == lenBefore,
        "INV-4 · Provenance: only submitArticle / ccipReceive can journal";
}

/// INV-4 · Digest binding on the direct lane: a successful submission
/// appends exactly one entry, and that entry IS keccak256(abi.encode(payload))
/// — the value `_submit` required to equal the caller-supplied leaf before
/// the push. CVL's multi-primitive keccak256 is the hash of the ABI
/// encoding, so this matches `keccak256(abi.encode(payload))` exactly.
/// Surviving the (non-reverting) path also implies the inlined
/// `ECDSA.recover(_hashTypedData(hashStruct(payload)), sig_) == author`
/// held under the hub's domain — see header for why recovery and the
/// domain binding themselves are pinned by tests instead.
rule submissionJournalsTheSignedContent(
    env e,
    bytes32 leaf,
    bytes signature,
    IArticleAnchor.ArticleSubmission payload
)
{
    require hub.journalLength() < max_uint;   // see journalAppendOnly's note
    uint256 lenBefore = hub.journalLength();

    hub.submitArticle@withrevert(e, leaf, signature, payload);
    bool rejected = lastReverted;

    assert !rejected => hub.journalLength() == lenBefore + 1,
        "INV-4 · One entry per accepted submission";
    assert !rejected => hub.journal(lenBefore) == leaf,
        "INV-4 · The journaled value is the caller-supplied leaf";
    assert !rejected => leaf == keccak256(
        payload.author,
        payload.titleHash,
        payload.bodyHash,
        payload.cidHash,
        payload.uuid,
        payload.timestamp,
        payload.deadline
    ),
        "INV-4 · Digest binding: the journaled leaf IS the signed payload";
}
