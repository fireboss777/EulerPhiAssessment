// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { Client } from "../src/interfaces/Client.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { MockRouter } from "./mocks/MockRouter.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";

contract CCIPTest is ArticleTestBase {
    uint64 internal constant TEST_SEL = 111_111;
    address internal constant GATEWAY = address(0xA11CE);
    uint256 internal constant AUTHOR_KEY = 0xC0FFEE;
    address internal constant FOREIGN_SENDER = address(0xDEAD);

    MockRouter internal mock;
    ArticleAnchor internal hub;

    function setUp() public override {
        super.setUp();
        mock = new MockRouter();
        hub = _deployHub(address(this), address(mock));
        hub.setGateway(TEST_SEL, GATEWAY);
    }

    // ------------------------------------------------------------------
    // Inbound lane (source-chain gateways -> hub)
    // ------------------------------------------------------------------

    function test_whitelistedSourceSubmits() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 1);

        mock.deliver(address(hub), _inbound(TEST_SEL, GATEWAY, leaf, sig, p));

        assertEq(hub.journalLength(), 1, "journaled via CCIP");
        assertEq(hub.journal(0), leaf, "leaf value");
    }

    function test_wrongChainSelectorReverts() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 2);
        Client.Any2EVMMessage memory m = _inbound(TEST_SEL + 1, GATEWAY, leaf, sig, p);

        vm.expectRevert(IArticleAnchor.BadChain.selector);
        mock.deliver(address(hub), m);
    }

    function test_wrongSenderReverts() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 3);
        Client.Any2EVMMessage memory m = _inbound(TEST_SEL, FOREIGN_SENDER, leaf, sig, p);

        vm.expectRevert(IArticleAnchor.BadSender.selector);
        mock.deliver(address(hub), m);
    }

    function test_secondChainGatewayAccepted() public {
        uint64 selB = 222_222;
        address gatewayB = address(0xB0B);
        hub.setGateway(selB, gatewayB);
        assertEq(hub.gatewayAt(TEST_SEL), GATEWAY, "first chain still registered");
        assertEq(hub.gatewayAt(selB), gatewayB, "second chain registered");
        assertEq(hub.gatewayAt(999_999), address(0), "unknown chain reads 0");

        (bytes32 leafA, bytes memory sigA, IArticleAnchor.ArticleSubmission memory pA) = _signedLeaf(AUTHOR_KEY, 7);
        mock.deliver(address(hub), _inbound(TEST_SEL, GATEWAY, leafA, sigA, pA));
        vm.warp(block.timestamp + 1 hours); // clear the per-author rate limit
        (bytes32 leafB, bytes memory sigB, IArticleAnchor.ArticleSubmission memory pB) = _signedLeaf(AUTHOR_KEY, 8);
        mock.deliver(address(hub), _inbound(selB, gatewayB, leafB, sigB, pB));

        assertEq(hub.journalLength(), 2, "both source chains journaled");
        assertEq(hub.journal(0), leafA, "chain A leaf");
        assertEq(hub.journal(1), leafB, "chain B leaf");
    }

    function test_revokedChainReverts() public {
        hub.setGateway(TEST_SEL, address(0));
        assertEq(hub.gatewayAt(TEST_SEL), address(0), "revoked reads 0");
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 9);
        vm.expectRevert(IArticleAnchor.BadChain.selector);
        mock.deliver(address(hub), _inbound(TEST_SEL, GATEWAY, leaf, sig, p));
    }

    function test_crossChainSenderRejected() public {
        uint64 selB = 222_222;
        address gatewayB = address(0xB0B);
        hub.setGateway(selB, gatewayB);
        assertEq(hub.gatewayAt(selB), gatewayB, "both chains registered");

        // Sender of chain B announced under chain A: pairing is per-chain —
        // membership in the registered set is not enough (Q1: strict pairing).
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 10);
        vm.expectRevert(IArticleAnchor.BadSender.selector);
        mock.deliver(address(hub), _inbound(TEST_SEL, gatewayB, leaf, sig, p));
    }

    function test_replayAcrossLanesReverts() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 4);

        // Lane 1: direct public call on the hub.
        hub.submitArticle(leaf, sig, p);
        assertEq(hub.journalLength(), 1, "direct submit landed");
        vm.warp(block.timestamp + 1 hours); // clear the per-author rate limit

        // Lane 2: the very same signed payload delivered via CCIP from a source chain.
        Client.Any2EVMMessage memory m = _inbound(TEST_SEL, GATEWAY, leaf, sig, p);
        vm.expectRevert(IArticleAnchor.DuplicateUuid.selector);
        mock.deliver(address(hub), m);

        assertEq(hub.journalLength(), 1, "no duplicate leaf");
    }

    function test_ccipReceiveForwards() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 5);

        // The standard IAny2EVMMessageReceiver entry (what a real router calls).
        mock.deliver(address(hub), _inbound(TEST_SEL, GATEWAY, leaf, sig, p));

        assertEq(hub.journalLength(), 1, "ccipReceive lands the payload");
    }

    /// @dev The pin has three legs; `msg.sender == router` is the first and
    /// the only one a direct (non-CCIP) caller faces. Bypassing the router
    /// must die here even with a perfectly valid chain/sender tuple — the CCIP
    /// entry itself checks nothing, the lane handler behind it does.
    function test_directConsumeRejected() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 6);
        Client.Any2EVMMessage memory m = _inbound(TEST_SEL, GATEWAY, leaf, sig, p);

        vm.expectRevert(IArticleAnchor.NotRouter.selector);
        hub.ccipReceive(m);
    }

    /// @dev The router is INV-2's first gate, so rotation must actually REWIRE
    /// the lane: the retired router loses it immediately (NotRouter, even with
    /// a perfectly valid chain/sender tuple) and the replacement delivers.
    function test_routerRotationRewiresTheLane() public {
        MockRouter replacement = new MockRouter();
        hub.setRouter(address(replacement));
        assertEq(hub.router(), address(replacement), "router rotated");

        (bytes32 leafOld, bytes memory sigOld, IArticleAnchor.ArticleSubmission memory pOld) =
            _signedLeaf(AUTHOR_KEY, 11);
        vm.expectRevert(IArticleAnchor.NotRouter.selector);
        mock.deliver(address(hub), _inbound(TEST_SEL, GATEWAY, leafOld, sigOld, pOld)); // retired router

        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 12);
        replacement.deliver(address(hub), _inbound(TEST_SEL, GATEWAY, leaf, sig, p));

        assertEq(hub.journalLength(), 1, "replacement router delivers");
        assertEq(hub.journal(0), leaf, "leaf value");
    }

    function _signedLeaf(uint256 key, uint256 salt)
        internal
        returns (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p)
    {
        p = _payloadFor(vm.addr(key), salt);
        leaf = _leafOf(p);
        sig = _signArticle(hub, p, key);
    }

    function _inbound(
        uint64 sel,
        address sender,
        bytes32 leaf,
        bytes memory sig,
        IArticleAnchor.ArticleSubmission memory p
    ) internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(leaf, sender)),
            sourceChainSelector: sel,
            sender: abi.encode(sender),
            data: abi.encode(leaf, sig, p),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }
}
