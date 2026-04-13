//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

contract LinearPool is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCastUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    uint32 private constant ONE_YEAR_IN_SECONDS = 365 days;

    uint64 public constant LINEAR_MAXIMUM_DELAY_DURATION = 35 days; // maximum 35 days delay

    // The accepted token
    IERC20 public linearAcceptedToken;
    // The reward distribution address
    address public linearRewardDistributor;
    // Info of each pool
    LinearPoolInfo[] public linearPoolInfo;
    // Info of each user that stakes in pools
    mapping(uint256 => mapping(address => LinearStakingData))
        public linearStakingData;
    // Info of pending withdrawals.
    mapping(uint256 => mapping(address => LinearPendingWithdrawal))
        public linearPendingWithdrawals;
    // The flexible lock duration. Users who stake in the flexible pool will be affected by this
    uint128 public linearFlexLockDuration;
    // Allow emergency withdraw feature
    bool public linearAllowEmergencyWithdraw;

    event LinearPoolCreated(uint256 indexed poolId, uint256 APR);
    event LinearDeposit(
        uint256 indexed poolId,
        address indexed account,
        uint256 amount
    );
    event LinearWithdraw(
        uint256 indexed poolId,
        address indexed account,
        uint256 amount
    );
    event LinearSwitch(
        uint256 indexed currentPoolId,
        uint256 indexed targetPoolId,
        address indexed account
    );
    event LinearRewardsHarvested(
        uint256 indexed poolId,
        address indexed account,
        uint256 reward
    );
    
    event LinearPendingWithdraw(
        uint256 indexed poolId,
        address indexed account,
        uint256 amount
    );

    event LinearEmergencyWithdraw(
        uint256 indexed poolId,
        address indexed account,
        uint256 amount
    );

    struct LinearPoolInfo {
        uint128 cap;
        uint128 totalStaked;
        uint128 minInvestment;
        uint128 maxInvestment;
        uint64 APR;
        uint128 lockDuration;
        uint128 delayDuration;
        uint128 startJoinTime;
        uint128 endJoinTime;
    }

    struct LinearStakingData {
        uint128 balance;
        uint128 joinTime;
        uint128 updatedTime;
        uint128 reward;
    }

    struct LinearPendingWithdrawal {
        uint128 amount;
        uint128 applicableAt;
    }

    /**
     * @notice Initialize the contract, get called in the first time deploy
     * @param _acceptedToken the token that the pools will use as staking and reward token
     */
    function __LinearPool_init(IERC20 _acceptedToken) public initializer {
        __Ownable_init();

        linearAcceptedToken = _acceptedToken;
    }

    /**
     * @notice Validate pool by pool ID
     * @param _poolId id of the pool
     */
    modifier linearValidatePoolById(uint256 _poolId) {
        require(_poolId < linearPoolInfo.length, "Linear: Pool are not exist");
        _;
    }

    /**
     * @notice Return total number of pools
     */
    function linearPoolLength() external view returns (uint256) {
        return linearPoolInfo.length;
    }

    /**
     * @notice Return total tokens staked in a pool
     * @param _poolId id of the pool
     */
    function linearTotalStaked(
        uint256 _poolId
    ) external view linearValidatePoolById(_poolId) returns (uint256) {
        return linearPoolInfo[_poolId].totalStaked;
    }

    /**
     * @notice Add a new pool with different APR and conditions. Can only be called by the owner.
     * @param _cap the maximum number of staking tokens the pool will receive. If this limit is reached, users can not deposit into this pool.
     * @param _minInvestment the minimum investment amount users need to use in order to join the pool.
     * @param _maxInvestment the maximum investment amount users can deposit to join the pool.
     * @param _APR the APR rate of the pool.
     * @param _lockDuration the duration users need to wait before being able to withdraw and claim the rewards.
     * @param _delayDuration the duration users need to wait to receive the principal amount, after unstaking from the pool.
     * @param _startJoinTime the time when users can start to join the pool
     * @param _endJoinTime the time when users can no longer join the pool
     */
    function linearAddPool(
        uint128 _cap,
        uint128 _minInvestment,
        uint128 _maxInvestment,
        uint64 _APR,
        uint128 _lockDuration,
        uint128 _delayDuration,
        uint128 _startJoinTime,
        uint128 _endJoinTime
    ) external onlyOwner {
        require(
            _endJoinTime >= block.timestamp && _endJoinTime > _startJoinTime,
            "Linear: invalid end join time"
        );
        require(
            _delayDuration <= LINEAR_MAXIMUM_DELAY_DURATION,
            "Linear: delay duration is too long"
        );

        linearPoolInfo.push(
            LinearPoolInfo({
                cap: _cap,
                totalStaked: 0,
                minInvestment: _minInvestment,
                maxInvestment: _maxInvestment,
                APR: _APR,
                lockDuration: _lockDuration,
                delayDuration: _delayDuration,
                startJoinTime: _startJoinTime,
                endJoinTime: _endJoinTime
            })
        );
        emit LinearPoolCreated(linearPoolInfo.length - 1, _APR);
    }

    /**
     * @notice Update the given pool's info. Can only be called by the owner.
     * @param _poolId id of the pool
     * @param _cap the maximum number of staking tokens the pool will receive. If this limit is reached, users can not deposit into this pool.
     * @param _minInvestment minimum investment users need to use in order to join the pool.
     * @param _maxInvestment the maximum investment amount users can deposit to join the pool.
     * @param _APR the APR rate of the pool.
     * @param _endJoinTime the time when users can no longer join the pool
     */
    function linearSetPool(
        uint128 _poolId,
        uint128 _cap,
        uint128 _minInvestment,
        uint128 _maxInvestment,
        uint64 _APR,
        uint128 _endJoinTime
    ) external onlyOwner linearValidatePoolById(_poolId) {
        LinearPoolInfo storage pool = linearPoolInfo[_poolId];

        require(
            _endJoinTime >= block.timestamp &&
                _endJoinTime > pool.startJoinTime,
            "Linear: invalid end join time"
        );

        linearPoolInfo[_poolId].cap = _cap;
        linearPoolInfo[_poolId].minInvestment = _minInvestment;
        linearPoolInfo[_poolId].maxInvestment = _maxInvestment;
        linearPoolInfo[_poolId].APR = _APR;
        linearPoolInfo[_poolId].endJoinTime = _endJoinTime;
    }

    /**
     * @notice Set the flexible lock time. This will affects the flexible pool.  Can only be called by the owner.
     * @param _flexLockDuration the minimum lock duration
     */
    function linearSetFlexLockDuration(
        uint128 _flexLockDuration
    ) external onlyOwner {
        require(
            _flexLockDuration <= LINEAR_MAXIMUM_DELAY_DURATION,
            "Linear: flexible lock duration is too long"
        );
        linearFlexLockDuration = _flexLockDuration;
    }

    /**
     * @notice Set the reward distributor. Can only be called by the owner.
     * @param _linearRewardDistributor the reward distributor
     */
    function linearSetRewardDistributor(
        address _linearRewardDistributor
    ) external onlyOwner {
        require(
            _linearRewardDistributor != address(0),
            "Linear: invalid reward distributor"
        );
        linearRewardDistributor = _linearRewardDistributor;
    }

    /**
     * @notice Deposit token to earn rewards
     * @param _poolId id of the pool
     * @param _amount amount of token to deposit
     */
    function linearDeposit(
        uint256 _poolId,
        uint128 _amount
    ) external nonReentrant linearValidatePoolById(_poolId) {
        address account = msg.sender;
        _linearDeposit(_poolId, _amount, account);

        linearAcceptedToken.safeTransferFrom(account, address(this), _amount);
        emit LinearDeposit(_poolId, account, _amount);
    }

    /**
     * @notice Withdraw token from a pool
     * @param _poolId id of the pool
     * @param _amount amount to withdraw
     */
    function linearWithdraw(
        uint256 _poolId,
        uint128 _amount
    ) external nonReentrant linearValidatePoolById(_poolId) {
        address account = msg.sender;
        LinearPoolInfo storage pool = linearPoolInfo[_poolId];
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            account
        ];

        uint128 lockDuration = pool.lockDuration > 0
            ? pool.lockDuration
            : linearFlexLockDuration;

        require(
            block.timestamp >= stakingData.joinTime + lockDuration,
            "Linear: still locked"
        );

        require(
            stakingData.balance >= _amount,
            "Linear: invalid withdraw amount"
        );

        _linearHarvest(_poolId, account);

        if (stakingData.reward > 0) {
            require(
                linearRewardDistributor != address(0),
                "Linear: invalid reward distributor"
            );

            uint128 reward = stakingData.reward;
            stakingData.reward = 0;
            linearAcceptedToken.safeTransferFrom(
                linearRewardDistributor,
                account,
                reward
            );
            emit LinearRewardsHarvested(_poolId, account, reward);
        }

        stakingData.balance -= _amount;
        if (pool.delayDuration == 0) {
            linearAcceptedToken.safeTransfer(account, _amount);
            emit LinearWithdraw(_poolId, account, _amount);
            return;
        }

        LinearPendingWithdrawal storage pending = linearPendingWithdrawals[
            _poolId
        ][account];

        pending.amount += _amount;
        pending.applicableAt = block.timestamp.toUint128() + pool.delayDuration;
        emit LinearWithdraw(_poolId, account, _amount);
    }

    /**
     * @notice Withdraw token from a pool
     * @param _currentPoolId id of the current pool
     * @param _targetPoolId id of the target pool
     */
    function linearSwitch(
        uint256 _currentPoolId,
        uint256 _targetPoolId
    )
        external
        nonReentrant
        linearValidatePoolById(_currentPoolId)
        linearValidatePoolById(_targetPoolId)
    {
        require(_currentPoolId != _targetPoolId, "Linear: invalid id");

        address account = msg.sender;
        LinearStakingData storage curStakingData = linearStakingData[
            _currentPoolId
        ][account];

        require(
            linearPoolInfo[_currentPoolId].endJoinTime < block.timestamp,
            "Linear: invalid pool to switch"
        );

        uint128 lockDuration = linearPoolInfo[_currentPoolId].lockDuration > 0
            ? linearPoolInfo[_currentPoolId].lockDuration
            : linearFlexLockDuration;

        require(
            block.timestamp >= curStakingData.joinTime + lockDuration,
            "Linear: still locked"
        );

        require(curStakingData.balance > 0, "Linear: nothing to switch");

        _linearHarvest(_currentPoolId, account);

        uint128 curReward = curStakingData.reward;
        curStakingData.reward = 0;
        if (curReward > 0) {
            require(
                linearRewardDistributor != address(0),
                "Linear: invalid reward distributor"
            );

            linearAcceptedToken.safeTransferFrom(
                linearRewardDistributor,
                address(this),
                curReward
            );
            emit LinearRewardsHarvested(_currentPoolId, account, curReward);
            emit LinearDeposit(_targetPoolId, account, curReward);
        }

        uint128 curBalance = curStakingData.balance;
        curStakingData.balance = 0;

        _linearDeposit(_targetPoolId, curBalance + curReward, account);
        emit LinearSwitch(_currentPoolId, _targetPoolId, account);
    }

    /**
     * @notice Claim pending withdrawal
     * @param _poolId id of the pool
     */
    function linearClaimPendingWithdraw(
        uint256 _poolId
    ) external nonReentrant linearValidatePoolById(_poolId) {
        address account = msg.sender;
        LinearPendingWithdrawal storage pending = linearPendingWithdrawals[
            _poolId
        ][account];
        uint128 amount = pending.amount;
        require(amount > 0, "Linear: nothing is currently pending");
        require(
            pending.applicableAt <= block.timestamp,
            "Linear: not released yet"
        );
        delete linearPendingWithdrawals[_poolId][account];
        linearAcceptedToken.safeTransfer(account, amount);
    }

    /**
     * @notice Claim reward token from a pool
     * @param _poolId id of the pool
     */
    function linearClaimReward(
        uint256 _poolId
    ) external nonReentrant linearValidatePoolById(_poolId) {
        address account = msg.sender;
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            account
        ];

        _linearHarvest(_poolId, account);

        if (stakingData.reward > 0) {
            require(
                linearRewardDistributor != address(0),
                "Linear: invalid reward distributor"
            );
            uint128 reward = stakingData.reward;
            stakingData.reward = 0;
            linearAcceptedToken.safeTransferFrom(
                linearRewardDistributor,
                account,
                reward
            );
            emit LinearRewardsHarvested(_poolId, account, reward);
        }
    }

    /**
     * @notice Compound reward into the pool, extend the duration
     * @param _poolId id of the pool
     */
    function linearCompoundReward(
        uint256 _poolId
    ) external nonReentrant linearValidatePoolById(_poolId) {
        address account = msg.sender;
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            account
        ];

        _linearHarvest(_poolId, account);

        require(stakingData.reward > 0, "Linear: nothing to compound");

        require(
            linearRewardDistributor != address(0),
            "Linear: invalid reward distributor"
        );

        uint128 reward = stakingData.reward;
        stakingData.reward = 0;
        linearAcceptedToken.safeTransferFrom(
            linearRewardDistributor,
            address(this),
            reward
        );
        emit LinearRewardsHarvested(_poolId, account, reward);

        _linearDeposit(_poolId, reward, account);
        emit LinearDeposit(_poolId, account, reward);
    }

    /**
     * @notice Gets number of reward tokens of a user from a pool
     * @param _poolId id of the pool
     * @param _account address of a user
     * @return reward earned reward of a user
     */
    function linearPendingReward(
        uint256 _poolId,
        address _account
    ) public view linearValidatePoolById(_poolId) returns (uint128 reward) {
        LinearPoolInfo storage pool = linearPoolInfo[_poolId];
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            _account
        ];

        uint128 startTime = stakingData.updatedTime > 0
            ? stakingData.updatedTime
            : block.timestamp.toUint128();

        uint128 endTime = block.timestamp.toUint128();
        if (
            pool.lockDuration > 0 &&
            stakingData.joinTime + pool.lockDuration < block.timestamp
        ) {
            endTime = stakingData.joinTime + pool.lockDuration;
        }

        if (pool.lockDuration == 0 && pool.endJoinTime < block.timestamp) {
            endTime = pool.endJoinTime;
        }

        uint128 stakedTimeInSeconds = endTime > startTime
            ? endTime - startTime
            : 0;
        uint128 pendingReward = ((stakingData.balance *
            stakedTimeInSeconds *
            pool.APR) / ONE_YEAR_IN_SECONDS) / 100;

        reward = stakingData.reward + pendingReward;
    }

    /**
     * @notice Gets number of deposited tokens in a pool  
     * @param _poolId id of the pool
     * @param _account address of a user
     * @return total token deposited in a pool by a user
     */
    function linearBalanceOf(
        uint256 _poolId,
        address _account
    ) external view linearValidatePoolById(_poolId) returns (uint128) {
        return linearStakingData[_poolId][_account].balance;
    }

    /**
     * @notice Update allowance for emergency withdraw
     * @param _shouldAllow should allow emergency withdraw or not
     */
    function linearSetAllowEmergencyWithdraw(
        bool _shouldAllow
    ) external onlyOwner {
        linearAllowEmergencyWithdraw = _shouldAllow;
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     * @param _poolId id of the pool
     */
    function linearEmergencyWithdraw(
        uint256 _poolId
    ) external nonReentrant linearValidatePoolById(_poolId) {
        require(
            linearAllowEmergencyWithdraw,
            "Linear: emergency withdrawal is not allowed yet"
        );

        address account = msg.sender;
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            account
        ];

        require(stakingData.balance > 0, "Linear: nothing to withdraw");

        uint128 amount = stakingData.balance;

        stakingData.balance = 0;
        stakingData.reward = 0;
        stakingData.updatedTime = block.timestamp.toUint128();

        linearAcceptedToken.safeTransfer(account, amount);
        emit LinearEmergencyWithdraw(_poolId, account, amount);
    }

    function recoverSigner(
        bytes32 hashedMessage,
        bytes memory sig
    ) public pure returns (address) {
        require(sig.length == 65);

        uint8 v;
        bytes32 r;
        bytes32 s;

        // Divide the signature in r, s and v variables
        assembly {
            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }

        // Version of signature should be 27 or 28, but 0 and 1 are also possible versions
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28);

        return ecrecover(hashedMessage, v, r, s);
    }

    function _linearDeposit(
        uint256 _poolId,
        uint128 _amount,
        address account
    ) internal {
        LinearPoolInfo storage pool = linearPoolInfo[_poolId];
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            account
        ];

        require(
            block.timestamp >= pool.startJoinTime,
            "Linear: pool is not started yet"
        );

        require(
            block.timestamp <= pool.endJoinTime,
            "Linear: pool is already closed"
        );

        require(
            stakingData.balance + _amount >= pool.minInvestment,
            "Linear: insufficient amount"
        );

        if (pool.maxInvestment > 0) {
            require(
                stakingData.balance + _amount <= pool.maxInvestment,
                "Linear: too large amount"
            );
        }

        if (pool.cap > 0) {
            require(
                pool.totalStaked + _amount <= pool.cap,
                "Linear: pool is full"
            );
        }

        _linearHarvest(_poolId, account);

        stakingData.balance += _amount;
        stakingData.joinTime = block.timestamp.toUint128();

        pool.totalStaked += _amount;
    }

    function _linearHarvest(uint256 _poolId, address _account) private {
        LinearStakingData storage stakingData = linearStakingData[_poolId][
            _account
        ];

        stakingData.reward = linearPendingReward(_poolId, _account);
        stakingData.updatedTime = block.timestamp.toUint128();
    }
}
