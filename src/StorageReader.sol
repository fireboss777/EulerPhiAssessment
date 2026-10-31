// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IArticleAnchor} from "./interfaces/IArticleAnchor.sol";
import {ISubmissionGateway} from "./interfaces/ISubmissionGateway.sol";
import {IStorageReader} from "./interfaces/IStorageReader.sol";

/// @title StorageReader — read-only facade over both namespaces of this project.
/// @notice See `IStorageReader` for the API and for why it exists (a `Storage`
/// struct holds mappings, so it cannot be returned — solc 4103).
/// @dev Stateless: two `immutable` targets, zero storage variables, so it needs
/// no namespace of its own. Each getter is a typed `staticcall` into the bound
/// target's own getters, which the compiler checks against `IArticleAnchor` /
/// `ISubmissionGateway` — so this file cannot drift from the layouts it
/// mirrors: if a name or signature changes upstream, it stops compiling here.
contract StorageReader is IStorageReader {
    /// @inheritdoc IStorageReader
    address public immutable hubTarget;
    /// @inheritdoc IStorageReader
    address public immutable gatewayTarget;

    constructor(address hubTarget_, address gatewayTarget_) {
        if (hubTarget_ == address(0) || gatewayTarget_ == address(0)) revert ZeroTarget();
        hubTarget = hubTarget_;
        gatewayTarget = gatewayTarget_;
    }

    // ---------------------------------------------------------------------
    // Hub namespace (`eulerphi.storage.ArticleAnchor`) — field getters
    // ---------------------------------------------------------------------

    /// @inheritdoc IStorageReader
    function admin() external view returns (address) {
        return IArticleAnchor(hubTarget).admin();
    }

    /// @inheritdoc IStorageReader
    function router() external view returns (address) {
        return IArticleAnchor(hubTarget).router();
    }

    /// @inheritdoc IStorageReader
    function ethChainSelector() external view returns (uint64) {
        return IArticleAnchor(hubTarget).ethChainSelector();
    }

    /// @inheritdoc IStorageReader
    function gateway() external view returns (address) {
        return IArticleAnchor(hubTarget).gateway();
    }

    /// @inheritdoc IStorageReader
    function batchOpenedAt() external view returns (uint256) {
        return IArticleAnchor(hubTarget).batchOpenedAt();
    }

    /// @inheritdoc IStorageReader
    function lastAnchoredIndex() external view returns (uint256) {
        return IArticleAnchor(hubTarget).lastAnchoredIndex();
    }

    /// @inheritdoc IStorageReader
    function anchoredBatches() external view returns (uint256) {
        return IArticleAnchor(hubTarget).anchoredBatches();
    }

    /// @inheritdoc IStorageReader
    function journalLength() external view returns (uint256) {
        return IArticleAnchor(hubTarget).journalLength();
    }

    /// @inheritdoc IStorageReader
    function pendingLeaves() external view returns (uint256) {
        return IArticleAnchor(hubTarget).pendingLeaves();
    }

    /// @inheritdoc IStorageReader
    function journal(uint256 i) external view returns (bytes32) {
        return IArticleAnchor(hubTarget).journal(i);
    }

    /// @inheritdoc IStorageReader
    function usedUuid(address author, bytes32 uuid) external view returns (bool) {
        return IArticleAnchor(hubTarget).usedUuid(author, uuid);
    }

    /// @inheritdoc IStorageReader
    function lastSubmit(address author) external view returns (uint256) {
        return IArticleAnchor(hubTarget).lastSubmit(author);
    }

    /// @inheritdoc IStorageReader
    function rootAt(uint256 batchIndex) external view returns (bytes32) {
        return IArticleAnchor(hubTarget).rootAt(batchIndex);
    }

    /// @inheritdoc IStorageReader
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256) {
        return IArticleAnchor(hubTarget).anchoredAtBlock(batchIndex);
    }

    /// @inheritdoc IStorageReader
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

    // ---------------------------------------------------------------------
    // Gateway namespace (`eulerphi.storage.SubmissionGateway`) — field getters
    // ---------------------------------------------------------------------

    /// @inheritdoc IStorageReader
    function nextBatch() external view returns (uint256) {
        return ISubmissionGateway(gatewayTarget).nextBatch();
    }

    /// @inheritdoc IStorageReader
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32) {
        return ISubmissionGateway(gatewayTarget).notarizedRoot(batchIndex);
    }

    /// @inheritdoc IStorageReader
    function gatewaySnapshot() external view returns (GatewaySnapshot memory out) {
        out.nextBatch = ISubmissionGateway(gatewayTarget).nextBatch();
    }
}
