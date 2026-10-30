// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ArticleAnchor} from "../src/ArticleAnchor.sol";
import {ArticleTestBase} from "./utils/ArticleTestBase.sol";
import {ArticleAnchorV2Stub} from "./mocks/ArticleAnchorV2Stub.sol";

contract UpgradeTest is ArticleTestBase {
    /// @dev Canonical deploy shape (mirrors script/DeployHub.s.sol):
    /// impl behind an ERC1967 proxy whose recorded factory-admin is
    /// address(0) — the factory's upgrade() path is permanently dead, so
    /// `upgradeToAndCall` (gated by _authorizeUpgrade) is the ONLY way up.
    function _proxyHub(address admin_, address router_, uint64 chainSelector_)
        internal
        returns (ArticleAnchor hub, ERC1967Factory factory)
    {
        ArticleAnchor impl = new ArticleAnchor(address(0), address(0), 0, address(0));
        factory = new ERC1967Factory();
        address proxy = factory.deployAndCall(
            address(impl), address(0), abi.encodeCall(ArticleAnchor.initialize, (admin_, router_, chainSelector_))
        );
        hub = ArticleAnchor(proxy);
    }

    function test_nonAdminUpgradeReverts() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);
        ArticleAnchor newImpl = new ArticleAnchor(address(0), address(0), 0, address(0));

        vm.prank(address(0xBAD));
        vm.expectRevert("admin only");
        hub.upgradeToAndCall(address(newImpl), "");
    }

    function test_journalPreservedAcrossUpgrade() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);
        seedBatch(hub, 3);
        bytes32 leaf0 = hub.journal(0);
        bytes32 leaf1 = hub.journal(1);
        bytes32 leaf2 = hub.journal(2);

        ArticleAnchorV2Stub stub = new ArticleAnchorV2Stub();
        hub.upgradeToAndCall(address(stub), "");

        assertEq(hub.journalLength(), 3, "journal length survived");
        assertEq(hub.journal(0), leaf0, "leaf0 survived");
        assertEq(hub.journal(1), leaf1, "leaf1 survived");
        assertEq(hub.journal(2), leaf2, "leaf2 survived");
        assertEq(hub.admin(), address(this), "admin survived");
        assertEq(ArticleAnchorV2Stub(address(hub)).v2Ping(), 42, "new implementation logic live");
    }

    function test_factoryAdminDisabled() public {
        (ArticleAnchor hub, ERC1967Factory factory) = _proxyHub(address(this), address(0), 8453);
        ArticleAnchor otherImpl = new ArticleAnchor(address(0), address(0), 0, address(0));

        // Recorded factory-admin is address(0): no EOA can ever be caller() == 0.
        vm.prank(address(0xF00));
        vm.expectRevert(ERC1967Factory.Unauthorized.selector);
        factory.upgrade(address(hub), address(otherImpl));
    }

    function test_setGatewayOnlyAdmin() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);

        vm.prank(address(0xBAD));
        vm.expectRevert("admin only");
        hub.setGateway(address(0x9999));

        hub.setGateway(address(0x9999));
        assertEq(hub.gateway(), address(0x9999), "admin setter works");
    }

    function test_initializeTwiceReverts() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);

        vm.expectRevert("initialized");
        hub.initialize(address(0xBAD), address(0), 8453);
    }
}
