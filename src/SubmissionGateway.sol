// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { SubmissionGatewayGetters } from "./SubmissionGatewayGetters.sol";
import { Client } from "./interfaces/Client.sol";
import { IAny2EVMMessageReceiver } from "./interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "./interfaces/IRouterClient.sol";
import { ISubmissionGateway } from "./interfaces/ISubmissionGateway.sol";
import { ArticleSubmission } from "./libraries/ArticleLib.sol";
import { GatewayLib } from "./libraries/GatewayLib.sol";

/// @title SubmissionGateway — the L1 endpoint (two roles, both pinned).
/// @notice Every external entry point, getter, constant and event is declared
/// and documented on `ISubmissionGateway`, which this contract inherits — read
/// the interface for the API (including the paid-lane / no-ecrecover design
/// notes). Its ERC-7201 namespace (slot constant + pointer) lives in
/// `GatewayLib`, so this contract declares NO state variable and NO constant.
/// Only implementation-side members are documented here.
contract SubmissionGateway is ISubmissionGateway, SubmissionGatewayGetters, IAny2EVMMessageReceiver {
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
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload)
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

    // ------------------------------------------------------------------
    // Notary receiver: hub -> gateway (roots land here)
    // ------------------------------------------------------------------

    /// @dev Inherits its documentation from `ISubmissionGateway`, which
    /// redeclares it alongside Chainlink's `IAny2EVMMessageReceiver` — hence
    /// the explicit override list.
    /// @inheritdoc ISubmissionGateway
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        override(ISubmissionGateway, IAny2EVMMessageReceiver)
    {
        require(message.sourceChainSelector == BASE_CHAIN_SELECTOR, BadChain());
        require(abi.decode(message.sender, (address)) == HUB, BadSender());
        _applyNotaryPayload(message.data);
    }

    /// @inheritdoc ISubmissionGateway
    function receiveRoot(uint256 batchIndex, bytes32 root) public {
        require(msg.sender == address(ROUTER), NotRouter());
        Storage storage $ = GatewayLib.getStorage();
        require(batchIndex == $.nextBatch, OutOfOrder());

        $.notarizedRoot[batchIndex] = root;
        $.nextBatch = batchIndex + 1;
        emit RootNotarized(batchIndex, root);
    }

    /// @dev The hub encodes `receiveRoot` with `abi.encodeCall` — 4-byte
    /// selector + the two encoded words (68 bytes). Length AND selector are
    /// checked before decoding, so a payload built for any other function can
    /// never be reinterpreted as `(batchIndex, root)`. Verified end-to-end by
    /// `test_notarizeRoundTripIntoGateway` (hub encode -> gateway decode).
    function _applyNotaryPayload(bytes calldata data) internal {
        require(data.length == 68, BadPayloadLength());
        require(bytes4(data[0:4]) == ISubmissionGateway.receiveRoot.selector, BadSelector());
        (uint256 batchIndex, bytes32 root) = abi.decode(data[4:], (uint256, bytes32));
        receiveRoot(batchIndex, root);
    }
}
