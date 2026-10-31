// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Client} from "./Client.sol";

/// @notice Minimal vendored copy of Chainlink CCIP's receiver interface.
/// Source: smartcontractkit/ccip @ commit 171f9f0cf249765116e3131b61f5b4157566f25f,
/// contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol
interface IAny2EVMMessageReceiver {
    /// @notice Called by the Router to deliver a message.
    /// @dev Ensure you check that msg.sender is the Router.
    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}
