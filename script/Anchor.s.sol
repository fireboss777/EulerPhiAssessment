// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @notice Keeper: closes the hub's open batch when eligible. Permissionless
/// by design — this script assumes nothing the contract doesn't enforce; if
/// the batch isn't ready it simply no-ops (the contract would revert anyway).
///
/// Env: HUB_ADDRESS
contract Anchor is Script {
    function run() external {
        ArticleAnchor hub = ArticleAnchor(vm.envAddress("HUB_ADDRESS"));

        uint256 pending = hub.pendingLeaves();
        uint256 opened = hub.batchOpenedAt();
        bool ready =
            pending > 0 && (pending >= ArticleLib.MIN_BATCH || block.timestamp >= opened + ArticleLib.BATCH_DEADLINE);

        if (!ready) {
            console.log("noop: batch not ready; pending =", pending);
            return;
        }

        vm.startBroadcast();
        bytes32 root = hub.anchorNextBatch();
        vm.stopBroadcast();

        console.log("anchored; pending was", pending);
        console.logBytes32(root);
    }
}
