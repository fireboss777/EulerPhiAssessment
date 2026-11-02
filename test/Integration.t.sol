// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Anchor } from "../script/Anchor.s.sol";
import { DeployGateway } from "../script/DeployGateway.s.sol";
import { DeployHub } from "../script/DeployHub.s.sol";
import { ArticleAnchor } from "../src/ArticleAnchor.sol";
import { SubmissionGateway } from "../src/SubmissionGateway.sol";
import { Client } from "../src/interfaces/Client.sol";
import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
import { MockRouter } from "./mocks/MockRouter.sol";
import { ArticleTestBase } from "./utils/ArticleTestBase.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

/// @notice The documented lifecycle, end to end, in ONE test — the integration
/// suite that replaced `script/e2e-anvil.sh` (its scripted form was overkill:
/// bash orchestration, hardcoded keys, no CI, and it never crossed chains
/// anyway). Everything runs through the REAL artifacts: the deploy scripts'
/// `run()` (param plumbing + proxy wiring), the paid lane with a fee-quote
/// router, a CCIP delivery on the hub side, and the keeper script after the
/// batch window. The two "chains" are the two contract sets plus the mock
/// transport — the standard Foundry shape, same as CCIP.t.sol.
contract IntegrationTest is ArticleTestBase {
    uint64 internal constant GW_SEL = 111_222; // source chain's Chainlink selector
    uint256 internal constant AUTHOR_KEY = 0xB0B;

    function test_fullLifecycle_deployWireSubmitAnchor() public {
        // 1. Deploy the hub through its script — params, no env vars.
        MockRouter dstRouter = new MockRouter(); // hub side ("chain B")
        address hubAddr = new DeployHub().run(address(this), address(dstRouter));
        ArticleAnchor hub = ArticleAnchor(hubAddr);
        assertEq(hub.owner(), address(this), "hub wiring: owner from params");
        assertEq(hub.router(), address(dstRouter), "hub wiring: router from params");

        // 2. Deploy the gateway through its script — uint64 selector is typed,
        //    so a wrong-but-plausible selector cannot be expressed at all.
        MockRouter srcRouter = new MockRouter(); // gateway side ("chain A")
        address gwAddr = new DeployGateway().run(address(this), address(srcRouter), hubAddr, GW_SEL);
        SubmissionGateway gw = SubmissionGateway(payable(gwAddr));
        assertEq(gw.owner(), address(this), "gateway wiring: owner");
        assertEq(gw.router(), address(srcRouter), "gateway wiring: router");
        assertEq(gw.hub(), hubAddr, "gateway wiring: hub");
        assertEq(gw.baseChainSelector(), GW_SEL, "gateway wiring: selector");

        // 3. Wire the lane (owner call, per source chain).
        hub.setGateway(GW_SEL, gwAddr);
        assertEq(hub.gatewayAt(GW_SEL), gwAddr, "lane registered");

        // 4. Paid entry on chain A: fee quoted by the router, excess refunded.
        IArticleAnchor.ArticleSubmission memory p = _payloadFor(vm.addr(AUTHOR_KEY), 1);
        bytes32 leaf = _leafOf(p);
        bytes memory sig = _signArticle(hub, p, AUTHOR_KEY); // signed vs the HUB's live domain
        vm.deal(address(this), 1 ether);
        gw.submitArticle{ value: 0.05 ether }(leaf, sig, p);
        assertEq(srcRouter.lastDest(), GW_SEL, "ccipSend: destination");
        assertEq(srcRouter.lastReceiver(), hubAddr, "ccipSend: receiver = hub");
        assertEq(srcRouter.lastValue(), srcRouter.fee(), "ccipSend: exactly the quote forwarded");
        assertEq(address(gw).balance, 0, "gateway retains nothing");

        // 5. CCIP delivery on chain B: the hub's OWN router hands over the
        //    captured bytes — same payload, second chain.
        dstRouter.deliver(
            hubAddr,
            Client.Any2EVMMessage({
                messageId: srcRouter.lastMessageId(),
                sourceChainSelector: GW_SEL,
                sender: abi.encode(gwAddr),
                data: srcRouter.lastData(),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
        assertEq(hub.journalLength(), 1, "journaled across lanes");
        assertEq(hub.journal(0), leaf, "journal holds the leaf");
        assertEq(hub.pendingLeaves(), 1, "pending before the keeper");

        // 6. One article < MIN_BATCH: the keeper closes on the 6h window.
        vm.warp(block.timestamp + ArticleLib.BATCH_DEADLINE + 1);
        new Anchor().run(hubAddr);

        // 7. Anchored and publicly verifiable.
        assertEq(hub.anchoredBatches(), 1, "one batch frozen");
        assertEq(hub.pendingLeaves(), 0, "keeper consumed the window");
        assertTrue(hub.rootAt(0) != bytes32(0), "root exists");
        bytes32[] memory tree = MerkleTreeLib.build(_sliceJournal(hub, 0, 1));
        assertTrue(
            hub.verifyAgainstBatch(0, leaf, MerkleTreeLib.leafProof(tree, 0)),
            "published proof verifies against the frozen root"
        );
    }
}
