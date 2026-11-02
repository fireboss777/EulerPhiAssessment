// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "../../src/interfaces/IArticleAnchor.sol";
import { ISubmissionGateway } from "../../src/interfaces/ISubmissionGateway.sol";

/// @notice Test double: relays a submission but REFUSES ETH — no `receive()`,
/// no `fallback()`. The gateway's excess refund targets `msg.sender`, so this
/// is the only shape of caller that can make it fail: EOAs and the test base
/// all accept transfers. Exists so `RefundFailed` (ISubmissionGateway) has a
/// test — without it the "the excess never strands silently" revert path is
/// dead code from the suite's point of view.
contract RejectingSubmitter {
    function submit(
        ISubmissionGateway gw,
        bytes32 leaf,
        bytes calldata sig,
        IArticleAnchor.ArticleSubmission calldata payload
    ) external payable {
        gw.submitArticle{ value: msg.value }(leaf, sig, payload);
    }
}
