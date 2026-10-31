// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IHubGetters — the hub's read API, declared in exactly ONE place.
/// @notice The 14 field getters over the hub's ERC-7201 namespace. Two
/// contracts expose them and neither redeclares a single one:
/// `IArticleAnchor is IHubGetters` (the hub's own interface still reaches its
/// full ABI) and `IHubStorageReader is IHubGetters` (the per-chain facade), so
/// `admin()` exists once as a declaration no matter where you read it from.
///
/// @dev Their bodies are necessarily different, and that is the whole point of
/// splitting them: `HubGetters` reads the namespace directly (an `sload` in the
/// account that owns it — the hub), while `HubStorageReader` `staticcall`s the
/// hub it was bound to, because the EVM has no opcode for reading ANOTHER
/// account's storage. The facade therefore cannot reuse the hub's bodies, but
/// it reuses these declarations — which is what keeps the two in lockstep: each
/// body is checked by the compiler against this file, so a signature change
/// breaks the build on both sides at once.
interface IHubGetters {
    /// @notice The only key allowed to upgrade the implementation and to wire
    /// the gateway. Set once (constructor / `initialize`) and never transferable
    /// — deploy with a multisig or timelock from day one.
    function admin() external view returns (address);

    /// @notice Chainlink Router used for both CCIP lanes; also the gate that
    /// must be `msg.sender` for any inbound delivery.
    function router() external view returns (address);

    /// @notice Chainlink chain selector of the opposite side (not a chain id).
    function ethChainSelector() external view returns (uint64);

    /// @notice The pinned L1 `SubmissionGateway`: sender whitelist for inbound
    /// submissions and receiver of notarized roots. Wired post-deploy.
    function gateway() external view returns (address);

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

    /// @notice Block at which batch `batchIndex` was anchored — the notary's
    /// `K`-confirmation clock starts here.
    /// @param batchIndex Anchored batch index.
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256);

    /// @notice Number of batches anchored so far (also the next batch index).
    function anchoredBatches() external view returns (uint256);
}
