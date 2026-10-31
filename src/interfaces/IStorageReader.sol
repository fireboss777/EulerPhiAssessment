// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title StorageReader — a read-only facade over this project's ERC-7201 namespaces.
/// @notice Why it exists: a hub or gateway `Storage` struct CANNOT be returned
/// from an external function — solc 4103, "Types containing (nested) mappings
/// can only be parameters or return variables of internal or library
/// functions". Half of both namespaces is mappings, so the state is exposed
/// the only way the compiler allows: one getter per field, plus a scalar-only
/// `Snapshot` per namespace for the "everything in one call" case.
///
/// The reader is bound at deployment (`hubTarget_`, `gatewayTarget_`), is
/// stateless apart from those two `immutable`s, and performs no writes — it is
/// safe to hand to a UI or a script that only needs to look.
///
/// @dev Every getter is a typed `staticcall` into the bound target's own
/// getters — and that is not a shortcut, it is the ONLY on-chain option: the
/// EVM has no opcode to read ANOTHER account's storage (`sload` reads strictly
/// the running account), so a "raw slot reader" would read its own empty
/// storage. (This project built exactly that by mistake first; the cross-check
/// tests returned zeros and caught it.) Reading foreign slots directly is an
/// off-chain capability — `cast`, `eth_getStorageAt`, `vm.load` — not an
/// on-chain one. Because the calls are typed against `IArticleAnchor` and
/// `ISubmissionGateway`, the compiler keeps this facade in lockstep with the
/// layouts: no offset or key derivation is recopied here, so none can drift.
interface IStorageReader {
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

    /// @notice Every non-mapping member of the gateway namespace, in one call.
    /// @dev The gateway's other member, `notarizedRoot`, is a mapping — read it
    /// through `notarizedRoot(uint256)`. Its `router`, `hub` and
    /// `baseChainSelector` are `immutable` (bytecode, not namespace state), so
    /// they are deliberately absent.
    struct GatewaySnapshot {
        uint256 nextBatch;
    }

    /// @notice A bound target was passed as `address(0)`.
    error ZeroTarget();

    /// @notice The hub proxy this reader was bound to.
    function hubTarget() external view returns (address);

    /// @notice The gateway this reader was bound to.
    function gatewayTarget() external view returns (address);

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

    // ---------------------------------------------------------------------
    // Gateway namespace (`eulerphi.storage.SubmissionGateway`) — field getters
    // ---------------------------------------------------------------------

    /// @notice Next batch index acceptable by the notary receiver. See `ISubmissionGateway.nextBatch`.
    function nextBatch() external view returns (uint256);

    /// @notice Notarized root of a batch as recorded on Ethereum.
    /// @param batchIndex Batch index, `batchIndex < nextBatch()`.
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32);

    /// @notice The whole scalar state of the gateway namespace in one call.
    function gatewaySnapshot() external view returns (GatewaySnapshot memory);
}
