// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ISubmissionGatewayGetters — the gateway's read API, declared in exactly ONE place.
/// @notice The 3 field getters over the gateway's ERC-7201 namespace. Declared
/// here, implemented once in `SubmissionGatewayGetters`, which
/// `SubmissionGateway` inherits — so each getter is a declaration in exactly
/// ONE file and code in exactly ONE contract, with nothing anywhere else
/// holding a copy.
///
/// @dev Direct reads: every body is an `sload` in the account that owns the
/// namespace — the only account that CAN read it, since the EVM has no opcode
/// for another account's storage. That is also why there is no separate reader
/// contract: a facade could only `staticcall` this contract back, adding a
/// second copy of every function for nothing. The declarations are what keep
/// the implementations honest — each body is checked by the compiler against
/// this file, so a signature change breaks the build.
interface ISubmissionGatewayGetters {
    /// @notice Chainlink Router of the gateway's chain: where fee quotes and `ccipSend`
    /// go. Storage, so an owner upgrade can retarget it — never a setter.
    function router() external view returns (address);

    /// @notice The `ArticleAnchor` proxy on the hub chain: receiver of the
    /// paid lane.
    function hub() external view returns (address);

    /// @notice Chainlink chain selector of the hub chain (not a chain id).
    function baseChainSelector() external view returns (uint64);
}
