// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ISubmissionGateway } from "./interfaces/ISubmissionGateway.sol";
import { ISubmissionGatewayGetters } from "./interfaces/ISubmissionGatewayGetters.sol";

/// @title SubmissionGatewayGetters — the gateway's 2 read getters, implemented once, here.
/// @notice `SubmissionGateway` inherits this contract instead of writing the
/// getters itself, so the main contract keeps only protocol behaviour (paid
/// lane, notary receiver) and its namespace pointer.
/// @dev Direct reads through `_getStorage()`, left `virtual` and unimplemented:
/// the literal belongs to the namespace owner (`SubmissionGateway` pins it to
/// `eulerphi.storage.SubmissionGateway`), not to this read layer, so this
/// contract is `abstract` and never deployed on its own. Same shape as
/// `ArticleAnchorGetters`: interface -> getter contract -> main contract.
abstract contract SubmissionGatewayGetters is ISubmissionGatewayGetters {
    /// @inheritdoc ISubmissionGatewayGetters
    function nextBatch() external view returns (uint256) {
        return _getStorage().nextBatch;
    }

    /// @inheritdoc ISubmissionGatewayGetters
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32) {
        return _getStorage().notarizedRoot[batchIndex];
    }

    /// @dev Namespace pointer — implemented by the owner of the namespace.
    function _getStorage() internal pure virtual returns (ISubmissionGateway.Storage storage);
}
