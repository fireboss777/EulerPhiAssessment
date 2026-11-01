// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { SubmissionGateway } from "../../src/SubmissionGateway.sol";

/// @notice V2 shape for upgrade tests: adds a function, adds NO storage —
/// config-layout stability is exactly what test_gatewayConfigPreserved checks.
contract SubmissionGatewayV2Stub is SubmissionGateway {
    function v2Ping() external pure returns (uint256) {
        return 42;
    }
}
