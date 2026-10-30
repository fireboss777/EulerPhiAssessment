// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

/// @title ArticleAnchor — the canonical journal & batch root registry (hub).
/// @notice Every external entry point, getter, constant and event is declared
/// and documented on `IArticleAnchor`, which this contract inherits — read the
/// interface for the API. Only implementation-side members (constructor,
/// modifiers, `internal` helpers) are documented here.
contract ArticleAnchor is IArticleAnchor, Initializable, EIP712, UUPSUpgradeable {
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
    // Configuration (storage, never immutables: proxy-safe)
    // ---------------------------------------------------------------------
    /// @inheritdoc IArticleAnchor
    address public admin;
    /// @inheritdoc IArticleAnchor
    address public router;
    /// @inheritdoc IArticleAnchor
    uint64 public ethChainSelector;
    /// @inheritdoc IArticleAnchor
    address public gateway;

    // ---------------------------------------------------------------------
    // Journal & batch state
    // ---------------------------------------------------------------------
    /// @inheritdoc IArticleAnchor
    bytes32[] public journal;
    /// @inheritdoc IArticleAnchor
    mapping(address => mapping(bytes32 => bool)) public usedUuid;
    /// @inheritdoc IArticleAnchor
    mapping(address => uint256) public lastSubmit;
    /// @inheritdoc IArticleAnchor
    uint256 public batchOpenedAt;
    /// @inheritdoc IArticleAnchor
    uint256 public lastAnchoredIndex;
    /// @inheritdoc IArticleAnchor
    mapping(uint256 => bytes32) public rootAt;
    /// @inheritdoc IArticleAnchor
    mapping(uint256 => uint256) public anchoredAtBlock;
    /// @inheritdoc IArticleAnchor
    uint256 public anchoredBatches;
    modifier onlyAdmin() {
        if (msg.sender != admin) revert AdminOnly();
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

    /// @inheritdoc IArticleAnchor
    function initialize(address admin_, address router_, uint64 chainSelector_) external initializer {
        if (admin_ == address(0)) revert ZeroAdmin();
        admin = admin_;
        router = router_;
        ethChainSelector = chainSelector_;
    }

    /// @inheritdoc IArticleAnchor
    function setGateway(address gateway_) external onlyAdmin {
        gateway = gateway_;
    }

    // ---------------------------------------------------------------------
    // EIP-712 / UUPS wiring
    // ---------------------------------------------------------------------

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("EulerPhiArticle", "1");
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != admin) revert AdminOnly();
    }

    // ---------------------------------------------------------------------
    // Submission
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload) external {
        _submit(leafDigest, sig, payload);
    }

    function _submit(bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) internal {
        if (block.timestamp > payload.deadline) revert Expired();
        if (keccak256(abi.encode(payload)) != leafDigest) revert DigestMismatch();
        // Canonical 65-byte (r, s, v) only; low-s enforced (Solady's recover
        // deliberately accepts malleable s, so the gate lives here).
        if (sig.length != 65) revert InvalidSignatureLength();
        bytes32 s;
        assembly ("memory-safe") {
            s := mload(add(sig, 0x40)) // `s` at offset 0x40 of the bytes payload
        }
        if (uint256(s) > _HIGH_S_MAX) revert NonCanonicalSignature();
        bytes32 digest = _hashTypedData(ArticleLib.hashStruct(payload));
        if (ECDSA.recover(digest, sig) != payload.author) revert NotAuthor();
        if (block.timestamp < lastSubmit[payload.author] + RATE_LIMIT) revert RateLimited();
        if (usedUuid[payload.author][payload.uuid]) revert DuplicateUuid();

        usedUuid[payload.author][payload.uuid] = true;
        lastSubmit[payload.author] = block.timestamp;
        // First leaf of a fresh batch window opens (and re-opens) the deadline.
        if (journal.length == lastAnchoredIndex) batchOpenedAt = block.timestamp;
        journal.push(leafDigest);

        emit Submitted(payload.author, msg.sender, leafDigest);
    }

    // ---------------------------------------------------------------------
    // CCIP lanes
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function ccipReceive(Client.Any2EVMMessage calldata message) external {
        consumeSubmittedArticle(message);
    }

    /// @inheritdoc IArticleAnchor
    function consumeSubmittedArticle(Client.Any2EVMMessage calldata message) public {
        if (msg.sender != address(router)) revert NotRouter();
        if (message.sourceChainSelector != ethChainSelector) revert BadChain();
        if (abi.decode(message.sender, (address)) != gateway) revert BadSender();
        (bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) =
            abi.decode(message.data, (bytes32, bytes, ArticleSubmission));
        _submit(leafDigest, sig, payload);
    }

    /// @inheritdoc IArticleAnchor
    function notarize(uint256 batchIndex) external payable {
        uint256 anchoredAt = anchoredAtBlock[batchIndex];
        if (anchoredAt == 0) revert NoBatch();
        if (block.number < anchoredAt + NOTARY_K) revert NotFinal();

        Client.EVM2AnyMessage memory m = Client.EVM2AnyMessage({
            receiver: abi.encode(gateway),
            data: abi.encodeCall(ISubmissionGateway.receiveRoot, (batchIndex, rootAt[batchIndex])),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytesV1(NOTARY_GAS_LIMIT)
        });
        bytes32 messageId = IRouterClient(router).ccipSend{value: msg.value}(ethChainSelector, m);
        emit Notarized(batchIndex, rootAt[batchIndex], messageId);
    }

    // ---------------------------------------------------------------------
    // Batching & anchoring
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function anchorNextBatch() external returns (bytes32 root) {
        uint256 start = lastAnchoredIndex;
        uint256 pending = journal.length - start;
        bool ready = pending > 0 && (pending >= MIN_BATCH || block.timestamp >= batchOpenedAt + BATCH_DEADLINE);
        if (!ready) revert BatchNotReady();

        uint256 count = pending > MAX_BATCH ? MAX_BATCH : pending;
        uint256 end = start + count;
        root = _buildRoot(start, end);

        uint256 batchIndex = anchoredBatches;
        rootAt[batchIndex] = root;
        anchoredAtBlock[batchIndex] = block.number;
        anchoredBatches = batchIndex + 1;
        lastAnchoredIndex = end;

        emit RootAnchored(batchIndex, root, start, end);
    }

    /// @dev Contract-side tree build over `journal[start..end)` in Solady's
    /// heap layout (pair-sorted keccak; leaf k sits at 2L-2-k, node i hashes
    /// children 2i+1/2i+2, so a leftover leaf pairs with an internal node).
    /// Kept in memory; any off-chain prover must use the same convention.
    function _buildRoot(uint256 start, uint256 end) internal view returns (bytes32) {
        uint256 n = end - start;
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = journal[start + i];
        }
        return MerkleTreeLib.root(MerkleTreeLib.build(leaves));
    }

    /// @inheritdoc IArticleAnchor
    function verifyAgainstBatch(uint256 batchIndex, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        return MerkleProofLib.verifyCalldata(proof, rootAt[batchIndex], leaf);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IArticleAnchor
    function journalLength() external view returns (uint256) {
        return journal.length;
    }

    /// @inheritdoc IArticleAnchor
    function pendingLeaves() external view returns (uint256) {
        return journal.length - lastAnchoredIndex;
    }
}
