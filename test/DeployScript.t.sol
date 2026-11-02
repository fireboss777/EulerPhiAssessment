// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { DeployGateway } from "../script/DeployGateway.s.sol";
import { Test } from "forge-std/Test.sol";

/// @notice The deploy script's input gate: `GW_BASE_CHAIN_SELECTOR` is
/// validated against `type(uint64).max` BEFORE the narrowing cast, so a
/// mistyped env var fails the deployment instead of truncating into a
/// wrong-but-plausible selector (a lane routing to nowhere, silently).
/// The script is a plain contract, so `run()` is exercised directly with
/// `vm.setEnv` — the require is the first thing that can reject the value,
/// before any broadcast.
contract DeployScriptTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ROUTER = address(0x4CC1);
    address internal constant HUB = address(0x4B1);

    function test_deployRejectsSelectorBeyondUint64() public {
        vm.setEnv("GW_OWNER", vm.toString(OWNER));
        vm.setEnv("GW_ROUTER", vm.toString(ROUTER));
        vm.setEnv("GW_HUB", vm.toString(HUB));
        // type(uint64).max + 1: exactly the value that would silently wrap to 0.
        vm.setEnv("GW_BASE_CHAIN_SELECTOR", vm.toString(uint256(type(uint64).max) + 1));

        DeployGateway script = new DeployGateway();
        vm.expectRevert(bytes("GW_BASE_CHAIN_SELECTOR does not fit uint64"));
        script.run();
    }
}
