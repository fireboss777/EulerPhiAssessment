// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ISubmissionGatewayGetters } from "./interfaces/ISubmissionGatewayGetters.sol";
import { GatewayLib } from "./libraries/GatewayLib.sol";

/// @title SubmissionGatewayGetters — the gateway's 2 read getters, implemented once, here.
/// @notice `SubmissionGateway` inherits this contract instead of writing the
/// getters itself, so the main contract keeps only protocol behaviour (paid
/// lane, notary receiver).
/// @dev Direct reads through `GatewayLib.getStorage()`, the gateway's namespace
/// pointer with its slot constant — the same shape as the hub's `ArticleLib`.
/// This contract carries neither and stays `abstract` (never deployed on its
/// own): interface -> getter contract -> main contract.
abstract contract SubmissionGatewayGetters is ISubmissionGatewayGetters {
    /// @inheritdoc ISubmissionGatewayGetters
    function nextBatch() external view returns (uint256) {
        return GatewayLib.getStorage().nextBatch;
    }

    /// @inheritdoc ISubmissionGatewayGetters
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32) {
        return GatewayLib.getStorage().notarizedRoot[batchIndex];
    }
}
