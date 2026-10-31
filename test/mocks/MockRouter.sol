// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Client } from "../../src/interfaces/Client.sol";
import { IArticleAnchor } from "../../src/interfaces/IArticleAnchor.sol";

/// @notice Test double for Chainlink's Router: captures ccipSend calls and
/// fakes ccipReceive-side deliveries. Mirrors upstream quirks worth keeping:
/// ccipSend is payable and swallows overpayment.
contract MockRouter {
    uint256 public fee = 0.01 ether;

    uint64 public lastDest;
    bytes public lastData;
    address public lastReceiver;
    uint256 public lastValue;
    bytes public lastExtraArgs;
    bytes32 public lastMessageId;
    /// @dev Capturing `lastData`/`lastExtraArgs` costs ~20k per stored word —
    /// ~500k for a submission payload. GasTest disables it so the measured
    /// gateway cost is the gateway's own work, not the test double's forensics.
    bool public capture = true;

    function setCapture(bool capture_) external {
        capture = capture_;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        require(msg.value >= fee, "mock: fee too low"); // upstream ccipSend semantics
        bytes32 messageId = keccak256(abi.encode(destinationChainSelector, message.data, block.number, msg.value));
        if (!capture) return messageId; // gas mode: pass-through, no forensics
        lastDest = destinationChainSelector;
        lastReceiver = abi.decode(message.receiver, (address));
        lastValue = msg.value;
        lastMessageId = messageId;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        return messageId;
    }

    // ------------------------------------------------------------------
    // Test-only delivery helpers (this contract IS the router to the hub).
    // ------------------------------------------------------------------

    /// @dev The single door into the hub/gateway: `ccipReceive` is the only
    /// external entry (the handler behind it is `internal`).
    function deliver(address target, Client.Any2EVMMessage calldata message) external {
        IArticleAnchor(target).ccipReceive(message);
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }
}
