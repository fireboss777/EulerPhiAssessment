//
// * CVL specifications for the source-chain gateway (SubmissionGateway) —
// * INVARIANTS.md predicates GW-1..GW-3, the gateway-side companion of the
// * hub's INV-1..INV-4 transcription (ArticleAnchor.spec).
// *
// * Harness assumptions:
// *  - Scene: SubmissionGateway + test/mocks/MockRouter (the router double)
// *    + certora/harness/GatewayCodec.sol (the abi encoder CVL lacks).
// *    Implementation-level, like the hub: production runs behind the
// *    ERC1967 proxy; proxy-specific pinning lives in test/Upgrade.t.sol.
// *  - Every rule pins `gw.router() == rt`: an un-pinned router makes
// *    getFee an unresolved external call, which pessimistically havocs
// *    state (the hub run's standing lesson — pin what you call).
// *  - Revert semantics: CVL ignores reverting paths by default (@norevert),
// *    so plain calls below only constrain successful executions; rejection
// *    rules use @withrevert and capture `lastReverted` into a local
// *    IMMEDIATELY (any later call would overwrite the flag).
// *  - The excess refund is a low-level `call{value}("")` (0-length calldata)
// *    to msg.sender. forwardsFaithfully pins `msg.sender == codec` (in-scene,
// *    receive() attached) and the conf sets `optimistic_fallback` — without
// *    both, the AUTO summary on that call havocs state INCLUDING GHOST
// *    WRITES (run-41 trace: summary wrote gDest=5, assert read back 6).
// *
// * Prover-run notes (not observable at lint time):
// *  - CVL has no abi.encode. The digest gate is CVL's multi-primitive
// *    keccak256 over the payload's seven STATIC fields — the hash of the ABI
// *    encoding of the tuple, which for a static struct IS the encoding of
// *    the struct; equivalence with Solidity's keccak256(abi.encode(payload))
// *    is the same form the green hub run verified in
// *    submissionJournalsTheSignedContent. The forwarded `data` field is
// *    mixed static/dynamic `(bytes32, bytes, struct)`, so it is checked by
// *    keccak congruence against GatewayCodec.encodeData — hash equality is
// *    taken as byte equality (collision resistance, the assumption INV-3
// *    already rests on); no injectivity axiom is needed in that direction.
// *  - ccipSend is handled by an expression-summary bridge that records the
// *    call's boundary facts into ghosts (see the bridge's doc). Twelve runs
// *    of attempts to execute MockRouter's code through the summary
// *    (DISPATCHER, re-issued CVL calls, no-ETH twins, fresh envs) all made
// *    every execution unreachable — the summary arguments already ARE the
// *    GW-1 facts, so the property is pinned at the boundary instead.
// *    MockRouter remains the scene's fee oracle (getFee, DISPATCHER) and
// *    its capture behavior is Foundry's concern (Gateway.t.sol).
// *  - `signature.length <= 128` bounds the harness's calldata-copy loop inside
// *    loop_iter; canonical EIP-712 signatures are 65 bytes (64 compact), so
// *    the bound covers every honest input.
// *  - Conf flags and why: `hashing_length_bound = 448` (the bridge hashes
// *    data up to 320+128 bytes; the default 224 silently killed every path
// *    containing the summary), `loop_iter = 20` (calldata/storage copies of
// *    that data exceed 4), `optimistic_fallback` (refund call — see above),
// *    plus the hub's `optimistic_loop` / `optimistic_hashing`.
// *

using SubmissionGateway as gw;
using MockRouter as rt;
using GatewayCodec as codec;

// GW-1 boundary observables: the expression-summary bridge records what the
// gateway ATTACHED to its outbound ccipSend call — the four facts GW-1 pins
// (destination, receiver encoding, paid value, data bytes). Ghosts, because
// CVL cannot re-encode a dynamic struct into calldata reliably; the summary
// arguments ARE the call-site facts, so no re-encoding is ever needed.
ghost uint64 gDest {
    init_state axiom gDest == 0;
}
ghost uint256 gPaid {
    init_state axiom gPaid == 0;
}
ghost bytes32 gReceiverHash {
    init_state axiom gReceiverHash == to_bytes32(0);
}
ghost bytes32 gDataHash {
    init_state axiom gDataHash == to_bytes32(0);
}

methods {
    function router() external returns (address) envfree;
    function hub() external returns (address) envfree;
    function baseChainSelector() external returns (uint64) envfree;
    // MockRouter fee oracle (the in-scene router double)
    function MockRouter.fee() external returns (uint256) envfree;
    // The scene codec (the pure abi encoder CVL lacks)
    function GatewayCodec.encodeData(bytes32,bytes,IArticleAnchor.ArticleSubmission) external returns (bytes32) envfree;
    function GatewayCodec.enc(address) external returns (bytes32) envfree;
    // getFee: the router config lives in an ERC-7201 library slot, not in a
    // declared Solidity field, so there is nothing for `link` to connect —
    // resolution goes through DISPATCHER. The ONLY scene implementer is
    // MockRouter, which every rule pins via `gw.router() == rt`, so the
    // dispatcher's alternative set coincides with the pinned reality (run 4:
    // unresolved -> AUTO summary: NONDET getFee return).
    function _.getFee(uint64,Client.EVM2AnyMessage) external => DISPATCHER(true);
    // ccipSend: boundary-recording expression summary (see bridge below).
    function _.ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage message)
        external with(env e)
        => forwardCcipToMock(e, destinationChainSelector, message)
        expect bytes32;
}

/// Bridge: record the outbound call's boundary facts into ghosts and return
/// a placeholder message id. No inner call is re-issued: re-encoding the
/// dynamic struct (or re-transferring its value) through a summary killed
/// every execution across runs 24-33; the summary ARGUMENTS already ARE the
/// facts GW-1 states, so the property is pinned at the boundary itself.
/// MockRouter stays the scene's fee oracle (getFee); its recording behavior
/// is Foundry's concern (Gateway.t.sol).
function forwardCcipToMock(env e, uint64 dest, Client.EVM2AnyMessage m) returns bytes32 {
    // Length bounds before hashing (the hub run's hashing_length_bound lesson):
    // the gateway always encodes the receiver as abi.encode(address) = 32
    // bytes, and data is leaf(32)+offset(32)+payload(224)+sigLen(32)+sig — with
    // signature <= 128 (canonical 65-byte sigs are covered) it never exceeds
    // 448 bytes. The bound keeps keccak256's input within the prover's hashing
    // bound instead of a nondet-length input.
    require m.receiver.length == 32;
    require m.data.length <= 448;
    gDest = dest;
    gPaid = e.msg.value;
    gReceiverHash = keccak256(m.receiver);
    gDataHash = keccak256(m.data);
    return to_bytes32(0);
}

/// GW-2 · shared digest vocabulary: keccak256(abi.encode(payload)) via the
/// seven static fields (see header). `leaf == payloadDigest(payload)` is the
/// gateway's own DigestMismatch precondition, restated for its gates.
function payloadDigest(IArticleAnchor.ArticleSubmission p) returns bytes32 {
    return keccak256(
        p.author,
        p.titleHash,
        p.bodyHash,
        p.cidHash,
        p.uuid,
        p.timestamp,
        p.deadline
    );
}

// ===========================================================================
// GW-1 — Faithful forwarding: bytes, fee, destination
// ===========================================================================

/// GW-1 · Faithful forwarding + value honesty: a successful submission
/// dispatches exactly the configured destination, a receiver that is
/// abi.encode(configured hub), the quoted fee as call value, and the
/// byte-identical data triple (recorded at the call boundary by the
/// expression-summary bridge — see its doc) — while the gateway keeps none
/// of msg.value and the caller nets exactly one fee (excess refunded: real
/// transfers, asserted below).
rule forwardsFaithfully(
    env e,
    bytes32 leaf,
    bytes signature,
    IArticleAnchor.ArticleSubmission payload
)
{
    // Scene pins + initialized configuration.
    require gw.router() == rt;
    require gw.hub() != 0;

    // The other gates pass: fresh deadline, well-formed digest, fee covered.
    require e.block.timestamp <= payload.deadline;
    require leaf == payloadDigest(payload);
    require e.msg.value >= rt.fee();

    // The refund target is pinned IN-scene: codec has known code and a
    // receive(), so the excess-refund call RESOLVES instead of AUTO-havocing
    // state (including ghost writes — the run-39 artifact).
    require e.msg.sender == codec;
    // Bound the harness's calldata-copy loop (canonical sigs are 65 bytes).
    require signature.length <= 128;
    // Reachability precondition: raw harness balances are unconstrained
    // uint256 words — run 6's counterexample held MockRouter at
    // 2^256-19120, so the fee's inbound credit overflows the transfer
    // arithmetic and EVERY execution reverts (the same artifact class as
    // journalLength = 2^256-1 in the hub run). 2^128 wei (~3.4e19 ETH) is
    // orders of magnitude above total supply — only physically reachable
    // balances pass; transfers below it can never overflow.
    require nativeBalances[gw] < 2^128;
    require nativeBalances[rt] < 2^128;
    require nativeBalances[e.msg.sender] < 2^128;

    uint256 feeNow = rt.fee();
    uint256 gatewayBefore = nativeBalances[gw];
    uint256 senderBefore = nativeBalances[e.msg.sender];

    gw.submitArticle(e, leaf, signature, payload);

    assert gDest == gw.baseChainSelector(),
        "GW-1 · destination is the configured baseChainSelector";
    assert gReceiverHash == codec.enc(gw.hub()),
        "GW-1 · receiver is the configured hub (keccak congruence)";
    assert gPaid == feeNow,
        "GW-1 · exactly the quoted fee is forwarded";
    assert gDataHash == codec.encodeData(leaf, signature, payload),
        "GW-1 · data byte-identical in transit (keccak congruence)";
    assert nativeBalances[gw] == gatewayBefore,
        "GW-1 · the gateway retains nothing of msg.value";
    assert nativeBalances[e.msg.sender] == senderBefore - feeNow,
        "GW-1 · the caller is charged exactly the fee (excess refunded)";
}

// ===========================================================================
// GW-2 — Fail-closed before any fee moves
// ===========================================================================

/// GW-2 · Deadline gate: an expired payload never dispatches — the router
/// quote is never even asked for.
rule expiredSubmissionsFailClosed(
    env e,
    bytes32 leaf,
    bytes signature,
    IArticleAnchor.ArticleSubmission payload
)
{
    require gw.router() == rt;
    require e.block.timestamp > payload.deadline;

    gw.submitArticle@withrevert(e, leaf, signature, payload);
    bool rejected = lastReverted;

    assert rejected, "GW-2 · expired deadline rejects the submission (Expired)";
}

/// GW-2 · Digest gate: a leaf that is not keccak256(abi.encode(payload))
/// never dispatches — the gateway forwards commitments, it does not mint
/// them.
rule digestMismatchFailsClosed(
    env e,
    bytes32 leaf,
    bytes signature,
    IArticleAnchor.ArticleSubmission payload
)
{
    require gw.router() == rt;
    require e.block.timestamp <= payload.deadline;
    require leaf != payloadDigest(payload);

    gw.submitArticle@withrevert(e, leaf, signature, payload);
    bool rejected = lastReverted;

    assert rejected, "GW-2 · digest mismatch rejects the submission (DigestMismatch)";
}

/// GW-2 · Fee gate: a shortfall never dispatches. Content, not just effect:
/// MockRouter.ccipSend only requires the VALUE ATTACHED to the call, which
/// the gateway would fund from its own balance if this gate were absent — so
/// a counterexample here would be a real subsidy bug, not a mock artifact.
rule underpaymentFailsClosed(
    env e,
    bytes32 leaf,
    bytes signature,
    IArticleAnchor.ArticleSubmission payload
)
{
    require gw.router() == rt;
    require e.block.timestamp <= payload.deadline;
    require leaf == payloadDigest(payload);
    require e.msg.value < rt.fee();

    gw.submitArticle@withrevert(e, leaf, signature, payload);
    bool rejected = lastReverted;

    assert rejected, "GW-2 · underpayment rejects the submission (InsufficientFee)";
}

// ===========================================================================
// GW-3 — Configuration written only by initialize
// ===========================================================================

/// GW-3 · The ERC-7201 configuration (router, hub, baseChainSelector) is
/// written only by initialize: every other entry point — submitArticle, the
/// OZ ownership surface, views — leaves it untouched. `initialize` is
/// filtered as the sole legitimate writer; `upgradeToAndCall` is filtered
/// because its low-level delegatecall is an unresolved external call in this
/// implementation-level scene (no proxy), which pessimistically havocs state
/// — upgrade semantics are pinned by test_gatewayConfigPreservedAcrossUpgrade
/// in test/Upgrade.t.sol instead.
rule configurationWrittenOnlyByInitialize(
    env e,
    method f,
    calldataarg args
)
    filtered {
        f -> f.selector != sig:initialize(address,address,address,uint64).selector
          && f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    // Pin the configured router to the in-scene double so submitArticle's
    // getFee dispatches to MockRouter and ccipSend hits the recording bridge
    // (rule holds for initialized gateways; an uninitialized one only has
    // reverting paths — call to address(0) — which @norevert ignores).
    require gw.router() == rt;
    // Keep the refund target outside the scene (see header).
    require e.msg.sender != gw && e.msg.sender != rt && e.msg.sender != codec;
    // Same reachability bounds as forwardsFaithfully (submitArticle's value
    // transfers must not overflow raw-harness balances or the instance has
    // no completing execution).
    require nativeBalances[gw] < 2^128;
    require nativeBalances[rt] < 2^128;
    require nativeBalances[e.msg.sender] < 2^128;

    address r = gw.router();
    address h = gw.hub();
    uint64 s = gw.baseChainSelector();

    gw.f(e, args);

    assert gw.router() == r && gw.hub() == h && gw.baseChainSelector() == s,
        "GW-3 · router, hub and baseChainSelector change only through initialize";
}


