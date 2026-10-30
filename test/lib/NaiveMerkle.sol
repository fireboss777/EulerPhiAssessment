// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Independent reference implementation of the exact tree shape
/// `MerkleTreeLib.build` produces (pair-sorted keccak256 over a heap-laid-out
/// array: leaf k at index `2L-2-k`, node i hashing children `2i+1`/`2i+2`,
/// odd node promoted raw). Written in idiomatic Solidity — no assembly — so
/// MerkleDifferential compares Solady's optimized asm against different code.
library NaiveMerkle {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 l = leaves.length;
        require(l > 0, "no leaves");
        bytes32[] memory nodes = new bytes32[](2 * l - 1);

        // Leaf placement: first leaf lands at the top slot, descending.
        for (uint256 k; k < l; ++k) {
            nodes[2 * l - 2 - k] = leaves[k];
        }

        // Internal nodes, bottom-up: node i = sorted-pair hash of 2i+1, 2i+2.
        for (uint256 idx = l - 1; idx > 0;) {
            unchecked {
                --idx;
            }
            bytes32 a = nodes[2 * idx + 1];
            bytes32 b = nodes[2 * idx + 2];
            nodes[idx] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        return nodes[0];
    }
}
