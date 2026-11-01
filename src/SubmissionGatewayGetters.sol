// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ISubmissionGatewayGetters } from "./interfaces/ISubmissionGatewayGetters.sol";
import { GatewayLib } from "./libraries/GatewayLib.sol";

/// @title SubmissionGatewayGetters — the gateway's 3 read getters, implemented once, here.
/// @notice `SubmissionGateway` inherits this contract instead of writing the
/// getters itself, so the gateway main contract keeps only protocol behaviour
/// (paid lane, lifecycle, upgrade gate).
/// @dev Direct reads: every body is an `sload` through `GatewayLib.getStorage()`,
/// i.e. in the account that owns the namespace — the only account that CAN read
/// it. The pointer and its slot constant both live in `GatewayLib`, so this
/// contract carries neither; it stays `abstract` (never deployed on its own)
/// because it is a read layer, not a product.
abstract contract SubmissionGatewayGetters is ISubmissionGatewayGetters {
    /// @inheritdoc ISubmissionGatewayGetters
    function router() external view returns (address) {
        return GatewayLib.getStorage().router;
    }

    /// @inheritdoc ISubmissionGatewayGetters
    function hub() external view returns (address) {
        return GatewayLib.getStorage().hub;
    }

    /// @inheritdoc ISubmissionGatewayGetters
    function baseChainSelector() external view returns (uint64) {
        return GatewayLib.getStorage().baseChainSelector;
    }
}
