// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IArticleAnchor} from "./interfaces/IArticleAnchor.sol";
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
    address public immutable hubTarget;

    constructor(address hubTarget_) {
        if (hubTarget_ == address(0)) revert ZeroTarget();
        hubTarget = hubTarget_;
    }

    // ---------------------------------------------------------------------
    // Hub namespace (`eulerphi.storage.ArticleAnchor`) — field getters
    // ---------------------------------------------------------------------

    /// @inheritdoc IHubStorageReader
    function admin() external view returns (address) {
        return IArticleAnchor(hubTarget).admin();
    }

    /// @inheritdoc IHubStorageReader
    function router() external view returns (address) {
        return IArticleAnchor(hubTarget).router();
    }

    /// @inheritdoc IHubStorageReader
    function ethChainSelector() external view returns (uint64) {
        return IArticleAnchor(hubTarget).ethChainSelector();
    }

    /// @inheritdoc IHubStorageReader
    function gateway() external view returns (address) {
        return IArticleAnchor(hubTarget).gateway();
    }

    /// @inheritdoc IHubStorageReader
    function batchOpenedAt() external view returns (uint256) {
        return IArticleAnchor(hubTarget).batchOpenedAt();
    }

    /// @inheritdoc IHubStorageReader
    function lastAnchoredIndex() external view returns (uint256) {
        return IArticleAnchor(hubTarget).lastAnchoredIndex();
    }

    /// @inheritdoc IHubStorageReader
    function anchoredBatches() external view returns (uint256) {
        return IArticleAnchor(hubTarget).anchoredBatches();
    }

    /// @inheritdoc IHubStorageReader
    function journalLength() external view returns (uint256) {
        return IArticleAnchor(hubTarget).journalLength();
    }

    /// @inheritdoc IHubStorageReader
    function pendingLeaves() external view returns (uint256) {
        return IArticleAnchor(hubTarget).pendingLeaves();
    }

    /// @inheritdoc IHubStorageReader
    function journal(uint256 i) external view returns (bytes32) {
        return IArticleAnchor(hubTarget).journal(i);
    }

    /// @inheritdoc IHubStorageReader
    function usedUuid(address author, bytes32 uuid) external view returns (bool) {
        return IArticleAnchor(hubTarget).usedUuid(author, uuid);
    }

    /// @inheritdoc IHubStorageReader
    function lastSubmit(address author) external view returns (uint256) {
        return IArticleAnchor(hubTarget).lastSubmit(author);
    }

    /// @inheritdoc IHubStorageReader
    function rootAt(uint256 batchIndex) external view returns (bytes32) {
        return IArticleAnchor(hubTarget).rootAt(batchIndex);
    }

    /// @inheritdoc IHubStorageReader
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256) {
        return IArticleAnchor(hubTarget).anchoredAtBlock(batchIndex);
    }

    /// @inheritdoc IHubStorageReader
    function hubSnapshot() external view returns (HubSnapshot memory out) {
        IArticleAnchor h = IArticleAnchor(hubTarget);
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
