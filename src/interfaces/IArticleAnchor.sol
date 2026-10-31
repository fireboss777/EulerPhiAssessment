// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ArticleSubmission } from "../ArticleLib.sol";
import { Client } from "./Client.sol";

/// @title ArticleAnchor — the canonical journal & batch root registry (hub).
/// @notice Public ABI of the hub, implemented by `src/ArticleAnchor.sol`
/// (which inherits this interface, so the compiler keeps ABI and docs in
/// lockstep). Authors sign `ArticleSubmission` payloads (EIP-712); anyone may
/// relay them on-chain. Leaves accumulate in an append-only journal; anyone
/// closes a batch, which builds the Merkle root *inside the contract* and
/// freezes it — anchors take no root input, so no malicious root can exist.
/// @dev v1 is deliberately role-free. Extension points (not implemented):
///  - role-gated publishing: gate submission on an `isAuthor[author]` registry;
///  - meta-tx sponsorship: wrap `submitArticle` behind a forwarder.
///
/// Constants are declared as getter functions here because Solidity forbids
/// variables in interfaces (Error 8274); the implementation's
/// `public constant` getters satisfy them.
///
/// @dev Deliberately NOT redeclared here (they come from base contracts, and
/// redeclaring them would force double-base overrides for no gain):
/// `eip712Domain()` (Solady `EIP712`); `upgradeToAndCall()`,
/// `proxiableUUID()`, `UPGRADE_INTERFACE_VERSION()` (OpenZeppelin
/// `UUPSUpgradeable`); and the `Upgraded` event — emitted by OZ's inlined
/// `ERC1967Utils`, so it IS part of this contract's ABI without being
/// declared by us. Everything else — 14 functions and 3 events — is declared
/// below. The 14 read getters are deliberately NOT here: they live in
/// `IArticleAnchorGetters`, brought in by `ArticleAnchorGetters`, which this
/// contract also inherits — the union of the two IS its complete ABI.
interface IArticleAnchor {
    /// @notice The hub's entire persistent state, in a single ERC-7201
    /// namespace. The implementation declares NO state variable of its own:
    /// every read and write goes through this struct at the fixed slot
    /// `keccak256(abi.encode(uint256(keccak256("eulerphi.storage.ArticleAnchor")) - 1)) & ~bytes32(uint256(0xff))`
    /// — frozen as a literal in `ArticleAnchor` (inline assembly accepts only
    /// number constants) and proven equal to this formula by
    /// `test_storageLivesAtErc7201Slot`. Why it is practical: a future base
    /// contract cannot collide with this layout, the layout is auditable as
    /// one block in this file, and reordering/adding fields is a deliberate,
    /// namespace-local decision instead of a global slot lottery.
    ///
    /// @custom:storage-location erc7201:eulerphi.storage.ArticleAnchor
    struct Storage {
        /// @dev Slot 0.
        address admin;
        /// @dev Slot 1, bytes 0..20.
        address router;
        /// @dev Slot 1, bytes 20..28 — packs with `router` (20 + 8 <= 32). This
        /// pairing is the original contract layout, byte for byte: `notarize`
        /// reads both, so they must share one cold word.
        uint64 ethChainSelector;
        /// @dev Slot 2.
        address gateway;
        /// @dev Slot 3 — the word holds the array length; element `i` lives at
        /// `keccak256(abi.encode(uint256(3), baseSlot)) + i`.
        bytes32[] journal;
        /// @dev Slot 4 — double-mapping base; entry slots derive from it.
        mapping(address => mapping(bytes32 => bool)) usedUuid;
        /// @dev Slot 5.
        mapping(address => uint256) lastSubmit;
        /// @dev Slot 6.
        uint256 batchOpenedAt;
        /// @dev Slot 7.
        uint256 lastAnchoredIndex;
        /// @dev Slot 8 — mapping base; value at `keccak256(abi.encode(uint256(batchIndex), baseSlot))`.
        mapping(uint256 => bytes32) rootAt;
        /// @dev Slot 9 — mapping base (value slots are never packed).
        mapping(uint256 => uint256) anchoredAtBlock;
        /// @dev Slot 10.
        uint256 anchoredBatches;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A signed payload entered the journal.
    /// @param author The byline — recovered from the EIP-712 signature, never trusted from args.
    /// @param submitter The gas payer (may be a third-party relayer).
    /// @param leafDigest The journaled commitment.
    event Submitted(address indexed author, address indexed submitter, bytes32 leafDigest);

    /// @notice Batch `batchIndex` was closed and its root frozen forever.
    /// @param root The contract-derived Merkle root over `journal[start..end)`.
    /// @param start Journal offset of the first leaf in this batch.
    /// @param end Journal offset one past the last leaf in this batch.
    event RootAnchored(uint256 indexed batchIndex, bytes32 root, uint256 start, uint256 end);

    /// @notice A batch root was sent to the L1 gateway over CCIP.
    /// @param messageId Chainlink's message id for the notarization.
    event Notarized(uint256 indexed batchIndex, bytes32 root, bytes32 messageId);

    // ---------------------------------------------------------------------
    // Errors (thrown by the implementation; declared here so the ABI and the
    // docs of every failure mode live with the API they belong to)
    // ---------------------------------------------------------------------

    /// @notice Caller is not the `admin`.
    error AdminOnly();
    /// @notice `initialize` was called with `admin_ = address(0)` — an
    /// admin-less hub could never be upgraded.
    error ZeroAdmin();
    /// @notice The payload's `deadline` is already in the past.
    error Expired();
    /// @notice `leafDigest` is not `keccak256(abi.encode(payload))`.
    error DigestMismatch();
    /// @notice Signature is not a canonical 65-byte `(r, s, v)`.
    error InvalidSignatureLength();
    /// @notice High-`s` (malleable, non EIP-2) form of the signature.
    error NonCanonicalSignature();
    /// @notice Recovered signer is not `payload.author`.
    error NotAuthor();
    /// @notice Author submitted again inside `RATE_LIMIT`.
    error RateLimited();
    /// @notice This `(author, uuid)` was already published.
    error DuplicateUuid();
    /// @notice Caller is not the pinned router (inbound CCIP lane gate).
    error NotRouter();
    /// @notice Message is from a chain other than the pinned selector.
    error BadChain();
    /// @notice Message is from a sender other than the pinned one.
    error BadSender();
    /// @notice The batch is neither big enough nor old enough to close.
    error BatchNotReady();
    /// @notice No such anchored batch — nothing to notarize.
    error NoBatch();
    /// @notice Batch has not reached `NOTARY_K` confirmations yet (reorg gate).
    error NotFinal();

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Proxy initializer — constructors don't run behind ERC1967
    /// proxies, so configuration lands here instead, passed as the proxy's
    /// constructor `_data` (OZ docs: initialize as early as possible). Guarded
    /// by OpenZeppelin's `initializer` modifier: at most once per proxy, and
    /// the bare implementation is locked forever by `_disableInitializers()`
    /// in its own constructor, so no stranger can ever own it.
    /// @dev Reverts `Initializable.InvalidInitialization()` on a second call,
    /// and `ZeroAdmin()` on `admin_ = address(0)`.
    function initialize(address admin_, address router_, uint64 chainSelector_) external;

    /// @notice Post-deploy wiring: the L1 gateway address is known only after
    /// the gateway contract exists (deploy order: hub -> gateway -> setGateway).
    /// @dev Admin-only.
    function setGateway(address gateway_) external;

    // ---------------------------------------------------------------------
    // Submission
    // ---------------------------------------------------------------------

    /// @notice Publish a signed article. Caller pays gas; may be anyone —
    /// authorship comes exclusively from `payload`'s EIP-712 signature.
    /// @dev Reverts, in order: `Expired()`, `DigestMismatch()`,
    /// `InvalidSignatureLength()`, `NonCanonicalSignature()`, `NotAuthor()`,
    /// `RateLimited()`, `DuplicateUuid()`.
    /// @param leafDigest The commitment that will be journaled.
    /// @param sig EIP-712 signature over `ArticleSubmission`, 65 bytes `(r, s, v)`.
    /// @param payload The typed article envelope (hashes only — content stays off-chain).
    function submitArticle(bytes32 leafDigest, bytes calldata sig, ArticleSubmission calldata payload) external;

    // ---------------------------------------------------------------------
    // CCIP lanes
    // ---------------------------------------------------------------------

    /// @notice Standard `IAny2EVMMessageReceiver` entry — what a real Router
    /// calls to deliver. Forwards into the pinned `consumeSubmittedArticle`.
    function ccipReceive(Client.Any2EVMMessage calldata message) external;

    /// @notice Inbound lane: signed article payloads from the pinned L1
    /// gateway. Pinned by (router, sourceChainSelector, sender) — all three,
    /// so a foreign router, chain, or contract cannot journal anything.
    /// @dev Shares every check with the direct lane: one `_submit`, one set of rules.
    function consumeSubmittedArticle(Client.Any2EVMMessage calldata message) external;

    /// @notice Notarize an anchored batch root to the L1 gateway via CCIP.
    /// Permissionless; the caller funds the fee (`msg.value`) — keepers pay
    /// for what they send, no protocol float to drain.
    /// @dev Reverts `NoBatch()` for an unanchored index and `NotFinal()` until
    /// `block.number >= anchoredAtBlock[batchIndex] + NOTARY_K` (reorg gate).
    /// @param batchIndex Index of the batch whose frozen root is being sent.
    function notarize(uint256 batchIndex) external payable;

    // ---------------------------------------------------------------------
    // Batching & anchoring
    // ---------------------------------------------------------------------

    /// @notice Close the current batch. Permissionless: takes NO arguments, so
    /// the only root it can ever publish is the one computed from the journal.
    /// @dev Ready when `pendingLeaves() >= MIN_BATCH` or the open window is
    /// older than `BATCH_DEADLINE`; at most `MAX_BATCH` leaves per call.
    /// @return root The freshly frozen Merkle root for `[lastAnchoredIndex, end)`.
    function anchorNextBatch() external returns (bytes32 root);

    // ---------------------------------------------------------------------
    // Views — batch & lane policy
    // ---------------------------------------------------------------------

    /// @notice Leaves required before a batch may close without waiting.
    function MIN_BATCH() external view returns (uint256);

    /// @notice Hard cap on leaves taken per batch (the window splits).
    function MAX_BATCH() external view returns (uint256);

    /// @notice Age of the open window after which a partial batch may close.
    function BATCH_DEADLINE() external view returns (uint256);

    /// @notice Minimum spacing between two submissions by the same author.
    function RATE_LIMIT() external view returns (uint256);

    /// @notice L2 block confirmations required before a root may be notarized upward.
    function NOTARY_K() external view returns (uint256);

    /// @notice Receiver-side gas limit attached to the CCIP notary message.
    function NOTARY_GAS_LIMIT() external view returns (uint256);

    // ---------------------------------------------------------------------
    // Views — verification (reader path)
    // ---------------------------------------------------------------------

    /// @notice Verify a leaf against an anchored batch root (reader path).
    /// @dev Batches are closed sets: a leaf from another batch fails even with
    /// a valid proof. Roots are read-only once anchored.
    /// @param batchIndex Batch whose frozen root to check against.
    /// @param leaf The commitment being proven.
    /// @param proof Sibling path in Solady `MerkleTreeLib` heap layout.
    /// @return True iff `leaf` is a member of that batch.
    function verifyAgainstBatch(uint256 batchIndex, bytes32 leaf, bytes32[] calldata proof) external view returns (bool);
}
