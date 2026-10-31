// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IArticleAnchor} from "./interfaces/IArticleAnchor.sol";
import {IHubGetters} from "./interfaces/IHubGetters.sol";

/// @title HubGetters — the hub's 14 read getters, implemented once, here.
/// @notice `ArticleAnchor` inherits this contract instead of writing the
/// getters itself, so the hub main contract keeps only protocol behaviour
/// (lifecycle, submission, anchoring, notarizing) and its namespace pointer.
/// @dev Direct reads: every body is an `sload` through `_getStorage()`, i.e. in
/// the account that owns the namespace — the only account that CAN read it.
/// `_getStorage()` is left `virtual` and unimplemented on purpose: the literal
/// belongs to the namespace owner (`ArticleAnchor` pins it to
/// `eulerphi.storage.ArticleAnchor`), not to this read layer, so a second
/// namespace could reuse these getters by implementing its own pointer. This
/// contract is therefore `abstract` and never deployed on its own.
abstract contract HubGetters is IHubGetters {
    /// @inheritdoc IHubGetters
    function admin() external view returns (address) {
        return _getStorage().admin;
    }

    /// @inheritdoc IHubGetters
    function router() external view returns (address) {
        return _getStorage().router;
    }

    /// @inheritdoc IHubGetters
    function ethChainSelector() external view returns (uint64) {
        return _getStorage().ethChainSelector;
    }

    /// @inheritdoc IHubGetters
    function gateway() external view returns (address) {
        return _getStorage().gateway;
    }

    /// @inheritdoc IHubGetters
    function journal(uint256 i) external view returns (bytes32) {
        return _getStorage().journal[i];
    }

    /// @inheritdoc IHubGetters
    function journalLength() external view returns (uint256) {
        return _getStorage().journal.length;
    }

    /// @inheritdoc IHubGetters
    function pendingLeaves() external view returns (uint256) {
        IArticleAnchor.Storage storage $ = _getStorage();
        return $.journal.length - $.lastAnchoredIndex;
    }

    /// @inheritdoc IHubGetters
    function usedUuid(address author, bytes32 uuid) external view returns (bool) {
        return _getStorage().usedUuid[author][uuid];
    }

    /// @inheritdoc IHubGetters
    function lastSubmit(address author) external view returns (uint256) {
        return _getStorage().lastSubmit[author];
    }

    /// @inheritdoc IHubGetters
    function batchOpenedAt() external view returns (uint256) {
        return _getStorage().batchOpenedAt;
    }

    /// @inheritdoc IHubGetters
    function lastAnchoredIndex() external view returns (uint256) {
        return _getStorage().lastAnchoredIndex;
    }

    /// @inheritdoc IHubGetters
    function rootAt(uint256 batchIndex) external view returns (bytes32) {
        return _getStorage().rootAt[batchIndex];
    }

    /// @inheritdoc IHubGetters
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256) {
        return _getStorage().anchoredAtBlock[batchIndex];
    }

    /// @inheritdoc IHubGetters
    function anchoredBatches() external view returns (uint256) {
        return _getStorage().anchoredBatches;
    }

    /// @dev Namespace pointer — unimplemented here, implemented by the owner of
    /// the namespace. Reading it is `view`, not `pure`, at the call sites; the
    /// signature is `pure` because it only computes a slot, never reads one.
    function _getStorage() internal pure virtual returns (IArticleAnchor.Storage storage);
}
