// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "./interfaces/IArticleAnchor.sol";
import { IArticleAnchorGetters } from "./interfaces/IArticleAnchorGetters.sol";

/// @title ArticleAnchorGetters — the hub's 14 read getters, implemented once, here.
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
abstract contract ArticleAnchorGetters is IArticleAnchorGetters {
    /// @inheritdoc IArticleAnchorGetters
    function admin() external view returns (address) {
        return _getStorage().admin;
    }

    /// @inheritdoc IArticleAnchorGetters
    function router() external view returns (address) {
        return _getStorage().router;
    }

    /// @inheritdoc IArticleAnchorGetters
    function ethChainSelector() external view returns (uint64) {
        return _getStorage().ethChainSelector;
    }

    /// @inheritdoc IArticleAnchorGetters
    function gateway() external view returns (address) {
        return _getStorage().gateway;
    }

    /// @inheritdoc IArticleAnchorGetters
    function journal(uint256 i) external view returns (bytes32) {
        return _getStorage().journal[i];
    }

    /// @inheritdoc IArticleAnchorGetters
    function journalLength() external view returns (uint256) {
        return _getStorage().journal.length;
    }

    /// @inheritdoc IArticleAnchorGetters
    function pendingLeaves() external view returns (uint256) {
        IArticleAnchor.Storage storage $ = _getStorage();
        return $.journal.length - $.lastAnchoredIndex;
    }

    /// @inheritdoc IArticleAnchorGetters
    function usedUuid(address author, bytes32 uuid) external view returns (bool) {
        return _getStorage().usedUuid[author][uuid];
    }

    /// @inheritdoc IArticleAnchorGetters
    function lastSubmit(address author) external view returns (uint256) {
        return _getStorage().lastSubmit[author];
    }

    /// @inheritdoc IArticleAnchorGetters
    function batchOpenedAt() external view returns (uint256) {
        return _getStorage().batchOpenedAt;
    }

    /// @inheritdoc IArticleAnchorGetters
    function lastAnchoredIndex() external view returns (uint256) {
        return _getStorage().lastAnchoredIndex;
    }

    /// @inheritdoc IArticleAnchorGetters
    function rootAt(uint256 batchIndex) external view returns (bytes32) {
        return _getStorage().rootAt[batchIndex];
    }

    /// @inheritdoc IArticleAnchorGetters
    function anchoredAtBlock(uint256 batchIndex) external view returns (uint256) {
        return _getStorage().anchoredAtBlock[batchIndex];
    }

    /// @inheritdoc IArticleAnchorGetters
    function anchoredBatches() external view returns (uint256) {
        return _getStorage().anchoredBatches;
    }

    /// @dev Namespace pointer — unimplemented here, implemented by the owner of
    /// the namespace. Reading it is `view`, not `pure`, at the call sites; the
    /// signature is `pure` because it only computes a slot, never reads one.
    function _getStorage() internal pure virtual returns (IArticleAnchor.Storage storage);
}
