// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "../interfaces/IArticleAnchor.sol";

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
    bytes32 internal constant TYPEHASH = keccak256(
        "ArticleSubmission(address author,bytes32 titleHash,bytes32 bodyHash,"
        "bytes32 cidHash,bytes32 uuid,uint256 timestamp,uint256 deadline)"
    );

    /// @dev ERC-7201 namespace slot of the hub — id `eulerphi.storage.ArticleAnchor`,
    /// i.e. `keccak256(abi.encode(uint256(keccak256("<id>")) - 1)) & ~bytes32(uint256(0xff))`.
    /// Frozen as a literal because inline assembly accepts only direct number
    /// constants (solc 7615) and solc 0.8.33 has no `erc7201` builtin (0.8.37+).
    /// `test_storageLivesAtErc7201Slot` recomputes it from the id and reads the
    /// raw slots, so this constant cannot drift from the namespace it claims.
    bytes32 internal constant STORAGE_SLOT = 0x15dbd2ada1700fe5c9739ea67ae301bf73151c332fba02dda344d3dd844a0300;

    /// @dev EIP-712 `hashStruct` (domain binding is applied by the caller via
    /// `_hashTypedData`; this is the chain-agnostic struct commitment).
    /// @dev Hand-rolled instead of `keccak256(abi.encode(...))` (`forge lint:
    /// asm-keccak256`): the payload is seven contiguous words, so the digest is
    /// one typehash word plus one fixed 224-byte copy — no encoder and no
    /// intermediate buffer. The free-memory region is used as scratch and NOT
    /// bumped, exactly as Solady's `EIP712` does it; the output is byte-for-byte
    /// the old one, pinned by `test_hashStructIsPinned`. `typehash` must be a
    /// local: a library constant is not visible inside assembly (solc 8198).
    function hashStruct(ArticleSubmission memory payload) internal pure returns (bytes32 result) {
        bytes32 typehash = TYPEHASH;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typehash)
            mstore(add(ptr, 0x20), mload(payload))
            mstore(add(ptr, 0x40), mload(add(payload, 0x20)))
            mstore(add(ptr, 0x60), mload(add(payload, 0x40)))
            mstore(add(ptr, 0x80), mload(add(payload, 0x60)))
            mstore(add(ptr, 0xa0), mload(add(payload, 0x80)))
            mstore(add(ptr, 0xc0), mload(add(payload, 0xa0)))
            mstore(add(ptr, 0xe0), mload(add(payload, 0xc0)))
            result := keccak256(ptr, 0x100)
        }
    }

    /// @dev The hub's namespace pointer: every state read and write in
    /// `ArticleAnchor` and `ArticleAnchorGetters` goes through it. A library
    /// function cannot be `virtual` — and does not need to be, since the slot
    /// is pinned right above: one pointer and one literal for this namespace
    /// instead of a `virtual`/`override` pair spread over two contracts. The
    /// local copy is required: a library constant is invisible inside assembly
    /// (solc 8198).
    function getStorage() internal pure returns (IArticleAnchor.Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
