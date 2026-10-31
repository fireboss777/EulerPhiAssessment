// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IHubStorageReader} from "../src/interfaces/IHubStorageReader.sol";
import {HubStorageReader} from "../src/HubStorageReader.sol";
import {ArticleSubmission} from "../src/ArticleLib.sol";
import {ArticleAnchor} from "../src/ArticleAnchor.sol";
import {ArticleTestBase} from "./utils/ArticleTestBase.sol";

/// @dev The reader mirrors a layout it does not own, so every test here is a
/// cross-check: each value read through the namespace must equal what the real
/// contract reports through its own API, after real state changes.
contract HubStorageReaderTest is ArticleTestBase {
    ArticleAnchor internal hub;
    HubStorageReader internal reader;

    function setUp() public override {
        super.setUp();
        hub = _deployHub();
        reader = new HubStorageReader(address(hub));
    }

    function test_boundTargetAndZeroTargetReverts() public {
        assertEq(reader.HUB_TARGET(), address(hub), "hub bound");

        vm.expectRevert(IHubStorageReader.ZeroTarget.selector);
        new HubStorageReader(address(0));
    }

    function test_scalarGettersMatchContract() public {
        hub.setGateway(address(0x9999));
        _seedBatch(hub, 12);

        assertEq(reader.admin(), hub.admin(), "admin");
        assertEq(reader.router(), hub.router(), "router");
        assertEq(reader.ethChainSelector(), hub.ethChainSelector(), "ethChainSelector");
        assertEq(reader.gateway(), hub.gateway(), "gateway");
        assertEq(reader.batchOpenedAt(), hub.batchOpenedAt(), "batchOpenedAt");
        assertEq(reader.journalLength(), hub.journalLength(), "journalLength");
        assertEq(reader.pendingLeaves(), hub.pendingLeaves(), "pendingLeaves");
        assertEq(reader.lastAnchoredIndex(), hub.lastAnchoredIndex(), "lastAnchoredIndex");
        assertEq(reader.anchoredBatches(), hub.anchoredBatches(), "anchoredBatches");

        // ... and the values must be non-trivial, or the check is vacuous
        assertGt(reader.journalLength(), 0, "journal has leaves");
        assertGt(reader.batchOpenedAt(), 0, "window is open");
        assertEq(reader.journalLength(), 12, "12 seeded leaves");

        hub.anchorNextBatch();

        assertEq(reader.lastAnchoredIndex(), hub.lastAnchoredIndex(), "lastAnchoredIndex after anchor");
        assertEq(reader.anchoredBatches(), hub.anchoredBatches(), "anchoredBatches after anchor");
        assertEq(reader.pendingLeaves(), hub.pendingLeaves(), "pendingLeaves after anchor");
        assertEq(reader.rootAt(0), hub.rootAt(0), "rootAt(0)");
        assertEq(reader.anchoredAtBlock(0), hub.anchoredAtBlock(0), "anchoredAtBlock(0)");
        assertGt(reader.anchoredBatches(), 0, "cursor advanced");
        assertTrue(reader.rootAt(0) != bytes32(0), "root recorded");
    }

    function test_mappingGettersMatchContract() public {
        address author = vm.addr(FORGER_KEY);
        ArticleSubmission memory p = _payloadFor(author, 42);
        _submitAs(hub, p, FORGER_KEY);

        assertTrue(reader.usedUuid(author, p.uuid), "uuid is spent");
        assertEq(reader.usedUuid(author, p.uuid), hub.usedUuid(author, p.uuid), "usedUuid match");
        assertEq(reader.lastSubmit(author), hub.lastSubmit(author), "lastSubmit match");
        assertGt(reader.lastSubmit(author), 0, "rate-limit stamp recorded");
        assertEq(reader.journal(0), hub.journal(0), "journal(0) match");
        assertEq(reader.journal(0), _leafOf(p), "journal(0) is our leaf");

        // an untouched key reads false/zero rather than reverting
        assertFalse(reader.usedUuid(author, bytes32(0)), "fresh uuid reads false");
        assertEq(reader.lastSubmit(address(0xdead)), 0, "unknown author reads 0");
    }

    function test_snapshotMatchesScalarGetters() public {
        hub.setGateway(address(0x9999));
        _seedBatch(hub, 12);
        hub.anchorNextBatch();

        IHubStorageReader.HubSnapshot memory got = reader.hubSnapshot();
        IHubStorageReader.HubSnapshot memory want = IHubStorageReader.HubSnapshot({
            admin: hub.admin(),
            router: hub.router(),
            ethChainSelector: hub.ethChainSelector(),
            gateway: hub.gateway(),
            batchOpenedAt: hub.batchOpenedAt(),
            lastAnchoredIndex: hub.lastAnchoredIndex(),
            anchoredBatches: hub.anchoredBatches(),
            journalLength: hub.journalLength(),
            pendingLeaves: hub.pendingLeaves()
        });
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)), "snapshot == getters");
        assertEq(got.journalLength - got.lastAnchoredIndex, got.pendingLeaves, "snapshot is self-consistent");
        assertTrue(got.gateway != address(0), "snapshot carries the wiring");
    }
}
