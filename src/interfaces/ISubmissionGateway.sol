// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleSubmission } from "../libraries/ArticleLib.sol";
import { Client } from "./Client.sol";

/// @title SubmissionGateway — the L1 endpoint (two roles, both pinned).
/// @notice Public ABI of the gateway, implemented by
/// `src/SubmissionGateway.sol` (which inherits this interface, so the compiler
/// keeps ABI and docs in lockstep). The two state reads live in
/// `ISubmissionGatewayGetters`, brought in through `SubmissionGatewayGetters`
/// — declared once, implemented once, never copied.
///
/// 1. Paid entry lane: `submitArticle` mirrors the hub's API plus `payable` —
/// the caller funds L1 execution + the CCIP fee for the L2 leg, and one
/// Ethereum transaction lands the payload in the hub's journal. Deliberately
/// performs NO signature checks (decision 1a): EIP-712 domains are
/// chain-bound, so the hub is the single signature authority — garbage
/// messages are priced by the attached fee instead of rejected by ecrecover.
///
/// 2. Notary receiver: roots notarized upward by the hub arrive via CCIP,
/// pinned to (ROUTER, BASE_CHAIN_SELECTOR, HUB) and applied strictly in batch
/// order — the audit-grade "original tree" record on Ethereum.
///
/// @dev The hub encodes its CCIP payload with `abi.encodeCall` against
/// `ISubmissionGateway.receiveRoot.selector` and this side checks length +
/// selector before decoding, so neither contract needs to import the other's
/// source while the wire format stays pinned on both ends. The gateway also
/// satisfies Chainlink's `IAny2EVMMessageReceiver` for the standard entry.
interface ISubmissionGateway {
    /// @notice The gateway's entire persistent state, in a single ERC-7201
    /// namespace — same rule as the hub: the implementation declares no state
    /// variable, everything lives here at
    /// `keccak256(abi.encode(uint256(keccak256("eulerphi.storage.SubmissionGateway")) - 1)) & ~bytes32(uint256(0xff))`
    /// (frozen literal in `SubmissionGateway`, proven by
    /// `test_storageLivesAtErc7201Slot`). Only this cursor and the root record
    /// are state: `ROUTER`, `HUB` and `BASE_CHAIN_SELECTOR` are `immutable`
    /// (bytecode) and `SUBMIT_GAS_LIMIT` is `constant`.
    ///
    /// @custom:storage-location erc7201:eulerphi.storage.SubmissionGateway
    struct Storage {
        /// @dev Slot 0.
        uint256 nextBatch;
        /// @dev Slot 1 — mapping base; value at `keccak256(abi.encode(uint256(batchIndex), baseSlot))`.
        mapping(uint256 => bytes32) notarizedRoot;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A paid submission was forwarded toward the hub.
    /// @param submitter The gas + fee payer (the transaction is theirs).
    /// @param messageId Chainlink's message id for the hop.
    event SubmittedOnL1(address indexed submitter, bytes32 indexed leafDigest, bytes32 messageId);

    /// @notice A notarized root was accepted and the cursor advanced.
    event RootNotarized(uint256 indexed batchIndex, bytes32 root);

    // ---------------------------------------------------------------------
    // Errors (thrown by the implementation; declared here so the ABI and the
    // docs of every failure mode live with the API they belong to)
    // ---------------------------------------------------------------------

    /// @notice The payload's `deadline` is already in the past.
    error Expired();
    /// @notice `leafDigest` is not `keccak256(abi.encode(payload))`.
    error DigestMismatch();
    /// @notice `msg.value` is below the router's quote.
    error InsufficientFee();
    /// @notice The excess-refund transfer to the caller failed; the whole
    /// submission reverts (nothing is sent, the caller keeps their funds).
    error RefundFailed();
    /// @notice Caller is not the pinned router (`receiveRoot` gate).
    error NotRouter();
    /// @notice Root arrived from a chain other than the pinned selector.
    error BadChain();
    /// @notice Root arrived from a sender other than the pinned hub.
    error BadSender();
    /// @notice Notary payload is not exactly 68 bytes.
    error BadPayloadLength();
    /// @notice Notary payload does not carry the `receiveRoot` selector.
    error BadSelector();
    /// @notice `batchIndex != nextBatch` — skips, reorders and replays die here.
    error OutOfOrder();

    // ---------------------------------------------------------------------
    // Paid entry lane: Ethereum -> hub
    // ---------------------------------------------------------------------

    /// @notice One L1 transaction that lands a signed payload in the hub's journal.
    /// @dev Checks only chain-agnostic state before any fee moves (`deadline`,
    /// digest) and no signature — see decision 1a above. Quotes the CCIP fee,
    /// forwards exactly `fee`, refunds the excess (the upstream router keeps
    /// overpayment; this contract retains nothing). A payload the hub will
    /// still reject (rate-limited, duplicate uuid) passes here and spends the
    /// fee, so callers should pre-check `lastSubmit`/`usedUuid` off-chain.
    /// @param leafDigest The commitment that will be journaled.
    /// @param sig EIP-712 signature over `ArticleSubmission`, forwarded byte-identical.
    /// @param payload The typed article envelope (hashes only — content stays off-chain).
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload) external payable;

    // ---------------------------------------------------------------------
    // Notary receiver: hub -> gateway (roots land here)
    // ---------------------------------------------------------------------

    /// @notice Standard router entry — context-gates (chain + sender), then applies.
    function ccipReceive(Client.Any2EVMMessage calldata message) external;

    /// @notice Applies a notarized root. Router-gated (any direct caller fails
    /// the `not router` check — msg.sender survives the ccipReceive hop) and
    /// strictly sequential: `batchIndex` must equal `nextBatch`.
    /// @dev Payload layout is fixed at 68 bytes = 4-byte `receiveRoot` selector
    /// + the two encoded words; anything else is rejected before decoding so it
    /// can never be reinterpreted as `(batchIndex, root)`. Verified end-to-end
    /// by `test_notarizeRoundTripIntoGateway` (hub encode -> gateway decode).
    /// @param batchIndex Must equal `nextBatch` (0, 1, 2 … in arrival order).
    /// @param root The frozen hub root for that batch.
    function receiveRoot(uint256 batchIndex, bytes32 root) external;

    // ---------------------------------------------------------------------
    // Views — configuration & record
    // ---------------------------------------------------------------------

    /// @notice Hub-side calldata for a journaled submission is small; 400k
    /// covers digest+sig checks + journal SSTORE with generous headroom.
    function SUBMIT_GAS_LIMIT() external view returns (uint256);

    /// @notice Chainlink Router on Ethereum (immutable — no lane retargeting).
    function ROUTER() external view returns (address);

    /// @notice The `ArticleAnchor` proxy on the hub chain: receiver of the
    /// paid lane and the only whitelisted sender of notarized roots.
    function HUB() external view returns (address);

    /// @notice Chainlink chain selector of the hub chain (not a chain id).
    function BASE_CHAIN_SELECTOR() external view returns (uint64);
}
