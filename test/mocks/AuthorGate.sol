// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSA} from "solady/utils/ECDSA.sol";

/// @dev Test-only author gate: mirrors the authorship check the hub runs, so
/// the signature-binding rule gets its own RED cycle without deploying the
/// hub. Kept in `mocks/` with the other doubles (one contract per file).
contract AuthorGate {
    function requireAuthor(bytes32 digest, bytes calldata sig, address author) external view {
        require(ECDSA.recover(digest, sig) == author, "not author");
    }
}
