// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IGatewayStorageReader — read-only facade over the gateway's ERC-7201 namespace.
/// @notice Why it exists: the gateway's `Storage` struct CANNOT be returned from
/// an external function — solc 4103 (it contains a mapping), so its two members
/// are exposed as individual getters plus a `GatewaySnapshot` for the
/// single-call case.
///
/// @dev ONE TARGET, ONE CHAIN: the gateway runs on its own chain, so this
/// reader must be deployed on that same chain. The hub's state is exposed by
/// `IHubStorageReader` on the hub's chain; no contract ever spans the two —
/// that is precisely why these readers are split.
///
/// @dev Each getter is a typed `staticcall` into the bound target's own
/// getters — the only on-chain option, since the EVM cannot read another
/// account's storage (`sload` is strictly the running account's). Typed calls
/// against `ISubmissionGateway` mean this facade cannot drift from what it
/// mirrors: a signature change upstream stops compiling here.
interface IGatewayStorageReader {
    /// @notice Every non-mapping member of the gateway namespace, in one call.
    /// @dev The gateway's other member, `notarizedRoot`, is a mapping — read it
    /// through `notarizedRoot(uint256)`. Its `router`, `hub` and
    /// `baseChainSelector` are `immutable` (bytecode, not namespace state), so
    /// they are deliberately absent.
    struct GatewaySnapshot {
        uint256 nextBatch;
    }

    /// @notice The bound target was passed as `address(0)`.
    error ZeroTarget();

    /// @notice The gateway this reader was bound to.
    function gatewayTarget() external view returns (address);

    // ---------------------------------------------------------------------
    // Gateway namespace (`eulerphi.storage.SubmissionGateway`) — field getters
    // ---------------------------------------------------------------------

    /// @notice Next batch index acceptable by the notary receiver. See `ISubmissionGateway.nextBatch`.
    function nextBatch() external view returns (uint256);

    /// @notice Notarized root of a batch as recorded on Ethereum.
    /// @param batchIndex Batch index, `batchIndex < nextBatch()`.
    function notarizedRoot(uint256 batchIndex) external view returns (bytes32);

    /// @notice The whole scalar state of the gateway namespace in one call.
    function gatewaySnapshot() external view returns (GatewaySnapshot memory);
}
