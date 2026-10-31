// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "./IArticleAnchor.sol";

/// @title SubmissionGateway — the L1 endpoint (paid entry lane, headless).
/// @notice Public ABI of the gateway, implemented by
/// `src/SubmissionGateway.sol` (which inherits this interface, so the compiler
/// keeps ABI and docs in lockstep). One role only:
///
/// 1. Paid entry lane: `submitArticle` mirrors the hub's API plus `payable` —
/// the caller funds L1 execution + the CCIP fee for the L2 leg, and one
/// Ethereum transaction lands the payload in the hub's journal. Deliberately
/// performs NO signature checks (decision 1a): EIP-712 domains are
/// chain-bound, so the hub is the single signature authority — garbage
/// messages are priced by the attached fee instead of rejected by ecrecover.
///
/// @dev CCIP travels one direction only: this contract SENDS on Ethereum and
/// the hub RECEIVES on its chain. The gateway holds no storage — the payload
/// is forwarded byte-identical and every judgement happens at the destination.
interface ISubmissionGateway {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A paid submission was forwarded toward the hub.
    /// @param submitter The gas + fee payer (the transaction is theirs).
    /// @param messageId Chainlink's message id for the hop.
    event SubmittedOnL1(address indexed submitter, bytes32 indexed leafDigest, bytes32 messageId);

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
    function submitArticle(bytes32 leafDigest, bytes calldata sig, IArticleAnchor.ArticleSubmission calldata payload)
        external
        payable;

    // ---------------------------------------------------------------------
    // Views — configuration
    // ---------------------------------------------------------------------

    /// @notice Chainlink Router on Ethereum (immutable — no lane retargeting).
    function ROUTER() external view returns (address);

    /// @notice The `ArticleAnchor` proxy on the hub chain: receiver of the
    /// paid lane.
    function HUB() external view returns (address);

    /// @notice Chainlink chain selector of the hub chain (not a chain id).
    function BASE_CHAIN_SELECTOR() external view returns (uint64);
}
