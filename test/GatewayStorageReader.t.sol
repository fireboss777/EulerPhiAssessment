// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { GatewayStorageReader } from "../src/GatewayStorageReader.sol";
import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { IGatewayStorageReader } from "../src/interfaces/IGatewayStorageReader.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";

/// @dev Same cross-check discipline as the hub reader: every value read through
/// the gateway namespace must equal what the gateway reports, after real state
/// changes (a delivered notary root).
contract GatewayStorageReaderTest is ArticleTestBase {
    ArticleAnchor internal hub;
    SubmissionGateway internal gw;
    GatewayStorageReader internal reader;

    function setUp() public override {
        super.setUp();
        hub = _deployHub();
        gw = new SubmissionGateway(address(0xB0B), address(hub), 777);
        reader = new GatewayStorageReader(address(gw));
    }

    function test_boundTargetAndZeroTargetReverts() public {
        assertEq(reader.GATEWAY_TARGET(), address(gw), "gateway bound");

        vm.expectRevert(IGatewayStorageReader.ZeroTarget.selector);
        new GatewayStorageReader(address(0));
    }

    function test_gatewayNamespaceMatchesContract() public {
        assertEq(reader.nextBatch(), gw.nextBatch(), "nextBatch before delivery");
        assertEq(reader.notarizedRoot(1), bytes32(0), "unwritten root reads zero");

        vm.prank(address(0xB0B)); // the pinned router
        gw.receiveRoot(0, bytes32(uint256(0xDEAD)));

        assertEq(reader.nextBatch(), gw.nextBatch(), "nextBatch after delivery");
        assertEq(reader.nextBatch(), 1, "cursor advanced");
        assertEq(reader.notarizedRoot(0), gw.notarizedRoot(0), "notarizedRoot match");
        assertEq(reader.notarizedRoot(0), bytes32(uint256(0xDEAD)), "recorded value");

        IGatewayStorageReader.GatewaySnapshot memory got = reader.gatewaySnapshot();
        assertEq(got.nextBatch, gw.nextBatch(), "gatewaySnapshot.nextBatch");
        assertEq(got.nextBatch, reader.nextBatch(), "snapshot == getter");
    }
}
