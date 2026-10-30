// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArticleSubmission} from "./ArticleLib.sol";
import {Client} from "./interfaces/Client.sol";
import {IRouterClient} from "./interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "./interfaces/IAny2EVMMessageReceiver.sol";

/// @title SubmissionGateway — the L1 endpoint (two roles, both pinned).
/// @notice 1. Paid entry lane: `submitArticle` mirrors the hub's API plus
/// `payable` — the caller funds L1 execution + the CCIP fee for the L2 leg,
/// and one Ethereum transaction lands the payload in the hub's journal.
/// Deliberately performs NO signature checks (decision 1a): EIP-712 domains
/// are chain-bound, so the hub is the single signature authority — garbage
/// messages are priced by the attached fee instead of rejected by ecrecover.
/// @notice 2. Notary receiver: roots notarized upward by the hub arrive via
/// CCIP, pinned to (router, baseChainSelector, hub) and applied strictly in
/// batch order — the audit-grade "original tree" record on Ethereum.
contract SubmissionGateway is IAny2EVMMessageReceiver {
    /// @notice Hub-side calldata for a journaled submission is small; 400k
    /// covers digest+sig checks + journal SSTORE with generous headroom.
    uint256 public constant SUBMIT_GAS_LIMIT = 400_000;

    address public immutable router;
    address public immutable hub;
    uint64 public immutable baseChainSelector;

    /// @notice Next batch index acceptable — no skips, no reordering, no replays.
    uint256 public nextBatch;
    mapping(uint256 => bytes32) public notarizedRoot;

    event SubmittedOnL1(address indexed submitter, bytes32 indexed leafDigest, bytes32 messageId);
    event RootNotarized(uint256 indexed batchIndex, bytes32 root);

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

    /// @notice Standard router entry — context-gates, then applies.
    function ccipReceive(Client.Any2EVMMessage calldata message) external {
        require(message.sourceChainSelector == baseChainSelector, "bad chain");
        require(abi.decode(message.sender, (address)) == hub, "bad sender");
        (uint256 batchIndex, bytes32 root) = abi.decode(message.data, (uint256, bytes32));
        receiveRoot(batchIndex, root);
    }

    /// @notice Applies a notarized root. Router-gated (any direct caller fails
    /// the `not router` check — msg.sender survives the ccipReceive hop) and
    /// strictly sequential: batchIndex must equal `nextBatch`.
    function receiveRoot(uint256 batchIndex, bytes32 root) public {
        require(msg.sender == address(router), "not router");
        require(batchIndex == nextBatch, "out of order");

        notarizedRoot[batchIndex] = root;
        nextBatch = batchIndex + 1;
        emit RootNotarized(batchIndex, root);
    }
}
