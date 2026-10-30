// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ArticleAnchor} from "../../src/ArticleAnchor.sol";
import {ArticleSubmission} from "../../src/ArticleLib.sol";

interface IEIP5267 {
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @notice Shared fixtures for ArticleAnchor suites: payload construction,
/// EIP-712 signing against the live domain, and multi-author batch seeding.
abstract contract ArticleTestBase is Test {
    event Submitted(address indexed author, address indexed submitter, bytes32 leafDigest);
    event RootAnchored(uint256 indexed batchIndex, bytes32 root, uint256 start, uint256 end);

    uint256 internal constant FORGER_KEY = 0xA11CE;
    uint256 internal uuidNonce;

    /// @dev Foundry's genesis timestamp is 1 — real networks start far later,
    /// and the per-author rate limit assumes a sane clock. Give suites a
    /// realistic base time so first submits aren't retro-rate-limited.
    function setUp() public virtual {
        vm.warp(block.timestamp + 2 hours);
    }

    /// @dev Refundable-ETH sink: this test contract plays the user role in
    /// gateway tests, so it must accept ETH like an EOA would.
    receive() external payable {}

    function deployHub() internal returns (ArticleAnchor hub) {
        hub = new ArticleAnchor(address(this), address(0), uint64(block.chainid), address(0));
    }

    function leafOf(ArticleSubmission memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function payloadFor(address author, uint256 salt) internal returns (ArticleSubmission memory) {
        unchecked {
            uuidNonce++;
        }
        return ArticleSubmission({
            author: author,
            titleHash: keccak256(abi.encode("title", salt)),
            bodyHash: keccak256(abi.encode("body", salt)),
            cidHash: keccak256(abi.encode("cid", salt)),
            uuid: keccak256(abi.encode("uuid", salt, uuidNonce)),
            timestamp: block.timestamp,
            deadline: block.timestamp + 1 days
        });
    }

    /// @dev Domain separator reconstructed from the contract's own EIP-5267 answer.
    function articleDigest(address target, ArticleSubmission memory p) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address vc,,) =
            IEIP5267(target).eip712Domain();
        bytes32 ds = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                vc
            )
        );
        return keccak256(abi.encodePacked(hex"1901", ds, _structHash(p)));
    }

    function _structHash(ArticleSubmission memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "ArticleSubmission(address author,bytes32 titleHash,bytes32 bodyHash,bytes32 cidHash,bytes32 uuid,uint256 timestamp,uint256 deadline)"
                ),
                p.author,
                p.titleHash,
                p.bodyHash,
                p.cidHash,
                p.uuid,
                p.timestamp,
                p.deadline
            )
        );
    }

    function signArticle(ArticleAnchor target, ArticleSubmission memory p, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, articleDigest(address(target), p));
        return abi.encodePacked(r, s, v);
    }

    function submitAs(ArticleAnchor hub, ArticleSubmission memory p, uint256 key) internal {
        hub.submitArticle(leafOf(p), signArticle(hub, p, key), p);
    }

    /// @dev Seeds `n` leaves signed by distinct fresh authors (no rate-limit
    /// warps needed; rate is per-author).
    function seedBatch(ArticleAnchor hub, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            uint256 key = uint256(keccak256(abi.encode("author", i, uuidNonce)))
                % (ECDSA.N - 1) + 1;
            submitAs(hub, payloadFor(vm.addr(key), i), key);
        }
    }

    function sliceJournal(ArticleAnchor hub, uint256 start, uint256 end)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](end - start);
        for (uint256 i; i < leaves.length; ++i) {
            leaves[i] = hub.journal(start + i);
        }
    }
}
