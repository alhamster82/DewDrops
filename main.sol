// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DewDrops — Airdrop platform for social tasks
/// @notice On-chain registry for task-based airdrops; complete social actions and claim droplets.
/// @dev Uses merkle roots for claim sets; task verifier and treasury are fixed at deploy.
///
/// Dew-drops collect on leaves at dawn; this contract records task completion and dispenses
/// rewards to eligible participants. Find your inner dew by completing social tasks.

contract DewDrops {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event MistTaskCreated(
        bytes32 indexed taskId,
        uint8 taskKind,
        uint256 rewardPerClaim,
        uint256 endBlock,
        bytes32 merkleRoot,
        uint256 createdAt
    );
    event MistTaskExtended(bytes32 indexed taskId, uint256 newEndBlock);
    event MistTaskDisabled(bytes32 indexed taskId, uint256 atBlock);
    event DropletFulfilled(
        address indexed participant,
        bytes32 indexed taskId,
        bytes32 proofNonce,
        uint256 rewardAmount,
        uint256 atBlock
    );
    event DewPoolTopped(bytes32 indexed taskId, uint256 amountAdded, uint256 newBalance);
    event TreasuryWithdrawn(address indexed to, uint256 amount, uint256 atBlock);
    event GuardianSet(address indexed guardian, bool status);
    event PauseToggled(bool paused, uint256 atBlock);
    event InnerDewClaimed(
        address indexed claimant,
        bytes32 indexed taskId,
        uint256 amount,
        uint256 totalClaimedForTask
    );
    event FallbackDeposit(address indexed from, uint256 amount);
    event TaskRewardUpdated(bytes32 indexed taskId, uint256 oldReward, uint256 newReward);
    event VestingConfigured(bytes32 indexed taskId, uint256 cliffBlocks, uint256 durationBlocks);
    event BatchTaskCreated(uint256 count, uint256 atBlock);
    event PoolToppedBatch(uint256 taskCount, uint256 totalWei);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error Mist_NotGuardian();
    error Mist_NotTreasury();
    error Mist_TaskExpired();
    error Mist_TaskDisabled();
    error Mist_TaskUnknown();
    error Mist_AlreadyFulfilled();
    error Mist_InvalidProof();
    error Mist_PoolInsufficient();
    error Mist_ZeroAmount();
    error Mist_ZeroAddress();
    error Mist_Reentrancy();
    error Mist_WhenPaused();
    error Mist_WhenNotPaused();
    error Mist_BatchLengthMismatch();
    error Mist_ArrayLengthMismatch();
    error Mist_MerkleRootEmpty();
    error Mist_EndBlockPast();
    error Mist_RewardZero();
    error Mist_TransferFailed();
    error Mist_IndexOutOfRange();
    error Mist_InvalidTaskKind();
    error Mist_RewardOutOfRange();
    error Mist_VestNotStarted();
    error Mist_VestAlreadyClaimed();
    error Mist_NoVesting();
    error Mist_GuardianAlreadySet();
    error Mist_TooManyTasksInBatch();
    error Mist_DuplicateTaskId();
    error Mist_InvalidCliff();
    error Mist_InvalidDuration();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant MIST_VERSION = 2;
    uint256 public constant MAX_TASK_KIND = 12;
    uint256 public constant MIN_END_BLOCK_OFFSET = 100;
    uint256 public constant MAX_CLAIM_BATCH = 88;
    uint256 public constant DEW_NAMESPACE = 0x8f3a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d;
    bytes32 public constant DOMAIN_SEED = keccak256("DewDrops.Mist.v2");
    uint256 public constant MAX_TASKS_PER_BATCH = 24;
    uint256 public constant MIN_REWARD_WEI = 1;
    uint256 public constant MAX_REWARD_WEI = 1000 ether;
    uint256 public constant DEFAULT_VEST_CLIFF_BLOCKS = 200;
    uint256 public constant DEFAULT_VEST_DURATION_BLOCKS = 1000;
    uint256 public constant PAGE_SIZE = 50;
    bytes32 public constant TASK_KIND_TWITTER = keccak256("twitter");
    bytes32 public constant TASK_KIND_DISCORD = keccak256("discord");
    bytes32 public constant TASK_KIND_TELEGRAM = keccak256("telegram");
    bytes32 public constant TASK_KIND_RETWEET = keccak256("retweet");
    bytes32 public constant TASK_KIND_QUOTE = keccak256("quote");
    bytes32 public constant TASK_KIND_LIKE = keccak256("like");
    bytes32 public constant TASK_KIND_COMMENT = keccak256("comment");
    bytes32 public constant TASK_KIND_JOIN = keccak256("join");
    bytes32 public constant TASK_KIND_SHARE = keccak256("share");
    bytes32 public constant TASK_KIND_WATCH = keccak256("watch");
    bytes32 public constant TASK_KIND_FOLLOW = keccak256("follow");
    bytes32 public constant TASK_KIND_CUSTOM = keccak256("custom");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable treasury;
    address public immutable taskVerifier;
    address public immutable guardianHub;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct MistTask {
        uint8 taskKind;
        uint256 rewardPerClaim;
        uint256 endBlock;
        bytes32 merkleRoot;
        uint256 poolBalance;
        bool disabled;
        uint256 totalClaimed;
    }

    mapping(bytes32 => MistTask) private _tasks;
    mapping(bytes32 => mapping(bytes32 => bool)) private _fulfilled;
    mapping(address => bool) private _guardians;
    bool private _paused;
    uint256 private _lock;
    bytes32[] private _taskIdList;
    uint256 private _taskCount;

    struct VestConfig {
        uint256 startBlock;
        uint256 cliffBlocks;
        uint256 durationBlocks;
        bool enabled;
    }
    mapping(bytes32 => VestConfig) private _vestConfig;
    mapping(bytes32 => mapping(address => uint256)) private _vestClaimed;

    mapping(bytes32 => uint256) private _taskCreatedAt;
    mapping(address => uint256) private _userTotalClaimed;
    uint256 private _globalTotalClaimed;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        treasury = 0xa1b2c3d4e5f6789012345678901234567890abcd;
        taskVerifier = 0xb2c3d4e5f6789012345678901234567890abcde1;
        guardianHub = 0xc3d4e5f6789012345678901234567890abcdef12;
        _guardians[0xc3d4e5f6789012345678901234567890abcdef12] = true;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyGuardian() {
        if (!_guardians[msg.sender]) revert Mist_NotGuardian();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert Mist_NotTreasury();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert Mist_WhenPaused();
        _;
    }

    modifier whenPaused() {
        if (!_paused) revert Mist_WhenNotPaused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 0) revert Mist_Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    // -------------------------------------------------------------------------
    // TASK LIFECYCLE (guardian)
    // -------------------------------------------------------------------------

    function createTask(
        bytes32 taskId,
        uint8 taskKind,
        uint256 rewardPerClaim,
        uint256 endBlock,
        bytes32 merkleRoot
    ) external onlyGuardian whenNotPaused nonReentrant {
        if (merkleRoot == bytes32(0)) revert Mist_MerkleRootEmpty();
        if (rewardPerClaim == 0) revert Mist_RewardZero();
        if (endBlock <= block.number) revert Mist_EndBlockPast();
        if (taskKind > MAX_TASK_KIND) revert Mist_TaskUnknown();
        if (_tasks[taskId].merkleRoot != bytes32(0)) revert Mist_TaskUnknown();

        _tasks[taskId] = MistTask({
            taskKind: taskKind,
            rewardPerClaim: rewardPerClaim,
            endBlock: endBlock,
            merkleRoot: merkleRoot,
            poolBalance: 0,
            disabled: false,
            totalClaimed: 0
        });
        _taskIdList.push(taskId);
        _taskCount += 1;
        _taskCreatedAt[taskId] = block.timestamp;
        emit MistTaskCreated(taskId, taskKind, rewardPerClaim, endBlock, merkleRoot, block.timestamp);
    }

    function createTaskWithVesting(
        bytes32 taskId,
        uint8 taskKind,
        uint256 rewardPerClaim,
        uint256 endBlock,
        bytes32 merkleRoot,
        uint256 cliffBlocks,
        uint256 durationBlocks
    ) external onlyGuardian whenNotPaused nonReentrant {
        if (merkleRoot == bytes32(0)) revert Mist_MerkleRootEmpty();
        if (rewardPerClaim == 0) revert Mist_RewardZero();
        if (endBlock <= block.number) revert Mist_EndBlockPast();
        if (taskKind > MAX_TASK_KIND) revert Mist_TaskUnknown();
        if (_tasks[taskId].merkleRoot != bytes32(0)) revert Mist_TaskUnknown();
        if (cliffBlocks > durationBlocks) revert Mist_InvalidCliff();
        if (durationBlocks == 0) revert Mist_InvalidDuration();

        _tasks[taskId] = MistTask({
            taskKind: taskKind,
            rewardPerClaim: rewardPerClaim,
            endBlock: endBlock,
            merkleRoot: merkleRoot,
            poolBalance: 0,
            disabled: false,
            totalClaimed: 0
        });
        _vestConfig[taskId] = VestConfig({
            startBlock: block.number,
            cliffBlocks: cliffBlocks,
            durationBlocks: durationBlocks,
            enabled: true
        });
        _taskIdList.push(taskId);
        _taskCount += 1;
        _taskCreatedAt[taskId] = block.timestamp;
        emit MistTaskCreated(taskId, taskKind, rewardPerClaim, endBlock, merkleRoot, block.timestamp);
    }

    function setVesting(bytes32 taskId, uint256 cliffBlocks, uint256 durationBlocks) external onlyGuardian {
        MistTask storage t = _tasks[taskId];
        if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        if (cliffBlocks > durationBlocks) revert Mist_InvalidCliff();
        if (durationBlocks == 0) revert Mist_InvalidDuration();
        _vestConfig[taskId] = VestConfig({
            startBlock: _vestConfig[taskId].startBlock != 0 ? _vestConfig[taskId].startBlock : block.number,
            cliffBlocks: cliffBlocks,
            durationBlocks: durationBlocks,
            enabled: true
        });
        emit VestingConfigured(taskId, cliffBlocks, durationBlocks);
    }

    function disableVesting(bytes32 taskId) external onlyGuardian {
        if (_tasks[taskId].merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        _vestConfig[taskId].enabled = false;
    }

    function createTaskBatch(
        bytes32[] calldata taskIds,
        uint8[] calldata taskKinds,
        uint256[] calldata rewardPerClaims,
        uint256[] calldata endBlocks,
        bytes32[] calldata merkleRoots
    ) external onlyGuardian whenNotPaused nonReentrant {
        uint256 n = taskIds.length;
        if (n != taskKinds.length || n != rewardPerClaims.length || n != endBlocks.length || n != merkleRoots.length) revert Mist_ArrayLengthMismatch();
        if (n > MAX_TASKS_PER_BATCH) revert Mist_TooManyTasksInBatch();

        for (uint256 i = 0; i < n; i++) {
            bytes32 taskId = taskIds[i];
            if (_tasks[taskId].merkleRoot != bytes32(0)) revert Mist_DuplicateTaskId();
            if (merkleRoots[i] == bytes32(0)) revert Mist_MerkleRootEmpty();
            if (rewardPerClaims[i] == 0) revert Mist_RewardZero();
            if (endBlocks[i] <= block.number) revert Mist_EndBlockPast();
            if (taskKinds[i] > MAX_TASK_KIND) revert Mist_InvalidTaskKind();

            _tasks[taskId] = MistTask({
                taskKind: taskKinds[i],
                rewardPerClaim: rewardPerClaims[i],
                endBlock: endBlocks[i],
                merkleRoot: merkleRoots[i],
                poolBalance: 0,
                disabled: false,
                totalClaimed: 0
            });
            _taskIdList.push(taskId);
            _taskCreatedAt[taskId] = block.timestamp;
            emit MistTaskCreated(taskId, taskKinds[i], rewardPerClaims[i], endBlocks[i], merkleRoots[i], block.timestamp);
        }
        _taskCount += n;
        emit BatchTaskCreated(n, block.number);
    }

    function topPoolBatch(bytes32[] calldata taskIds, uint256[] calldata amounts) external payable onlyGuardian whenNotPaused {
        uint256 n = taskIds.length;
        if (n != amounts.length) revert Mist_ArrayLengthMismatch();
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) {
            total += amounts[i];
            MistTask storage t = _tasks[taskIds[i]];
            if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
            t.poolBalance += amounts[i];
            emit DewPoolTopped(taskIds[i], amounts[i], t.poolBalance);
        }
        if (total != msg.value) revert Mist_ZeroAmount();
        emit PoolToppedBatch(n, msg.value);
