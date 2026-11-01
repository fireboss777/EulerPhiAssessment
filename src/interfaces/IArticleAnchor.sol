// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
/// Policy constants (`MIN_BATCH`, `RATE_LIMIT` …) are NOT here
/// either: they live as `public constant`s in `ArticleLib`. Solidity forbids
/// variables in interfaces (Error 8274), and a contract getter forwarding a
/// value the compiler inlines would be pure indirection.
///
/// @dev Deliberately NOT redeclared here (they come from base contracts, and
/// redeclaring them would force double-base overrides for no gain):
/// `eip712Domain()` (Solady `EIP712`); `upgradeToAndCall()`,
/// `proxiableUUID()`, `UPGRADE_INTERFACE_VERSION()` (OpenZeppelin
/// `UUPSUpgradeable`); and the `Upgraded` event — emitted by OZ's inlined
/// `ERC1967Utils`, so it IS part of this contract's ABI without being
/// declared by us. Everything else — 6 functions and 3 events — is declared
/// below. The 11 read getters are deliberately NOT here: they live in
/// `IArticleAnchorGetters`, brought in by `ArticleAnchorGetters`, which this
/// contract also inherits — the union of the two IS its complete ABI.
interface IArticleAnchor {
    /// @notice The hub's entire persistent state, in a single ERC-7201
    /// namespace. The implementation declares NO state variable of its own:
    /// every read and write goes through this struct at the fixed slot
    /// `keccak256(abi.encode(uint256(keccak256("eulerphi.storage.ArticleAnchor")) - 1)) & ~bytes32(uint256(0xff))`
    /// — frozen as `ArticleLib.STORAGE_SLOT` (inline assembly accepts only
    /// number constants) and proven equal to this formula by
    /// `test_storageLivesAtErc7201Slot`. Why it is practical: a future base
    /// contract cannot collide with this layout, the layout is auditable as
    /// one block in this file, and reordering/adding fields is a deliberate,
    /// namespace-local decision instead of a global slot lottery.
    ///
    /// @custom:storage-location erc7201:eulerphi.storage.ArticleAnchor
    struct Storage {
        /// @dev Slot 0, bytes 0..20.
        address router;
        /// @dev Slot 1 — mapping base (stores nothing); the entry for
        /// `chainSelector` at `keccak256(abi.encode(uint64 chainSelector, uint256(1)))`
        /// — the absolute slot is namespace base + 1. 0 = chain not authorized
        /// (or revoked).
        mapping(uint64 => address) gatewayAt;
        /// @dev Slot 2 — the word holds the array length; element `i` lives at
        /// `keccak256(abi.encode(uint256(2), baseSlot)) + i`.
        bytes32[] journal;
        /// @dev Slot 3 — double-mapping base; entry slots derive from it.
        mapping(address => mapping(bytes32 => bool)) usedUuid;
        /// @dev Slot 4.
        mapping(address => uint256) lastSubmit;
        /// @dev Slot 5.
        uint256 batchOpenedAt;
        /// @dev Slot 6.
        uint256 lastAnchoredIndex;
        /// @dev Slot 7 — mapping base; value at `keccak256(abi.encode(uint256(batchIndex), baseSlot))`.
        mapping(uint256 => bytes32) rootAt;
        /// @dev Slot 8.
        uint256 anchoredBatches;
    }

    /// @notice The universal article envelope: what a writer signs (EIP-712 struct)
    /// and what the hub journals as a leaf. Content lives off-chain (IPFS); only
    /// commitments (hashes) travel through this struct.
    struct ArticleSubmission {
        address author;
        bytes32 titleHash;
        bytes32 bodyHash;
        bytes32 cidHash;
        bytes32 uuid;
        uint256 timestamp;
        uint256 deadline;
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

    /// @notice The owner registered (or, with `gateway_ = address(0)`, revoked)
    /// the inbound gateway of one source chain.
    /// @param chainSelector Chainlink selector of the source chain.
    /// @param gateway The only sender accepted from that chain; 0 revokes the chain.
    event GatewaySet(uint64 indexed chainSelector, address gateway);

    // ---------------------------------------------------------------------
    // Errors (thrown by the implementation; declared here so the ABI and the
    // docs of every failure mode live with the API they belong to. Access
    // control — `OwnableUnauthorizedAccount`, `OwnableInvalidOwner` — is
    // declared by OZ's `OwnableUpgradeable`, never redeclared here.)
    // ---------------------------------------------------------------------

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
    /// @notice No gateway is registered for the message's source chain (revoked
    /// or never authorized).
    error BadChain();
    /// @notice Message sender differs from the gateway registered for its source
    /// chain.
    error BadSender();
    /// @notice The batch is neither big enough nor old enough to close.
    error BatchNotReady();

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
    /// and OZ's `OwnableInvalidOwner(address(0))` on `initialOwner = address(0)`
    /// (the zero check lives in `__Ownable_init`).
    function initialize(address initialOwner, address router_) external;

    /// @notice Post-deploy authorization of one source chain: the gateway address
    /// is known only after its contract exists (deploy order: hub -> gateway per
    /// chain -> setGateway(chainSelector, gateway)). `gateway_ = address(0)`
    /// revokes the chain — inbound messages from it then revert `BadChain()`.
    /// @dev owner-only. Emits `GatewaySet`.
    function setGateway(uint64 chainSelector, address gateway_) external;

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
    // CCIP lane — inbound only (source-chain gateways -> hub)
    // ---------------------------------------------------------------------

    /// @notice Standard `IAny2EVMMessageReceiver` entry — what a real Router
    /// calls to deliver. The ONLY external door into the inbound lane: it
    /// forwards into `_consumeSubmittedArticle`, which holds the three checks
    /// (router, `gatewayAt` registration for `sourceChainSelector`, sender) so a
    /// foreign router, chain or contract cannot journal anything. Shares every check with the direct
    /// lane: one `_submit`, one set of rules.
    function ccipReceive(Client.Any2EVMMessage calldata message) external;

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
