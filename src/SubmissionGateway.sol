// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ArticleSubmission} from "./ArticleLib.sol";
import {Client} from "./interfaces/Client.sol";
import {IRouterClient} from "./interfaces/IRouterClient.sol";
import {ISubmissionGateway} from "./interfaces/ISubmissionGateway.sol";
import {IAny2EVMMessageReceiver} from "./interfaces/IAny2EVMMessageReceiver.sol";

/// @title SubmissionGateway — the L1 endpoint (two roles, both pinned).
/// @notice Every external entry point, getter, constant and event is declared
/// and documented on `ISubmissionGateway`, which this contract inherits — read
/// the interface for the API (including the paid-lane / no-ecrecover design
/// notes). Only implementation-side members are documented here.
contract SubmissionGateway is ISubmissionGateway, IAny2EVMMessageReceiver {
    /// @inheritdoc ISubmissionGateway
    uint256 public constant SUBMIT_GAS_LIMIT = 400_000;

    /// @inheritdoc ISubmissionGateway
    address public immutable router;
    /// @inheritdoc ISubmissionGateway
    address public immutable hub;
    /// @inheritdoc ISubmissionGateway
    uint64 public immutable baseChainSelector;

    /// @inheritdoc ISubmissionGateway
    uint256 public nextBatch;
    /// @inheritdoc ISubmissionGateway
    mapping(uint256 => bytes32) public notarizedRoot;

    constructor(address router_, address hub_, uint64 baseChainSelector_) {
        router = router_;
        hub = hub_;
        baseChainSelector = baseChainSelector_;
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
            receiver: abi.encode(hub),
            data: abi.encode(leafDigest, sig, payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // native fee via msg.value
            extraArgs: Client._argsToBytesV1(SUBMIT_GAS_LIMIT)
        });

        uint256 fee = IRouterClient(router).getFee(baseChainSelector, m);
        require(msg.value >= fee, InsufficientFee());

        bytes32 messageId = IRouterClient(router).ccipSend{value: fee}(baseChainSelector, m);
        emit SubmittedOnL1(msg.sender, leafDigest, messageId);

        // Return the unused portion (router keeps overpayment; we don't).
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
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
        require(message.sourceChainSelector == baseChainSelector, BadChain());
        require(abi.decode(message.sender, (address)) == hub, BadSender());
        _applyNotaryPayload(message.data);
    }

    /// @inheritdoc ISubmissionGateway
    function receiveRoot(uint256 batchIndex, bytes32 root) public {
        require(msg.sender == address(router), NotRouter());
        require(batchIndex == nextBatch, OutOfOrder());

        notarizedRoot[batchIndex] = root;
        nextBatch = batchIndex + 1;
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
