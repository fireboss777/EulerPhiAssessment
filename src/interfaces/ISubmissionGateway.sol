// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "./IArticleAnchor.sol";

/// @title SubmissionGateway — the L1 endpoint (paid entry lane, UUPS proxy).
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
/// the hub RECEIVES on its chain; every judgement happens at the destination.
/// The gateway is proxied like the hub (OZ `ERC1967Proxy` + UUPS): its whole
/// configuration lives in the ERC-7201 `Storage` struct below, so an upgrade
/// never changes the address the hub pins. Its four reads live on
/// `ISubmissionGatewayGetters` — declared once, implemented once.
interface ISubmissionGateway {
    /// @notice The gateway's entire persistent state, in a single ERC-7201
    /// namespace — same rule as the hub: the implementation declares no state
    /// variable, everything lives here at
    /// `keccak256(abi.encode(uint256(keccak256("eulerphi.storage.SubmissionGateway")) - 1)) & ~bytes32(uint256(0xff))`
    /// (frozen as `GatewayLib.STORAGE_SLOT`, proven by
    /// `test_storageLivesAtErc7201Slot`). Configuration only — the fee-lane
    /// policy (`SUBMIT_GAS_LIMIT`) lives in `GatewayLib`, and the three reads
    /// live on `ISubmissionGatewayGetters`.
    ///
    /// @custom:storage-location erc7201:eulerphi.storage.SubmissionGateway
    struct Storage {
        /// @dev Slot 0, bytes 0..20.
        address router;
        /// @dev Slot 0, bytes 20..28 — packs with `router` (20 + 8 <= 32): this
        /// pairing is NEW with this layout (the pre-proxy gateway held no
        /// storage at all) and exists because `submitArticle` reads both, so
        /// they share one cold word.
        uint64 baseChainSelector;
        /// @dev Slot 1.
        address hub;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A paid submission was forwarded toward the hub.
    /// @param submitter The gas + fee payer (the transaction is theirs).
    /// @param messageId Chainlink's message id for the hop.
    event SubmittedOnL1(address indexed submitter, bytes32 indexed leafDigest, bytes32 messageId);

    // ---------------------------------------------------------------------
    // Errors (thrown by the implementation; declared here so the ABI and the
    // docs of every failure mode live with the API they belong to. Access
    // control — `OwnableUnauthorizedAccount`, `OwnableInvalidOwner` — is
    // declared by OZ's `OwnableUpgradeable`, never redeclared here.)
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
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Proxy initializer — constructors don't run behind ERC1967
    /// proxies, so configuration lands here instead, passed as the proxy's
    /// constructor `_data` (OZ docs: initialize as early as possible). Guarded
    /// by OpenZeppelin's `initializer` modifier: at most once per proxy, and
    /// the bare implementation is locked forever by `_disableInitializers()`
    /// in its own constructor, so no stranger can ever own it.
    /// @dev Reverts `Initializable.InvalidInitialization()` on a second call,
    /// and OZ's `OwnableInvalidOwner(address(0))` on `initialOwner = address(0)`
    /// (the zero check lives in `__Ownable_init`).
    function initialize(address initialOwner, address router_, address hub_, uint64 baseChainSelector_) external;

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
}
