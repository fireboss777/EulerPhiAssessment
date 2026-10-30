// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal vendored subset of Chainlink CCIP's Client library.
/// Source: smartcontractkit/ccip @ commit 171f9f0cf249765116e3131b61f5b4157566f25f,
/// contracts/src/v0.8/ccip/libraries/Client.sol (structs re-verified against that commit).
/// Only the structs and tag constants this project touches — kept in lockstep
/// with upstream; any real-lane deployment must re-verify against current upstream.
library Client {
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    struct EVM2AnyMessage {
        bytes receiver; // abi.encode(receiver address) for dest EVM chains
        bytes data; // calldata payload
        EVMTokenAmount[] tokenAmounts; // token transfers
        address feeToken; // address(0) means msg.value
        bytes extraArgs; // _argsToBytes(EVMExtraArgsV1) for gas limit
    }

    struct Any2EVMMessage {
        bytes32 messageId; // corresponds to ccipSend on source
        uint64 sourceChainSelector; // source chain selector (pin-able)
        bytes sender; // abi.encode(sender) when source is EVM
        bytes data; // payload from the source message
        EVMTokenAmount[] destTokenAmounts; // tokens in destination representation
    }

    /// @dev bytes4(keccak256("CCIP EVMExtraArgsV1")) — upstream tag.
    bytes4 internal constant EVM_EXTRA_ARGS_V1_TAG = bytes4(keccak256("CCIP EVMExtraArgsV1"));

    function _argsToBytesV1(uint256 gasLimit) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V1_TAG, gasLimit);
    }
}
