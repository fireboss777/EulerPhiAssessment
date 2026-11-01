// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { Client } from "../src/interfaces/Client.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ISubmissionGateway } from "../src/interfaces/ISubmissionGateway.sol";
import { MockRouter } from "./mocks/MockRouter.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";

contract GatewayTest is ArticleTestBase {
    uint64 internal constant BASE_SEL = 999_999;
    address internal constant HUB = address(0x4B1);
    address internal constant FOREIGN = address(0xF0E1);
    uint256 internal constant AUTHOR_KEY = 0xD00D;

    MockRouter internal mock;
    SubmissionGateway internal gw;

    function setUp() public override {
        super.setUp();
        mock = new MockRouter();
        gw = _deployGateway(address(this), address(mock), HUB, BASE_SEL);
    }

    // ------------------------------------------------------------------
    // Paid entry lane (Ethereum -> hub)
    // ------------------------------------------------------------------

    function test_gatewayForwardsByteIdenticalCalldata() public {
        (IArticleAnchor.ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        bytes32 leaf = _leafOf(p);
        vm.deal(address(this), 1 ether);

        gw.submitArticle{ value: 0.05 ether }(leaf, sig, p);

        assertEq(mock.lastDest(), BASE_SEL, "destination chain");
        assertEq(mock.lastReceiver(), HUB, "receiver = hub");
        assertEq(mock.lastValue(), mock.fee(), "exactly the fee forwarded");
        assertEq(mock.lastData(), abi.encode(leaf, sig, p), "bytes identical in transit");

        (bytes32 leaf2, bytes memory sig2, IArticleAnchor.ArticleSubmission memory p2) =
            abi.decode(mock.lastData(), (bytes32, bytes, IArticleAnchor.ArticleSubmission));
        assertEq(leaf2, leaf, "leaf roundtrip");
        assertEq(sig2, sig, "sig roundtrip");
        assertEq(keccak256(abi.encode(p2)), keccak256(abi.encode(p)), "payload roundtrip");
    }

    function test_gatewayDigestMismatchReverts() public {
        (IArticleAnchor.ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        bytes32 wrongLeaf = bytes32(uint256(_leafOf(p)) ^ 1);

        vm.expectRevert(ISubmissionGateway.DigestMismatch.selector);
        gw.submitArticle{ value: 0 }(wrongLeaf, sig, p);
    }

    function test_insufficientFeeReverts() public {
        (IArticleAnchor.ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        vm.deal(address(this), 1 ether);

        vm.expectRevert(ISubmissionGateway.InsufficientFee.selector);
        gw.submitArticle{ value: 0.005 ether }(_leafOf(p), sig, p); // fee is 0.01
    }

    function test_excessRefunded() public {
        (IArticleAnchor.ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        vm.deal(address(this), 1 ether);

        gw.submitArticle{ value: 0.03 ether }(_leafOf(p), sig, p);

        assertEq(address(gw).balance, 0, "gateway retains nothing");
        assertEq(mock.lastValue(), mock.fee(), "router got the fee, not the excess");
        assertEq(address(this).balance, 1 ether - mock.fee(), "excess came back (gas excluded)");
    }

    // ------------------------------------------------------------------
    // Wire-format round trip: gateway encode -> (router) -> hub decode.
    // The gateway never verifies signatures, so this proves the two sides
    // agree on bytes end-to-end — the failure mode no unit test sees.
    // ------------------------------------------------------------------

    function test_gatewayPayloadLandsInHub() public {
        // Hub pinned to this gateway, mock as shared router.
        ArticleAnchor hub = _deployHub(address(this), address(mock));
        hub.setGateway(BASE_SEL, address(gw));
        assertEq(hub.gatewayAt(BASE_SEL), address(gw), "wiring");

        uint256 key = AUTHOR_KEY;
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(key), 12);
        bytes32 leaf = _leafOf(p);
        bytes memory sig = _signArticle(hub, p, key);
        vm.deal(address(this), 1 ether);

        gw.submitArticle{ value: 0.05 ether }(leaf, sig, p);

        // Relay the captured payload as if CCIP delivered it.
        Client.Any2EVMMessage memory delivered = Client.Any2EVMMessage({
            messageId: mock.lastMessageId(),
            sourceChainSelector: BASE_SEL,
            sender: abi.encode(address(gw)),
            data: mock.lastData(),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        mock.deliver(address(hub), delivered);

        assertEq(hub.journalLength(), 1, "payload journaled via gateway lane");
        assertEq(hub.journal(0), leaf, "leaf roundtrip through both contracts");
    }

    /// @dev Gateway lane never verifies signatures (decision 1a) — sig bytes
    /// here are payload bytes, byte-identity is what's under test.
    function _payloadAndSig() internal returns (IArticleAnchor.ArticleSubmission memory p, bytes memory sig) {
        p = _payloadFor(vm.addr(AUTHOR_KEY), 11);
        sig = abi.encodePacked(bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), uint8(27));
    }
}
