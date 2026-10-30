// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The notarization receiver surface of the L1 SubmissionGateway
/// (implemented in Task 5). The hub encodes calls against this selector so
/// neither contract needs to import the other's source.
interface ISubmissionGateway {
    function receiveRoot(uint256 batchIndex, bytes32 root) external;
}
