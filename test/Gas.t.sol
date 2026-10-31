// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { ArticleSubmission } from "../src/libraries/ArticleLib.sol";
import { MockRouter } from "./mocks/MockRouter.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";
import { console } from "forge-std/console.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

/// @notice Marginal-cost meter: the numbers quoted in README's cost table.
/// Each figure is a `gasleft()` delta around ONE call taken from a COLD
/// access list (`vm.cool` first) — the state a real, separate transaction
/// starts from — so no fixture warmth leaks into the numbers.
/// Smoke-asserted so a cost regression turns this red instead of silently
/// shipping a stale README table.
contract GasTest is ArticleTestBase {
    uint64 internal constant SEL = 8453;
    uint256 internal constant KEY = 0x9A5;

    function test_gasSubmit() public {
        ArticleAnchor hub = _newHub(address(0));
        (uint256 cold,) = _measuredSubmit(hub, 1, KEY);
        (uint256 warm,) = _measuredSubmit(hub, 2, KEY ^ 0x51);
        console.log("submit (cold, 1st leaf)   ", cold);
        console.log("submit (steady state)     ", warm);
        assertLt(cold, 180_000, "submit cost drifted up");
        assertLt(warm, 120_000, "steady submit cost drifted up");
    }

    function test_gasAnchor() public {
        ArticleAnchor hub = _newHub(address(0));
        _seedBatch(hub, 10);
        vm.cool(address(hub));
        uint256 g0 = gasleft();
        hub.anchorNextBatch();
        uint256 anchor10 = g0 - gasleft();

        ArticleAnchor hub2 = _newHub(address(0));
        _seedBatch(hub2, 200);
        vm.cool(address(hub2));
        g0 = gasleft();
        hub2.anchorNextBatch();
        uint256 anchor200 = g0 - gasleft();

        console.log("anchor (10 leaves)        ", anchor10);
        console.log("anchor (200 leaves)       ", anchor200);
        assertLt(anchor10, 175_000, "anchor(10) cost drifted up");
        assertLt(anchor200, 950_000, "anchor(200) cost drifted up");
    }

    function test_gasVerify() public {
        ArticleAnchor hub = _newHub(address(0));
        _seedBatch(hub, 10);
        hub.anchorNextBatch();
        bytes32[] memory proof = MerkleTreeLib.leafProof(MerkleTreeLib.build(_sliceJournal(hub, 0, 10)), 3);

        vm.cool(address(hub)); // a reader's eth_call starts cold
        uint256 g0 = gasleft();
        bool ok = hub.verifyAgainstBatch(0, hub.journal(3), proof);
        uint256 used = g0 - gasleft();

        assertTrue(ok, "proof must verify");
        console.log("verify (10-leaf batch)    ", used);
        assertLt(used, 17_000, "verify cost drifted up");
    }

    function test_gasNotarize() public {
        MockRouter mock = new MockRouter();
        mock.setCapture(false); // forensics off: measure the keeper's own cost
        ArticleAnchor hub = _newHub(address(mock));
        _seedBatch(hub, 10);
        hub.anchorNextBatch();
        vm.roll(hub.anchoredAtBlock(0) + hub.NOTARY_K());
        vm.deal(address(this), 1 ether);
        vm.cool(address(hub));
        vm.cool(address(mock));

        uint256 g0 = gasleft();
        hub.notarize{ value: mock.fee() }(0);
        uint256 used = g0 - gasleft();

        console.log("notarize (incl. ccipSend) ", used);
        assertLt(used, 52_000, "notarize cost drifted up");
    }

    function test_gasGatewaySubmit() public {
        MockRouter mock = new MockRouter();
        mock.setCapture(false); // forensics off: measure the gateway's own cost
        ArticleAnchor hub = _newHub(address(mock));
        SubmissionGateway gw = new SubmissionGateway(address(mock), address(hub), SEL);
        vm.deal(address(this), 1 ether);

        ArticleSubmission memory p = _payloadFor(vm.addr(KEY), 3);
        bytes memory sig = _signArticle(hub, p, KEY);
        uint256 g0 = gasleft();
        gw.submitArticle{ value: mock.fee() }(_leafOf(p), sig, p);
        uint256 used = g0 - gasleft();

        console.log("gateway submit (incl fee) ", used);
        assertLt(used, 52_000, "gateway cost drifted up");
    }

    function _newHub(address router) internal returns (ArticleAnchor) {
        ArticleAnchor hub = _deployHub(address(this), router, SEL);
        hub.setGateway(address(0x9999));
        return hub;
    }

    function _measuredSubmit(ArticleAnchor hub, uint256 salt, uint256 key)
        internal
        returns (uint256 used, ArticleSubmission memory p)
    {
        p = _payloadFor(vm.addr(key), salt);
        bytes memory sig = _signArticle(hub, p, key);
        vm.cool(address(hub)); // fresh transaction: all slots cold
        uint256 g0 = gasleft();
        hub.submitArticle(_leafOf(p), sig, p);
        used = g0 - gasleft();
    }
}
