// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArticleAnchor} from "../src/ArticleAnchor.sol";
import {ArticleSubmission} from "../src/ArticleLib.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ArticleTestBase} from "./utils/ArticleTestBase.sol";

contract SubmitTest is ArticleTestBase {
    uint256 internal constant AUTHOR_KEY = 0xB0B;

    function test_validSubmitAppendsJournal() public {
        ArticleAnchor hub = deployHub();
        address author = vm.addr(AUTHOR_KEY);
        ArticleSubmission memory p = payloadFor(author, 1);
        bytes32 leaf = leafOf(p);
        bytes memory sig = signArticle(hub, p, AUTHOR_KEY);

        vm.expectEmit(address(hub));
        emit Submitted(author, address(this), leaf);
        hub.submitArticle(leaf, sig, p);

        assertEq(hub.journalLength(), 1, "journal count");
        assertEq(hub.journal(0), leaf, "journal leaf");
    }

    function test_digestMismatchReverts() public {
        ArticleAnchor hub = deployHub();
        ArticleSubmission memory p = payloadFor(vm.addr(AUTHOR_KEY), 2);
        bytes memory sig = signArticle(hub, p, AUTHOR_KEY);
        bytes32 wrongLeaf = bytes32(uint256(leafOf(p)) ^ 1);

        vm.expectRevert("digest mismatch");
        hub.submitArticle(wrongLeaf, sig, p);
    }

    function test_lowSEnforced() public {
        ArticleAnchor hub = deployHub();
        ArticleSubmission memory p = payloadFor(vm.addr(AUTHOR_KEY), 3);
        bytes memory good = signArticle(hub, p, AUTHOR_KEY);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(good, 0x20))
            s := mload(add(good, 0x40))
            v := byte(0, mload(add(good, 0x60)))
        }
        // Malleable twin: (r, N-s, v flipped) — same signer, high-s form.
        bytes memory malleable = abi.encodePacked(r, ECDSA.N - uint256(s), v == 27 ? 28 : 27);

        vm.expectRevert("high-s");
        hub.submitArticle(leafOf(p), malleable, p);
    }

    function test_expiredDeadlineReverts() public {
        ArticleAnchor hub = deployHub();
        ArticleSubmission memory p = payloadFor(vm.addr(AUTHOR_KEY), 4);
        bytes memory sig = signArticle(hub, p, AUTHOR_KEY);
        vm.warp(p.deadline + 1);

        vm.expectRevert("expired");
        hub.submitArticle(leafOf(p), sig, p);
    }

    function test_rateLimit1hReverts() public {
        ArticleAnchor hub = deployHub();
        address author = vm.addr(AUTHOR_KEY);
        submitAs(hub, payloadFor(author, 5), AUTHOR_KEY);
        ArticleSubmission memory second = payloadFor(author, 6);
        bytes memory sig2 = signArticle(hub, second, AUTHOR_KEY);

        vm.expectRevert(bytes("rate"));
        hub.submitArticle(leafOf(second), sig2, second);
    }

    function test_duplicateUuidReverts() public {
        ArticleAnchor hub = deployHub();
        address author = vm.addr(AUTHOR_KEY);
        ArticleSubmission memory p = payloadFor(author, 7);
        submitAs(hub, p, AUTHOR_KEY);
        bytes memory sig = signArticle(hub, p, AUTHOR_KEY);
        vm.warp(block.timestamp + 1 hours); // clear the per-author rate limit

        vm.expectRevert(bytes("dup"));
        hub.submitArticle(leafOf(p), sig, p);
    }

    function test_thirdPartySubmitWithAuthorSigPasses() public {
        ArticleAnchor hub = deployHub();
        address author = vm.addr(AUTHOR_KEY);
        ArticleSubmission memory p = payloadFor(author, 8);
        bytes32 leaf = leafOf(p);
        bytes memory sig = signArticle(hub, p, AUTHOR_KEY);

        vm.expectEmit(address(hub));
        emit Submitted(author, address(0xBEEF), leaf);
        vm.prank(address(0xBEEF));
        hub.submitArticle(leaf, sig, p);

        assertEq(hub.journalLength(), 1, "relayed leaf journaled");
        assertEq(hub.journal(0), leaf, "leaf value");
    }

    function test_forgedByAuthorSigReverts() public {
        ArticleAnchor hub = deployHub();
        ArticleSubmission memory p = payloadFor(vm.addr(AUTHOR_KEY), 9);
        bytes memory forged = signArticle(hub, p, FORGER_KEY);

        vm.expectRevert("not author");
        hub.submitArticle(leafOf(p), forged, p);
    }
}
