// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ISubmissionGatewayGetters — the gateway's read API, declared in exactly ONE place.
/// @notice The two field getters over the gateway's ERC-7201 namespace:
/// declared here, implemented once in `SubmissionGatewayGetters`, which
/// `SubmissionGateway` inherits. `ISubmissionGateway` holds the actions,
/// events, errors and the immutable/constant getters; this one holds the state
/// reads — each function exists as a declaration in exactly one file and as
/// code in exactly one contract.
///
/// @dev Direct reads: an `sload` in the account that owns the namespace — the
/// only account that CAN read it, since the EVM has no opcode for another
/// account's storage. That is also why there is no separate reader contract: a
/// facade could only `staticcall` this contract back, adding a second copy of
/// two functions for nothing.
interface ISubmissionGatewayGetters {
    /// @notice Next batch index acceptable — no skips, no reordering, no replays.
    function nextBatch() external view returns (uint256);

    /// @notice Notarized root of batch `batchIndex` as recorded on Ethereum.
    /// @param batchIndex Batch index, `batchIndex < nextBatch()`.
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32);
}
