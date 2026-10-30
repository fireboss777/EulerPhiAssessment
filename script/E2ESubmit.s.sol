// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ArticleAnchor} from "../src/ArticleAnchor.sol";
import {ArticleLib, ArticleSubmission} from "../src/ArticleLib.sol";

interface IEIP5267S {
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @notice Anvil end-to-end helper (verification aid for the keeper scripts):
/// the broadcaster signs one article against the hub's live EIP-712 domain
/// and publishes it through the direct lane.
///
/// Env: HUB_ADDRESS, ARTICLE_AUTHOR_KEY
contract E2ESubmit is Script {
    function run() external {
        ArticleAnchor hub = ArticleAnchor(vm.envAddress("HUB_ADDRESS"));
        uint256 authorKey = vm.envUint("ARTICLE_AUTHOR_KEY");
        address author = vm.addr(authorKey);

        ArticleSubmission memory p = ArticleSubmission({
            author: author,
            titleHash: keccak256("e2e title"),
            bodyHash: keccak256("e2e body"),
            cidHash: keccak256("e2e cid"),
            uuid: keccak256(abi.encode("e2e", author, block.timestamp)),
            timestamp: block.timestamp,
            deadline: block.timestamp + 1 days
        });
        bytes32 leaf = keccak256(abi.encode(p));

        (, string memory name, string memory ver, uint256 chainId, address vc,,) =
            IEIP5267S(address(hub)).eip712Domain();
        bytes32 ds = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(ver)),
                chainId,
                vc
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", ds, ArticleLib.hashStruct(p)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorKey, digest);

        vm.startBroadcast(authorKey);
        hub.submitArticle(leaf, abi.encodePacked(r, s, v), p);
        vm.stopBroadcast();

        console.log("submitted article for", author);
        console.logBytes32(leaf);
    }
}
