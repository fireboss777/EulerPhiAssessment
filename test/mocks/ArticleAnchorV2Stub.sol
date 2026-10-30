// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArticleAnchor} from "../../src/ArticleAnchor.sol";

/// @notice V2 shape for upgrade tests: adds a function, adds NO storage —
/// storage-layout stability is exactly what test_journalPreserved checks.
contract ArticleAnchorV2Stub is ArticleAnchor {
    function v2Ping() external pure returns (uint256) {
        return 42;
    }
}
