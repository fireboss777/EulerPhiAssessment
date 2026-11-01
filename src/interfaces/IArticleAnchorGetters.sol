// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IArticleAnchorGetters — the hub's read API, declared in exactly ONE place.
/// @notice The 11 field getters over the hub's ERC-7201 namespace. Declared
/// here, implemented once in `ArticleAnchorGetters`, which `ArticleAnchor`
/// inherits — so each getter is a declaration in exactly ONE file and code in
/// exactly ONE contract, with nothing anywhere else holding a copy.
///
/// @dev Direct reads: every body is an `sload` in the account that owns the
/// namespace — the only account that CAN read it, since the EVM has no opcode
/// for another account's storage. That is also why there is no separate reader
/// contract: a facade could only `staticcall` this contract back, adding a
/// second copy of every function for nothing. The declarations are what keep
/// the implementations honest — each body is checked by the compiler against
/// this file, so a signature change breaks the build.
interface IArticleAnchorGetters {
    /// @notice Chainlink Router of the CCIP lane; also the gate that
    /// must be `msg.sender` for any inbound delivery.
    function router() external view returns (address);

    /// @notice The gateway registered for source chain `chainSelector` — the only
    /// sender accepted from it. 0 = chain not authorized (or revoked).
    /// @param chainSelector Chainlink selector of the source chain.
    function gatewayAt(uint64 chainSelector) external view returns (address);

    /// @notice Leaf `i` of the append-only journal (`keccak256(abi.encode(payload))`).
    /// @param i Journal index, `0 <= i < journalLength()`.
    function journal(uint256 i) external view returns (bytes32);

    /// @notice Total leaves journaled, anchored or not.
    function journalLength() external view returns (uint256);

    /// @notice Leaves journaled since the last anchored batch.
    function pendingLeaves() external view returns (uint256);

    /// @notice Dedup key is (author, uuid): an attacker must not be able to
    /// squat a victim's predictable uuid with a payload of their own.
    /// @param author The byline.
    /// @param uuid The dedup key.
    function usedUuid(address author, bytes32 uuid) external view returns (bool);

    /// @notice Timestamp of an author's last accepted submission (rate limit).
    /// @param author The byline.
    function lastSubmit(address author) external view returns (uint256);

    /// @notice When the current open batch window started (drives the deadline).
    function batchOpenedAt() external view returns (uint256);

    /// @notice Journal end offset of the last anchored batch — anchors freeze
    /// `[lastAnchoredIndex, end)`; later appends land in the next window.
    function lastAnchoredIndex() external view returns (uint256);

    /// @notice Frozen Merkle root of batch `batchIndex`, derived by the contract.
    /// @param batchIndex Anchored batch index.
    function rootAt(uint256 batchIndex) external view returns (bytes32);

    /// @notice Number of batches anchored so far (also the next batch index).
    function anchoredBatches() external view returns (uint256);
}
