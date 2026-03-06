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
    }

    function extendTaskEnd(bytes32 taskId, uint256 newEndBlock) external onlyGuardian whenNotPaused {
        MistTask storage t = _tasks[taskId];
        if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        if (newEndBlock <= block.number) revert Mist_EndBlockPast();
        t.endBlock = newEndBlock;
        emit MistTaskExtended(taskId, newEndBlock);
    }

    function disableTask(bytes32 taskId) external onlyGuardian {
        MistTask storage t = _tasks[taskId];
        if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        t.disabled = true;
        emit MistTaskDisabled(taskId, block.number);
    }

    function topPool(bytes32 taskId, uint256 amount) external payable onlyGuardian whenNotPaused {
        MistTask storage t = _tasks[taskId];
        if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        if (amount != msg.value) revert Mist_ZeroAmount();
        if (amount == 0) revert Mist_ZeroAmount();
        t.poolBalance += amount;
        emit DewPoolTopped(taskId, amount, t.poolBalance);
    }

    // -------------------------------------------------------------------------
    // CLAIM (participants)
    // -------------------------------------------------------------------------

    function claimDroplet(
        bytes32 taskId,
        bytes32 proofNonce,
        bytes32[] calldata merkleProof
    ) external whenNotPaused nonReentrant {
        MistTask storage t = _tasks[taskId];
        if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        if (t.disabled) revert Mist_TaskDisabled();
        if (block.number > t.endBlock) revert Mist_TaskExpired();
        if (_fulfilled[taskId][proofNonce]) revert Mist_AlreadyFulfilled();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, proofNonce, taskId, DOMAIN_SEED));
        if (!_verifyMerkle(merkleProof, t.merkleRoot, leaf)) revert Mist_InvalidProof();

        uint256 amount = t.rewardPerClaim;
        if (t.poolBalance < amount) revert Mist_PoolInsufficient();

        _fulfilled[taskId][proofNonce] = true;
        t.poolBalance -= amount;
        t.totalClaimed += amount;
        _userTotalClaimed[msg.sender] += amount;
        _globalTotalClaimed += amount;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert Mist_TransferFailed();

        emit DropletFulfilled(msg.sender, taskId, proofNonce, amount, block.number);
        emit InnerDewClaimed(msg.sender, taskId, amount, t.totalClaimed);
    }

    mapping(bytes32 => mapping(address => uint256)) private _vestPending;

    function claimDropletVested(
        bytes32 taskId,
        bytes32 proofNonce,
        bytes32[] calldata merkleProof
    ) external whenNotPaused nonReentrant {
        MistTask storage t = _tasks[taskId];
        VestConfig storage v = _vestConfig[taskId];
        if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
        if (t.disabled) revert Mist_TaskDisabled();
        if (block.number > t.endBlock) revert Mist_TaskExpired();
        if (_fulfilled[taskId][proofNonce]) revert Mist_AlreadyFulfilled();
        if (!v.enabled) revert Mist_NoVesting();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, proofNonce, taskId, DOMAIN_SEED));
        if (!_verifyMerkle(merkleProof, t.merkleRoot, leaf)) revert Mist_InvalidProof();

        uint256 amount = t.rewardPerClaim;
        if (t.poolBalance < amount) revert Mist_PoolInsufficient();

        _fulfilled[taskId][proofNonce] = true;
        t.poolBalance -= amount;
        _vestPending[taskId][msg.sender] += amount;
        t.totalClaimed += amount;
        emit DropletFulfilled(msg.sender, taskId, proofNonce, amount, block.number);
    }

    function claimVested(bytes32 taskId) external whenNotPaused nonReentrant {
        VestConfig storage v = _vestConfig[taskId];
        if (!v.enabled) revert Mist_NoVesting();
        uint256 start = v.startBlock;
        uint256 cliff = v.cliffBlocks;
        uint256 dur = v.durationBlocks;
        if (block.number < start + cliff) revert Mist_VestNotStarted();

        uint256 pending = _vestPending[taskId][msg.sender];
        if (pending == 0) revert Mist_ZeroAmount();

        uint256 elapsed = block.number - start;
        if (elapsed > dur) elapsed = dur;
        uint256 vestedTotal = (pending * elapsed) / dur;
        uint256 already = _vestClaimed[taskId][msg.sender];
        if (vestedTotal <= already) revert Mist_ZeroAmount();
        uint256 toSend = vestedTotal - already;
        _vestClaimed[taskId][msg.sender] = vestedTotal;

        _userTotalClaimed[msg.sender] += toSend;
        _globalTotalClaimed += toSend;

        (bool ok,) = payable(msg.sender).call{value: toSend}("");
        if (!ok) revert Mist_TransferFailed();
        emit InnerDewClaimed(msg.sender, taskId, toSend, _tasks[taskId].totalClaimed);
    }

    function claimDropletBatch(
        bytes32[] calldata taskIds,
        bytes32[] calldata proofNonces,
        bytes32[][] calldata merkleProofs
    ) external whenNotPaused nonReentrant {
        uint256 n = taskIds.length;
        if (n != proofNonces.length || n != merkleProofs.length) revert Mist_BatchLengthMismatch();
        if (n > MAX_CLAIM_BATCH) revert Mist_ArrayLengthMismatch();

        uint256 totalPay = 0;
        for (uint256 i = 0; i < n; i++) {
            bytes32 taskId = taskIds[i];
            bytes32 proofNonce = proofNonces[i];
            MistTask storage t = _tasks[taskId];
            if (t.merkleRoot == bytes32(0)) revert Mist_TaskUnknown();
            if (t.disabled) revert Mist_TaskDisabled();
            if (block.number > t.endBlock) revert Mist_TaskExpired();
            if (_fulfilled[taskId][proofNonce]) revert Mist_AlreadyFulfilled();

            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, proofNonce, taskId, DOMAIN_SEED));
            if (!_verifyMerkle(merkleProofs[i], t.merkleRoot, leaf)) revert Mist_InvalidProof();

            uint256 amount = t.rewardPerClaim;
            if (t.poolBalance < amount) revert Mist_PoolInsufficient();

            _fulfilled[taskId][proofNonce] = true;
            t.poolBalance -= amount;
            t.totalClaimed += amount;
            totalPay += amount;
        }
        _userTotalClaimed[msg.sender] += totalPay;
        _globalTotalClaimed += totalPay;

        (bool ok,) = payable(msg.sender).call{value: totalPay}("");
        if (!ok) revert Mist_TransferFailed();

        for (uint256 i = 0; i < n; i++) {
            emit DropletFulfilled(msg.sender, taskIds[i], proofNonces[i], _tasks[taskIds[i]].rewardPerClaim, block.number);
            emit InnerDewClaimed(msg.sender, taskIds[i], _tasks[taskIds[i]].rewardPerClaim, _tasks[taskIds[i]].totalClaimed);
        }
    }

    // -------------------------------------------------------------------------
    // GUARDIAN ADMIN
    // -------------------------------------------------------------------------

    function setGuardian(address account, bool status) external onlyGuardian {
        if (account == address(0)) revert Mist_ZeroAddress();
        _guardians[account] = status;
        emit GuardianSet(account, status);
    }

    function setPaused(bool paused_) external onlyGuardian {
        _paused = paused_;
        emit PauseToggled(_paused, block.timestamp);
    }

    function emergencyWithdrawEth(uint256 amount, address to) external onlyGuardian whenPaused nonReentrant {
        if (to == address(0)) revert Mist_ZeroAddress();
        if (amount == 0) revert Mist_ZeroAmount();
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert Mist_TransferFailed();
        emit TreasuryWithdrawn(to, amount, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // TREASURY
    // -------------------------------------------------------------------------

    function withdrawToTreasury(uint256 amount) external onlyTreasury nonReentrant {
        if (amount == 0) revert Mist_ZeroAmount();
        (bool ok,) = payable(treasury).call{value: amount}("");
        if (!ok) revert Mist_TransferFailed();
        emit TreasuryWithdrawn(treasury, amount, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // VIEWS
    // -------------------------------------------------------------------------

    function getTask(bytes32 taskId) external view returns (
        uint8 taskKind,
        uint256 rewardPerClaim,
        uint256 endBlock,
        bytes32 merkleRoot,
        uint256 poolBalance,
        bool disabled,
        uint256 totalClaimed
    ) {
        MistTask storage t = _tasks[taskId];
        return (
            t.taskKind,
            t.rewardPerClaim,
            t.endBlock,
            t.merkleRoot,
            t.poolBalance,
            t.disabled,
            t.totalClaimed
        );
    }

    function hasFulfilled(bytes32 taskId, bytes32 proofNonce) external view returns (bool) {
        return _fulfilled[taskId][proofNonce];
    }

    function isGuardian(address account) external view returns (bool) {
        return _guardians[account];
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function taskIdAt(uint256 index) external view returns (bytes32) {
        return _taskIdList[index];
    }

    function taskCount() external view returns (uint256) {
        return _taskCount;
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getVestConfig(bytes32 taskId) external view returns (
        uint256 startBlock,
        uint256 cliffBlocks,
        uint256 durationBlocks,
        bool enabled
    ) {
        VestConfig storage v = _vestConfig[taskId];
        return (v.startBlock, v.cliffBlocks, v.durationBlocks, v.enabled);
    }

    function getVestPending(bytes32 taskId, address account) external view returns (uint256) {
        return _vestPending[taskId][account];
    }

    function getVestClaimed(bytes32 taskId, address account) external view returns (uint256) {
        return _vestClaimed[taskId][account];
    }

    function getVestedAmount(bytes32 taskId, address account) external view returns (uint256 claimable) {
        VestConfig storage v = _vestConfig[taskId];
        if (!v.enabled) return 0;
        uint256 pending = _vestPending[taskId][account];
        if (pending == 0) return 0;
        uint256 start = v.startBlock;
        uint256 cliff = v.cliffBlocks;
        uint256 dur = v.durationBlocks;
        if (block.number < start + cliff) return 0;
        uint256 elapsed = block.number - start;
        if (elapsed > dur) elapsed = dur;
        uint256 vestedTotal = (pending * elapsed) / dur;
        uint256 already = _vestClaimed[taskId][account];
        if (vestedTotal <= already) return 0;
        return vestedTotal - already;
    }

    function taskCreatedAt(bytes32 taskId) external view returns (uint256) {
        return _taskCreatedAt[taskId];
    }

    function userTotalClaimed(address account) external view returns (uint256) {
        return _userTotalClaimed[account];
    }

    function globalTotalClaimed() external view returns (uint256) {
        return _globalTotalClaimed;
    }

    function getTaskIdsPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        uint256 total = _taskIdList.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _taskIdList[offset + i];
    }

    function getTasksBatch(bytes32[] calldata taskIds) external view returns (
        uint8[] memory taskKinds,
        uint256[] memory rewardPerClaims,
        uint256[] memory endBlocks,
        bytes32[] memory merkleRoots,
        uint256[] memory poolBalances,
        bool[] memory disableds,
        uint256[] memory totalClaimeds
    ) {
        uint256 n = taskIds.length;
        taskKinds = new uint8[](n);
        rewardPerClaims = new uint256[](n);
        endBlocks = new uint256[](n);
        merkleRoots = new bytes32[](n);
        poolBalances = new uint256[](n);
        disableds = new bool[](n);
        totalClaimeds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            MistTask storage t = _tasks[taskIds[i]];
            taskKinds[i] = t.taskKind;
            rewardPerClaims[i] = t.rewardPerClaim;
            endBlocks[i] = t.endBlock;
            merkleRoots[i] = t.merkleRoot;
            poolBalances[i] = t.poolBalance;
            disableds[i] = t.disabled;
            totalClaimeds[i] = t.totalClaimed;
        }
    }

    function isTaskActive(bytes32 taskId) external view returns (bool) {
        MistTask storage t = _tasks[taskId];
        return t.merkleRoot != bytes32(0) && !t.disabled && block.number <= t.endBlock;
    }

    function blocksRemaining(bytes32 taskId) external view returns (uint256) {
        MistTask storage t = _tasks[taskId];
        if (t.endBlock <= block.number) return 0;
        return t.endBlock - block.number;
    }

    function computeLeaf(address participant, bytes32 proofNonce, bytes32 taskId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(participant, proofNonce, taskId, DOMAIN_SEED));
    }

    function getTaskKindName(uint8 kind) external pure returns (string memory) {
        if (kind == 0) return "twitter";
        if (kind == 1) return "discord";
        if (kind == 2) return "telegram";
        if (kind == 3) return "retweet";
        if (kind == 4) return "quote";
        if (kind == 5) return "like";
        if (kind == 6) return "comment";
        if (kind == 7) return "join";
        if (kind == 8) return "share";
        if (kind == 9) return "watch";
        if (kind == 10) return "follow";
        if (kind == 11) return "custom";
        return "unknown";
    }

    function taskReward(bytes32 taskId) external view returns (uint256) { return _tasks[taskId].rewardPerClaim; }
    function taskEndBlock(bytes32 taskId) external view returns (uint256) { return _tasks[taskId].endBlock; }
    function taskPoolBalance(bytes32 taskId) external view returns (uint256) { return _tasks[taskId].poolBalance; }
    function taskMerkleRoot(bytes32 taskId) external view returns (bytes32) { return _tasks[taskId].merkleRoot; }
    function taskDisabled(bytes32 taskId) external view returns (bool) { return _tasks[taskId].disabled; }
    function taskTotalClaimed(bytes32 taskId) external view returns (uint256) { return _tasks[taskId].totalClaimed; }
    function taskKind(bytes32 taskId) external view returns (uint8) { return _tasks[taskId].taskKind; }

    function vestStartBlock(bytes32 taskId) external view returns (uint256) { return _vestConfig[taskId].startBlock; }
    function vestCliffBlocks(bytes32 taskId) external view returns (uint256) { return _vestConfig[taskId].cliffBlocks; }
    function vestDurationBlocks(bytes32 taskId) external view returns (uint256) { return _vestConfig[taskId].durationBlocks; }
    function vestEnabled(bytes32 taskId) external view returns (bool) { return _vestConfig[taskId].enabled; }

    function canClaimImmediate(bytes32 taskId, address who, bytes32 proofNonce) external view returns (bool) {
        MistTask storage t = _tasks[taskId];
        if (t.merkleRoot == bytes32(0) || t.disabled || block.number > t.endBlock) return false;
        if (_fulfilled[taskId][proofNonce]) return false;
        if (t.poolBalance < t.rewardPerClaim) return false;
        if (_vestConfig[taskId].enabled) return false;
        return true;
    }

    function canClaimVested(bytes32 taskId, address who) external view returns (bool) {
        if (!_vestConfig[taskId].enabled) return false;
        if (_vestPending[taskId][who] == 0) return false;
        VestConfig storage v = _vestConfig[taskId];
        if (block.number < v.startBlock + v.cliffBlocks) return false;
        uint256 elapsed = block.number - v.startBlock;
        if (elapsed > v.durationBlocks) elapsed = v.durationBlocks;
        uint256 vestedTotal = (_vestPending[taskId][who] * elapsed) / v.durationBlocks;
        return vestedTotal > _vestClaimed[taskId][who];
    }

    function getTaskSummary(bytes32 taskId) external view returns (
        uint256 reward,
        uint256 endBlock,
        uint256 poolBal,
        uint256 claimed,
        bool active
    ) {
        MistTask storage t = _tasks[taskId];
        active = t.merkleRoot != bytes32(0) && !t.disabled && block.number <= t.endBlock;
        return (t.rewardPerClaim, t.endBlock, t.poolBalance, t.totalClaimed, active);
    }

    function getGlobalStats() external view returns (
        uint256 totalTasks,
        uint256 totalClaimedWei,
        uint256 balanceWei
    ) {
        return (_taskCount, _globalTotalClaimed, address(this).balance);
    }

    function getParticipantStats(address account) external view returns (
        uint256 totalClaimedWei
    ) {
        return (_userTotalClaimed[account]);
    }

    function hasFulfilledBatch(bytes32[] calldata taskIds, bytes32[] calldata proofNonces, address account) external view returns (bool[] memory) {
        uint256 n = taskIds.length;
        if (n != proofNonces.length) revert Mist_ArrayLengthMismatch();
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _fulfilled[taskIds[i]][proofNonces[i]];
        return out;
    }

    function getVestedAmountBatch(bytes32[] calldata taskIds, address account) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            VestConfig storage v = _vestConfig[taskIds[i]];
            if (!v.enabled) { out[i] = 0; continue; }
            uint256 pending = _vestPending[taskIds[i]][account];
            if (pending == 0) { out[i] = 0; continue; }
            uint256 start = v.startBlock;
            uint256 cliff = v.cliffBlocks;
            uint256 dur = v.durationBlocks;
            if (block.number < start + cliff) { out[i] = 0; continue; }
            uint256 elapsed = block.number - start;
            if (elapsed > dur) elapsed = dur;
            uint256 vestedTotal = (pending * elapsed) / dur;
            uint256 already = _vestClaimed[taskIds[i]][account];
            out[i] = vestedTotal > already ? vestedTotal - already : 0;
        }
        return out;
    }

    // --- Pure helpers (no state) ---
    function minU256(uint256 a, uint256 b) public pure returns (uint256) { return a < b ? a : b; }
    function maxU256(uint256 a, uint256 b) public pure returns (uint256) { return a > b ? a : b; }
    function saturatingSub(uint256 a, uint256 b) public pure returns (uint256) { return a > b ? a - b : 0; }
    function clampBlock(uint256 val, uint256 lo, uint256 hi) public pure returns (uint256) {
        if (val < lo) return lo;
        if (val > hi) return hi;
        return val;
    }
    function proportional(uint256 part, uint256 total, uint256 whole) public pure returns (uint256) {
        if (total == 0) return 0;
        return (part * whole) / total;
    }
    function isZeroAddress(address a) public pure returns (bool) { return a == address(0); }
    function isZeroBytes32(bytes32 b) public pure returns (bool) { return b == bytes32(0); }

    // -------------------------------------------------------------------------
    // ADDITIONAL VIEWS (convenience)
    // -------------------------------------------------------------------------

    function listActiveTaskIds(uint256 maxReturn) external view returns (bytes32[] memory) {
        uint256 total = _taskIdList.length;
        uint256 count = 0;
        for (uint256 i = 0; i < total && count < maxReturn; i++) {
            if (isTaskActive(_taskIdList[i])) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < total && count < maxReturn; i++) {
            bytes32 id = _taskIdList[i];
            if (isTaskActive(id)) { out[count] = id; count++; }
        }
        return out;
    }

    function listTaskIdsByKind(uint8 kind, uint256 maxReturn) external view returns (bytes32[] memory) {
        uint256 total = _taskIdList.length;
        uint256 count = 0;
        for (uint256 i = 0; i < total && count < maxReturn; i++) {
            if (_tasks[_taskIdList[i]].taskKind == kind) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < total && count < maxReturn; i++) {
            bytes32 id = _taskIdList[i];
            if (_tasks[id].taskKind == kind) { out[count] = id; count++; }
        }
        return out;
    }

    function getPoolBalances(bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].poolBalance;
        return out;
    }

    function getRewards(bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].rewardPerClaim;
        return out;
    }

    function getEndBlocks(bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].endBlock;
        return out;
    }

    function getTotalClaimeds(bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].totalClaimed;
        return out;
    }

    function getDisabledFlags(bytes32[] calldata taskIds) external view returns (bool[] memory) {
        uint256 n = taskIds.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].disabled;
        return out;
    }

    function getTaskKinds(bytes32[] calldata taskIds) external view returns (uint8[] memory) {
        uint256 n = taskIds.length;
        uint8[] memory out = new uint8[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].taskKind;
        return out;
    }

    function getMerkleRoots(bytes32[] calldata taskIds) external view returns (bytes32[] memory) {
        uint256 n = taskIds.length;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].merkleRoot;
        return out;
    }

    function getCreatedAts(bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _taskCreatedAt[taskIds[i]];
        return out;
    }

    function vestProgress(bytes32 taskId, address account) external view returns (
        uint256 pending,
        uint256 claimedSoFar,
        uint256 claimableNow,
        uint256 startBlock,
        uint256 cliffEnd,
        uint256 vestEnd
    ) {
        VestConfig storage v = _vestConfig[taskId];
        pending = _vestPending[taskId][account];
        claimedSoFar = _vestClaimed[taskId][account];
        startBlock = v.startBlock;
        cliffEnd = v.startBlock + v.cliffBlocks;
        vestEnd = v.startBlock + v.durationBlocks;
        if (!v.enabled || pending == 0) { claimableNow = 0; return (pending, claimedSoFar, 0, startBlock, cliffEnd, vestEnd); }
        if (block.number < cliffEnd) { claimableNow = 0; return (pending, claimedSoFar, 0, startBlock, cliffEnd, vestEnd); }
        uint256 elapsed = block.number - startBlock;
        if (elapsed > v.durationBlocks) elapsed = v.durationBlocks;
        uint256 vestedTotal = (pending * elapsed) / v.durationBlocks;
        claimableNow = vestedTotal > claimedSoFar ? vestedTotal - claimedSoFar : 0;
    }

    function estimateVestAtBlock(bytes32 taskId, address account, uint256 atBlock) external view returns (uint256 claimable) {
        VestConfig storage v = _vestConfig[taskId];
        if (!v.enabled) return 0;
        uint256 pending = _vestPending[taskId][account];
        if (pending == 0) return 0;
        if (atBlock < v.startBlock + v.cliffBlocks) return 0;
        uint256 elapsed = atBlock - v.startBlock;
        if (elapsed > v.durationBlocks) elapsed = v.durationBlocks;
        uint256 vestedTotal = (pending * elapsed) / v.durationBlocks;
        uint256 already = _vestClaimed[taskId][account];
        return vestedTotal > already ? vestedTotal - already : 0;
    }

    function totalVestPendingForTask(bytes32 taskId) external view returns (uint256) {
        return _tasks[taskId].totalClaimed;
    }

    function getVersion() external pure returns (uint256) { return MIST_VERSION; }
    function getMaxTaskKind() external pure returns (uint256) { return MAX_TASK_KIND; }
    function getMaxClaimBatch() external pure returns (uint256) { return MAX_CLAIM_BATCH; }
    function getPageSize() external pure returns (uint256) { return PAGE_SIZE; }
    function getDomainSeed() external pure returns (bytes32) { return DOMAIN_SEED; }
    function getTreasuryAddress() external view returns (address) { return treasury; }
    function getTaskVerifierAddress() external view returns (address) { return taskVerifier; }
    function getGuardianHubAddress() external view returns (address) { return guardianHub; }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS — task metadata and eligibility
    // -------------------------------------------------------------------------

    function getTaskFull(bytes32 taskId) external view returns (
        uint8 kind,
        uint256 rewardPerClaim,
        uint256 endBlock,
        bytes32 merkleRoot,
        uint256 poolBalance,
        bool disabled,
        uint256 totalClaimed,
        uint256 createdAt,
        bool hasVesting,
        uint256 vestCliff,
        uint256 vestDuration
    ) {
        MistTask storage t = _tasks[taskId];
        VestConfig storage v = _vestConfig[taskId];
        return (
            t.taskKind,
            t.rewardPerClaim,
            t.endBlock,
            t.merkleRoot,
            t.poolBalance,
            t.disabled,
            t.totalClaimed,
            _taskCreatedAt[taskId],
            v.enabled,
            v.cliffBlocks,
            v.durationBlocks
        );
    }

    function getEligibility(bytes32 taskId, address account, bytes32 proofNonce) external view returns (
        bool taskExists,
        bool taskActive,
        bool notYetFulfilled,
        bool poolSufficient,
        bool hasVestingOption,
        bool canClaimNow
    ) {
        MistTask storage t = _tasks[taskId];
        taskExists = t.merkleRoot != bytes32(0);
        taskActive = taskExists && !t.disabled && block.number <= t.endBlock;
        notYetFulfilled = !_fulfilled[taskId][proofNonce];
        poolSufficient = t.poolBalance >= t.rewardPerClaim;
        hasVestingOption = _vestConfig[taskId].enabled;
        canClaimNow = taskActive && notYetFulfilled && poolSufficient && !hasVestingOption;
    }

    function getTaskIdsRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory) {
        uint256 total = _taskIdList.length;
        if (fromIndex >= total) return new bytes32[](0);
        if (toIndex > total) toIndex = total;
        if (fromIndex >= toIndex) return new bytes32[](0);
        uint256 n = toIndex - fromIndex;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _taskIdList[fromIndex + i];
        return out;
    }

    function countActiveTasks() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _taskIdList.length; i++) {
            if (isTaskActive(_taskIdList[i])) c++;
        }
        return c;
    }

    function countTasksByKind(uint8 kind) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _taskIdList.length; i++) {
            if (_tasks[_taskIdList[i]].taskKind == kind) c++;
        }
        return c;
    }

    function totalPoolBalance() external view returns (uint256 sum) {
        for (uint256 i = 0; i < _taskIdList.length; i++) sum += _tasks[_taskIdList[i]].poolBalance;
    }

    function getTaskIdByIndex(uint256 index) external view returns (bytes32) {
        if (index >= _taskIdList.length) revert Mist_IndexOutOfRange();
        return _taskIdList[index];
    }

    function taskListLength() external view returns (uint256) {
        return _taskIdList.length;
    }

    // --- Pure numeric helpers (used by frontends) ---
    function weiToEther(uint256 weiVal) public pure returns (uint256) {
        return weiVal / 1 ether;
    }
    function etherToWei(uint256 etherVal) public pure returns (uint256) {
        return etherVal * 1 ether;
    }
    function percentOf(uint256 part, uint256 whole) public pure returns (uint256) {
        if (whole == 0) return 0;
        return (part * 100) / whole;
    }
    function blocksToApproxTime(uint256 blocks, uint256 blockTimeSec) public pure returns (uint256 seconds_) {
        return blocks * blockTimeSec;
    }
    function isExpired(bytes32 taskId) external view returns (bool) {
        return block.number > _tasks[taskId].endBlock;
    }
    function isDisabled(bytes32 taskId) external view returns (bool) {
        return _tasks[taskId].disabled;
    }
    function exists(bytes32 taskId) external view returns (bool) {
        return _tasks[taskId].merkleRoot != bytes32(0);
    }

    // -------------------------------------------------------------------------
    // DEW DROPS — social task kind identifiers (for off-chain indexing)
    // -------------------------------------------------------------------------
    // Kind 0: twitter — follow, like, retweet
    // Kind 1: discord — join server, react, message
    // Kind 2: telegram — join channel, forward
    // Kind 3: retweet — retweet specific tweet
    // Kind 4: quote — quote tweet
    // Kind 5: like — like post
    // Kind 6: comment — comment on post
    // Kind 7: join — join community
    // Kind 8: share — share link
    // Kind 9: watch — watch video
    // Kind 10: follow — follow account
    // Kind 11: custom — custom task type
    // -------------------------------------------------------------------------

    function taskKindLabel(uint8 k) external pure returns (bytes32) {
        if (k == 0) return TASK_KIND_TWITTER;
        if (k == 1) return TASK_KIND_DISCORD;
        if (k == 2) return TASK_KIND_TELEGRAM;
        if (k == 3) return TASK_KIND_RETWEET;
        if (k == 4) return TASK_KIND_QUOTE;
        if (k == 5) return TASK_KIND_LIKE;
        if (k == 6) return TASK_KIND_COMMENT;
        if (k == 7) return TASK_KIND_JOIN;
        if (k == 8) return TASK_KIND_SHARE;
        if (k == 9) return TASK_KIND_WATCH;
        if (k == 10) return TASK_KIND_FOLLOW;
        if (k == 11) return TASK_KIND_CUSTOM;
        return bytes32(0);
    }

    function requireTaskExists(bytes32 taskId) external view returns (bool) {
        if (_tasks[taskId].merkleRoot == bytes32(0)) return false;
        return true;
    }

    function getMultipleTaskSummaries(bytes32[] calldata taskIds) external view returns (
        uint256[] memory rewards,
        uint256[] memory endBlocks,
        uint256[] memory pools,
        uint256[] memory claimeds,
        bool[] memory actives
    ) {
        uint256 n = taskIds.length;
        rewards = new uint256[](n);
        endBlocks = new uint256[](n);
        pools = new uint256[](n);
        claimeds = new uint256[](n);
        actives = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            MistTask storage t = _tasks[taskIds[i]];
            rewards[i] = t.rewardPerClaim;
            endBlocks[i] = t.endBlock;
            pools[i] = t.poolBalance;
            claimeds[i] = t.totalClaimed;
            actives[i] = t.merkleRoot != bytes32(0) && !t.disabled && block.number <= t.endBlock;
        }
    }

    function getMultipleVestConfigs(bytes32[] calldata taskIds) external view returns (
        uint256[] memory startBlocks,
        uint256[] memory cliffBlocks,
        uint256[] memory durationBlocks,
        bool[] memory enableds
    ) {
        uint256 n = taskIds.length;
        startBlocks = new uint256[](n);
        cliffBlocks = new uint256[](n);
        durationBlocks = new uint256[](n);
        enableds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            VestConfig storage v = _vestConfig[taskIds[i]];
            startBlocks[i] = v.startBlock;
            cliffBlocks[i] = v.cliffBlocks;
            durationBlocks[i] = v.durationBlocks;
            enableds[i] = v.enabled;
        }
    }

    function getParticipantVestSummary(address account, bytes32[] calldata taskIds) external view returns (
        uint256[] memory pendingAmounts,
        uint256[] memory claimedAmounts,
        uint256[] memory claimableAmounts
    ) {
        uint256 n = taskIds.length;
        pendingAmounts = new uint256[](n);
        claimedAmounts = new uint256[](n);
        claimableAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = taskIds[i];
            pendingAmounts[i] = _vestPending[id][account];
            claimedAmounts[i] = _vestClaimed[id][account];
            VestConfig storage v = _vestConfig[id];
            if (!v.enabled || pendingAmounts[i] == 0) { claimableAmounts[i] = 0; continue; }
            if (block.number < v.startBlock + v.cliffBlocks) { claimableAmounts[i] = 0; continue; }
            uint256 elapsed = block.number - v.startBlock;
            if (elapsed > v.durationBlocks) elapsed = v.durationBlocks;
            uint256 vestedTotal = (pendingAmounts[i] * elapsed) / v.durationBlocks;
            claimableAmounts[i] = vestedTotal > claimedAmounts[i] ? vestedTotal - claimedAmounts[i] : 0;
        }
    }

    function computeLeafFor(address participant, bytes32 proofNonce, bytes32 taskId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(participant, proofNonce, taskId, DOMAIN_SEED));
    }

    function verifyProofAgainstRoot(bytes32[] calldata proof, bytes32 root, bytes32 leaf) external pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }

    // -------------------------------------------------------------------------
    // BULK READ HELPERS — reduce RPC calls from UIs
    // -------------------------------------------------------------------------

    function getTaskIdsFromOffset(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return getTaskIdsPaginated(offset, limit);
    }

    function getActiveTaskIdsBounded(uint256 maxLen) external view returns (bytes32[] memory) {
        return listActiveTaskIds(maxLen);
    }

    function getTaskRewardsForIds(bytes32[] calldata ids) external view returns (uint256[] memory) {
        return getRewards(ids);
    }

    function getTaskPoolsForIds(bytes32[] calldata ids) external view returns (uint256[] memory) {
        return getPoolBalances(ids);
    }

    function getTaskEndBlocksForIds(bytes32[] calldata ids) external view returns (uint256[] memory) {
        return getEndBlocks(ids);
    }

    function getTaskTotalClaimedsForIds(bytes32[] calldata ids) external view returns (uint256[] memory) {
        return getTotalClaimeds(ids);
    }

    function getTaskDisabledForIds(bytes32[] calldata ids) external view returns (bool[] memory) {
        return getDisabledFlags(ids);
    }

    function getTaskKindsForIds(bytes32[] calldata ids) external view returns (uint8[] memory) {
        return getTaskKinds(ids);
    }

    function getTaskMerkleRootsForIds(bytes32[] calldata ids) external view returns (bytes32[] memory) {
        return getMerkleRoots(ids);
    }

    function getTaskCreatedAtsForIds(bytes32[] calldata ids) external view returns (uint256[] memory) {
        return getCreatedAts(ids);
    }

    function getBlocksRemainingBatch(bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        uint256 n = taskIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            MistTask storage t = _tasks[taskIds[i]];
            if (t.endBlock <= block.number) out[i] = 0;
            else out[i] = t.endBlock - block.number;
        }
        return out;
    }

    function getIsTaskActiveBatch(bytes32[] calldata taskIds) external view returns (bool[] memory) {
        uint256 n = taskIds.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = isTaskActive(taskIds[i]);
        return out;
    }

    function getExistsBatch(bytes32[] calldata taskIds) external view returns (bool[] memory) {
        uint256 n = taskIds.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _tasks[taskIds[i]].merkleRoot != bytes32(0);
        return out;
    }

    function getIsExpiredBatch(bytes32[] calldata taskIds) external view returns (bool[] memory) {
        uint256 n = taskIds.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = block.number > _tasks[taskIds[i]].endBlock;
        return out;
    }

    function getIsDisabledBatch(bytes32[] calldata taskIds) external view returns (bool[] memory) {
        return getDisabledFlags(taskIds);
    }

    function getHasFulfilledForUser(bytes32 taskId, address user, bytes32[] calldata proofNonces) external view returns (bool[] memory) {
        uint256 n = proofNonces.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = _fulfilled[taskId][proofNonces[i]];
        return out;
    }

    function getClaimableVestedForUser(address user, bytes32[] calldata taskIds) external view returns (uint256[] memory) {
        return getVestedAmountBatch(taskIds, user);
    }

    function sumRewards(bytes32[] calldata taskIds) external view returns (uint256 total) {
        for (uint256 i = 0; i < taskIds.length; i++) total += _tasks[taskIds[i]].rewardPerClaim;
    }

    function sumPools(bytes32[] calldata taskIds) external view returns (uint256 total) {
        for (uint256 i = 0; i < taskIds.length; i++) total += _tasks[taskIds[i]].poolBalance;
    }

    function sumClaimed(bytes32[] calldata taskIds) external view returns (uint256 total) {
        for (uint256 i = 0; i < taskIds.length; i++) total += _tasks[taskIds[i]].totalClaimed;
    }

    function firstTaskId() external view returns (bytes32) {
        if (_taskIdList.length == 0) return bytes32(0);
        return _taskIdList[0];
    }

    function lastTaskId() external view returns (bytes32) {
        if (_taskIdList.length == 0) return bytes32(0);
        return _taskIdList[_taskIdList.length - 1];
    }

    function indexOfTaskId(bytes32 taskId) external view returns (int256) {
        for (uint256 i = 0; i < _taskIdList.length; i++) {
            if (_taskIdList[i] == taskId) return int256(i);
        }
        return -1;
    }

    function taskIdExists(bytes32 taskId) external view returns (bool) {
        return _tasks[taskId].merkleRoot != bytes32(0);
    }

    function getConstants() external pure returns (
        uint256 version,
        uint256 maxTaskKind,
        uint256 maxClaimBatch,
        uint256 pageSize,
        uint256 maxTasksPerBatch,
        uint256 minRewardWei,
        uint256 maxRewardWei
    ) {
        return (
            MIST_VERSION,
            MAX_TASK_KIND,
            MAX_CLAIM_BATCH,
            PAGE_SIZE,
            MAX_TASKS_PER_BATCH,
            MIN_REWARD_WEI,
            MAX_REWARD_WEI
        );
    }

    function getImmutables() external view returns (
        address treasuryAddr,
        address verifierAddr,
        address guardianAddr
    ) {
        return (treasury, taskVerifier, guardianHub);
    }

    function getStateFlags() external view returns (
        bool isPaused,
        uint256 numTasks,
        uint256 totalClaimedWei,
        uint256 contractBal
    ) {
        return (_paused, _taskCount, _globalTotalClaimed, address(this).balance);
    }

    function userClaimedForTask(bytes32 taskId, address account) external view returns (uint256) {
        return _vestClaimed[taskId][account] + (_vestPending[taskId][account] > 0 ? 0 : 0);
    }

    function hasAnyVestPending(address account, bytes32[] calldata taskIds) external view returns (bool) {
        for (uint256 i = 0; i < taskIds.length; i++) {
            if (_vestPending[taskIds[i]][account] > 0) return true;
        }
        return false;
    }

    function totalVestPendingForUser(address account, bytes32[] calldata taskIds) external view returns (uint256 total) {
        for (uint256 i = 0; i < taskIds.length; i++) total += _vestPending[taskIds[i]][account];
    }

    function totalVestClaimedForUser(address account, bytes32[] calldata taskIds) external view returns (uint256 total) {
