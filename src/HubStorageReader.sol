// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IArticleAnchor} from "./interfaces/IArticleAnchor.sol";
import {IHubGetters} from "./interfaces/IHubGetters.sol";
import {IHubStorageReader} from "./interfaces/IHubStorageReader.sol";

/// @title HubStorageReader — read-only facade over the hub's ERC-7201 namespace.
/// @notice See `IHubStorageReader` for the API, for why it exists (a `Storage`
/// struct holds mappings, so it cannot be returned — solc 4103) and for the
/// one-target-one-chain rule.
/// @dev Stateless: one `immutable` target, zero storage variables, so it needs
/// no namespace of its own. Every getter is a typed `staticcall` into the
/// hub's own getters, which the compiler checks against `IArticleAnchor` — this
/// file cannot drift from the layout it mirrors, and it reads only what lives
/// on ITS chain.
contract HubStorageReader is IHubStorageReader {
    /// @inheritdoc IHubStorageReader
    address public immutable HUB_TARGET;

    constructor(address hubTarget_) {
        if (hubTarget_ == address(0)) revert ZeroTarget();
        HUB_TARGET = hubTarget_;
    }

    // ---------------------------------------------------------------------
    // Hub namespace (`eulerphi.storage.ArticleAnchor`) — field getters
    // ---------------------------------------------------------------------

    /// @inheritdoc IHubGetters
    function admin() external view returns (address) {
        return IArticleAnchor(HUB_TARGET).admin();
    }

    /// @inheritdoc IHubGetters
    function router() external view returns (address) {
        return IArticleAnchor(HUB_TARGET).router();
    }

    /// @inheritdoc IHubGetters
    function ethChainSelector() external view returns (uint64) {
        return IArticleAnchor(HUB_TARGET).ethChainSelector();
    }

    /// @inheritdoc IHubGetters
    function gateway() external view returns (address) {
        return IArticleAnchor(HUB_TARGET).gateway();
    }

    /// @inheritdoc IHubGetters
    function batchOpenedAt() external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).batchOpenedAt();
    }

    /// @inheritdoc IHubGetters
    function lastAnchoredIndex() external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).lastAnchoredIndex();
    }

    /// @inheritdoc IHubGetters
    function anchoredBatches() external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).anchoredBatches();
    }

    /// @inheritdoc IHubGetters
    function journalLength() external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).journalLength();
    }

    /// @inheritdoc IHubGetters
    function pendingLeaves() external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).pendingLeaves();
    }

    /// @inheritdoc IHubGetters
    function journal(uint256 i) external view returns (bytes32) {
        return IArticleAnchor(HUB_TARGET).journal(i);
    }

    /// @inheritdoc IHubGetters
    function usedUuid(address author, bytes32 uuid) external view returns (bool) {
        return IArticleAnchor(HUB_TARGET).usedUuid(author, uuid);
    }

    /// @inheritdoc IHubGetters
    function lastSubmit(address author) external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).lastSubmit(author);
    }

    /// @inheritdoc IHubGetters
    function rootAt(uint256 batchIndex) external view returns (bytes32) {
        return IArticleAnchor(HUB_TARGET).rootAt(batchIndex);
    }

    /// @inheritdoc IHubGetters
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256) {
        return IArticleAnchor(HUB_TARGET).anchoredAtBlock(batchIndex);
    }

    /// @inheritdoc IHubStorageReader
    function hubSnapshot() external view returns (HubSnapshot memory out) {
        IArticleAnchor h = IArticleAnchor(HUB_TARGET);
        out.admin = h.admin();
        out.router = h.router();
        out.ethChainSelector = h.ethChainSelector();
        out.gateway = h.gateway();
        out.batchOpenedAt = h.batchOpenedAt();
        out.lastAnchoredIndex = h.lastAnchoredIndex();
        out.anchoredBatches = h.anchoredBatches();
        out.journalLength = h.journalLength();
        out.pendingLeaves = h.pendingLeaves();
    }
}
