// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ArticleAnchor} from "../src/ArticleAnchor.sol";

/// @notice Deploys ArticleAnchor behind an ERC1967 proxy in the canonical
/// single-upgrade-path shape: factory admin recorded as address(0), so the
/// only upgrade route is `upgradeToAndCall` gated by `_authorizeUpgrade`.
///
/// Env: HUB_ADMIN, HUB_ROUTER, HUB_ETH_CHAIN_SELECTOR
/// Post-deploy: run DeployGateway, then `setGateway(gatewayAddress)` as admin.
contract DeployHub is Script {
    function run() external returns (address proxy) {
        address admin = vm.envAddress("HUB_ADMIN");
        address router = vm.envAddress("HUB_ROUTER");
        uint64 selector = uint64(vm.envUint("HUB_ETH_CHAIN_SELECTOR"));

        vm.startBroadcast();
        ArticleAnchor impl = new ArticleAnchor(address(0), address(0), 0, address(0));
        ERC1967Factory factory = new ERC1967Factory();
        proxy = factory.deployAndCall(
            address(impl),
            address(0),
            abi.encodeCall(ArticleAnchor.initialize, (admin, router, selector))
        );
        vm.stopBroadcast();
    }
}
