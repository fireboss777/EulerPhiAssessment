// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @notice Deploys ArticleAnchor behind OpenZeppelin's ERC1967 proxy — which
/// has NO admin entry of its own (the ERC-1967 admin slot stays empty), so the
/// only upgrade route is `upgradeToAndCall` gated by `_authorizeUpgrade`.
/// The proxy runs `initialize` in its constructor via `data`.
///
/// Env: HUB_OWNER, HUB_ROUTER, HUB_ETH_CHAIN_SELECTOR
/// Post-deploy: run DeployGateway, then `setGateway(gatewayAddress)` as owner.
contract DeployHub is Script {
    function run() external returns (address proxy) {
        address owner = vm.envAddress("HUB_OWNER");
        address router = vm.envAddress("HUB_ROUTER");
        uint64 selector = uint64(vm.envUint("HUB_ETH_CHAIN_SELECTOR"));

        vm.startBroadcast();
        ArticleAnchor impl = new ArticleAnchor();
        proxy = address(
            new ERC1967Proxy(address(impl), abi.encodeCall(ArticleAnchor.initialize, (owner, router, selector)))
        );
        vm.stopBroadcast();
        console.log("HUB_PROXY", proxy);
    }
}
