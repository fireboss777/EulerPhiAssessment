// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArticleAnchor} from "../src/ArticleAnchor.sol";
import {ArticleSubmission} from "../src/ArticleLib.sol";
import {Client} from "../src/interfaces/Client.sol";
import {ISubmissionGateway} from "../src/interfaces/ISubmissionGateway.sol";
import {SubmissionGateway} from "../src/SubmissionGateway.sol";
import {ArticleTestBase} from "./utils/ArticleTestBase.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract GatewayTest is ArticleTestBase {
    uint64 internal constant BASE_SEL = 999999;
    address internal constant HUB = address(0x4B1);
    address internal constant FOREIGN = address(0xF0E1);
    uint256 internal constant AUTHOR_KEY = 0xD00D;

    MockRouter internal mock;
    SubmissionGateway internal gw;

    function setUp() public override {
        super.setUp();
        mock = new MockRouter();
        gw = new SubmissionGateway(address(mock), HUB, BASE_SEL);
    }

    /// @dev Gateway lane never verifies signatures (decision 1a) — sig bytes
    /// here are payload bytes, byte-identity is what's under test.
    function _payloadAndSig() internal returns (ArticleSubmission memory p, bytes memory sig) {
        p = payloadFor(vm.addr(AUTHOR_KEY), 11);
        sig = abi.encodePacked(bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), uint8(27));
    }

    /// @dev Production wire format: the hub sends `abi.encodeCall` of
    /// `receiveRoot` — fixtures must use the SAME encoding as the contract,
    /// otherwise the tests validate a payload nobody produces.
    function _rootMsg(uint64 sel, address sender, uint256 batchIndex, bytes32 root)
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(batchIndex, root)),
            sourceChainSelector: sel,
            sender: abi.encode(sender),
            data: abi.encodeCall(ISubmissionGateway.receiveRoot, (batchIndex, root)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    // ------------------------------------------------------------------
    // Paid entry lane (Ethereum -> hub)
    // ------------------------------------------------------------------

    function test_gatewayForwardsByteIdenticalCalldata() public {
        (ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        bytes32 leaf = leafOf(p);
        vm.deal(address(this), 1 ether);

        gw.submitArticle{value: 0.05 ether}(leaf, sig, p);

        assertEq(mock.lastDest(), BASE_SEL, "destination chain");
        assertEq(mock.lastReceiver(), HUB, "receiver = hub");
        assertEq(mock.lastValue(), mock.fee(), "exactly the fee forwarded");
        assertEq(mock.lastData(), abi.encode(leaf, sig, p), "bytes identical in transit");

        (bytes32 leaf2, bytes memory sig2, ArticleSubmission memory p2) =
            abi.decode(mock.lastData(), (bytes32, bytes, ArticleSubmission));
        assertEq(leaf2, leaf, "leaf roundtrip");
        assertEq(sig2, sig, "sig roundtrip");
        assertEq(keccak256(abi.encode(p2)), keccak256(abi.encode(p)), "payload roundtrip");
    }

    function test_gatewayDigestMismatchReverts() public {
        (ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        bytes32 wrongLeaf = bytes32(uint256(leafOf(p)) ^ 1);

        vm.expectRevert("digest mismatch");
        gw.submitArticle{value: 0}(wrongLeaf, sig, p);
    }

    function test_insufficientFeeReverts() public {
        (ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        vm.deal(address(this), 1 ether);

        vm.expectRevert("insufficient fee");
        gw.submitArticle{value: 0.005 ether}(leafOf(p), sig, p); // fee is 0.01
    }

    function test_excessRefunded() public {
        (ArticleSubmission memory p, bytes memory sig) = _payloadAndSig();
        vm.deal(address(this), 1 ether);

        gw.submitArticle{value: 0.03 ether}(leafOf(p), sig, p);

        assertEq(address(gw).balance, 0, "gateway retains nothing");
        assertEq(mock.lastValue(), mock.fee(), "router got the fee, not the excess");
        assertEq(address(this).balance, 1 ether - mock.fee(), "excess came back (gas excluded)");
    }

    // ------------------------------------------------------------------
    // Notary receiver (hub -> gateway), pinned + monotonic
    // ------------------------------------------------------------------

    function test_receiveRootMonotonicPrevRoot() public {
        bytes32 r0 = keccak256("r0");
        bytes32 r1 = keccak256("r1");

        // Batch 1 before batch 0 — rejected (no skipping, no reordering).
        vm.expectRevert("out of order");
        mock.deliverViaCcipReceive(address(gw), _rootMsg(BASE_SEL, HUB, 1, r1));

        mock.deliverViaCcipReceive(address(gw), _rootMsg(BASE_SEL, HUB, 0, r0));
        assertEq(gw.notarizedRoot(0), r0, "batch 0 recorded");
        assertEq(gw.nextBatch(), 1, "cursor advanced");

        // Replay of batch 0 — rejected.
        vm.expectRevert("out of order");
        mock.deliverViaCcipReceive(address(gw), _rootMsg(BASE_SEL, HUB, 0, r0));

        mock.deliverViaCcipReceive(address(gw), _rootMsg(BASE_SEL, HUB, 1, r1));
        assertEq(gw.notarizedRoot(1), r1, "batch 1 recorded");
    }

    function test_receiveRootWrongSourceReverts() public {
        vm.expectRevert("bad chain");
        mock.deliverViaCcipReceive(address(gw), _rootMsg(BASE_SEL + 1, HUB, 0, keccak256("r")));

        vm.expectRevert("bad sender");
        mock.deliverViaCcipReceive(address(gw), _rootMsg(BASE_SEL, FOREIGN, 0, keccak256("r")));
    }

    /// @dev `receiveRoot` is public (plan-named API) but router-gated inside:
    /// a direct caller — even with a perfectly ordered batch — dies at the gate.
    function test_receiveRootDirectCallReverts() public {
        vm.expectRevert("not router");
        gw.receiveRoot(0, keccak256("r0"));
    }

    // ------------------------------------------------------------------
    // Wire-format round trip: gateway encode -> (router) -> hub decode.
    // The gateway never verifies signatures, so this proves the two sides
    // agree on bytes end-to-end — the failure mode no unit test sees.
    // ------------------------------------------------------------------

    function test_gatewayPayloadLandsInHub() public {
        // Hub pinned to this gateway, mock as shared router.
        ArticleAnchor hub = deployHub(address(this), address(mock), BASE_SEL);
        hub.setGateway(address(gw));
        assertEq(hub.gateway(), address(gw), "wiring");

        uint256 key = AUTHOR_KEY;
        ArticleSubmission memory p = payloadFor(vm.addr(key), 12);
        bytes32 leaf = leafOf(p);
        bytes memory sig = signArticle(hub, p, key);
        vm.deal(address(this), 1 ether);

        gw.submitArticle{value: 0.05 ether}(leaf, sig, p);

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

    // ------------------------------------------------------------------
    // Wire-format round trip: hub notarize encode -> (router) -> gateway decode.
    // Send-side assertions alone cannot see a decoder mismatch — they check
    // the payload against the very interface the sender used.
    // ------------------------------------------------------------------

    function test_notarizeRoundTripIntoGateway() public {
        ArticleAnchor hub = deployHub(address(this), address(mock), BASE_SEL);
        SubmissionGateway gw2 = new SubmissionGateway(address(mock), address(hub), BASE_SEL);
        hub.setGateway(address(gw2)); // production wiring, not a dummy address
        seedBatch(hub, 10);
        hub.anchorNextBatch();
        vm.roll(hub.anchoredAtBlock(0) + hub.NOTARY_K());
        vm.deal(address(this), 1 ether);

        hub.notarize{value: mock.fee()}(0); // hub-side encode (encodeCall)

        Client.Any2EVMMessage memory delivered = Client.Any2EVMMessage({
            messageId: mock.lastMessageId(),
            sourceChainSelector: BASE_SEL,
            sender: abi.encode(address(hub)),
            data: mock.lastData(), // exactly the bytes the hub produced
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        mock.deliverViaCcipReceive(address(gw2), delivered);

        assertEq(gw2.notarizedRoot(0), hub.rootAt(0), "root roundtrip through both contracts");
        assertEq(gw2.nextBatch(), 1, "cursor advanced");
    }

    function test_receiveRootRejectsWrongWireFormat() public {
        bytes32 root = keccak256("r0");

        Client.Any2EVMMessage memory noSelector = _rootMsg(BASE_SEL, HUB, 0, root);
        noSelector.data = abi.encode(0, root); // 64-byte tuple: no selector
        vm.expectRevert("bad len");
        mock.deliverViaCcipReceive(address(gw), noSelector);

        Client.Any2EVMMessage memory wrongSelector = _rootMsg(BASE_SEL, HUB, 0, root);
        wrongSelector.data = abi.encodePacked(hex"deadbeef", abi.encode(0, root));
        vm.expectRevert("bad selector");
        mock.deliverViaCcipReceive(address(gw), wrongSelector);
    }
}
