// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Client} from "../../src/interfaces/Client.sol";

interface IHubCCIP {
    function consumeSubmittedArticle(Client.Any2EVMMessage calldata message) external;

    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}

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

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        lastDest = destinationChainSelector;
        lastData = message.data;
        lastReceiver = abi.decode(message.receiver, (address));
        lastValue = msg.value;
        lastExtraArgs = message.extraArgs;
        lastMessageId = keccak256(
            abi.encode(destinationChainSelector, message.data, block.number, msg.value)
        );
        return lastMessageId;
    }

    // ------------------------------------------------------------------
    // Test-only delivery helpers (this contract IS the router to the hub).
    // ------------------------------------------------------------------

    function deliver(address hub, Client.Any2EVMMessage calldata message) external {
        IHubCCIP(hub).consumeSubmittedArticle(message);
    }

    function deliverViaCcipReceive(address hub, Client.Any2EVMMessage calldata message) external {
        IHubCCIP(hub).ccipReceive(message);
    }
}
