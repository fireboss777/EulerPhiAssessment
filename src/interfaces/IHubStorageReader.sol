// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IHubGetters } from "./IHubGetters.sol";

/// @title IHubStorageReader — read-only facade over the hub's ERC-7201 namespace.
/// @notice Why it exists: the hub's `Storage` struct CANNOT be returned from an
/// external function — solc 4103, "Types containing (nested) mappings can only
/// be parameters or return variables of internal or library functions". Half of
/// that namespace is mappings, so its state is exposed the only way the
/// compiler allows: one getter per field, plus a scalar-only `HubSnapshot` for
/// the "everything in one call" case.
///
/// @dev ONE TARGET, ONE CHAIN: the hub runs on its own chain, so this reader
/// must be deployed on that same chain — a contract can only call addresses
/// that exist where it runs. The gateway's state is exposed by its own reader
/// (`IGatewayStorageReader`), deployed on the gateway's chain; no contract ever
/// spans the two.
///
/// @dev The 14 field getters are inherited from `IHubGetters` — declared once
/// for both the hub and this facade, never twice. Their bodies here are typed
/// `staticcall`s into the bound target's own getters, and that is the ONLY
/// on-chain option: the EVM has no opcode to read ANOTHER account's storage
/// (`sload` reads strictly the running account), so a "raw slot reader" would
/// read its own empty storage — a design this project built by mistake first
/// and whose cross-check tests caught by returning zeros. Reading foreign slots
/// directly is an off-chain capability — `cast`, `eth_getStorageAt`, `vm.load`
/// — not an on-chain one. Because the calls are typed against `IArticleAnchor`,
/// the compiler keeps this facade in lockstep with the layout: no offset or key
/// derivation is recopied here, so none can drift.
interface IHubStorageReader is IHubGetters {
    /// @notice Every non-mapping member of the hub namespace, in one call.
    /// @dev Members that cannot ride along: the mappings (`usedUuid`,
    /// `lastSubmit`, `rootAt`, `anchoredAtBlock` — solc 4103) and the bulk
    /// `journal` array (unbounded payload; its length is here, its leaves come
    /// from `journal(uint256)`).
    struct HubSnapshot {
        address admin;
        address router;
        uint64 ethChainSelector;
        address gateway;
        uint256 batchOpenedAt;
        uint256 lastAnchoredIndex;
        uint256 anchoredBatches;
        uint256 journalLength;
        uint256 pendingLeaves;
    }

    /// @notice The bound target was passed as `address(0)`.
    error ZeroTarget();

    /// @notice The hub proxy this reader was bound to.
    function HUB_TARGET() external view returns (address);

    /// @notice The whole scalar state of the hub namespace in one call.
    function hubSnapshot() external view returns (HubSnapshot memory);
}
