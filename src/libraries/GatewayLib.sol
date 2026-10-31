// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice The gateway's policy vocabulary, in one place: the fee-lane
/// constant. `public`, so it is readable from this library's own ABI as well
/// as inlined at each use site — the gateway exposes no getter for it.
library GatewayLib {
    /// @notice Hub-side calldata for a journaled submission is small; 400k
    /// covers digest+sig checks + journal SSTORE with generous headroom.
    uint256 public constant SUBMIT_GAS_LIMIT = 400_000;
}
