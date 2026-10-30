// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ArticleAnchor} from "../src/ArticleAnchor.sol";

/// @notice Keeper: notarizes hub batch roots upward to the L1 gateway via
/// CCIP. The contract enforces the K-confirmation gate itself — when it
/// reverts "not final" (or anything else) this script stops; it assumes
/// nothing and records nothing beyond what the chain does.
///
/// Env:
///   HUB_ADDRESS      — ArticleAnchor proxy
///   NOTARY_BATCH_START — cursor: first batch index not yet on L1
///   NOTARY_FEE_WEI   — the CCIP fee for ONE message (upstream keeps
///                      overpayment — send the exact quote!)
contract Notarize is Script {
    function run() external {
        ArticleAnchor hub = ArticleAnchor(vm.envAddress("HUB_ADDRESS"));
        uint256 start = vm.envUint("NOTARY_BATCH_START");
        uint256 fee = vm.envUint("NOTARY_FEE_WEI");
        uint256 anchoredBatches = hub.anchoredBatches();

        vm.startBroadcast();
        uint256 sent;
        for (uint256 i = start; i < anchoredBatches; ++i) {
            try hub.notarize{value: fee}(i) {
                unchecked {
                    ++sent;
                }
            } catch (bytes memory reason) {
                console.log("stopped at batch", i);
                console.logBytes(reason);
                break;
            }
        }
        vm.stopBroadcast();

        console.log("notarized messages sent:", sent);
    }
}
