// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IArticleAnchor } from "../../src/interfaces/IArticleAnchor.sol";

/// @title GatewayCodec — Certora scene helper for `SubmissionGateway.spec`.
/// @notice CVL has no `abi.encode`, and the gateway's forwarded `data` field
/// is `(bytes32, bytes, struct)` — mixed static/dynamic, so neither CVL's
/// multi-primitive `keccak256` (static-only) nor field-level decoding can
/// reconstruct it. This contract performs the exact Solidity encoding so the
/// spec can assert byte-identity by keccak congruence:
/// `keccak256(rt.lastData()) == codec.encodeData(leaf, sig, payload)`.
/// @dev Stateless and `pure` — reads nothing, writes nothing, exists only in
/// the Certora scene (never deployed by Foundry; lives outside src/test).
contract GatewayCodec {
    /// @notice `keccak256(abi.encode(leaf, sig, payload))` — the exact bytes
    /// `SubmissionGateway.submitArticle` forwards as `EVM2AnyMessage.data`.
    function encodeData(bytes32 leaf, bytes calldata sig, IArticleAnchor.ArticleSubmission calldata payload)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(leaf, sig, payload));
    }

    /// @notice `keccak256(abi.encode(a))` — lets CVL pin a `bytes` receiver
    /// field to a clean 32-byte address encoding by keccak congruence
    /// (`require keccak256(m.receiver) == codec.enc(someAddress)`), since CVL
    /// has no abi encoder and struct fields can only be constrained via
    /// `require`.
    function enc(address a) external pure returns (bytes32) {
        return keccak256(abi.encode(a));
    }

    /// @notice Lets the spec pin `msg.sender == codec` as a refund target
    /// with known code: the excess-refund `call` then RESOLVES (no AUTO
    /// havoc of ghost state — the run-39 artifact where the post-summary
    /// ghost read came back havoced).
    receive() external payable { }
}
