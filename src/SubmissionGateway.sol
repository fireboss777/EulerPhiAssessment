// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Client } from "./interfaces/Client.sol";
import { IArticleAnchor } from "./interfaces/IArticleAnchor.sol";
import { IRouterClient } from "./interfaces/IRouterClient.sol";
import { ISubmissionGateway } from "./interfaces/ISubmissionGateway.sol";
import { GatewayLib } from "./libraries/GatewayLib.sol";

/// @title SubmissionGateway — the L1 endpoint (paid entry lane, headless).
/// @notice Every external entry point, constant and event is declared and
/// documented on `ISubmissionGateway`, which this contract inherits — read
/// the interface for the API (including the paid-lane / no-ecrecover design
/// notes). Its fee-lane policy lives in `GatewayLib`; this contract holds
/// three immutables, NO storage slot and NO constant of its own.
/// Only implementation-side members are documented here.
contract SubmissionGateway is ISubmissionGateway {
    /// @inheritdoc ISubmissionGateway
    address public immutable ROUTER;
    /// @inheritdoc ISubmissionGateway
    address public immutable HUB;
    /// @inheritdoc ISubmissionGateway
    uint64 public immutable BASE_CHAIN_SELECTOR;

    constructor(address router_, address hub_, uint64 baseChainSelector_) {
        ROUTER = router_;
        HUB = hub_;
        BASE_CHAIN_SELECTOR = baseChainSelector_;
    }

    // ------------------------------------------------------------------
    // Paid entry lane: Ethereum -> hub
    // ------------------------------------------------------------------

    /// @inheritdoc ISubmissionGateway
    function submitArticle(bytes32 leafDigest, bytes calldata sig, IArticleAnchor.ArticleSubmission calldata payload)
        external
        payable
    {
        // Cheap, chain-agnostic sanity checks before any fee moves:
        require(block.timestamp <= payload.deadline, Expired());
        require(keccak256(abi.encode(payload)) == leafDigest, DigestMismatch());

        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(HUB),
            data: abi.encode(leafDigest, sig, payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // native fee via msg.value
            extraArgs: Client._argsToBytesV1(GatewayLib.SUBMIT_GAS_LIMIT)
        });

        uint256 fee = IRouterClient(ROUTER).getFee(BASE_CHAIN_SELECTOR, m);
        require(msg.value >= fee, InsufficientFee());

        bytes32 messageId = IRouterClient(ROUTER).ccipSend{ value: fee }(BASE_CHAIN_SELECTOR, m);
        emit SubmittedOnL1(msg.sender, leafDigest, messageId);

        // Return the unused portion (router keeps overpayment; we don't).
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{ value: excess }("");
            require(ok, RefundFailed());
        }
    }
}
