// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "../interfaces/IArticleAnchor.sol";

/// @notice The hub's shared vocabulary, in one place: the EIP-712 envelope and
/// its typehash, the batch/submission policy constants, and the
/// ERC-7201 namespace (slot constant + pointer). Every constant here is
/// `public`, so it is readable from this library's own ABI as well as inlined
/// at each use site — no contract exposes a getter for any of them.
library ArticleLib {
    /// @dev keccak256 of the canonical type string.
    bytes32 public constant TYPEHASH = keccak256(
        "ArticleSubmission(address author,bytes32 titleHash,bytes32 bodyHash,"
        "bytes32 cidHash,bytes32 uuid,uint256 timestamp,uint256 deadline)"
    );

    /// @dev ERC-7201 namespace slot of the hub — id `eulerphi.storage.ArticleAnchor`,
    /// i.e. `keccak256(abi.encode(uint256(keccak256("<id>")) - 1)) & ~bytes32(uint256(0xff))`.
    /// Frozen as a literal because inline assembly accepts only direct number
    /// constants (solc 7615) and solc 0.8.33 has no `erc7201` builtin (0.8.37+).
    /// `test_storageLivesAtErc7201Slot` recomputes it from the id and reads the
    /// raw slots, so this constant cannot drift from the namespace it claims.
    bytes32 public constant STORAGE_SLOT = 0x15dbd2ada1700fe5c9739ea67ae301bf73151c332fba02dda344d3dd844a0300;

    /// @notice Leaves required before a batch may close without waiting.
    uint256 public constant MIN_BATCH = 10;

    /// @notice Hard cap on leaves taken per batch (the window splits).
    uint256 public constant MAX_BATCH = 200;

    /// @notice Age of the open window after which a partial batch may close.
    uint256 public constant BATCH_DEADLINE = 6 hours;

    /// @notice Minimum spacing between two submissions by the same author.
    uint256 public constant RATE_LIMIT = 60 minutes;

    /// @dev floor(N/2) of secp256k1: signatures must be canonical low-s (EIP-2).
    uint256 public constant HIGH_S_MAX = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    /// @dev EIP-712 `hashStruct` (domain binding is applied by the caller via
    /// `_hashTypedData`; this is the chain-agnostic struct commitment).
    /// @dev Hand-rolled instead of `keccak256(abi.encode(...))` (`forge lint:
    /// asm-keccak256`): the payload is seven contiguous words, so the digest is
    /// one typehash word plus one fixed 224-byte copy — no encoder and no
    /// intermediate buffer. The free-memory region is used as scratch and NOT
    /// bumped, exactly as Solady's `EIP712` does it; the output is byte-for-byte
    /// the old one, pinned by `test_hashStructIsPinned`. `typehash` must be a
    /// local: a library constant is not visible inside assembly (solc 8198).
    function hashStruct(IArticleAnchor.ArticleSubmission memory payload) internal pure returns (bytes32 result) {
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

    /// @dev The journal leaf — `keccak256(abi.encode(payload))` hand-rolled the
    /// same way `hashStruct` is (`forge lint: asm-keccak256`): the payload is
    /// seven contiguous words, so the digest is one fixed 224-byte copy straight
    /// to keccak — no encoder, no intermediate buffer, and byte-for-byte the
    /// digest the encoder produced. Two entry points because Solidity refuses to
    /// overload on data location alone (error 9582): `payloadLeaf` reads memory
    /// (the hub's `_submit` — `ccipReceive` decodes there), `payloadLeafCalldata`
    /// reads calldata (the gateway's paid lane pays no copy at all). ONE
    /// semantics, pinned against the encoder itself by
    /// `test_payloadLeafMatchesAbiEncode` and
    /// `test_payloadLeafCalldataMatchesAbiEncode`. The free-memory region is
    /// used as scratch and NOT bumped, exactly as `hashStruct` above does it.
    function payloadLeaf(IArticleAnchor.ArticleSubmission memory payload) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, mload(payload))
            mstore(add(ptr, 0x20), mload(add(payload, 0x20)))
            mstore(add(ptr, 0x40), mload(add(payload, 0x40)))
            mstore(add(ptr, 0x60), mload(add(payload, 0x60)))
            mstore(add(ptr, 0x80), mload(add(payload, 0x80)))
            mstore(add(ptr, 0xa0), mload(add(payload, 0xa0)))
            mstore(add(ptr, 0xc0), mload(add(payload, 0xc0)))
            result := keccak256(ptr, 0xe0)
        }
    }

    /// @dev Calldata twin of `payloadLeaf` (see its doc): the struct is static —
    /// seven contiguous words — so the digest reads them straight out of calldata.
    /// A static calldata struct has no `.offset` suffix (solc error 3622); the
    /// variable itself evaluates to its calldata offset inside assembly.
    function payloadLeafCalldata(IArticleAnchor.ArticleSubmission calldata payload)
        internal
        pure
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, calldataload(payload))
            mstore(add(ptr, 0x20), calldataload(add(payload, 0x20)))
            mstore(add(ptr, 0x40), calldataload(add(payload, 0x40)))
            mstore(add(ptr, 0x60), calldataload(add(payload, 0x60)))
            mstore(add(ptr, 0x80), calldataload(add(payload, 0x80)))
            mstore(add(ptr, 0xa0), calldataload(add(payload, 0xa0)))
            mstore(add(ptr, 0xc0), calldataload(add(payload, 0xc0)))
            result := keccak256(ptr, 0xe0)
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
