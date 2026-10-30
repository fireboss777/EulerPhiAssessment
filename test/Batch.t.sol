// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MerkleTreeLib} from "solady/utils/MerkleTreeLib.sol";
import {IArticleAnchor} from "../src/interfaces/IArticleAnchor.sol";
import {ArticleAnchor} from "../src/ArticleAnchor.sol";
import {ArticleTestBase} from "./utils/ArticleTestBase.sol";

contract BatchTest is ArticleTestBase {
    function test_anchorRequiresMinOrDeadline() public {
        ArticleAnchor hub = deployHub();
        seedBatch(hub, hub.MIN_BATCH() - 1); // 9 < 10, same block => no deadline either

        vm.expectRevert(IArticleAnchor.BatchNotReady.selector);
        hub.anchorNextBatch();

        vm.warp(block.timestamp + hub.BATCH_DEADLINE());
        hub.anchorNextBatch();

        assertTrue(hub.rootAt(0) != bytes32(0), "root anchored");
        assertEq(hub.lastAnchoredIndex(), 9, "index advanced");
        assertEq(hub.anchoredBatches(), 1, "one batch");
        assertEq(hub.anchoredAtBlock(0), block.number, "anchor block recorded");
    }

    function test_anchorAtMaxBatch() public {
        ArticleAnchor hub = deployHub();
        seedBatch(hub, hub.MAX_BATCH() + 5); // 205 pending

        hub.anchorNextBatch();
        assertEq(hub.lastAnchoredIndex(), 200, "capped at MAX_BATCH");

        vm.expectRevert(IArticleAnchor.BatchNotReady.selector); // 5 pending, < MIN, fresh window
        hub.anchorNextBatch();

        vm.warp(block.timestamp + hub.BATCH_DEADLINE() + 1);
        hub.anchorNextBatch();
        assertEq(hub.lastAnchoredIndex(), 205, "remainder anchored");
        assertTrue(hub.rootAt(1) != bytes32(0), "second root exists");
        assertEq(hub.anchoredBatches(), 2, "two batches");
    }

    function test_permissionlessAnchor() public {
        ArticleAnchor hub = deployHub();
        seedBatch(hub, 10);

        vm.prank(address(0x5EED));
        hub.anchorNextBatch();

        assertEq(hub.lastAnchoredIndex(), 10, "anyone may anchor");
    }

    function test_emptyAnchorReverts() public {
        ArticleAnchor hub = deployHub();

        vm.expectRevert(IArticleAnchor.BatchNotReady.selector);
        hub.anchorNextBatch();
    }

    function test_rangeFreezeAfterAppend() public {
        ArticleAnchor hub = deployHub();
        seedBatch(hub, 10);
        hub.anchorNextBatch();
        bytes32 root0 = hub.rootAt(0);

        seedBatch(hub, 1); // leaf enters the NEXT batch's window
        bytes32 rebuilt = MerkleTreeLib.root(MerkleTreeLib.build(sliceJournal(hub, 0, 10)));
        assertEq(rebuilt, root0, "batch0 root reproducible from journal");

        vm.warp(block.timestamp + hub.BATCH_DEADLINE() + 1);
        hub.anchorNextBatch();

        assertEq(hub.rootAt(0), root0, "anchored root frozen after later append");
        assertEq(hub.lastAnchoredIndex(), 11, "second batch closed");
    }

    function test_verifyAgainstBatchTrue() public {
        ArticleAnchor hub = deployHub();
        seedBatch(hub, 10);
        hub.anchorNextBatch();

        bytes32[] memory tree = MerkleTreeLib.build(sliceJournal(hub, 0, 10));
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 3);

        assertTrue(hub.verifyAgainstBatch(0, hub.journal(3), proof), "honest proof verifies");
    }

    function test_verifyAgainstBatchFalse() public {
        ArticleAnchor hub = deployHub();
        seedBatch(hub, 10);
        hub.anchorNextBatch();

        bytes32[] memory tree = MerkleTreeLib.build(sliceJournal(hub, 0, 10));
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 3);
        bytes32 leaf = hub.journal(3);

        assertFalse(hub.verifyAgainstBatch(0, bytes32(uint256(leaf) ^ 1), proof), "forged leaf");
        assertFalse(hub.verifyAgainstBatch(1, leaf, proof), "leaf cannot cross batches");
    }
}
