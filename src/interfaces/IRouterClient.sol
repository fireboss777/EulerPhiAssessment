// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Client} from "./Client.sol";

/// @notice Minimal vendored subset of Chainlink CCIP's IRouterClient.
/// Source: smartcontractkit/ccip @ ccip-develop,
/// contracts/src/v0.8/ccip/interfaces/IRouterClient.sol
interface IRouterClient {
    error UnsupportedDestinationChain(uint64 destChainSelector);
    error InsufficientFeeTokenAmount();
    error InvalidMsgValue();

    function isChainSupported(uint64 destinationChainSelector) external view returns (bool);

    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
        external
        view
        returns (uint256 fee);

    /// @dev Upstream: excess msg.value over fee is accepted with NO refund.
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}
