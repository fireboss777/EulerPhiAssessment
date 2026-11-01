// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "./interfaces/IArticleAnchor.sol";
import { IArticleAnchorGetters } from "./interfaces/IArticleAnchorGetters.sol";
import { ArticleLib } from "./libraries/ArticleLib.sol";

/// @title ArticleAnchorGetters — the hub's 11 read getters, implemented once, here.
/// @notice `ArticleAnchor` inherits this contract instead of writing the
/// getters itself, so the hub main contract keeps only protocol behaviour
/// (lifecycle, submission, anchoring).
/// @dev Direct reads: every body is an `sload` through `ArticleLib.getStorage()`,
/// i.e. in the account that owns the namespace — the only account that CAN read
/// it. The pointer and its slot constant both live in `ArticleLib`, so this
/// contract carries neither; it stays `abstract` (never deployed on its own)
/// because it is a read layer, not a product.
abstract contract ArticleAnchorGetters is IArticleAnchorGetters {
    /// @inheritdoc IArticleAnchorGetters
    function router() external view returns (address) {
        return ArticleLib.getStorage().router;
    }

    /// @inheritdoc IArticleAnchorGetters
    function gatewayAt(uint64 chainSelector) external view returns (address) {
        return ArticleLib.getStorage().gatewayAt[chainSelector];
    }

    /// @inheritdoc IArticleAnchorGetters
    function journal(uint256 i) external view returns (bytes32) {
        return ArticleLib.getStorage().journal[i];
    }

    /// @inheritdoc IArticleAnchorGetters
    function journalLength() external view returns (uint256) {
        return ArticleLib.getStorage().journal.length;
    }

    /// @inheritdoc IArticleAnchorGetters
    function pendingLeaves() external view returns (uint256) {
        IArticleAnchor.Storage storage $ = ArticleLib.getStorage();
        return $.journal.length - $.lastAnchoredIndex;
    }

    /// @inheritdoc IArticleAnchorGetters
    function usedUuid(address author, bytes32 uuid) external view returns (bool) {
        return ArticleLib.getStorage().usedUuid[author][uuid];
    }

    /// @inheritdoc IArticleAnchorGetters
    function lastSubmit(address author) external view returns (uint256) {
        return ArticleLib.getStorage().lastSubmit[author];
    }

    /// @inheritdoc IArticleAnchorGetters
    function batchOpenedAt() external view returns (uint256) {
        return ArticleLib.getStorage().batchOpenedAt;
    }

    /// @inheritdoc IArticleAnchorGetters
    function lastAnchoredIndex() external view returns (uint256) {
        return ArticleLib.getStorage().lastAnchoredIndex;
    }

    /// @inheritdoc IArticleAnchorGetters
    function rootAt(uint256 batchIndex) external view returns (bytes32) {
        return ArticleLib.getStorage().rootAt[batchIndex];
    }

    /// @inheritdoc IArticleAnchorGetters
    function anchoredBatches() external view returns (uint256) {
        return ArticleLib.getStorage().anchoredBatches;
    }
}
