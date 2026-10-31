// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { Script } from "forge-std/Script.sol";

/// @notice Deploys the L1 SubmissionGateway (plain contract — no proxy, no
/// upgrade path: the L1 record endpoint is deliberately immutable).
///
/// Env: GW_ROUTER (Chainlink Router on Ethereum), GW_HUB (ArticleAnchor proxy
/// address on the hub chain), GW_BASE_CHAIN_SELECTOR (hub chain selector).
///
/// Deploy order: DeployHub -> DeployGateway -> (admin) setGateway(gw) on the hub.
contract DeployGateway is Script {
    function run() external returns (address gateway) {
        address router = vm.envAddress("GW_ROUTER");
        address hub = vm.envAddress("GW_HUB");
        uint64 selector = uint64(vm.envUint("GW_BASE_CHAIN_SELECTOR"));

        vm.startBroadcast();
        gateway = address(new SubmissionGateway(router, hub, selector));
        vm.stopBroadcast();
    }
}
