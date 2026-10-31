// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { Client } from "../src/interfaces/Client.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ISubmissionGateway } from "../src/interfaces/ISubmissionGateway.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
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
        hub = _deployHub(address(this), address(mock), TEST_SEL);
        hub.setGateway(GATEWAY);
    }

    // ------------------------------------------------------------------
    // Inbound lane (Ethereum L1 gateway -> hub)
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

    function test_replayAcrossLanesReverts() public {
        (bytes32 leaf, bytes memory sig, IArticleAnchor.ArticleSubmission memory p) = _signedLeaf(AUTHOR_KEY, 4);

        // Lane 1: direct public call on the hub.
        hub.submitArticle(leaf, sig, p);
        assertEq(hub.journalLength(), 1, "direct submit landed");
        vm.warp(block.timestamp + 1 hours); // clear the per-author rate limit

        // Lane 2: the very same signed payload delivered via CCIP from L1.
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

    // ------------------------------------------------------------------
    // Outbound notarization (hub -> L1 gateway), K-confirmation gate
    // ------------------------------------------------------------------

    function test_notarizeUnanchoredBatchReverts() public {
        vm.expectRevert(IArticleAnchor.NoBatch.selector);
        hub.notarize{ value: 0 }(0);
    }

    function test_notarizeRevertsBeforeK() public {
        _seedBatch(hub, 10);
        hub.anchorNextBatch();
        uint256 anchoredAt = hub.anchoredAtBlock(0);
        vm.roll(anchoredAt + ArticleLib.NOTARY_K - 1);

        vm.expectRevert(IArticleAnchor.NotFinal.selector);
        hub.notarize{ value: 0.01 ether }(0);
    }

    function test_notarizeSendsAfterK() public {
        _seedBatch(hub, 10);
        hub.anchorNextBatch();
        vm.roll(hub.anchoredAtBlock(0) + ArticleLib.NOTARY_K);
        bytes32 root = hub.rootAt(0);

        hub.notarize{ value: 0.02 ether }(0);

        assertEq(mock.lastDest(), TEST_SEL, "destination = gateway chain");
        assertEq(mock.lastReceiver(), GATEWAY, "receiver = gateway");
        assertEq(mock.lastValue(), 0.02 ether, "fee value forwarded");
        assertEq(
            mock.lastData(), abi.encodeCall(ISubmissionGateway.receiveRoot, (0, root)), "payload = (batchIndex, root)"
        );
        assertGt(mock.lastExtraArgs().length, 0, "gas limit extraArgs attached");
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
