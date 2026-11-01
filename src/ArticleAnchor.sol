// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleAnchorGetters } from "./ArticleAnchorGetters.sol";
import { Client } from "./interfaces/Client.sol";
import { IArticleAnchor } from "./interfaces/IArticleAnchor.sol";
import { ArticleLib } from "./libraries/ArticleLib.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

/// @title ArticleAnchor — the canonical journal & batch root registry (hub).
/// @notice Every external entry point, getter, constant and event is declared
/// and documented on `IArticleAnchor`, which this contract inherits — read the
/// interface for the API. Ownership and the upgrade gate come from OZ's
/// `Ownable2StepUpgradeable` (`owner()`, two-step `transferOwnership`/
/// `acceptOwnership`, `renounceOwnership`) — declared and documented by OZ,
/// not redeclared here. Its ERC-7201 namespace (slot + pointer) and its whole
/// batch/signature policy live in `ArticleLib` as `public constant`s, so
/// this contract declares NO state variable and NO constant. Only
/// implementation-side members (constructor, modifiers, `internal` helpers)
/// are documented here.
contract ArticleAnchor is
    IArticleAnchor,
    ArticleAnchorGetters,
    Initializable,
    EIP712,
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

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function initialize(address initialOwner, address router_, uint64 chainSelector_) external initializer {
        __Ownable_init(initialOwner);
        Storage storage $ = ArticleLib.getStorage();
        $.router = router_;
        $.ethChainSelector = chainSelector_;
    }

    /// @inheritdoc IArticleAnchor
    function setGateway(address gateway_) external onlyOwner {
        ArticleLib.getStorage().gateway = gateway_;
    }

    // ---------------------------------------------------------------------
    // Submission
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload) external {
        _submit(leafDigest, sig, payload);
    }

    // ---------------------------------------------------------------------
    // CCIP lane — inbound only (L1 gateway -> hub)
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function ccipReceive(Client.Any2EVMMessage calldata message) external {
        _consumeSubmittedArticle(message);
    }

    // ---------------------------------------------------------------------
    // Batching & anchoring
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function anchorNextBatch() external returns (bytes32 root) {
        Storage storage $ = ArticleLib.getStorage();
        uint256 start = $.lastAnchoredIndex;
        uint256 pending = $.journal.length - start;
        require(
            pending > 0
                && (pending >= ArticleLib.MIN_BATCH || block.timestamp >= $.batchOpenedAt + ArticleLib.BATCH_DEADLINE),
            BatchNotReady()
        );

        uint256 count = pending > ArticleLib.MAX_BATCH ? ArticleLib.MAX_BATCH : pending;
        uint256 end = start + count;
        root = _buildRoot(start, end);

        uint256 batchIndex = $.anchoredBatches;
        $.rootAt[batchIndex] = root;
        $.anchoredBatches = batchIndex + 1;
        $.lastAnchoredIndex = end;

        emit RootAnchored(batchIndex, root, start, end);
    }

    // ---------------------------------------------------------------------
    // Views — verification (the 12 state getters live in `ArticleAnchorGetters`)
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function verifyAgainstBatch(uint256 batchIndex, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        return MerkleProofLib.verifyCalldata(proof, ArticleLib.getStorage().rootAt[batchIndex], leaf);
    }

    // ---------------------------------------------------------------------
    // Internal helpers (inbound lane, submission core, EIP-712 & UUPS wiring)
    // ---------------------------------------------------------------------

    /// @dev The pinned inbound lane — (router, sourceChainSelector, sender), then
    /// decode and hand to `_submit`. Only reachable through `ccipReceive` (the
    /// entry Chainlink's interface mandates), which forwards here without
    /// checking anything itself, so these three pins ARE the lane's security.
    function _consumeSubmittedArticle(Client.Any2EVMMessage calldata message) internal {
        Storage storage $ = ArticleLib.getStorage();
        require(msg.sender == address($.router), NotRouter());
        require(message.sourceChainSelector == $.ethChainSelector, BadChain());
        require(abi.decode(message.sender, (address)) == $.gateway, BadSender());
        (bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) =
            abi.decode(message.data, (bytes32, bytes, ArticleSubmission));
        _submit(leafDigest, sig, payload);
    }

    function _submit(bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) internal {
        Storage storage $ = ArticleLib.getStorage();
        require(block.timestamp <= payload.deadline, Expired());
        require(keccak256(abi.encode(payload)) == leafDigest, DigestMismatch());
        // Canonical 65-byte (r, s, v) only; low-s enforced (Solady's recover
        // deliberately accepts malleable s, so the gate lives here).
        require(sig.length == 65, InvalidSignatureLength());
        bytes32 s;
        assembly ("memory-safe") {
            s := mload(add(sig, 0x40)) // `s` at offset 0x40 of the bytes payload
        }
        require(uint256(s) <= ArticleLib.HIGH_S_MAX, NonCanonicalSignature());
        bytes32 digest = _hashTypedData(ArticleLib.hashStruct(payload));
        require(ECDSA.recover(digest, sig) == payload.author, NotAuthor());
        require(block.timestamp >= $.lastSubmit[payload.author] + ArticleLib.RATE_LIMIT, RateLimited());
        require(!$.usedUuid[payload.author][payload.uuid], DuplicateUuid());

        $.usedUuid[payload.author][payload.uuid] = true;
        $.lastSubmit[payload.author] = block.timestamp;
        // First leaf of a fresh batch window opens (and re-opens) the deadline.
        if ($.journal.length == $.lastAnchoredIndex) $.batchOpenedAt = block.timestamp;
        $.journal.push(leafDigest);

        emit Submitted(payload.author, msg.sender, leafDigest);
    }

    /// @dev The guard IS OZ's `onlyOwner` modifier, hence the empty body: OZ
    /// invokes this hook from `upgradeToAndCall` before writing the ERC-1967
    /// implementation slot, and `msg.sender` survives the delegatecall hop.
    function _authorizeUpgrade(address) internal view override onlyOwner { }

    /// @dev Contract-side tree build over `journal[start..end)` in Solady's
    /// heap layout (pair-sorted keccak; leaf k sits at 2L-2-k, node i hashes
    /// children 2i+1/2i+2, so a leftover leaf pairs with an internal node).
    /// Kept in memory; any off-chain prover must use the same convention.
    function _buildRoot(uint256 start, uint256 end) internal view returns (bytes32) {
        Storage storage $ = ArticleLib.getStorage();
        uint256 n = end - start;
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = $.journal[start + i];
        }
        return MerkleTreeLib.root(MerkleTreeLib.build(leaves));
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("EulerPhiArticle", "1");
    }
}
