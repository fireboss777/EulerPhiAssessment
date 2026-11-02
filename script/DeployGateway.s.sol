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
/// Deploy order: DeployHub -> DeployGateway -> (owner) setGateway(chainSelector, proxy) on the hub.
contract DeployGateway is Script {
    /// @param owner The gateway's upgrade key — a multisig/timelock, same advice as the hub's.
    /// @param router Chainlink Router on the gateway's chain.
    /// @param hub ArticleAnchor proxy address on the hub chain.
    /// @param baseChainSelector Chainlink selector of the hub's chain. Typed
    /// `uint64`: the forge CLI parser rejects an out-of-range literal and the ABI
    /// decoder rejects a dirty word, so a mistyped selector can no longer reach
    /// the cast at all — that structural bound replaced the runtime `require`
    /// this script used to carry.
    function run(address owner, address router, address hub, uint64 baseChainSelector)
        external
        returns (address proxy)
    {
        vm.startBroadcast();
        SubmissionGateway impl = new SubmissionGateway();
        proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(SubmissionGateway.initialize, (owner, router, hub, baseChainSelector))
            )
        );
        vm.stopBroadcast();
        console.log("GATEWAY_PROXY", proxy);
    }
}
