// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArticleAnchor} from "../../src/ArticleAnchor.sol";

/// @notice V2 shape for upgrade tests: adds a function, adds NO storage —
/// storage-layout stability is exactly what test_journalPreserved checks.
contract ArticleAnchorV2Stub is ArticleAnchor {
    constructor() ArticleAnchor(address(0), address(0), 0, address(0)) {}

    function v2Ping() external pure returns (uint256) {
        return 42;
    }
}
