// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
contract SubmissionGateway is IAny2EVMMessageReceiver, ISubmissionGateway {
    uint256 public constant SUBMIT_GAS_LIMIT = 400_000;

    address public immutable router;
    address public immutable hub;
    uint64 public immutable baseChainSelector;

    uint256 public nextBatch;
    mapping(uint256 => bytes32) public notarizedRoot;

    constructor(address router_, address hub_, uint64 baseChainSelector_) {
        router = router_;
        hub = hub_;
        baseChainSelector = baseChainSelector_;
    }

    // ------------------------------------------------------------------
    // Paid entry lane: Ethereum -> hub
    // ------------------------------------------------------------------

    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload)
        external
        payable
    {
        // Cheap, chain-agnostic sanity checks before any fee moves:
        require(block.timestamp <= payload.deadline, "expired");
        require(keccak256(abi.encode(payload)) == leafDigest, "digest mismatch");

        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(hub),
            data: abi.encode(leafDigest, sig, payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // native fee via msg.value
            extraArgs: Client._argsToBytesV1(SUBMIT_GAS_LIMIT)
        });

        uint256 fee = IRouterClient(router).getFee(baseChainSelector, m);
        require(msg.value >= fee, "insufficient fee");

        bytes32 messageId = IRouterClient(router).ccipSend{value: fee}(baseChainSelector, m);
        emit SubmittedOnL1(msg.sender, leafDigest, messageId);

        // Return the unused portion (router keeps overpayment; we don't).
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
    }

    // ------------------------------------------------------------------
    // Notary receiver: hub -> gateway (roots land here)
    // ------------------------------------------------------------------

    /// @dev Inherits its documentation from `ISubmissionGateway`, which
    /// redeclares it alongside Chainlink's `IAny2EVMMessageReceiver` — hence
    /// the explicit override list.
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        override(IAny2EVMMessageReceiver, ISubmissionGateway)
    {
        require(message.sourceChainSelector == baseChainSelector, "bad chain");
        require(abi.decode(message.sender, (address)) == hub, "bad sender");
        _applyNotaryPayload(message.data);
    }

    /// @dev The hub encodes `receiveRoot` with `abi.encodeCall` — 4-byte
    /// selector + the two encoded words (68 bytes). Length AND selector are
    /// checked before decoding, so a payload built for any other function can
    /// never be reinterpreted as `(batchIndex, root)`. Verified end-to-end by
    /// `test_notarizeRoundTripIntoGateway` (hub encode -> gateway decode).
    function _applyNotaryPayload(bytes calldata data) internal {
        require(data.length == 68, "bad len");
        require(bytes4(data[0:4]) == ISubmissionGateway.receiveRoot.selector, "bad selector");
        (uint256 batchIndex, bytes32 root) = abi.decode(data[4:], (uint256, bytes32));
        receiveRoot(batchIndex, root);
    }

    function receiveRoot(uint256 batchIndex, bytes32 root) public {
        require(msg.sender == address(router), "not router");
        require(batchIndex == nextBatch, "out of order");

        notarizedRoot[batchIndex] = root;
        nextBatch = batchIndex + 1;
        emit RootNotarized(batchIndex, root);
    }
}
