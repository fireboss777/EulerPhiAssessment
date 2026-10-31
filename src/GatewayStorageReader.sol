// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IGatewayStorageReader } from "./interfaces/IGatewayStorageReader.sol";
import { ISubmissionGateway } from "./interfaces/ISubmissionGateway.sol";

/// @title GatewayStorageReader — read-only facade over the gateway's ERC-7201 namespace.
/// @notice See `IGatewayStorageReader` for the API, for why it exists (a
/// `Storage` struct holds a mapping, so it cannot be returned — solc 4103) and
/// for the one-target-one-chain rule.
/// @dev Stateless: one `immutable` target, zero storage variables, so it needs
/// no namespace of its own. Every getter is a typed `staticcall` into the
/// gateway's own getters, which the compiler checks against
/// `ISubmissionGateway` — this file cannot drift from what it mirrors, and it
/// reads only what lives on ITS chain.
contract GatewayStorageReader is IGatewayStorageReader {
    /// @inheritdoc IGatewayStorageReader
    address public immutable GATEWAY_TARGET;

    constructor(address gatewayTarget_) {
        if (gatewayTarget_ == address(0)) revert ZeroTarget();
        GATEWAY_TARGET = gatewayTarget_;
    }

    // ---------------------------------------------------------------------
    // Gateway namespace (`eulerphi.storage.SubmissionGateway`) — field getters
    // ---------------------------------------------------------------------

    /// @inheritdoc IGatewayStorageReader
    function nextBatch() external view returns (uint256) {
        return ISubmissionGateway(GATEWAY_TARGET).nextBatch();
    }

    /// @inheritdoc IGatewayStorageReader
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32) {
        return ISubmissionGateway(GATEWAY_TARGET).notarizedRoot(batchIndex);
    }

    /// @inheritdoc IGatewayStorageReader
    function gatewaySnapshot() external view returns (GatewaySnapshot memory out) {
        out.nextBatch = ISubmissionGateway(GATEWAY_TARGET).nextBatch();
    }
}
