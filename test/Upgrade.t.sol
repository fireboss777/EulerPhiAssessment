// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ISubmissionGateway } from "../src/interfaces/ISubmissionGateway.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
import { GatewayLib } from "../src/libraries/GatewayLib.sol";
import { ArticleAnchorV2Stub } from "./mocks/ArticleAnchorV2Stub.sol";
import { MockRouter } from "./mocks/MockRouter.sol";
import { SubmissionGatewayV2Stub } from "./mocks/SubmissionGatewayV2Stub.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeTest is ArticleTestBase {
    function test_nonAdminUpgradeReverts() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);
        ArticleAnchor newImpl = new ArticleAnchor();

        vm.prank(address(0xBAD));
        vm.expectRevert(IArticleAnchor.AdminOnly.selector);
        hub.upgradeToAndCall(address(newImpl), "");
    }

    function test_journalPreservedAcrossUpgrade() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);
        _seedBatch(hub, 3);
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

    function test_setGatewayOnlyAdmin() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);

        vm.prank(address(0xBAD));
        vm.expectRevert(IArticleAnchor.AdminOnly.selector);
        hub.setGateway(address(0x9999));

        hub.setGateway(address(0x9999));
        assertEq(hub.gateway(), address(0x9999), "admin setter works");
    }

    function test_initializeTwiceReverts() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0), 8453);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hub.initialize(address(0xBAD), address(0), 8453);
    }

    /// @dev The bare implementation ships with `admin = address(0)` in the
    /// deploy script — its own `initialize` guard must not be open on it.
    function test_bareImplementationCannotBeInitialized() public {
        ArticleAnchor impl = new ArticleAnchor();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(0xBAD), address(0), 8453);
    }

    /// @dev A fresh hub must refuse `admin_ = 0`: an admin-less hub would be
    /// permanently un-upgradeable (nobody passes `msg.sender == admin`).
    /// OZ's proxy forbids EMPTY init data (`ERC1967ProxyUninitialized`), so we
    /// satisfy its guard with a harmless view call — that leaves the hub's own
    /// `_initialized` flag untouched, i.e. the hub really is uninitialized.
    function test_initializeRejectsZeroAdmin() public {
        ArticleAnchor impl = new ArticleAnchor();
        ArticleAnchor fresh =
            ArticleAnchor(address(new ERC1967Proxy(address(impl), abi.encodeWithSignature("journalLength()"))));

        vm.expectRevert(IArticleAnchor.ZeroAdmin.selector);
        fresh.initialize(address(0), address(0), 8453);

        fresh.initialize(address(this), address(0), 8453); // failed attempt must not consume the flag
        assertEq(fresh.admin(), address(this), "legit init works");
    }

    /// @dev Deploy-time safety: a botched `initialize(admin_ = 0)` bubbles out
    /// of the proxy CONSTRUCTOR, so no broken, un-upgradeable proxy is ever
    /// left behind on chain.
    function test_zeroAdminProxyCannotBeConstructed() public {
        ArticleAnchor impl = new ArticleAnchor();

        vm.expectRevert(IArticleAnchor.ZeroAdmin.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(ArticleAnchor.initialize, (address(0), address(0), 8453)));
    }

    /// @dev OZ's `onlyProxy`: `upgradeToAndCall` called on the BARE
    /// implementation (no active proxy in front of it) must die. Pins OZ's
    /// error selector — Solady's guard reverted with a different one, which is
    /// exactly what makes this test RED before the library swap.
    function test_bareImplementationUpgradeReverts() public {
        ArticleAnchor impl = new ArticleAnchor();
        ArticleAnchor other = new ArticleAnchor();

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(other), "");
    }

    /// @dev The ERC-1967 ADMIN slot of the proxy must be empty: the proxy has
    /// no admin/authority of its own (no factory key, no guardian), so the only
    /// upgrade route is `upgradeToAndCall` gated by `_authorizeUpgrade`.
    function test_proxyHasNoAdminSlot() public {
        (ArticleAnchor hub, ArticleAnchor impl) = _proxyHub(address(this), address(0), 8453);
        // ERC-1967 standard slots (see OpenZeppelin ERC1967Utils / EIP-1967).
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

        address recordedAdmin = address(uint160(uint256(vm.load(address(hub), adminSlot))));
        assertEq(recordedAdmin, address(0), "proxy admin must not exist");
        assertEq(
            address(uint160(uint256(vm.load(address(hub), implSlot)))),
            address(impl),
            "impl slot must point at the implementation"
        );
        assertEq(hub.admin(), address(this), "app state lives behind the proxy");

        // Same two slots on the gateway proxy — its guarantees must match the hub's.
        (SubmissionGateway gw, SubmissionGateway gwImpl) =
            _proxyGateway(address(this), address(0xB0B), address(0x4B1), 8453);
        assertEq(
            address(uint160(uint256(vm.load(address(gw), adminSlot)))), address(0), "gateway proxy admin must not exist"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(gw), implSlot)))),
            address(gwImpl),
            "gateway impl slot must point at the implementation"
        );
        assertEq(gw.admin(), address(this), "gateway state lives behind the proxy");
    }

    /// @dev ERC-7201 proof: recompute each namespace slot FROM ITS ID and read
    /// it raw. This pins two things at once — `ArticleLib.STORAGE_SLOT`
    /// really is the ERC-7201 formula (id-derived, constant and raw slots are
    /// independent computations that must agree),
    /// and the struct really lives there, packing included: `router` (20B) + `ethChainSelector` (8B)
    /// share word 1 of the hub namespace, exactly as the pre-migration
    /// contract layout packed them. The gateway half does the same for
    /// `GatewayLib.STORAGE_SLOT` and its four config words.
    function test_storageLivesAtErc7201Slot() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0xACE), 8453);
        hub.setGateway(address(0x9999));

        bytes32 hubSlot =
            keccak256(abi.encode(uint256(keccak256("eulerphi.storage.ArticleAnchor")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(ArticleLib.STORAGE_SLOT, hubSlot, "hub slot constant == formula");
        uint256 base = uint256(vm.load(address(hub), hubSlot));
        assertEq(address(uint160(base)), hub.admin(), "admin lives at the namespace base");
        uint256 word1 = uint256(vm.load(address(hub), bytes32(uint256(hubSlot) + 1)));
        assertEq(address(uint160(word1)), hub.router(), "router at base+1");
        assertEq(uint64(word1 >> 160), hub.ethChainSelector(), "ethChainSelector packs with router in base+1");
        assertEq(
            address(uint160(uint256(vm.load(address(hub), bytes32(uint256(hubSlot) + 2))))),
            hub.gateway(),
            "gateway at base+2"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(hub), bytes32(uint256(hubSlot) + 2))))),
            hub.gateway(),
            "gateway at base+2"
        );

        SubmissionGateway gw = _deployGateway(address(this), address(0xB0B), address(0x4B1), 999_999);
        bytes32 gwSlot = keccak256(abi.encode(uint256(keccak256("eulerphi.storage.SubmissionGateway")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(GatewayLib.STORAGE_SLOT, gwSlot, "gateway slot constant == formula");
        uint256 gbase = uint256(vm.load(address(gw), gwSlot));
        assertEq(address(uint160(gbase)), gw.admin(), "gateway admin at the namespace base");
        uint256 gword1 = uint256(vm.load(address(gw), bytes32(uint256(gwSlot) + 1)));
        assertEq(address(uint160(gword1)), gw.router(), "router at base+1");
        assertEq(uint64(gword1 >> 160), gw.baseChainSelector(), "baseChainSelector packs with router in base+1");
        assertEq(
            address(uint160(uint256(vm.load(address(gw), bytes32(uint256(gwSlot) + 2))))), gw.hub(), "hub at base+2"
        );
    }

    // ------------------------------------------------------------------
    // Gateway: the same guarantees on the L1 contract — each test mirrors
    // the hub test of the same name above, with SubmissionGateway swapped in.
    // ------------------------------------------------------------------

    function test_gatewayNonAdminUpgradeReverts() public {
        (SubmissionGateway gw,) = _proxyGateway(address(this), address(0xB0B), address(0x4B1), 8453);
        SubmissionGateway newImpl = new SubmissionGateway();

        vm.prank(address(0xBAD));
        vm.expectRevert(ISubmissionGateway.AdminOnly.selector);
        gw.upgradeToAndCall(address(newImpl), "");
    }

    function test_gatewayConfigPreservedAcrossUpgrade() public {
        MockRouter mock = new MockRouter();
        (SubmissionGateway gw,) = _proxyGateway(address(this), address(mock), address(0x4B1), 999_999);
        bytes memory sig = abi.encodePacked(bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), uint8(27));
        vm.deal(address(this), 1 ether);

        // One submission through the proxy: the config is exercised, not just read.
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(FORGER_KEY), 1);
        gw.submitArticle{ value: mock.fee() }(_leafOf(p), sig, p);

        SubmissionGatewayV2Stub stub = new SubmissionGatewayV2Stub();
        gw.upgradeToAndCall(address(stub), "");

        assertEq(gw.admin(), address(this), "admin survived");
        assertEq(gw.router(), address(mock), "router survived");
        assertEq(gw.hub(), address(0x4B1), "hub survived");
        assertEq(gw.baseChainSelector(), 999_999, "selector survived");
        assertEq(SubmissionGatewayV2Stub(address(gw)).v2Ping(), 42, "new implementation logic live");

        // The lane still works after the upgrade, byte-identical, through the pins.
        IArticleAnchor.ArticleSubmission memory p2 = _payloadFor(vm.addr(FORGER_KEY), 2);
        gw.submitArticle{ value: mock.fee() }(_leafOf(p2), sig, p2);
        assertEq(mock.lastData(), abi.encode(_leafOf(p2), sig, p2), "still forwards byte-identical");
        assertEq(mock.lastReceiver(), address(0x4B1), "receiver pin survived");
        assertEq(mock.lastDest(), uint64(999_999), "destination selector survived");
    }

    function test_gatewayInitializeTwiceReverts() public {
        (SubmissionGateway gw,) = _proxyGateway(address(this), address(0xB0B), address(0x4B1), 8453);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gw.initialize(address(0xBAD), address(0), address(0), 8453);
    }

    /// @dev The bare gateway implementation must ship locked: its own
    /// `initialize` guard is closed forever.
    function test_gatewayBareImplementationCannotBeInitialized() public {
        SubmissionGateway impl = new SubmissionGateway();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(0xBAD), address(0), address(0), 8453);
    }

    /// @dev A fresh gateway proxy must refuse `admin_ = 0` — an admin-less
    /// gateway would be permanently un-upgradeable. The proxy needs NON-empty
    /// init data (OZ `ERC1967ProxyUninitialized`), so a harmless view call
    /// stands in; it leaves `_initialized` at 0.
    function test_gatewayInitializeRejectsZeroAdmin() public {
        SubmissionGateway impl = new SubmissionGateway();
        SubmissionGateway fresh =
            SubmissionGateway(address(new ERC1967Proxy(address(impl), abi.encodeWithSignature("admin()"))));

        vm.expectRevert(ISubmissionGateway.ZeroAdmin.selector);
        fresh.initialize(address(0), address(0), address(0), 8453);

        fresh.initialize(address(this), address(0xB0B), address(0x4B1), 8453); // failed attempt must not consume the
        // flag
        assertEq(fresh.admin(), address(this), "legit init works");
    }

    /// @dev Deploy-time safety: a botched `initialize(admin_ = 0)` bubbles out
    /// of the proxy constructor, so no broken, un-upgradeable gateway proxy is
    /// ever left behind on chain.
    function test_gatewayZeroAdminProxyCannotBeConstructed() public {
        SubmissionGateway impl = new SubmissionGateway();

        vm.expectRevert(ISubmissionGateway.ZeroAdmin.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(SubmissionGateway.initialize, (address(0), address(0), address(0), 8453))
        );
    }

    /// @dev OZ's `onlyProxy` on the gateway too: `upgradeToAndCall` against
    /// the BARE implementation must die.
    function test_gatewayBareImplementationUpgradeReverts() public {
        SubmissionGateway impl = new SubmissionGateway();
        SubmissionGateway other = new SubmissionGateway();

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(other), "");
    }

    /// @dev Canonical deploy shape (mirrors script/DeployHub.s.sol): an OZ
    /// ERC1967 proxy — with NO admin/authority entry at all — running
    /// `initialize` in its constructor, so `upgradeToAndCall` (gated by
    /// `_authorizeUpgrade`) is the ONLY way up. Returns the implementation so
    /// tests can assert what the proxy's ERC-1967 slots point at.
    function _proxyHub(address admin_, address router_, uint64 chainSelector_)
        internal
        returns (ArticleAnchor hub, ArticleAnchor impl)
    {
        impl = new ArticleAnchor();
        address proxy = address(
            new ERC1967Proxy(address(impl), abi.encodeCall(ArticleAnchor.initialize, (admin_, router_, chainSelector_)))
        );
        hub = ArticleAnchor(proxy);
    }

    /// @dev Gateway twin of `_proxyHub`: the same proxy shape
    /// (script/DeployGateway.s.sol), returning the implementation so tests
    /// can assert what the proxy's ERC-1967 slots point at.
    function _proxyGateway(address admin_, address router_, address hub_, uint64 baseChainSelector_)
        internal
        returns (SubmissionGateway gw, SubmissionGateway impl)
    {
        impl = new SubmissionGateway();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(SubmissionGateway.initialize, (admin_, router_, hub_, baseChainSelector_))
            )
        );
        gw = SubmissionGateway(proxy);
    }
}
