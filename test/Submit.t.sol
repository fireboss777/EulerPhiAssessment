// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

contract SubmitTest is ArticleTestBase {
    uint256 internal constant AUTHOR_KEY = 0xB0B;

    function test_validSubmitAppendsJournal() public {
        ArticleAnchor hub = _deployHub();
        address author = vm.addr(AUTHOR_KEY);
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(author, 1);
        bytes32 leaf = _leafOf(p);
        bytes memory sig = _signArticle(hub, p, AUTHOR_KEY);

        vm.expectEmit(address(hub));
        emit Submitted(author, address(this), leaf);
        hub.submitArticle(leaf, sig, p);

        assertEq(hub.journalLength(), 1, "journal count");
        assertEq(hub.journal(0), leaf, "journal leaf");
        // the two bookkeeping reads, exercised straight through the hub: their
        // getters live in `ArticleAnchorGetters` and nothing else wraps them
        assertTrue(hub.usedUuid(author, p.uuid), "uuid marked used");
        assertEq(hub.lastSubmit(author), block.timestamp, "rate-limit stamp");
        assertFalse(hub.usedUuid(author, bytes32(0)), "fresh uuid reads false");
    }

    function test_digestMismatchReverts() public {
        ArticleAnchor hub = _deployHub();
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(AUTHOR_KEY), 2);
        bytes memory sig = _signArticle(hub, p, AUTHOR_KEY);
        bytes32 wrongLeaf = bytes32(uint256(_leafOf(p)) ^ 1);

        vm.expectRevert(IArticleAnchor.DigestMismatch.selector);
        hub.submitArticle(wrongLeaf, sig, p);
    }

    function test_lowSEnforced() public {
        ArticleAnchor hub = _deployHub();
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(AUTHOR_KEY), 3);
        bytes memory good = _signArticle(hub, p, AUTHOR_KEY);
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

        vm.expectRevert(IArticleAnchor.NonCanonicalSignature.selector);
        hub.submitArticle(_leafOf(p), malleable, p);
    }

    function test_expiredDeadlineReverts() public {
        ArticleAnchor hub = _deployHub();
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(AUTHOR_KEY), 4);
        bytes memory sig = _signArticle(hub, p, AUTHOR_KEY);
        vm.warp(p.deadline + 1);

        vm.expectRevert(IArticleAnchor.Expired.selector);
        hub.submitArticle(_leafOf(p), sig, p);
    }

    function test_rateLimit1hReverts() public {
        ArticleAnchor hub = _deployHub();
        address author = vm.addr(AUTHOR_KEY);
        _submitAs(hub, _payloadFor(author, 5), AUTHOR_KEY);
        IArticleAnchor.ArticleSubmission memory second = _payloadFor(author, 6);
        bytes memory sig2 = _signArticle(hub, second, AUTHOR_KEY);

        vm.expectRevert(IArticleAnchor.RateLimited.selector);
        hub.submitArticle(_leafOf(second), sig2, second);
    }

    function test_duplicateUuidReverts() public {
        ArticleAnchor hub = _deployHub();
        address author = vm.addr(AUTHOR_KEY);
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(author, 7);
        _submitAs(hub, p, AUTHOR_KEY);
        bytes memory sig = _signArticle(hub, p, AUTHOR_KEY);
        vm.warp(block.timestamp + 1 hours); // clear the per-author rate limit

        vm.expectRevert(IArticleAnchor.DuplicateUuid.selector);
        hub.submitArticle(_leafOf(p), sig, p);
    }

    function test_thirdPartySubmitWithAuthorSigPasses() public {
        ArticleAnchor hub = _deployHub();
        address author = vm.addr(AUTHOR_KEY);
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(author, 8);
        bytes32 leaf = _leafOf(p);
        bytes memory sig = _signArticle(hub, p, AUTHOR_KEY);

        vm.expectEmit(address(hub));
        emit Submitted(author, address(0xBEEF), leaf);
        vm.prank(address(0xBEEF));
        hub.submitArticle(leaf, sig, p);

        assertEq(hub.journalLength(), 1, "relayed leaf journaled");
        assertEq(hub.journal(0), leaf, "leaf value");
    }

    function test_forgedByAuthorSigReverts() public {
        ArticleAnchor hub = _deployHub();
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(AUTHOR_KEY), 9);
        bytes memory forged = _signArticle(hub, p, FORGER_KEY);

        vm.expectRevert(IArticleAnchor.NotAuthor.selector);
        hub.submitArticle(_leafOf(p), forged, p);
    }

    /// @dev EIP-712 domain binding: a payload signed for another verifying
    /// contract or another chain cannot authorize a submit on this hub —
    /// the digest differs, so recovery yields a different address.
    function test_payloadSignedForAnotherDomainReverts() public {
        ArticleAnchor hub = _deployHub();
        ArticleAnchor otherHub = _deployHub();
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(AUTHOR_KEY), 10);
        bytes32 leaf = _leafOf(p);

        bytes memory foreignContractSig = _signArticle(otherHub, p, AUTHOR_KEY);
        vm.expectRevert(IArticleAnchor.NotAuthor.selector);
        hub.submitArticle(leaf, foreignContractSig, p);

        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        bytes memory foreignChainSig = _signArticle(hub, p, AUTHOR_KEY);
        vm.chainId(originalChainId);

        vm.expectRevert(IArticleAnchor.NotAuthor.selector);
        hub.submitArticle(leaf, foreignChainSig, p);
    }

    /// @dev The uuid dedup must be scoped to the author: otherwise anyone can
    /// squat a victim's predictable uuid (e.g. keccak(content)) with their own
    /// payload and permanently block the victim's real article.
    function test_uuidSquatDoesNotBlockVictim() public {
        ArticleAnchor hub = _deployHub();
        bytes32 predicted = keccak256("predictable content id");

        IArticleAnchor.ArticleSubmission memory squat = _payloadFor(vm.addr(FORGER_KEY), 21);
        squat.uuid = predicted;
        _submitAs(hub, squat, FORGER_KEY); // attacker front-runs the uuid

        IArticleAnchor.ArticleSubmission memory victim = _payloadFor(vm.addr(AUTHOR_KEY), 22);
        victim.uuid = predicted;
        _submitAs(hub, victim, AUTHOR_KEY); // must NOT revert "dup"

        assertEq(hub.journalLength(), 2, "both authors journaled");
    }

    /// @dev Same author, same uuid, any lane: still exactly once.
    function test_sameAuthorSameUuidStillDeduped() public {
        ArticleAnchor hub = _deployHub();
        address author = vm.addr(AUTHOR_KEY);

        IArticleAnchor.ArticleSubmission memory p = _payloadFor(author, 23);
        p.uuid = keccak256("one shot");
        _submitAs(hub, p, AUTHOR_KEY);
        vm.warp(block.timestamp + 1 hours);

        IArticleAnchor.ArticleSubmission memory twin = _payloadFor(author, 24);
        twin.uuid = keccak256("one shot"); // same uuid, different content
        bytes memory sig = _signArticle(hub, twin, AUTHOR_KEY);

        vm.expectRevert(IArticleAnchor.DuplicateUuid.selector);
        hub.submitArticle(_leafOf(twin), sig, twin);
    }
}
