// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
import { GatewayLib } from "../src/libraries/GatewayLib.sol";
import { ArticleAnchorV2Stub } from "./mocks/ArticleAnchorV2Stub.sol";
import { MockRouter } from "./mocks/MockRouter.sol";
import { SubmissionGatewayV2Stub } from "./mocks/SubmissionGatewayV2Stub.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeTest is ArticleTestBase {
    /// @dev Mirrors of OZ's ownership events so `vm.expectEmit` can name them
    /// — a test contract does not inherit `OwnableUpgradeable`.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    function test_nonOwnerUpgradeReverts() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
        ArticleAnchor newImpl = new ArticleAnchor();

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hub.upgradeToAndCall(address(newImpl), "");
    }

    function test_journalPreservedAcrossUpgrade() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
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
        assertEq(hub.owner(), address(this), "owner survived");
        assertEq(ArticleAnchorV2Stub(address(hub)).v2Ping(), 42, "new implementation logic live");
    }

    function test_setGatewayOnlyOwner() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hub.setGateway(8453, address(0x9999));

        vm.expectEmit(true, false, false, true);
        emit IArticleAnchor.GatewaySet(8453, address(0x9999));
        hub.setGateway(8453, address(0x9999));
        assertEq(hub.gatewayAt(8453), address(0x9999), "owner setter works");
    }

    function test_initializeTwiceReverts() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hub.initialize(address(0xBAD), address(0));
    }

    /// @dev The bare implementation ships uninitialized — its own
    /// `initialize` guard must not be open on it.
    function test_bareImplementationCannotBeInitialized() public {
        ArticleAnchor impl = new ArticleAnchor();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(0xBAD), address(0));
    }

    /// @dev A fresh hub must refuse `initialOwner = 0`: an owner-less hub would
    /// be permanently un-upgradeable (no sender can equal `owner()`).
    /// OZ's proxy forbids EMPTY init data (`ERC1967ProxyUninitialized`), so we
    /// satisfy its guard with a harmless view call — that leaves the hub's own
    /// `_initialized` flag untouched, i.e. the hub really is uninitialized.
    function test_initializeRejectsZeroOwner() public {
        ArticleAnchor impl = new ArticleAnchor();
        ArticleAnchor fresh =
            ArticleAnchor(address(new ERC1967Proxy(address(impl), abi.encodeWithSignature("journalLength()"))));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        fresh.initialize(address(0), address(0));

        fresh.initialize(address(this), address(0)); // failed attempt must not consume the flag
        assertEq(fresh.owner(), address(this), "legit init works");
    }

    /// @dev Deploy-time safety: a botched `initialize(initialOwner = 0)` bubbles out
    /// of the proxy CONSTRUCTOR, so no broken, un-upgradeable proxy is ever
    /// left behind on chain.
    function test_zeroOwnerProxyCannotBeConstructed() public {
        ArticleAnchor impl = new ArticleAnchor();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(ArticleAnchor.initialize, (address(0), address(0))));
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
        (ArticleAnchor hub, ArticleAnchor impl) = _proxyHub(address(this), address(0));
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
        assertEq(hub.owner(), address(this), "app state lives behind the proxy");

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
        assertEq(gw.owner(), address(this), "gateway state lives behind the proxy");
    }

    /// @dev ERC-7201 proof: recompute each namespace slot FROM ITS ID and read
    /// it raw. This pins two things at once — `ArticleLib.STORAGE_SLOT`
    /// really is the ERC-7201 formula (id-derived, constant and raw slots are
    /// independent computations that must agree),
    /// and the struct really lives there, layout included: `router` (20B) sits
    /// alone at the hub's namespace base, `gatewayAt`'s mapping base (base+1)
    /// stores nothing, and its entry for chain 8453 lands at
    /// `keccak256(abi.encode(uint64(8453), uint256(hubSlot) + 1))`.
    /// The gateway half does the same for
    /// `GatewayLib.STORAGE_SLOT` and its config words.
    function test_storageLivesAtErc7201Slot() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0xACE));
        hub.setGateway(8453, address(0x9999));

        bytes32 hubSlot =
            keccak256(abi.encode(uint256(keccak256("eulerphi.storage.ArticleAnchor")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(ArticleLib.STORAGE_SLOT, hubSlot, "hub slot constant == formula");
        uint256 base = uint256(vm.load(address(hub), hubSlot));
        assertEq(address(uint160(base)), hub.router(), "router at the namespace base");
        assertEq(uint256(vm.load(address(hub), bytes32(uint256(hubSlot) + 1))), 0, "mapping base slot stores nothing");
        uint256 entry = uint256(keccak256(abi.encode(uint64(8453), uint256(hubSlot) + 1)));
        assertEq(
            address(uint160(uint256(vm.load(address(hub), bytes32(entry))))),
            address(0x9999),
            "gatewayAt[8453] at keccak256(abi.encode(uint64, base+1))"
        );

        SubmissionGateway gw = _deployGateway(address(this), address(0xB0B), address(0x4B1), 999_999);
        bytes32 gwSlot = keccak256(abi.encode(uint256(keccak256("eulerphi.storage.SubmissionGateway")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(GatewayLib.STORAGE_SLOT, gwSlot, "gateway slot constant == formula");
        uint256 gbase = uint256(vm.load(address(gw), gwSlot));
        assertEq(address(uint160(gbase)), gw.router(), "router at the namespace base");
        assertEq(uint64(gbase >> 160), gw.baseChainSelector(), "baseChainSelector packs with router at the base");
        assertEq(
            address(uint160(uint256(vm.load(address(gw), bytes32(uint256(gwSlot) + 1))))), gw.hub(), "hub at base+1"
        );
    }

    /// @dev Packing proof — the hub side of the symmetry the gateway already
    /// has at its base word (router+selector share one slot, asserted above).
    /// The batch trio `batchOpenedAt` (uint64) + `lastAnchoredIndex` (uint128)
    /// + `anchoredBatches` (uint64) = 256 bits exactly must live in ONE word at
    /// `base + 5`, in that order, and the retired per-field homes (`base + 6`,
    /// `base + 8`) must read empty. Read raw on purpose: the getters widen
    /// back to uint256 by design, so they cannot tell a packed layout from a
    /// spread one — only the slot contents can.
    function test_batchScalarsPackIntoOneSlot() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);
        hub.anchorNextBatch();

        // The namespace ROOT slot IS struct slot 0, so absolute field slots are
        // STORAGE_SLOT + i (the existing ERC-7201 test's `base` is the VALUE
        // stored in slot 0, i.e. the router — not an address to index by).
        uint256 base = uint256(ArticleLib.STORAGE_SLOT);
        uint256 word = uint256(vm.load(address(hub), bytes32(base + 5)));

        assertEq(word & type(uint64).max, hub.batchOpenedAt(), "batchOpenedAt: low 64 bits of base+5");
        assertEq((word >> 64) & type(uint128).max, hub.lastAnchoredIndex(), "lastAnchoredIndex: bits 64..192 of base+5");
        assertEq((word >> 192) & type(uint64).max, hub.anchoredBatches(), "anchoredBatches: bits 192..256 of base+5");
        assertEq(
            uint256(vm.load(address(hub), bytes32(base + 6))), 0, "base+6 retired (rootAt mapping base stores nothing)"
        );
        assertEq(uint256(vm.load(address(hub), bytes32(base + 8))), 0, "base+8 retired");
    }

    // ------------------------------------------------------------------
    // Gateway: the same guarantees on the gateway contract — each test mirrors
    // the hub test of the same name above, with SubmissionGateway swapped in.
    // ------------------------------------------------------------------

    function test_gatewayNonOwnerUpgradeReverts() public {
        (SubmissionGateway gw,) = _proxyGateway(address(this), address(0xB0B), address(0x4B1), 8453);
        SubmissionGateway newImpl = new SubmissionGateway();

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
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

        assertEq(gw.owner(), address(this), "owner survived");
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

    /// @dev A fresh gateway proxy must refuse `initialOwner = 0` — an owner-less
    /// gateway would be permanently un-upgradeable. The proxy needs NON-empty
    /// init data (OZ `ERC1967ProxyUninitialized`), so a harmless view call
    /// stands in; it leaves `_initialized` at 0.
    function test_gatewayInitializeRejectsZeroOwner() public {
        SubmissionGateway impl = new SubmissionGateway();
        SubmissionGateway fresh =
            SubmissionGateway(address(new ERC1967Proxy(address(impl), abi.encodeWithSignature("owner()"))));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        fresh.initialize(address(0), address(0), address(0), 8453);

        fresh.initialize(address(this), address(0xB0B), address(0x4B1), 8453); // failed attempt must not consume the
        // flag
        assertEq(fresh.owner(), address(this), "legit init works");
    }

    /// @dev Deploy-time safety: a botched `initialize(initialOwner = 0)` bubbles out
    /// of the proxy constructor, so no broken, un-upgradeable gateway proxy is
    /// ever left behind on chain.
    function test_gatewayZeroOwnerProxyCannotBeConstructed() public {
        SubmissionGateway impl = new SubmissionGateway();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
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

    // ------------------------------------------------------------------
    // Ownership: OZ Ownable2Step replaces the old admin — each test pins one
    // guarantee of the two-step flow. Impl contracts are created BEFORE any
    // expectRevert/prank so creates never sit inside an expectation window.
    // ------------------------------------------------------------------

    function test_transferOwnershipStartsTwoStep() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
        address newOwner = address(0x0B1);
        ArticleAnchor newImpl = new ArticleAnchor();

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferStarted(address(this), newOwner);
        hub.transferOwnership(newOwner);
        assertEq(hub.owner(), address(this), "owner unchanged until accept");
        assertEq(hub.pendingOwner(), newOwner, "pending owner set");

        // The pending owner has NO power before accepting.
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, newOwner));
        hub.upgradeToAndCall(address(newImpl), "");
    }

    function test_acceptOwnershipCompletesTransfer() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
        address newOwner = address(0x0B1);
        ArticleAnchor newImpl = new ArticleAnchor();
        hub.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(this), newOwner);
        hub.acceptOwnership();
        assertEq(hub.owner(), newOwner, "ownership moved");
        assertEq(hub.pendingOwner(), address(0), "pending cleared");

        // Old owner is out ...
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.upgradeToAndCall(address(newImpl), "");

        // ... the new owner holds the gate.
        ArticleAnchorV2Stub stub = new ArticleAnchorV2Stub();
        vm.prank(newOwner);
        hub.upgradeToAndCall(address(stub), "");
        assertEq(ArticleAnchorV2Stub(address(hub)).v2Ping(), 42, "new owner can upgrade");
    }

    function test_acceptOwnershipRejectsNonPending() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
        hub.transferOwnership(address(0x0B1));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hub.acceptOwnership();
    }

    function test_transferOwnershipOnlyOwner() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hub.transferOwnership(address(0xBAD));
        assertEq(hub.pendingOwner(), address(0), "no pending owner was set");
    }

    function test_renounceOwnershipDisablesUpgrades() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
        (SubmissionGateway gw,) = _proxyGateway(address(this), address(0xB0B), address(0x4B1), 8453);
        ArticleAnchor newImpl = new ArticleAnchor();
        SubmissionGateway newGwImpl = new SubmissionGateway();

        hub.renounceOwnership();
        assertEq(hub.owner(), address(0), "hub ownerless");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.upgradeToAndCall(address(newImpl), "");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setGateway(8453, address(0x9999));

        gw.renounceOwnership();
        assertEq(gw.owner(), address(0), "gateway ownerless");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        gw.upgradeToAndCall(address(newGwImpl), "");
    }

    function test_transferToZeroCancelsPending() public {
        (ArticleAnchor hub,) = _proxyHub(address(this), address(0));
        address newOwner = address(0x0B1);
        hub.transferOwnership(newOwner);

        hub.transferOwnership(address(0)); // OZ 2Step: zero cancels the pending transfer
        assertEq(hub.pendingOwner(), address(0), "pending cleared by zero");
        assertEq(hub.owner(), address(this), "owner unchanged by cancel");

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, newOwner));
        hub.acceptOwnership();
    }

    function test_gatewayTransferOwnershipTwoStep() public {
        (SubmissionGateway gw,) = _proxyGateway(address(this), address(0xB0B), address(0x4B1), 8453);
        SubmissionGatewayV2Stub stub = new SubmissionGatewayV2Stub();
        address newOwner = address(0x0B2);

        gw.transferOwnership(newOwner);
        assertEq(gw.owner(), address(this), "gateway owner unchanged until accept");
        assertEq(gw.pendingOwner(), newOwner, "gateway pending set");

        vm.prank(newOwner);
        gw.acceptOwnership();
        assertEq(gw.owner(), newOwner, "gateway ownership moved");
        assertEq(gw.pendingOwner(), address(0), "gateway pending cleared");

        // Old owner loses the gate, new owner holds it.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        gw.upgradeToAndCall(address(stub), "");
        vm.prank(newOwner);
        gw.upgradeToAndCall(address(stub), "");
        assertEq(SubmissionGatewayV2Stub(address(gw)).v2Ping(), 42, "gateway new owner upgraded");
    }

    /// @dev Canonical deploy shape (mirrors script/DeployHub.s.sol): an OZ
    /// ERC1967 proxy — with NO admin/authority entry at all — running
    /// `initialize` in its constructor, so `upgradeToAndCall` (gated by
    /// `_authorizeUpgrade`) is the ONLY way up. Returns the implementation so
    /// tests can assert what the proxy's ERC-1967 slots point at.
    function _proxyHub(address initialOwner_, address router_)
        internal
        returns (ArticleAnchor hub, ArticleAnchor impl)
    {
        impl = new ArticleAnchor();
        address proxy = address(
            new ERC1967Proxy(address(impl), abi.encodeCall(ArticleAnchor.initialize, (initialOwner_, router_)))
        );
        hub = ArticleAnchor(proxy);
    }

    /// @dev Gateway twin of `_proxyHub`: the same proxy shape
    /// (script/DeployGateway.s.sol), returning the implementation so tests
    /// can assert what the proxy's ERC-1967 slots point at.
    function _proxyGateway(address initialOwner_, address router_, address hub_, uint64 baseChainSelector_)
        internal
        returns (SubmissionGateway gw, SubmissionGateway impl)
    {
        impl = new SubmissionGateway();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(SubmissionGateway.initialize, (initialOwner_, router_, hub_, baseChainSelector_))
            )
        );
        gw = SubmissionGateway(proxy);
    }
}
