// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ISubmissionGateway } from "../interfaces/ISubmissionGateway.sol";

/// @notice The gateway's ERC-7201 namespace in one place: its slot constant and
/// the pointer to it — the mirror image of `ArticleLib` for `SubmissionGateway`.
library GatewayLib {
    /// @dev ERC-7201 namespace slot of the gateway — id `eulerphi.storage.SubmissionGateway`,
    /// i.e. `keccak256(abi.encode(uint256(keccak256("<id>")) - 1)) & ~bytes32(uint256(0xff))`.
    /// Frozen as a literal for the same two reasons as `ArticleLib.STORAGE_SLOT`
    /// (solc 7615 for assembly, no `erc7201` builtin before 0.8.37) and pinned
    /// to the id by `test_storageLivesAtErc7201Slot`.
    bytes32 internal constant STORAGE_SLOT = 0x778a257330d5654b80658ea659939fc3425c0d3adecc97aad5fc044843fd4100;

    /// @dev The gateway's namespace pointer: every state read and write in
    /// `SubmissionGateway` and `SubmissionGatewayGetters` goes through it. One
    /// pointer, one literal, no `virtual`/`override` pair; the local copy is
    /// required because a library constant is invisible inside assembly
    /// (solc 8198).
    function getStorage() internal pure returns (ISubmissionGateway.Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
