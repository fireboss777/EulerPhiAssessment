// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The notarization receiver surface of the L1 SubmissionGateway
/// (implemented in `src/SubmissionGateway.sol`). The hub encodes its CCIP
/// payload with `abi.encodeCall` against THIS selector and the gateway checks
/// it before decoding, so neither contract needs to import the other's source
/// while the wire format stays pinned on both ends.
interface ISubmissionGateway {
    function receiveRoot(uint256 batchIndex, bytes32 root) external;
}
