// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

contract BatchTest is ArticleTestBase {
    function test_anchorRequiresMinOrDeadline() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, ArticleLib.MIN_BATCH - 1); // 9 < 10, same block => no deadline either

        vm.expectRevert(IArticleAnchor.BatchNotReady.selector);
        hub.anchorNextBatch();

        vm.warp(block.timestamp + ArticleLib.BATCH_DEADLINE);
        hub.anchorNextBatch();

        assertTrue(hub.rootAt(0) != bytes32(0), "root anchored");
        assertEq(hub.lastAnchoredIndex(), 9, "index advanced");
        assertEq(hub.anchoredBatches(), 1, "one batch");
    }

    function test_anchorAtMaxBatch() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, ArticleLib.MAX_BATCH + 5); // 205 pending

        hub.anchorNextBatch();
        assertEq(hub.lastAnchoredIndex(), 200, "capped at MAX_BATCH");

        vm.expectRevert(IArticleAnchor.BatchNotReady.selector); // 5 pending, < MIN, fresh window
        hub.anchorNextBatch();

        vm.warp(block.timestamp + ArticleLib.BATCH_DEADLINE + 1);
        hub.anchorNextBatch();
        assertEq(hub.lastAnchoredIndex(), 205, "remainder anchored");
        assertTrue(hub.rootAt(1) != bytes32(0), "second root exists");
        assertEq(hub.anchoredBatches(), 2, "two batches");
    }

    function test_permissionlessAnchor() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);

        vm.prank(address(0x5EED));
        hub.anchorNextBatch();

        assertEq(hub.lastAnchoredIndex(), 10, "anyone may anchor");
    }

    function test_emptyAnchorReverts() public {
        ArticleAnchor hub = _deployHub();

        vm.expectRevert(IArticleAnchor.BatchNotReady.selector);
        hub.anchorNextBatch();
    }

    function test_rangeFreezeAfterAppend() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);
        hub.anchorNextBatch();
        bytes32 root0 = hub.rootAt(0);

        _seedBatch(hub, 1); // leaf enters the NEXT batch's window
        bytes32 rebuilt = MerkleTreeLib.root(MerkleTreeLib.build(_sliceJournal(hub, 0, 10)));
        assertEq(rebuilt, root0, "batch0 root reproducible from journal");

        vm.warp(block.timestamp + ArticleLib.BATCH_DEADLINE + 1);
        hub.anchorNextBatch();

        assertEq(hub.rootAt(0), root0, "anchored root frozen after later append");
        assertEq(hub.lastAnchoredIndex(), 11, "second batch closed");
    }

    function test_verifyAgainstBatchTrue() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);
        hub.anchorNextBatch();

        bytes32[] memory tree = MerkleTreeLib.build(_sliceJournal(hub, 0, 10));
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 3);

        assertTrue(hub.verifyAgainstBatch(0, hub.journal(3), proof), "honest proof verifies");
    }

    function test_verifyAgainstBatchFalse() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);
        hub.anchorNextBatch();

        bytes32[] memory tree = MerkleTreeLib.build(_sliceJournal(hub, 0, 10));
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 3);
        bytes32 leaf = hub.journal(3);

        assertFalse(hub.verifyAgainstBatch(0, bytes32(uint256(leaf) ^ 1), proof), "forged leaf");
        assertFalse(hub.verifyAgainstBatch(1, leaf, proof), "leaf cannot cross batches");
    }

    /// @dev The 6h window pinned by VALUE and by an absolute clock. The rest of
    /// the suite warps relative to a base at t=7,201s — below BATCH_DEADLINE —
    /// so deleting the `batchOpenedAt` write left every one of them green while
    /// the policy died for any real chain (unix time ≫ 6h): a fresh partial
    /// batch would be anchorable by anyone instantly. This test seeds at
    /// absolute t = 2 days, asserts the recorded open time, checks the deadline
    /// is measured from OPEN (not from the raw epoch), and checks re-opening.
    function test_batchWindowRecordsOpensAndGates() public {
        ArticleAnchor hub = _deployHub();
        vm.warp(2 days); // absolute clock far past the raw 6h number
        uint256 openedAt = block.timestamp;
        _seedBatch(hub, 9); // 9 < MIN_BATCH: the deadline is the only way out

        assertEq(hub.batchOpenedAt(), openedAt, "first leaf of a fresh window records batchOpenedAt");

        // Inside the window measured from OPEN, even though the absolute time
        // already exceeds the raw BATCH_DEADLINE constant.
        vm.warp(openedAt + ArticleLib.BATCH_DEADLINE - 1);
        vm.expectRevert(IArticleAnchor.BatchNotReady.selector);
        hub.anchorNextBatch();

        // ...and anchorable exactly at open + deadline.
        vm.warp(openedAt + ArticleLib.BATCH_DEADLINE);
        hub.anchorNextBatch();
        assertEq(hub.lastAnchoredIndex(), 9, "partial batch anchored on the window deadline");
        assertEq(hub.anchoredBatches(), 1, "one batch");

        // The next leaf after a fully-consumed window re-opens a fresh one.
        uint256 reopenedAt = openedAt + ArticleLib.BATCH_DEADLINE + 100;
        vm.warp(reopenedAt);
        _seedBatch(hub, 1);
        assertEq(hub.batchOpenedAt(), reopenedAt, "fresh window re-opens the deadline");
    }

    /// @dev The cross-batch leg deserves a REAL second root:
    /// `test_verifyAgainstBatchFalse` checks it against `rootAt[1] == 0` (batch 1
    /// never anchored there), which only proves "not against an empty slot".
    /// Two anchored batches prove the property itself: a proof is bound to its
    /// OWN batch's root, in both crossing directions, against two distinct,
    /// non-zero roots.
    function test_crossBatchProofsBoundToTheirOwnRoot() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);
        hub.anchorNextBatch();
        _seedBatch(hub, 10); // fresh window re-opened by the 11th leaf
        hub.anchorNextBatch(); // 10 pending >= MIN_BATCH: no deadline needed

        assertEq(hub.anchoredBatches(), 2, "two real batches");
        assertTrue(hub.rootAt(0) != hub.rootAt(1), "the two roots genuinely differ");

        bytes32[] memory tree0 = MerkleTreeLib.build(_sliceJournal(hub, 0, 10));
        bytes32[] memory tree1 = MerkleTreeLib.build(_sliceJournal(hub, 10, 20));
        bytes32 leaf0 = hub.journal(2);
        bytes32 leaf1 = hub.journal(15);

        assertTrue(hub.verifyAgainstBatch(0, leaf0, MerkleTreeLib.leafProof(tree0, 2)), "batch0 proof on batch0");
        assertTrue(hub.verifyAgainstBatch(1, leaf1, MerkleTreeLib.leafProof(tree1, 5)), "batch1 proof on batch1");
        assertFalse(hub.verifyAgainstBatch(0, leaf1, MerkleTreeLib.leafProof(tree1, 5)), "batch1 proof vs batch0 root");
        assertFalse(hub.verifyAgainstBatch(1, leaf0, MerkleTreeLib.leafProof(tree0, 2)), "batch0 proof vs batch1 root");
    }

    /// @dev `pendingLeaves` is the reader of the packed cursor (`journal.length
    /// − lastAnchoredIndex`, widened uint256 arithmetic) and the number the
    /// keeper script actually polls before paying for a transaction — it had
    /// zero tests, so a wrong subtraction (off-by-window, reading the wrong
    /// packed field) would only surface as a keeper that wastes gas or never
    /// fires. Value AND transition pinned: pending grows with the journal,
    /// drops to 0 on anchor, grows again in the next window.
    function test_pendingLeavesTracksTheCursor() public {
        ArticleAnchor hub = _deployHub();
        _seedBatch(hub, 10);
        assertEq(hub.pendingLeaves(), 10, "seeded journal is fully pending");

        hub.anchorNextBatch();
        assertEq(hub.pendingLeaves(), 0, "anchored window leaves nothing pending");

        _seedBatch(hub, 3); // next window re-opened, below MIN_BATCH
        assertEq(hub.pendingLeaves(), 3, "next window's partial batch is pending");
    }
}
