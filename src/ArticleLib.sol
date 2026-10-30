// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The universal article envelope: what a writer signs (EIP-712 struct)
/// and what the hub journals as a leaf. Content lives off-chain (IPFS); only
/// commitments (hashes) travel through this struct.
struct ArticleSubmission {
    address author;
    bytes32 titleHash;
    bytes32 bodyHash;
    bytes32 cidHash;
    bytes32 uuid;
    uint256 timestamp;
    uint256 deadline;
}

/// @notice Pure hashing helpers for `ArticleSubmission`.
library ArticleLib {
    /// @dev keccak256 of the canonical type string.
    bytes32 internal constant TYPEHASH =
        keccak256(
            "ArticleSubmission(address author,bytes32 titleHash,bytes32 bodyHash,bytes32 cidHash,bytes32 uuid,uint256 timestamp,uint256 deadline)"
        );

    /// @dev EIP-712 `hashStruct` (domain binding is applied by the caller via
    /// `_hashTypedData`; this is the chain-agnostic struct commitment).
    function hashStruct(ArticleSubmission memory payload) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TYPEHASH,
                payload.author,
                payload.titleHash,
                payload.bodyHash,
                payload.cidHash,
                payload.uuid,
                payload.timestamp,
                payload.deadline
            )
        );
    }
}
