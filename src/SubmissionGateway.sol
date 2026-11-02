// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { SubmissionGatewayGetters } from "./SubmissionGatewayGetters.sol";
import { Client } from "./interfaces/Client.sol";
import { IArticleAnchor } from "./interfaces/IArticleAnchor.sol";
import { IRouterClient } from "./interfaces/IRouterClient.sol";
import { ISubmissionGateway } from "./interfaces/ISubmissionGateway.sol";
import { ArticleLib } from "./libraries/ArticleLib.sol";
import { GatewayLib } from "./libraries/GatewayLib.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SubmissionGateway — the source-chain endpoint (paid entry lane, UUPS proxy).
/// @notice Every external entry point and event is declared and documented on
/// `ISubmissionGateway`, which this contract inherits — read the interface for
/// the API (including the paid-lane / no-ecrecover design notes). Ownership
/// and the upgrade gate come from OZ's `Ownable2StepUpgradeable` (`owner()`,
/// two-step `transferOwnership`/`acceptOwnership`, `renounceOwnership`) —
/// declared and documented by OZ, not redeclared here. Its ERC-7201
/// namespace (slot + pointer) and fee-lane policy live in `GatewayLib`, so
/// this contract declares NO state variable and NO constant of its own.
/// Only implementation-side members are documented here.
contract SubmissionGateway is
    ISubmissionGateway,
    SubmissionGatewayGetters,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev OZ best practice (docs, `Initializable`): a contract deployed
    /// behind a proxy writes NO configuration here — constructor state would
    /// live on the implementation and never be visible through the proxy.
    /// The constructor's only job is to LOCK this implementation so it can
    /// never be initialized by anyone: `_disableInitializers()`.
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// @inheritdoc ISubmissionGateway
    function initialize(address initialOwner, address router_, address hub_, uint64 baseChainSelector_)
        external
        initializer
    {
        __Ownable_init(initialOwner);
        Storage storage $ = GatewayLib.getStorage();
        $.router = router_;
        $.hub = hub_;
        $.baseChainSelector = baseChainSelector_;
    }

    // ------------------------------------------------------------------
    // Paid entry lane: this chain -> hub
    // ------------------------------------------------------------------

    /// @inheritdoc ISubmissionGateway
    function submitArticle(bytes32 leafDigest, bytes calldata sig, IArticleAnchor.ArticleSubmission calldata payload)
        external
        payable
    {
        // Cheap, chain-agnostic sanity checks before any fee moves:
        require(block.timestamp <= payload.deadline, Expired());
        require(ArticleLib.payloadLeafCalldata(payload) == leafDigest, DigestMismatch());

        Storage storage $ = GatewayLib.getStorage();
        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode($.hub),
            data: abi.encode(leafDigest, sig, payload),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // native fee via msg.value
            extraArgs: Client._argsToBytesV1(GatewayLib.SUBMIT_GAS_LIMIT)
        });

        uint256 fee = IRouterClient($.router).getFee($.baseChainSelector, m);
        require(msg.value >= fee, InsufficientFee());

        bytes32 messageId = IRouterClient($.router).ccipSend{ value: fee }($.baseChainSelector, m);
        emit Forwarded(msg.sender, leafDigest, messageId);

        // Return the unused portion (router keeps overpayment; we don't).
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{ value: excess }("");
            require(ok, RefundFailed());
        }
    }

    // ------------------------------------------------------------------
    // Upgrade
    // ------------------------------------------------------------------

    /// @dev The guard IS OZ's `onlyOwner` modifier, hence the empty body: OZ
    /// invokes this hook from `upgradeToAndCall` before writing the ERC-1967
    /// implementation slot, and `msg.sender` survives the delegatecall hop.
    function _authorizeUpgrade(address) internal view override onlyOwner { }
}
