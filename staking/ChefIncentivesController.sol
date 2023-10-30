// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../interfaces/IMultiFeeDistribution.sol";
import "../interfaces/IRewardEligibleDataProvider.sol";

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/IERC20Detailed.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";

/// @title Chef Incentives Controller
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
///  The One problem of this reward mechanism is rewardPerSecond
///  can be lower than set value when there's many locks expired
contract ChefIncentivesController is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Info of each user.
    /// reward = user.`amount` * pool.`accRewardPerShare` - `rewardDebt`
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    /// @notice Info of each pool.
    struct PoolInfo {
        uint256 totalSupply;
        uint256 allocPoint; // How many allocation points assigned to this pool.
        uint256 lastRewardTime; // Last second that reward distribution occurs.
        uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12. See below.
    }

    // Info about token emissions for a given time period.
    struct EmissionPoint {
        uint128 startTimeOffset;
        uint128 rewardsPerSecond;
    }

    // If true, keep this new reward rate indefinitely
    // If false, keep this reward rate until the next scheduled block offset, then return to the schedule.
    bool public persistRewardsPerSecond;

    // Index in emission schedule which the last rewardsPerSeconds was used
    // only used for scheduled rewards
    uint256 public emissionScheduleIndex;

    // Data about the future reward rates. emissionSchedule stored in chronological order,
    // whenever the number of blocks since the start block exceeds the next block offset a new
    // reward rate is applied.
    EmissionPoint[] public emissionSchedule;

    uint256 private constant ACC_REWARD_PRECISION = 1e12;

    /********************** Contract Addresses ***********************/

    /// @notice The address of pool configurator who is gonna add pool to chef
    address public poolConfigurator;

    /// @notice Address of eligible deposit amount provider
    IRewardEligibleDataProvider public eligibleDataProvider;

    /// @notice Address of reward distribution contract
    IMiddleFeeDistribution public rewardMinter;

    /********************** Emission Info ***********************/

    /// @notice Flag for eligbility
    bool public disableEligibilty;

    /// @notice Current reward per second
    uint256 public rewardsPerSecond;

    /// @notice Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The block number when reward mining starts.
    uint256 public startTime;

    /// @notice Array of tokens for reward
    address[] public registeredTokens;

    /// @notice Info of each pool.
    mapping(address => PoolInfo) public poolInfo;

    /// @notice token => user => Info of each user that stakes LP tokens.
    mapping(address => mapping(address => UserInfo)) public userInfo;

    /// @notice user => base claimable balance
    /// @dev total reward of a user is `Sum of pending rewards in all pools` + `baseClaimable of the user`
    mapping(address => uint256) public userBaseClaimable;

    /// @dev Sum of all base claimable
    uint256 private totalBaseClaimable;

    /// @dev Sum of all debts
    uint256 private totalRewardDebt;

    /********************** Other ***********************/

    /// @notice account earning rewards => receiver of rewards for this account
    ///  if receiver is set to address(0), rewards are paid to the earner
    ///  this is used to aid 3rd party contract integrations
    mapping(address => address) public claimReceiver;

    /********************** Events ***********************/

    /// @notice Emitted when disableEligibility is updated
    event SetDisableEligibility(bool disableEligibilty);

    /// @notice Emitted when rewardPerSecond is updated
    event RewardsPerSecondUpdated(uint256 indexed rewardsPerSecond, bool persist);

    event EmissionScheduleAppended(
        uint256[] startTimeOffsets,
        uint256[] rewardsPerSeconds
    );

    /// @notice Emitted when token balance of this user is updated; by handleAction
    event BalanceUpdated(
        address indexed token,
        address indexed user,
        uint256 balance,
        uint256 totalSupply
    );

    /**
     * @param _poolConfigurator Pool configuration address.
     * @param _eligibleDataProvider Eligible deposit provider contract address.
     * @param _rewardMinter MiddleFeeDistribution address.
     * @param _rewardsPerSecond Rewards per second.
     */
    function initialize(
        address _poolConfigurator,
        IRewardEligibleDataProvider _eligibleDataProvider,
        IMiddleFeeDistribution _rewardMinter,
        uint256 _rewardsPerSecond
    ) public initializer {
        __Ownable_init();

        poolConfigurator = _poolConfigurator;
        eligibleDataProvider = _eligibleDataProvider;
        rewardMinter = _rewardMinter;
        persistRewardsPerSecond = true;
        rewardsPerSecond = _rewardsPerSecond;
        totalAllocPoint = 0;
    }

    function start() public onlyOwner {
        require(startTime == 0);
        startTime = block.timestamp;
    }

    /**
     * @notice Sets the reward per second to be distributed. Can only be called by the owner.
     * @dev Its decimals count is ACC_REWARD_PRECISION
     * @param _rewardsPerSecond The amount of reward to be distributed per second.
     */
    function setRewardsPerSecond(uint256 _rewardsPerSecond, bool _persist) external onlyOwner {
        _massUpdatePools();
        rewardsPerSecond = _rewardsPerSecond;
        persistRewardsPerSecond = _persist;
        if (!_persist) {
            uint256 length = emissionSchedule.length;
            uint256 i = emissionScheduleIndex;
            uint128 offset = uint128(block.timestamp.sub(startTime));
            for (
                ;
                i < length && offset >= emissionSchedule[i].startTimeOffset;
                i++
            ) {}
            if (i > emissionScheduleIndex) {
                emissionScheduleIndex = i;
            }
        }
        emit RewardsPerSecondUpdated(_rewardsPerSecond, _persist);
    }

    function setEmissionSchedule(
        uint256[] calldata _startTimeOffsets,
        uint256[] calldata _rewardsPerSecond
    ) external onlyOwner {

        uint256 length = _startTimeOffsets.length;
        require(length > 0 && length == _rewardsPerSecond.length);
        if (startTime > 0) {
            require(_startTimeOffsets[0] > block.timestamp.sub(startTime));
        }

        for (uint256 i = 0; i < length; i++) {
            emissionSchedule.push(
                EmissionPoint({
                    startTimeOffset: uint128(_startTimeOffsets[i]),
                    rewardsPerSecond: uint128(_rewardsPerSecond[i])
                })
            );
        }
        emit EmissionScheduleAppended(_startTimeOffsets, _rewardsPerSecond);
    }

    /**
     * @notice Sets the receiver of rewards.
     * @param _user Original owner.
     * @param _receiver Receiver of rewards.
     */
    function setClaimReceiver(address _user, address _receiver) external {
        require(msg.sender == _user || msg.sender == owner());
        claimReceiver[_user] = _receiver;
    }

    /**
     * @notice Set to disable eligibility. If false, functions like V1.
     */
    function setDisableEligibility(bool _disableEligibilty) external onlyOwner {
        disableEligibilty = _disableEligibilty;
        emit SetDisableEligibility(_disableEligibilty);
    }

    /**
     * @notice Add a new lp to the pool. Can only be called by the poolConfigurator.
     */
    function addPool(address _token, uint256 _allocPoint) external {
        require(
            msg.sender == poolConfigurator,
            "Caller is not pool configurator"
        );
        require(poolInfo[_token].lastRewardTime == 0, "Pool is already added");

        // Add pool should be done at the early deployment
        // If not, it can affect rewards based on eligibility
        // _massUpdatePools();
        updateEmissions();
        registeredTokens.push(_token);
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo[_token] = PoolInfo({
            totalSupply: 0,
            allocPoint: _allocPoint,
            lastRewardTime: block.timestamp,
            accRewardPerShare: 0
        });
    }

    /**
     * @notice Update the given pool's allocation point. Can only be called by the owner.
     * @param _tokens Array of tokens
     * @param _allocPoints Array of alloc points.
     */
    function batchUpdateAllocPoint(
        address[] calldata _tokens,
        uint256[] calldata _allocPoints
    ) external onlyOwner {
        require(_tokens.length == _allocPoints.length, "Length mismatch");
        // _massUpdatePools();
        updateEmissions();
        uint256 _totalAllocPoint = totalAllocPoint;
        for (uint256 i = 0; i < _tokens.length; i++) {
            PoolInfo storage pool = poolInfo[_tokens[i]];
            require(pool.lastRewardTime > 0, "Pool doesn't exist");
            _totalAllocPoint = _totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoints[i]
            );
            pool.allocPoint = _allocPoints[i];
        }
        totalAllocPoint = _totalAllocPoint;
    }

    /********************** View functions ***********************/

    /**
     * @notice View function to get registered tokens
     */
    function getRegisteredTokens () external view returns (address[] memory) {
        address[] memory tokens = new address[](registeredTokens.length);
        tokens = registeredTokens;
        return tokens;
    }

    /**
     * @notice View function to get number of added pools.
     * @return length of registeredTokens array.
     */
    function poolLength() external view returns (uint256) {
        return registeredTokens.length;
    }

    /**
     * @notice View function to see pending rewards of specifc pool.
     * @dev It doens't update accRewardPerShare, it's just a view function.
     *
     *  pending reward = (user.amount * pool.accRewardPerShare) - user.rewardDebt
     *
     *  this calculates rewards based on last eligible time
     *  basically, we assume lastEligibleTime is between lastRewardTime and now
     *  so updatePool shouldn't be called without consideration of eligibility
     *
     * @param _user Address of user.
     * @param _token Address of pool token.
     * @return pending reward for a given user.
     */
    function pendingReward(
        address _user,
        address _token,
        uint256 lastEligibleTime
    ) public view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_token];
        if (pool.lastRewardTime == 0) return 0;
        UserInfo memory user = userInfo[_token][_user];

        if (lastEligibleTime > block.timestamp) {
            lastEligibleTime = block.timestamp;
        }

        if (lastEligibleTime == 0) {
            return 0;
        }

        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalSupply;
        uint256 availableReward = _availalbeReward();
        if (lpSupply != 0) {
            if (lastEligibleTime >= pool.lastRewardTime) {
                uint256 duration = lastEligibleTime.sub(pool.lastRewardTime);
                uint256 newReward = duration.mul(rewardsPerSecond);
                if (newReward > availableReward) {
                    newReward = availableReward;
                }
                uint256 newAccRewardPerShare = newReward
                    .mul(pool.allocPoint)
                    .div(totalAllocPoint)
                    .mul(ACC_REWARD_PRECISION)
                    .div(lpSupply);
                accRewardPerShare = accRewardPerShare.add(newAccRewardPerShare);
            } else {
                uint256 duration = pool.lastRewardTime.sub(lastEligibleTime);
                uint256 newReward = duration.mul(rewardsPerSecond);
                if (newReward > availableReward) {
                    newReward = availableReward;
                }
                uint256 newAccRewardPerShare = newReward
                    .mul(pool.allocPoint)
                    .div(totalAllocPoint)
                    .mul(ACC_REWARD_PRECISION)
                    .div(lpSupply);
                if (accRewardPerShare > newAccRewardPerShare) {
                    accRewardPerShare = accRewardPerShare.sub(newAccRewardPerShare);
                } else {
                    // this happens when initial supply of this pool is added
                    // after `lastEligibleTime`
                    accRewardPerShare = 0;
                }
            }
        }
        pending = user
            .amount
            .mul(accRewardPerShare)
            .div(ACC_REWARD_PRECISION);
        // this happens when rewardDebt is updated at `handleActionAfter`
        if (pending > user.rewardDebt) {
            pending = pending.sub(user.rewardDebt);
        } else {
            pending = 0;
        }
    }

    /**
     * @notice View function to claimable reward accross several pools
     * @return array of claimable reward.
     */
    function pendingRewards(address _user, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory claimable = new uint256[](_tokens.length);
        uint256 lastEligibleTime = disableEligibilty ? block.timestamp : eligibleDataProvider.lastEligibleTime(_user);
        for (uint256 i = 0; i < _tokens.length; i++) {
            claimable[i] = pendingReward(_user, _tokens[i], lastEligibleTime);
        }
        return claimable;
    }

    /**
     * @notice Total reward amount that this contract owes
     * @return reward amount in total
     */
    function totalReward() external view returns (uint256) {
        uint256 totalAccReward;
        for (uint256 i = 0; i < registeredTokens.length; i++) {
            PoolInfo memory pool = poolInfo[registeredTokens[i]];
            totalAccReward = totalAccReward.add(
                pool.accRewardPerShare.mul(pool.totalSupply).div(ACC_REWARD_PRECISION)
            );
        }
        return totalBaseClaimable.add(totalAccReward).sub(totalRewardDebt);
    }

    /********************** Operate functions ***********************/

    /**
     * @notice Save user rewards to base.
     */
    function saveUserRewards(address[] memory _users) public {
        address[] memory _tokens = registeredTokens;
        for (uint256 i = 0; i < _users.length; i++) {
            if (_users[i] != address(0)) {
                claimToBase(_users[i], _tokens);
            }
        }
    }

    /**
     * @notice Claim pending rewards for one or more pools into base claimable.
     * @dev Rewards are not transferred, just converted into base claimable.
     *
     *  Very imporant: this must be called before TVL or Lock update
     *  Always use `before` hook
     * 
     */
    function claimToBase(address _user, address[] memory _tokens) public {
        uint256 _totalAllocPoint = totalAllocPoint;
        uint256 _userBaseClaimable = userBaseClaimable[_user];

        // updatePool must be called after calculation of pending rewards
        // this is because of reward calculation based on eligibility
        uint256[] memory pending = pendingRewards(_user, _tokens);
        // _massUpdatePools();
        updateEmissions();
        for (uint256 i = 0; i < _tokens.length; i++) {
            UserInfo storage user = userInfo[_tokens[i]][_user];
            _userBaseClaimable = _userBaseClaimable.add(pending[i]);

            // Set pending reward to zero
            PoolInfo storage pool = poolInfo[_tokens[i]];
            uint256 newDebt = user.amount.mul(pool.accRewardPerShare).div(ACC_REWARD_PRECISION);
            totalRewardDebt = totalRewardDebt.add(newDebt).sub(user.rewardDebt);
            user.rewardDebt = newDebt;
        }
        totalBaseClaimable = totalBaseClaimable.add(_userBaseClaimable).sub(
            userBaseClaimable[_user]
        );
        userBaseClaimable[_user] = _userBaseClaimable;
    }

    /**
     * @notice Claim pending rewards for one or more pools.
     * @dev Rewards are not received directly, they are minted by the rewardMinter.
     */
    function claim(address _user, address[] memory _tokens) external {
        claimToBase(_user, _tokens);

        uint256 pending = userBaseClaimable[_user];
        totalBaseClaimable = totalBaseClaimable.sub(pending);
        userBaseClaimable[_user] = 0;

        address receiver = claimReceiver[_user];
        if (receiver == address(0)) receiver = _user;
        _claim(receiver, pending, true);
    }

    /**
     * @notice `before` Hook for deposit and borrow update.
     * @dev important! eligible status can be updated here
     */
    function handleActionBefore(
        address _user
    ) external {
        claimToBase(_user, registeredTokens);
    }

    /**
     * @notice `after` Hook for deposit and borrow update.
     * @dev important! eligible status can be updated here
     */
    function handleActionAfter(
        address _user,
        uint256 _balance,
        uint256 _totalSupply
    ) external {
        PoolInfo storage pool = poolInfo[msg.sender];
        require(pool.lastRewardTime > 0);
        UserInfo storage user = userInfo[msg.sender][_user];

        eligibleDataProvider.refresh(msg.sender, _user, _balance);

        uint256 newDebt = _balance.mul(pool.accRewardPerShare).div(
            ACC_REWARD_PRECISION
        );
        totalRewardDebt = totalRewardDebt.add(newDebt).sub(user.rewardDebt);
        user.amount = _balance;
        user.rewardDebt = newDebt;
        pool.totalSupply = _totalSupply;

        emit BalanceUpdated(msg.sender, _user, _balance, _totalSupply);
    }

    /**
     * @notice Hook for lock update.
     * @dev Called by the locking contracts before locking or unlocking happens
     */
    function beforeLockUpdate(address _user) external {
        claimToBase(_user, registeredTokens);
    }

    /**
     * @notice Hook for lock update.
     * @dev Called by the locking contracts after locking or unlocking happens
     */
    function afterLockUpdate(address _user) external {
        eligibleDataProvider.refresh(address(0), _user, 0);
    }

    /********************** Internal functions ***********************/

    /**
     * @notice Returns left reward inside contract
     * @dev Updates accRewardPerShare and lastRewardTime.
     */
    function _availalbeReward() internal view returns(uint256) {
        uint256 totalAccReward;
        address rdntToken = rewardMinter.getRdntTokenAddress();
        for (uint256 i = 0; i < registeredTokens.length; i++) {
            PoolInfo memory pool = poolInfo[registeredTokens[i]];
            totalAccReward = totalAccReward.add(pool.accRewardPerShare.mul(pool.totalSupply).div(ACC_REWARD_PRECISION));
        }
        uint256 balance = IERC20(rdntToken).balanceOf(address(this)).add(totalRewardDebt);
        uint256 rewards = totalAccReward.add(totalBaseClaimable);
        if (balance > rewards) {
            return balance.sub(rewards);
        }
        return 0;
    }

    /**
     * @notice Update reward variables of the given pool to be up-to-date.
     * @dev Updates accRewardPerShare and lastRewardTime.
     */
    function _updatePool(PoolInfo storage pool, uint256 _totalAllocPoint)
        internal
    {
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.totalSupply;
        if (lpSupply > 0) {
            uint256 duration = block.timestamp.sub(pool.lastRewardTime);
            uint256 newReward = duration.mul(rewardsPerSecond);
            uint256 availableReward = _availalbeReward();
            if (newReward > availableReward) {
                newReward = availableReward;
            }
            pool.accRewardPerShare = pool.accRewardPerShare.add(
                newReward
                    .mul(pool.allocPoint)
                    .div(_totalAllocPoint)
                    .mul(ACC_REWARD_PRECISION)
                    .div(lpSupply)
            );
        }
        pool.lastRewardTime = block.timestamp;
    }

    function updateEmissions() public {
        if (persistRewardsPerSecond) {
            _massUpdatePools();
        } else {
            uint256 length = emissionSchedule.length;
            uint256 i = emissionScheduleIndex;
            uint128 offset = uint128(block.timestamp.sub(startTime));
            for (
                ;
                i < length && offset >= emissionSchedule[i].startTimeOffset;
                i++
            ) {}
            if (i > emissionScheduleIndex) {
                emissionScheduleIndex = i;
                _massUpdatePools();
                rewardsPerSecond = uint256(
                    emissionSchedule[i - 1].rewardsPerSecond
                );
            }
        }
    }

    /**
     * @notice Update reward variables for all pools
     */
    function _massUpdatePools() internal {
        uint256 _totalAllocPoint = totalAllocPoint;
        uint256 length = registeredTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            _updatePool(poolInfo[registeredTokens[i]], _totalAllocPoint);
        }
    }

    /**
     * @notice Transfer reward to the receiver
     */
    function _claim(
        address receiver,
        uint256 amount,
        bool withPenalty
    ) internal {
        if (amount == 0) return;
        address rdntToken = rewardMinter.getRdntTokenAddress();
        address multiFeeDistribution = rewardMinter
            .getMultiFeeDistributionAddress();
        if (receiver == address(rewardMinter)) {
            receiver = multiFeeDistribution;
        }
        IERC20(rdntToken).safeTransfer(address(multiFeeDistribution), amount);
        IFeeDistribution(multiFeeDistribution).mint(
            receiver,
            amount,
            withPenalty
        );
    }
}
