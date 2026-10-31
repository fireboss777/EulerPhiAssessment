// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EIP712} from "solady/utils/EIP712.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {MerkleTreeLib} from "solady/utils/MerkleTreeLib.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ArticleLib, ArticleSubmission} from "./ArticleLib.sol";
import {Client} from "./interfaces/Client.sol";
import {IRouterClient} from "./interfaces/IRouterClient.sol";
import {ISubmissionGateway} from "./interfaces/ISubmissionGateway.sol";
import {IArticleAnchor} from "./interfaces/IArticleAnchor.sol";
import {HubGetters} from "./HubGetters.sol";

/// @title ArticleAnchor — the canonical journal & batch root registry (hub).
/// @notice Every external entry point, getter, constant and event is declared
/// and documented on `IArticleAnchor`, which this contract inherits — read the
/// interface for the API. Only implementation-side members (constructor,
/// modifiers, `internal` helpers) are documented here.
contract ArticleAnchor is IArticleAnchor, HubGetters, Initializable, EIP712, UUPSUpgradeable {
    // ---------------------------------------------------------------------
    // Constants (see plan: batch policy)
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    uint256 public constant MIN_BATCH = 10;
    /// @inheritdoc IArticleAnchor
    uint256 public constant MAX_BATCH = 200;
    /// @inheritdoc IArticleAnchor
    uint256 public constant BATCH_DEADLINE = 6 hours;
    /// @inheritdoc IArticleAnchor
    uint256 public constant RATE_LIMIT = 60 minutes;
    /// @inheritdoc IArticleAnchor
    uint256 public constant NOTARY_K = 64;
    /// @inheritdoc IArticleAnchor
    uint256 public constant NOTARY_GAS_LIMIT = 200_000;
    /// @dev floor(N/2) of secp256k1: signatures must be canonical low-s (EIP-2).
    uint256 private constant _HIGH_S_MAX = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    // ---------------------------------------------------------------------
    // ERC-7201 namespaced storage — the whole layout lives in
    // `IArticleAnchor.Storage` (this contract declares NO state variable)
    // ---------------------------------------------------------------------

    /// @dev ERC-7201 formula — `keccak256(abi.encode(uint256(keccak256(
    /// "eulerphi.storage.ArticleAnchor")) - 1)) & ~bytes32(uint256(0xff))`.
    /// Frozen as a literal because inline assembly accepts only direct number
    /// constants (`$.slot := _STORAGE_SLOT`) and solc 0.8.33 has no
    /// `erc7201` builtin (0.8.37+). `test_storageLivesAtErc7201Slot`
    /// recomputes the formula from the id and reads it back, so the literal
    /// can never drift from the namespace it claims to be.
    bytes32 private constant _STORAGE_SLOT = 0x15dbd2ada1700fe5c9739ea67ae301bf73151c332fba02dda344d3dd844a0300;

    modifier onlyAdmin() {
        Storage storage $ = _getStorage();
        require(msg.sender == $.admin, AdminOnly());
        _;
    }

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
    function initialize(address admin_, address router_, uint64 chainSelector_) external initializer {
        require(admin_ != address(0), ZeroAdmin());
        Storage storage $ = _getStorage();
        $.admin = admin_;
        $.router = router_;
        $.ethChainSelector = chainSelector_;
    }

    /// @inheritdoc IArticleAnchor
    function setGateway(address gateway_) external onlyAdmin {
        _getStorage().gateway = gateway_;
    }

    // ---------------------------------------------------------------------
    // Submission
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload) external {
        _submit(leafDigest, sig, payload);
    }

    // ---------------------------------------------------------------------
    // CCIP lanes
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function ccipReceive(Client.Any2EVMMessage calldata message) external {
        consumeSubmittedArticle(message);
    }

    /// @inheritdoc IArticleAnchor
    function notarize(uint256 batchIndex) external payable {
        Storage storage $ = _getStorage();
        uint256 anchoredAt = $.anchoredAtBlock[batchIndex];
        require(anchoredAt != 0, NoBatch());
        require(block.number >= anchoredAt + NOTARY_K, NotFinal());

        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode($.gateway),
            data: abi.encodeCall(ISubmissionGateway.receiveRoot, (batchIndex, $.rootAt[batchIndex])),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytesV1(NOTARY_GAS_LIMIT)
        });
        bytes32 messageId = IRouterClient($.router).ccipSend{value: msg.value}($.ethChainSelector, m);
        emit Notarized(batchIndex, $.rootAt[batchIndex], messageId);
    }

    // ---------------------------------------------------------------------
    // Batching & anchoring
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function anchorNextBatch() external returns (bytes32 root) {
        Storage storage $ = _getStorage();
        uint256 start = $.lastAnchoredIndex;
        uint256 pending = $.journal.length - start;
        require(
            pending > 0 && (pending >= MIN_BATCH || block.timestamp >= $.batchOpenedAt + BATCH_DEADLINE),
            BatchNotReady()
        );

        uint256 count = pending > MAX_BATCH ? MAX_BATCH : pending;
        uint256 end = start + count;
        root = _buildRoot(start, end);

        uint256 batchIndex = $.anchoredBatches;
        $.rootAt[batchIndex] = root;
        $.anchoredAtBlock[batchIndex] = block.number;
        $.anchoredBatches = batchIndex + 1;
        $.lastAnchoredIndex = end;

        emit RootAnchored(batchIndex, root, start, end);
    }

    // ---------------------------------------------------------------------
    // Views — verification (the 14 state getters live in `HubGetters`)
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function verifyAgainstBatch(uint256 batchIndex, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        return MerkleProofLib.verifyCalldata(proof, _getStorage().rootAt[batchIndex], leaf);
    }

    // ---------------------------------------------------------------------
    // Public: inbound lane handler (ccipReceive forwards into it)
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function consumeSubmittedArticle(Client.Any2EVMMessage calldata message) public {
        Storage storage $ = _getStorage();
        require(msg.sender == address($.router), NotRouter());
        require(message.sourceChainSelector == $.ethChainSelector, BadChain());
        require(abi.decode(message.sender, (address)) == $.gateway, BadSender());
        (bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) =
            abi.decode(message.data, (bytes32, bytes, ArticleSubmission));
        _submit(leafDigest, sig, payload);
    }

    // ---------------------------------------------------------------------
    // Internal helpers (submission core, EIP-712 & UUPS wiring)
    // ---------------------------------------------------------------------

    function _submit(bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) internal {
        Storage storage $ = _getStorage();
        require(block.timestamp <= payload.deadline, Expired());
        require(keccak256(abi.encode(payload)) == leafDigest, DigestMismatch());
        // Canonical 65-byte (r, s, v) only; low-s enforced (Solady's recover
        // deliberately accepts malleable s, so the gate lives here).
        require(sig.length == 65, InvalidSignatureLength());
        bytes32 s;
        assembly ("memory-safe") {
            s := mload(add(sig, 0x40)) // `s` at offset 0x40 of the bytes payload
        }
        require(uint256(s) <= _HIGH_S_MAX, NonCanonicalSignature());
        bytes32 digest = _hashTypedData(ArticleLib.hashStruct(payload));
        require(ECDSA.recover(digest, sig) == payload.author, NotAuthor());
        require(block.timestamp >= $.lastSubmit[payload.author] + RATE_LIMIT, RateLimited());
        require(!$.usedUuid[payload.author][payload.uuid], DuplicateUuid());

        $.usedUuid[payload.author][payload.uuid] = true;
        $.lastSubmit[payload.author] = block.timestamp;
        // First leaf of a fresh batch window opens (and re-opens) the deadline.
        if ($.journal.length == $.lastAnchoredIndex) $.batchOpenedAt = block.timestamp;
        $.journal.push(leafDigest);

        emit Submitted(payload.author, msg.sender, leafDigest);
    }

    /// @dev The guard IS the `onlyAdmin` modifier, hence the empty body: OZ
    /// invokes this hook from `upgradeToAndCall` before writing the ERC-1967
    /// implementation slot, and `msg.sender` survives the delegatecall hop.
    function _authorizeUpgrade(address) internal view override onlyAdmin {}

    /// @dev Contract-side tree build over `journal[start..end)` in Solady's
    /// heap layout (pair-sorted keccak; leaf k sits at 2L-2-k, node i hashes
    /// children 2i+1/2i+2, so a leftover leaf pairs with an internal node).
    /// Kept in memory; any off-chain prover must use the same convention.
    function _buildRoot(uint256 start, uint256 end) internal view returns (bytes32) {
        Storage storage $ = _getStorage();
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

    /// @dev The namespace pointer: every state access in this contract goes
    /// through it. `HubGetters` declares it `virtual` and unimplemented, so the
    /// literal belongs here — to the namespace owner — and not to the read
    /// layer. `internal` is the least visibility that can `override`; a derived
    /// implementation that needs a different layout must declare its OWN
    /// namespace instead of silently extending this one.
    function _getStorage() internal pure override returns (Storage storage $) {
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }
}
