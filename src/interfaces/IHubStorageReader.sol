// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IHubStorageReader — read-only facade over the hub's ERC-7201 namespace.
/// @notice Why it exists: the hub's `Storage` struct CANNOT be returned from an
/// external function — solc 4103, "Types containing (nested) mappings can only
/// be parameters or return variables of internal or library functions". Half of
/// that namespace is mappings, so its state is exposed the only way the
/// compiler allows: one getter per field, plus a scalar-only `HubSnapshot` for
/// the "everything in one call" case.
///
/// @dev ONE TARGET, ONE CHAIN: the hub runs on its own chain, so this reader
/// must be deployed on that same chain — a contract can only call addresses
/// that exist where it runs. The gateway's state is exposed by its own reader
/// (`IGatewayStorageReader`), deployed on the gateway's chain; no contract ever
/// spans the two.
///
/// @dev Each getter is a typed `staticcall` into the bound target's own
/// getters, and that is the ONLY on-chain option: the EVM has no opcode to read
/// ANOTHER account's storage (`sload` reads strictly the running account), so a
/// "raw slot reader" would read its own empty storage — a design this project
/// built by mistake first and whose cross-check tests caught by returning
/// zeros. Reading foreign slots directly is an off-chain capability — `cast`,
/// `eth_getStorageAt`, `vm.load` — not an on-chain one. Because the calls are
/// typed against `IArticleAnchor`, the compiler keeps this facade in lockstep
/// with the layout: no offset or key derivation is recopied here, so none can
/// drift.
interface IHubStorageReader {
    /// @notice Every non-mapping member of the hub namespace, in one call.
    /// @dev Members that cannot ride along: the mappings (`usedUuid`,
    /// `lastSubmit`, `rootAt`, `anchoredAtBlock` — solc 4103) and the bulk
    /// `journal` array (unbounded payload; its length is here, its leaves come
    /// from `journal(uint256)`).
    struct HubSnapshot {
        address admin;
        address router;
        uint64 ethChainSelector;
        address gateway;
        uint256 batchOpenedAt;
        uint256 lastAnchoredIndex;
        uint256 anchoredBatches;
        uint256 journalLength;
        uint256 pendingLeaves;
    }

    /// @notice The bound target was passed as `address(0)`.
    error ZeroTarget();

    /// @notice The hub proxy this reader was bound to.
    function hubTarget() external view returns (address);

    // ---------------------------------------------------------------------
    // Hub namespace (`eulerphi.storage.ArticleAnchor`) — field getters
    // ---------------------------------------------------------------------

    /// @notice The hub's only upgrade/wiring authority. See `IArticleAnchor.admin`.
    function admin() external view returns (address);

    /// @notice The hub's pinned CCIP router. See `IArticleAnchor.router`.
    function router() external view returns (address);

    /// @notice The hub's pinned chain selector. See `IArticleAnchor.ethChainSelector`.
    function ethChainSelector() external view returns (uint64);

    /// @notice The hub's pinned L1 gateway. See `IArticleAnchor.gateway`.
    function gateway() external view returns (address);

    /// @notice When the open batch window started. See `IArticleAnchor.batchOpenedAt`.
    function batchOpenedAt() external view returns (uint256);

    /// @notice Journal offset of the last anchored batch. See `IArticleAnchor.lastAnchoredIndex`.
    function lastAnchoredIndex() external view returns (uint256);

    /// @notice Batches anchored so far. See `IArticleAnchor.anchoredBatches`.
    function anchoredBatches() external view returns (uint256);

    /// @notice Journal length (leaves anchored or not). See `IArticleAnchor.journalLength`.
    function journalLength() external view returns (uint256);

    /// @notice Leaves journaled since the last anchored batch. See `IArticleAnchor.pendingLeaves`.
    function pendingLeaves() external view returns (uint256);

    /// @notice Leaf `i` of the append-only journal.
    /// @param i Journal index, `0 <= i < journalLength()`.
    function journal(uint256 i) external view returns (bytes32);

    /// @notice Whether `(author, uuid)` has been published.
    /// @param author The byline.
    /// @param uuid The dedup key.
    function usedUuid(address author, bytes32 uuid) external view returns (bool);

    /// @notice Timestamp of an author's last accepted submission.
    /// @param author The byline.
    function lastSubmit(address author) external view returns (uint256);

    /// @notice Frozen Merkle root of a batch.
    /// @param batchIndex Anchored batch index.
    function rootAt(uint256 batchIndex) external view returns (bytes32);

    /// @notice Block at which a batch was anchored (the notary's K-clock origin).
    /// @param batchIndex Anchored batch index.
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256);

    /// @notice The whole scalar state of the hub namespace in one call.
    function hubSnapshot() external view returns (HubSnapshot memory);
}
