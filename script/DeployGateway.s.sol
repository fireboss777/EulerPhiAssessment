// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @notice Deploys a SubmissionGateway behind OpenZeppelin's ERC1967
/// proxy — which has NO admin entry of its own (the ERC-1967 admin slot stays
/// empty), so the only upgrade route is `upgradeToAndCall` gated by
/// `_authorizeUpgrade` (`onlyOwner`, OZ `Ownable2Step`). The proxy runs
/// `initialize` in its
/// constructor via `data`.
///
/// Env: GW_OWNER (the gateway's upgrade key — a multisig/timelock, the same
/// advice as HUB_OWNER), GW_ROUTER (Chainlink Router on the gateway's chain), GW_HUB
/// (ArticleAnchor proxy address on the hub chain), GW_BASE_CHAIN_SELECTOR
/// (hub chain selector).
///
/// Deploy order: DeployHub -> DeployGateway -> (owner) setGateway(chainSelector, proxy) on the hub.
contract DeployGateway is Script {
    function run() external returns (address proxy) {
        address owner = vm.envAddress("GW_OWNER");
        address router = vm.envAddress("GW_ROUTER");
        address hub = vm.envAddress("GW_HUB");
        // Chain selectors are uint64 on both Chainlink's side and ours: a
        // mistyped env var must fail HERE, not be silently truncated into a
        // wrong-but-plausible selector that would deploy a lane routing to
        // nowhere.
        uint256 rawSelector = vm.envUint("GW_BASE_CHAIN_SELECTOR");
        require(rawSelector <= type(uint64).max, "GW_BASE_CHAIN_SELECTOR does not fit uint64");
        // casting to 'uint64' is safe because the require above proves
        // rawSelector <= type(uint64).max — the exact check this lint asks for
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 selector = uint64(rawSelector);

        vm.startBroadcast();
        SubmissionGateway impl = new SubmissionGateway();
        proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(SubmissionGateway.initialize, (owner, router, hub, selector))
            )
        );
        vm.stopBroadcast();
        console.log("GATEWAY_PROXY", proxy);
    }
}
