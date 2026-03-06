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

