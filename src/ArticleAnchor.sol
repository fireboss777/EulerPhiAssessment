// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "solady/utils/EIP712.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {MerkleTreeLib} from "solady/utils/MerkleTreeLib.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ArticleLib, ArticleSubmission} from "./ArticleLib.sol";
import {Client} from "./interfaces/Client.sol";
import {IRouterClient} from "./interfaces/IRouterClient.sol";
import {ISubmissionGateway} from "./interfaces/ISubmissionGateway.sol";

/// @title ArticleAnchor — the canonical journal & batch root registry (hub).
/// @notice Authors sign `ArticleSubmission` payloads (EIP-712); anyone may
/// relay them on-chain. Leaves accumulate in an append-only journal; anyone
/// closes a batch, which builds the Merkle root *inside the contract* and
/// freezes it — anchors take no root input, so no malicious root can exist.
/// @dev v1 is deliberately role-free. Extension points (not implemented):
///  - role-gated publishing: gate `_submit` on an `isAuthor[author]` registry;
///  - meta-tx sponsorship: wrap `submitArticle` behind a forwarder.
contract ArticleAnchor is EIP712, UUPSUpgradeable {
    // ---------------------------------------------------------------------
    // Constants (see plan: batch policy)
    // ---------------------------------------------------------------------
    uint256 public constant MIN_BATCH = 10;
    uint256 public constant MAX_BATCH = 200;
    uint256 public constant BATCH_DEADLINE = 6 hours;
    uint256 public constant RATE_LIMIT = 1 hours;
    /// @notice L2 block confirmations required before a root may be notarized upward.
    uint256 public constant NOTARY_K = 64;
    /// @notice Receiver-side gas limit attached to the CCIP notary message.
    uint256 public constant NOTARY_GAS_LIMIT = 200_000;
    /// @dev floor(N/2) of secp256k1: signatures must be canonical low-s (EIP-2).
    uint256 private constant _HIGH_S_MAX =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    // ---------------------------------------------------------------------
    // Configuration (storage, never immutables: proxy-safe)
    // ---------------------------------------------------------------------
    address public admin;
    address public router;
    uint64 public ethChainSelector;
    address public gateway;

    // ---------------------------------------------------------------------
    // Journal & batch state
    // ---------------------------------------------------------------------
    bytes32[] public journal;
    mapping(bytes32 => bool) public usedUuid;
    mapping(address => uint256) public lastSubmit;
    uint256 public batchOpenedAt;
    uint256 public lastAnchoredIndex;
    mapping(uint256 => bytes32) public rootAt;
    mapping(uint256 => uint256) public anchoredAtBlock;
    uint256 public anchoredBatches;

    event Submitted(address indexed author, address indexed submitter, bytes32 leafDigest);
    event RootAnchored(uint256 indexed batchIndex, bytes32 root, uint256 start, uint256 end);
    event Notarized(uint256 indexed batchIndex, bytes32 root, bytes32 messageId);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin only");
        _;
    }

    constructor(address admin_, address router_, uint64 chainSelector_, address gateway_) {
        admin = admin_;
        router = router_;
        ethChainSelector = chainSelector_;
        gateway = gateway_;
    }

    /// @notice Proxy initializer — constructors don't run behind ERC1967
    /// proxies. Guarded by `admin == 0` (fresh proxy storage only; the direct-
    /// deploy constructor sets admin, so the implementation can't be re-inited).
    function initialize(address admin_, address router_, uint64 chainSelector_) external {
        require(admin == address(0), "initialized");
        admin = admin_;
        router = router_;
        ethChainSelector = chainSelector_;
    }

    /// @notice Post-deploy wiring: the L1 gateway address is known only after
    /// the gateway contract exists (deploy order: hub -> gateway -> setGateway).
    function setGateway(address gateway_) external onlyAdmin {
        gateway = gateway_;
    }

    // ---------------------------------------------------------------------
    // EIP-712 / UUPS wiring
    // ---------------------------------------------------------------------

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("EulerPhiArticle", "1");
    }

    function _authorizeUpgrade(address) internal override {
        require(msg.sender == admin, "admin only");
    }

    // ---------------------------------------------------------------------
    // Submission
    // ---------------------------------------------------------------------

    /// @notice Publish a signed article. Caller pays gas; may be anyone —
    /// authorship comes exclusively from `payload`'s EIP-712 signature.
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload)
        external
    {
        _submit(leafDigest, sig, payload);
    }

    function _submit(bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload)
        internal
    {
        require(block.timestamp <= payload.deadline, "expired");
        require(keccak256(abi.encode(payload)) == leafDigest, "digest mismatch");
        // Canonical 65-byte (r, s, v) only; low-s enforced (Solady's recover
        // deliberately accepts malleable s, so the gate lives here).
        require(sig.length == 65, "sig len");
        bytes32 s;
        assembly ("memory-safe") {
            s := mload(add(sig, 0x40)) // `s` at offset 0x40 of the bytes payload
        }
        require(uint256(s) <= _HIGH_S_MAX, "high-s");
        bytes32 digest = _hashTypedData(ArticleLib.hashStruct(payload));
        require(ECDSA.recover(digest, sig) == payload.author, "not author");
        require(block.timestamp >= lastSubmit[payload.author] + RATE_LIMIT, "rate");
        require(!usedUuid[payload.uuid], "dup");

        usedUuid[payload.uuid] = true;
        lastSubmit[payload.author] = block.timestamp;
        // First leaf of a fresh batch window opens (and re-opens) the deadline.
        if (journal.length == lastAnchoredIndex) batchOpenedAt = block.timestamp;
        journal.push(leafDigest);

        emit Submitted(payload.author, msg.sender, leafDigest);
    }

    // ---------------------------------------------------------------------
    // CCIP lanes
    // ---------------------------------------------------------------------

    /// @notice Standard IAny2EVMMessageReceiver entry — what a real Router
    /// calls to deliver. Forwards into the pinned `consumeSubmittedArticle`.
    function ccipReceive(Client.Any2EVMMessage calldata message) external {
        consumeSubmittedArticle(message);
    }

    /// @notice Inbound lane: signed article payloads from the pinned L1
    /// gateway. Pinned by (router, sourceChainSelector, sender) — all three,
    /// so a foreign router, chain, or contract cannot journal anything.
    function consumeSubmittedArticle(Client.Any2EVMMessage calldata message) public {
        require(msg.sender == address(router), "not router");
        require(message.sourceChainSelector == ethChainSelector, "bad chain");
        require(abi.decode(message.sender, (address)) == gateway, "bad sender");
        (bytes32 leafDigest, bytes memory sig, ArticleSubmission memory payload) =
            abi.decode(message.data, (bytes32, bytes, ArticleSubmission));
        _submit(leafDigest, sig, payload);
    }

    /// @notice Notarize an anchored batch root to the L1 gateway via CCIP.
    /// Permissionless; the caller funds the fee (`msg.value`) — keepers pay
    /// for what they send, no protocol float to drain.
    function notarize(uint256 batchIndex) external payable {
        uint256 anchoredAt = anchoredAtBlock[batchIndex];
        require(anchoredAt != 0, "no batch");
        require(block.number >= anchoredAt + NOTARY_K, "not final");

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

    /// @notice Close the current batch. Permissionless: takes NO arguments, so
    /// the only root it can ever publish is the one computed from the journal.
    function anchorNextBatch() external returns (bytes32 root) {
        uint256 start = lastAnchoredIndex;
        uint256 pending = journal.length - start;
        require(
            pending > 0
                && (pending >= MIN_BATCH || block.timestamp >= batchOpenedAt + BATCH_DEADLINE),
            "batch not ready"
        );

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

    /// @dev Contract-side tree build over `journal[start..end)` — Solady
    /// semantics (pair-sorted keccak, odd node promoted raw). Kept in memory.
    function _buildRoot(uint256 start, uint256 end) internal view returns (bytes32) {
        uint256 n = end - start;
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = journal[start + i];
        }
        return MerkleTreeLib.root(MerkleTreeLib.build(leaves));
    }

    /// @notice Verify a leaf against an anchored batch root (reader path).
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

    function journalLength() external view returns (uint256) {
        return journal.length;
    }

    function pendingLeaves() external view returns (uint256) {
        return journal.length - lastAnchoredIndex;
    }
}
