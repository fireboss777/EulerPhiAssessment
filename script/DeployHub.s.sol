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
/// Post-deploy: run DeployGateway, then authorize it per source chain:
/// `setGateway(chainSelector, gatewayAddress)` as owner.
contract DeployHub is Script {
    /// @param owner The hub's upgrade/owner key — a multisig/timelock, not an EOA.
    /// @param router Chainlink Router of the hub's chain (also the CCIP lane gate).
    function run(address owner, address router) external returns (address proxy) {
        vm.startBroadcast();
        ArticleAnchor impl = new ArticleAnchor();
        proxy = address(new ERC1967Proxy(address(impl), abi.encodeCall(ArticleAnchor.initialize, (owner, router))));
        vm.stopBroadcast();
        console.log("HUB_PROXY", proxy);
    }
}
