// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MerkleTreeLib} from "solady/utils/MerkleTreeLib.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {NaiveMerkle} from "./lib/NaiveMerkle.sol";

/// @notice Differential harness: Solady's optimized builder/verifier against
/// an independent naive implementation (see test/lib/NaiveMerkle.sol).
contract MerkleDifferentialTest is Test {
    function _leaves(uint256 s, uint256 n) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = keccak256(abi.encode(s, i));
        }
    }

    function test_matchesNaiveReference(uint256 s, uint8 n) public view {
        uint256 count = bound(uint256(n), 1, 64);
        bytes32[] memory leaves = _leaves(s, count);

        bytes32 soladyRoot = MerkleTreeLib.root(MerkleTreeLib.build(leaves));
        assertEq(soladyRoot, NaiveMerkle.root(leaves), "Solady root != naive root");

        // Spot-check builder<->verifier consistency on a middle leaf.
        uint256 idx = count / 2;
        bytes32[] memory proof = MerkleTreeLib.leafProof(MerkleTreeLib.build(leaves), idx);
        assertTrue(MerkleProofLib.verify(proof, soladyRoot, leaves[idx]), "proof invalid");
    }

    function test_oddLeafCounts() public view {
        uint256[3] memory lens = [uint256(3), uint256(5), uint256(7)];
        for (uint256 k; k < lens.length; ++k) {
            bytes32[] memory leaves = _leaves(k + 100, lens[k]);
            bytes32 soladyRoot = MerkleTreeLib.root(MerkleTreeLib.build(leaves));
            assertEq(soladyRoot, NaiveMerkle.root(leaves), "odd-count root mismatch");

            bytes32[] memory tree = MerkleTreeLib.build(leaves);
            for (uint256 i; i < leaves.length; ++i) {
                bytes32[] memory proof = MerkleTreeLib.leafProof(tree, i);
                assertTrue(MerkleProofLib.verify(proof, soladyRoot, leaves[i]), "odd-count proof invalid");
            }
        }
    }

    function test_singleLeafRoot() public view {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("solo");

        bytes32 soladyRoot = MerkleTreeLib.root(MerkleTreeLib.build(leaves));
        assertEq(soladyRoot, leaves[0], "single leaf root is the leaf");
        assertEq(soladyRoot, NaiveMerkle.root(leaves), "naive agrees on single leaf");

        bytes32[] memory noProof = new bytes32[](0);
        assertTrue(MerkleProofLib.verify(noProof, soladyRoot, leaves[0]), "empty proof verifies");
    }
}
