// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "../src/interfaces/IArticleAnchor.sol";
import { ArticleLib } from "../src/libraries/ArticleLib.sol";
import { AuthorGate } from "./mocks/AuthorGate.sol";
import { Test } from "forge-std/Test.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

contract ArticleLibTest is Test {
    /// @dev Independent pins from `cast keccak` + `cast abi-encode` (see Task 1 brief).
    bytes32 internal constant TYPEHASH_PIN = 0xb7a5cafa749837922201f262a702dcc1b0da047ce6107c03390180d257799845;
    bytes32 internal constant HASHSTRUCT_PIN = 0x15faf34648bb978be8e781da13f243f411b5e8f5d815e7bf5eaa98763aed0adb;

    address internal constant AUTHOR = 0x1111111111111111111111111111111111111111;
    uint256 internal constant FORGER_KEY = 0xA11CE;

    function test_forgedByAuthorSigReverts() public {
        IArticleAnchor.ArticleSubmission memory p = _pinnedPayload();
        bytes32 digest = ArticleLib.hashStruct(p);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FORGER_KEY, digest);
        bytes memory forgedSig = abi.encodePacked(r, s, v);

        AuthorGate gate = new AuthorGate();
        vm.expectRevert("not author");
        gate.requireAuthor(digest, forgedSig, p.author);
    }

    function test_genuineAuthorSigAccepted() public {
        IArticleAnchor.ArticleSubmission memory p = _pinnedPayload();
        bytes32 digest = ArticleLib.hashStruct(p);
        uint256 authorKey = uint256(uint160(AUTHOR)) ^ 1; // deterministic key; identity is the recovered address
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorKey, digest);
        bytes memory goodSig = abi.encodePacked(r, s, v);
        assertEq(ECDSA.recover(digest, goodSig), vm.addr(authorKey), "recover mismatch");

        AuthorGate(address(new AuthorGate())).requireAuthor(digest, goodSig, vm.addr(authorKey));
    }

    function test_hashStructIsPinned() public pure {
        assertEq(ArticleLib.TYPEHASH, TYPEHASH_PIN, "typehash drifted");
        assertEq(ArticleLib.hashStruct(_pinnedPayload()), HASHSTRUCT_PIN, "struct hash drifted");
    }

    /// @dev The leaf digest must be byte-identical to `keccak256(abi.encode(payload))`
    /// for ARBITRARY payloads: `ArticleLib.payloadLeaf` replaces the encoder at both
    /// lanes (hub reads memory, gateway reads calldata — Solidity refuses an overload
    /// differing only by data location, hence two entry points, one semantics). The
    /// reference is the encoder itself, an implementation-independent path.
    function test_payloadLeafMatchesAbiEncode(IArticleAnchor.ArticleSubmission memory payload) public pure {
        assertEq(ArticleLib.payloadLeaf(payload), keccak256(abi.encode(payload)), "memory leaf drifted from abi.encode");
    }

    function test_payloadLeafCalldataMatchesAbiEncode(IArticleAnchor.ArticleSubmission calldata payload) public pure {
        assertEq(
            ArticleLib.payloadLeafCalldata(payload),
            keccak256(abi.encode(payload)),
            "calldata leaf drifted from abi.encode"
        );
    }

    function _pinnedPayload() internal pure returns (IArticleAnchor.ArticleSubmission memory) {
        return IArticleAnchor.ArticleSubmission({
            author: AUTHOR,
            titleHash: bytes32(uint256(1)),
            bodyHash: bytes32(uint256(2)),
            cidHash: bytes32(uint256(3)),
            uuid: bytes32(uint256(4)),
            timestamp: 1_700_000_000,
            deadline: 1_700_003_600
        });
    }
}
