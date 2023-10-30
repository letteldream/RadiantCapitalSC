// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../interfaces/IChefIncentivesController.sol";
import "../interfaces/IMultiFeeDistribution.sol";
import "../interfaces/LockedBalance.sol";
import "../interfaces/IMintableToken.sol";
import "../interfaces/IPriceProvider.sol";

import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/IERC20Detailed.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";
import "../libraries/AddressPagination.sol";

/// @title Multi Fee Distribution Contract
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract MultiFeeDistribution is IMultiFeeDistribution, Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMintableToken;
    using AddressPagination for address[];

    struct Reward {
        uint256 periodFinish;
        uint256 rewardPerSecond;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        // tracks already-added balances to handle accrued interest in aToken rewards
        // for the stakingToken this value is unused and will always be 0
        uint256 balance;
    }

    struct Balances {
        uint256 total; // sum of earnings and lockings; no use when LP and RDNT is different
        uint256 unlocked; // RDNT token
        uint256 locked; // LP token or RDNT token
        uint256 earned; // RDNT token
    }

    struct RewardData {
        address token;
        uint256 amount;
    }

    /********************** Constants ***********************/

    uint256 private constant QUART = 25000; //  25%
    uint256 private constant HALF = 65000; //  65%
    uint256 private constant WHOLE = 100000; // 100%
    uint256 private constant BURN = 0; //  20%

    /// @notice Duration that rewards are streamed over
    uint256 public REWARDS_DURATION;

    /// @notice Duration that rewards loop back
    uint256 public REWARDS_LOOKBACK;

    /// @notice Duration of lock/earned penalty period
    uint256 public LOCK_DURATION;

    /********************** Contract Addresses ***********************/

    /// @notice Address of Middle Fee Distribution Contract
    IMiddleFeeDistribution public middleFeeDistribution;

    /// @notice Address of CIC contract
    IChefIncentivesController public incentivesController;

    /// @notice Address of RDNT
    IMintableToken public rdntToken;

    /// @notice Address of LP token
    IERC20 public stakingToken;

    // Address of MFD stats
    address internal mfdStats;

    IPriceProvider internal priceProvider;

    /********************** Lock & Earn Info ***********************/

    // Private mappings for balance data
    mapping(address => Balances) private balances;
    mapping(address => LockedBalance[]) private userLocks;
    mapping(address => LockedBalance[]) private userEarnings;

    /// @notice Total staked supply to this contract
    uint256 public totalSupply;

    /// @notice Total locked value
    uint256 public lockedSupply;

    /// @notice Total burnt amount
    uint256 public burnedSupply;

    /********************** Reward Info ***********************/

    /// @notice Reward tokens being distributed
    address[] public rewardTokens;

    /// @notice Reward data per token
    mapping(address => Reward) public rewardData;

    /// @notice user -> reward token -> rpt; RPT for paid amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;

    /// @notice user -> reward token -> amount; used to store reward amount
    mapping(address => mapping(address => uint256)) public rewards;

    /********************** Other Info ***********************/

    /// @notice DAO wallet
    address public daoTreasury;

    /// @notice Addresses approved to call mint
    mapping(address => bool) public minters;

    /// @notice Flag to prevent more minter addings
    bool public mintersAreSet;

    /// @notice Exit delegations
    mapping(address => address) public exitDelegatee;

    // Users list
    address[] internal userlist;
    mapping(address => uint256) internal indexOf;
    mapping(address => bool) internal inserted;

    /********************** Events ***********************/

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, bool locked);
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 receivedAmount,
        uint256 penalty,
        uint256 burn
    );
    event RewardPaid(
        address indexed user,
        address indexed rewardToken,
        uint256 reward
    );
    event RewardsDurationUpdated(address token, uint256 newDuration);
    event Recovered(address token, uint256 amount);

    /**
     * @dev Constructor
     *  First reward MUST be the staking token or things will break
     *  related to the 50% penalty and distribution to locked balances.
     * @param _stakingToken LP token address.
     * @param _rdntToken RDNT token address.
     * @param _mfdStats MFD stats address.
     * @param _rewardsDuration set reward stream time.
     * @param _rewardsLookback reward lookback
     * @param _lockDuration lock duration
     */

    function initialize(
        address _stakingToken,
        address _rdntToken,
        address _mfdStats,
        address _priceProvider,
        uint256 _rewardsDuration,
        uint256 _rewardsLookback,
        uint256 _lockDuration
    ) public initializer {
        __Ownable_init();

        mfdStats = _mfdStats;
        priceProvider = IPriceProvider(_priceProvider);
        stakingToken = IERC20(_stakingToken);
        rdntToken = IMintableToken(_rdntToken);
        rewardTokens.push(_rdntToken);
        rewardData[_rdntToken].lastUpdateTime = block.timestamp;

        REWARDS_DURATION = _rewardsDuration;
        REWARDS_LOOKBACK = _rewardsLookback;
        LOCK_DURATION = _lockDuration;
    }

    /********************** Setters ***********************/

    /**
     * @notice Set minters
     * @dev Can be called only once
     */
    function setMinters(address[] memory _minters) external onlyOwner {
        require(!mintersAreSet);
        for (uint256 i; i < _minters.length; i++) {
            minters[_minters[i]] = true;
        }
        mintersAreSet = true;
    }

    /**
     * @notice Set CIC.
     */
    function setIncentivesController(IChefIncentivesController _controller)
        external
        onlyOwner
    {
        incentivesController = _controller;
    }

    /**
     * @notice Set Middle Fee Distribution.
     */
    function setMiddleFeeDistribution(
        IMiddleFeeDistribution _middleFeeDistribution
    ) external onlyOwner {
        middleFeeDistribution = _middleFeeDistribution;
    }

    /**
     * @notice Set LP token.
     */
    function setLPToken(IERC20 _stakingToken) external onlyOwner {
        require(address(stakingToken) == address(0));
        stakingToken = _stakingToken;
    }

    /**
     * @notice Set DAO Treasury.
     */
    function setDAOTreasury(address _daoTreasury) external onlyOwner {
        require(_daoTreasury != address(0));
        daoTreasury = _daoTreasury;
    }

    /**
     * @notice Add a new reward token to be distributed to stakers.
     */
    function addReward(address _rewardToken) external override {
        require(minters[msg.sender]);
        require(rewardData[_rewardToken].lastUpdateTime == 0);
        rewardTokens.push(_rewardToken);
        rewardData[_rewardToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardToken].periodFinish = block.timestamp;
    }

    /********************** View functions ***********************/

    /**
     * @notice Returns mfd stats address.
     */
    function getMFDstatsAddress() external view override returns (address) {
        return mfdStats;
    }

    /**
     * @notice Return the number of users.
     */
    function lockersCount() external view returns (uint256) {
        return userlist.length;
    }

    /**
     * @notice Return the list of users.
     */
    function getUsers(uint256 page, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        return userlist.paginate(page, limit);
    }

    /**
     * @notice Returns all locks of a user.
     */
    function lockInfo(address user)
        external
        view
        override
        returns (LockedBalance[] memory)
    {
        return userLocks[user];
    }

    /**
     * @notice Total balance of an account, including unlocked, locked and earned tokens.
     */
    function totalBalance(address user)
        external
        view
        override
        returns (uint256 amount)
    {
        if (address(stakingToken) == address(rdntToken)) {
            return balances[user].total;
        }
        return balances[user].locked;
    }

    /**
     * @notice Information on a user's lockings
     * @return total balance of locks
     * @return unlockable balance
     * @return locked balance
     * @return lockData which is an array of locks
     */
    function lockedBalances(address user)
        external
        view
        override
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            LockedBalance[] memory lockData
        )
    {
        LockedBalance[] storage locks = userLocks[user];
        uint256 idx;
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked = locked.add(locks[i].amount);
            } else {
                unlockable = unlockable.add(locks[i].amount);
            }
        }
        return (balances[user].locked, unlockable, locked, lockData);
    }

    /**
     * @notice Earnings which is locked yet
     * @dev Earned balances may be withdrawn immediately for a 50% penalty.
     * @return total earnings
     * @return unlocked earnings
     * @return earningsData which is an array of all infos
     */
    function earnedBalances(address user)
        external
        view
        returns (
            uint256 total,
            uint256 unlocked,
            LockedBalance[] memory earningsData
        )
    {
        unlocked = balances[user].unlocked;
        LockedBalance[] storage earnings = userEarnings[user];
        uint256 idx;
        for (uint256 i = 0; i < earnings.length; i++) {
            if (earnings[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    earningsData = new LockedBalance[](earnings.length - i);
                }
                earningsData[idx] = earnings[i];
                idx++;
                total = total.add(earnings[i].amount);
            } else {
                unlocked = unlocked.add(earnings[i].amount);
            }
        }
        return (total, unlocked, earningsData);
    }

    /**
     * @notice Final balance received and penalty balance paid by user upon calling exit.
     * @dev This is earnings, not locks.
     */
    function withdrawableBalance(address user)
        public
        view
        returns (
            uint256 amount,
            uint256 penaltyAmount,
            uint256 burnAmount
        )
    {
        Balances storage bal = balances[user];
        uint256 earned = bal.earned;
        if (earned > 0) {
            uint256 length = userEarnings[user].length;
            for (uint256 i = 0; i < length; i++) {
                uint256 earnedAmount = userEarnings[user][i].amount;
                if (earnedAmount == 0) continue;
                uint256 unlockTime = userEarnings[user][i].unlockTime;

                uint256 penaltyFactor;
                if (unlockTime > block.timestamp) {
                    // 90% on day 1, decays to 25% on day 90
                    penaltyFactor = unlockTime
                        .sub(block.timestamp)
                        .mul(HALF)
                        .div(LOCK_DURATION)
                        .add(QUART); // 25% + timeLeft/LOCK_DURATION * 65%
                }

                penaltyAmount = penaltyAmount.add(
                    earnedAmount.mul(penaltyFactor).div(WHOLE)
                );
                burnAmount = burnAmount.add(penaltyAmount.mul(BURN).div(WHOLE));
            }
        }
        amount = bal.unlocked.add(earned).sub(penaltyAmount);
        return (amount, penaltyAmount, burnAmount);
    }

    /********************** Reward functions ***********************/

    /**
     * @notice Reward amount of the duration.
     * @param _rewardToken for the reward
     */
    function getRewardForDuration(address _rewardToken)
        external
        view
        returns (uint256)
    {
        return
            rewardData[_rewardToken].rewardPerSecond.mul(REWARDS_DURATION).div(1e12);
    }

    /**
     * @notice Returns reward applicable timestamp.
     */
    function lastTimeRewardApplicable(address _rewardToken)
        public
        view
        returns (uint256)
    {
        uint256 periodFinish = rewardData[_rewardToken].periodFinish;
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Reward amount per token
     * @dev Reward is distributed only for locks.
     * @param _rewardToken for reward
     */
    function rewardPerToken(address _rewardToken)
        public
        view
        returns (uint256 rptStored)
    {
        rptStored = rewardData[_rewardToken].rewardPerTokenStored;
        if (lockedSupply > 0) {
            uint256 newReward = lastTimeRewardApplicable(_rewardToken)
                .sub(rewardData[_rewardToken].lastUpdateTime)
                .mul(rewardData[_rewardToken].rewardPerSecond);
            rptStored = rptStored.add(
                newReward.mul(1e18).div(lockedSupply)
            );
        }
    }

    /**
     * @notice Address and claimable amount of all reward tokens for the given account.
     * @param account for rewards
     */
    function claimableRewards(address account)
        external
        view
        returns (RewardData[] memory rewards)
    {
        rewards = new RewardData[](rewardTokens.length);
        for (uint256 i = 0; i < rewards.length; i++) {
            rewards[i].token = rewardTokens[i];
            rewards[i].amount = _earned(
                account,
                rewards[i].token,
                balances[account].locked,
                rewardPerToken(rewards[i].token)
            ).div(1e12);
        }
        return rewards;
    }

    /********************** Operate functions ***********************/

    /**
     * @notice Stake tokens to receive rewards.
     * @dev Locked tokens cannot be withdrawn for LOCK_DURATION and are eligible to receive rewards.
     */
    function stake(
        uint256 amount,
        bool lock,
        address onBehalfOf
    ) public override {
        require(amount > 0, "Cannot stake 0");
        require(lock == true, "Staking disabled");

        incentivesController.beforeLockUpdate(onBehalfOf);

        _updateReward(onBehalfOf);

        Balances storage bal = balances[onBehalfOf];
        bal.total = bal.total.add(amount);
        totalSupply = totalSupply.add(amount);

        if (lock) {
            bal.locked = bal.locked.add(amount);
            lockedSupply = lockedSupply.add(amount);

            uint256 unlockTime = block.timestamp.add(LOCK_DURATION); // No Epoch applied
            // In case we add Epoch, there will be overlapping locks but not for now
            LockedBalance[] storage lockings = userLocks[onBehalfOf];
            uint256 idx = lockings.length;
            if (idx == 0 || lockings[idx - 1].unlockTime < unlockTime) {
                lockings.push(
                    LockedBalance({amount: amount, unlockTime: unlockTime})
                );
            } else {
                lockings[idx - 1].amount = lockings[idx - 1].amount.add(amount);
            }

            _addToList(onBehalfOf);
        } else {
            bal.unlocked = bal.unlocked.add(amount);
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        incentivesController.afterLockUpdate(onBehalfOf);

        _updatePriceProvider();

        emit Staked(onBehalfOf, amount, lock);
    }

    /**
     * @notice Add to earnings
     * @dev Minted tokens receive rewards normally but incur a 50% penalty when
     *  withdrawn before LOCK_DURATION has passed.
     */
    function mint(
        address user,
        uint256 amount,
        bool withPenalty
    ) external override {
        require(minters[msg.sender]);
        if (amount == 0) return;

        _updateReward(user);

        if (user == address(this)) {
            // minting to this contract adds the new tokens as incentives for lockers
            _notifyReward(address(rdntToken), amount);
            return;
        }

        Balances storage bal = balances[user];
        bal.total = bal.total.add(amount);
        totalSupply = totalSupply.add(amount);
        if (withPenalty) {
            bal.earned = bal.earned.add(amount);
            LockedBalance[] storage earnings = userEarnings[user];
            uint256 idx = earnings.length;
            uint256 unlockTime = block.timestamp.add(LOCK_DURATION);
            if (idx == 0 || earnings[idx - 1].unlockTime < unlockTime) {
                earnings.push(
                    LockedBalance({amount: amount, unlockTime: unlockTime})
                );
            } else {
                earnings[idx - 1].amount = earnings[idx - 1].amount.add(amount);
            }
        } else {
            bal.unlocked = bal.unlocked.add(amount);
        }

        emit Staked(user, amount, false);
    }

    /**
     * @notice Withdraw all currently locked tokens where the unlock time has passed.
     */
    function withdrawExpiredLocks() external {
        withdrawExpiredLocksFor(msg.sender);
    }

    /**
     * @notice Withdraw all currently locked tokens where the unlock time has passed.
     * @param _address of the user.
     */
    function withdrawExpiredLocksFor(address _address) public returns (uint256) {
        incentivesController.beforeLockUpdate(_address);
        _updateReward(_address);

        LockedBalance[] storage locks = userLocks[_address];
        Balances storage bal = balances[_address];
        uint256 amount = _cleanWithdrawableLocks(_address, bal.locked);
        bal.locked = bal.locked.sub(amount);
        bal.total = bal.total.sub(amount);
        totalSupply = totalSupply.sub(amount);
        lockedSupply = lockedSupply.sub(amount);
        stakingToken.safeTransfer(_address, amount);
        incentivesController.afterLockUpdate(_address);
        emit Withdrawn(_address, address(stakingToken), amount, 0, 0);
        return amount;
    }

    /**
     * @notice Withdraw tokens from earnings and unlocked.
     * @dev First withdraws unlocked tokens, then earned tokens. Withdrawing earned tokens
     *  incurs a 50% penalty which is distributed based on locked balances.
     */
    function withdraw(uint256 amount) external {
        address _address = msg.sender;
        require(amount > 0, "Cannot withdraw 0");

        // Call CIC hook
        incentivesController.beforeLockUpdate(_address);

        _updateReward(_address);

        uint256 penaltyAmount;
        uint256 burnAmount;
        Balances storage bal = balances[_address];

        if (amount <= bal.unlocked) {
            bal.unlocked = bal.unlocked.sub(amount);
        } else {
            uint256 remaining = amount.sub(bal.unlocked);
            require(bal.earned >= remaining, "Insufficient unlocked balance");
            bal.unlocked = 0;
            uint256 sumEarned = bal.earned;
            for (uint256 i = 0; ; i++) {
                uint256 earnedAmount = userEarnings[_address][i].amount;
                if (earnedAmount == 0) continue;

                uint256 penaltyFactor;
                uint256 unlockTime = userEarnings[_address][i].unlockTime;
                if (unlockTime > block.timestamp) {
                    // 90% on day 1, decays to 25% on day 90
                    penaltyFactor = unlockTime
                        .sub(block.timestamp)
                        .mul(HALF)
                        .div(LOCK_DURATION)
                        .add(QUART); // 25% + timeLeft/LOCK_DURATION * 65%
                }

                // Amount required from this lock, taking into account the penalty
                uint256 requiredAmount = remaining.mul(WHOLE).div(
                    WHOLE.sub(penaltyFactor)
                );
                if (requiredAmount >= earnedAmount) {
                    requiredAmount = earnedAmount;
                    delete userEarnings[_address][i];
                    remaining = remaining.sub(
                        earnedAmount.mul(WHOLE.sub(penaltyFactor)).div(WHOLE)
                    ); // remaining -= earned * (1 - pentaltyFactor)
                } else {
                    userEarnings[_address][i].amount = earnedAmount.sub(
                        requiredAmount
                    );
                    remaining = 0;
                }
                sumEarned = sumEarned.sub(requiredAmount);

                penaltyAmount = penaltyAmount.add(
                    requiredAmount.mul(penaltyFactor).div(WHOLE)
                ); // penalty += amount * penaltyFactor
                burnAmount = burnAmount.add(penaltyAmount.mul(BURN).div(WHOLE)); // burn += penalty * burnFactor

                if (remaining == 0) {
                    break;
                } else {
                    require(sumEarned > 0, "Insufficient balance");
                }
            }
            bal.earned = sumEarned;
        }
        
        // Update values
        uint256 adjustedAmount = amount.add(penaltyAmount);
        bal.total = bal.total.sub(adjustedAmount);
        totalSupply = totalSupply.sub(adjustedAmount);

        // Call CIC hook
        incentivesController.afterLockUpdate(_address);

        // Process tokens
        rdntToken.safeTransfer(_address, amount);
        if (penaltyAmount > 0) {
            if (burnAmount > 0) {
                rdntToken.burn(burnAmount);
                burnedSupply = burnedSupply.add(burnAmount);
            }
            rdntToken.safeTransfer(daoTreasury, penaltyAmount.sub(burnAmount));
        }

        emit Withdrawn(
            _address,
            address(rdntToken),
            amount,
            penaltyAmount,
            burnAmount
        );
        _updatePriceProvider();
    }

    /**
     * @notice Withdraw full unlocked balance and earnings, optionally claim pending rewards.
     */
    function exit(bool claimRewards, address onBehalfOf) external override {
        require(
            onBehalfOf == msg.sender || exitDelegatee[onBehalfOf] == msg.sender
        );
        _updateReward(onBehalfOf);
        (
            uint256 amount,
            uint256 penaltyAmount,
            uint256 burnAmount
        ) = withdrawableBalance(onBehalfOf);
        delete userEarnings[onBehalfOf];
        Balances storage bal = balances[onBehalfOf];
        bal.total = bal.total.sub(bal.unlocked).sub(bal.earned);
        bal.unlocked = 0;
        bal.earned = 0;
        totalSupply = totalSupply.sub(amount).sub(penaltyAmount);

        rdntToken.safeTransfer(onBehalfOf, amount);
        if (penaltyAmount > 0) {
            if (burnAmount > 0) {
                rdntToken.burn(burnAmount);
                burnedSupply = burnedSupply.add(burnAmount);
            }
            rdntToken.safeTransfer(daoTreasury, penaltyAmount.sub(burnAmount));
        }

        if (claimRewards) {
            _getReward(onBehalfOf, rewardTokens);
        }

        emit Withdrawn(
            onBehalfOf,
            address(rdntToken),
            amount,
            penaltyAmount,
            burnAmount
        );
        _updatePriceProvider();
    }

    /**
     * @notice Withdraw all currently locked tokens where the unlock time has passed.
     */
    function cleanExpiredLocksAndEarnings(address[] memory users) external {
        for (uint256 i = 0; i < users.length; i += 1) {
            _cleanExpiredLocksAndEarnings(users[i]);
        }
    }

    /**
     * @notice Claim all pending staking rewards.
     */
    function getReward(address[] memory _rewardTokens) public {
        _updateReward(msg.sender);
        _getReward(msg.sender, _rewardTokens);
    }

    /**
     * @notice Delegate exit.
     */
    function delegateExit(address delegatee) external {
        exitDelegatee[msg.sender] = delegatee;
    }

    /**
     * @notice Withdraw and restake assets.
     */
    function relock() external {
        uint256 amount = withdrawExpiredLocksFor(msg.sender);
        stake(amount, true, msg.sender);
    }

    /**
     * @notice Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders.
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        require(
            tokenAddress != address(stakingToken),
            "Cannot withdraw staking token"
        );
        require(
            rewardData[tokenAddress].lastUpdateTime == 0,
            "Cannot withdraw reward token"
        );
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }


    /********************** Internal functions ***********************/

    /**
     * @notice Calculate earnings.
     */
    function _earned(
        address _user,
        address _rewardToken,
        uint256 _balance,
        uint256 _currentRewardPerToken
    ) internal view returns (uint256 earnings) {
        earnings = rewards[_user][_rewardToken];
        uint256 realRPT = _currentRewardPerToken.sub(userRewardPerTokenPaid[_user][_rewardToken]);
        earnings = earnings.add(_balance.mul(realRPT).div(1e18));
    }

    /**
     * @notice Update user reward info.
     */
    function _updateReward(address account) internal {
        uint256 balance = balances[account].locked;
        uint256 length = rewardTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = rewardTokens[i];
            uint256 rpt = rewardPerToken(token);

            Reward storage r = rewardData[token];
            r.rewardPerTokenStored = rpt;
            r.lastUpdateTime = lastTimeRewardApplicable(token);

            if (account != address(this)) {
                rewards[account][token] = _earned(account, token, balance, rpt);
                userRewardPerTokenPaid[account][token] = rpt;
            }
        }
    }

    /**
     * @notice Add new reward.
     * @dev If prev reward period is not done, then it resets `rewardPerSecond` and restarts period
     */
    function _notifyReward(address _rewardToken, uint256 reward) internal {
        Reward storage r = rewardData[_rewardToken];
        if (block.timestamp >= r.periodFinish) {
            r.rewardPerSecond = reward.mul(1e12).div(REWARDS_DURATION);
        } else {
            uint256 remaining = r.periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(r.rewardPerSecond).div(1e12);
            r.rewardPerSecond = reward.add(leftover).mul(1e12).div(REWARDS_DURATION);
        }

        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp.add(REWARDS_DURATION);
        r.balance = r.balance.add(reward);
    }

    /**
     * @notice Notify unseen rewards.
     * @dev for rewards other than stakingToken, every 24 hours we check if new
     *  rewards were sent to the contract or accrued via aToken interest.
     */
    function _notifyUnseenReward(address token) internal {
        if (token == address(rdntToken)) {
            return;
        }
        Reward storage r = rewardData[token];
        uint256 periodFinish = r.periodFinish;
        require(periodFinish > 0, "Unknown reward token");
        if (
            periodFinish <
            block.timestamp.add(REWARDS_DURATION - REWARDS_LOOKBACK)
        ) {
            uint256 unseen = IERC20(token).balanceOf(address(this)).sub(
                r.balance
            );
            if (unseen > 0) {
                _notifyReward(token, unseen);
            }
        }
    }

    /**
     * @notice User gets reward
     */
    function _getReward(address _user, address[] memory _rewardTokens) internal {
        middleFeeDistribution.forwardReward(_rewardTokens);
        uint256 length = _rewardTokens.length;
        for (uint256 i; i < length; i++) {
            address token = _rewardTokens[i];
            _notifyUnseenReward(token);
            uint256 reward = rewards[_user][token].div(1e12);
            if (reward > 0) {
                rewards[_user][token] = 0;
                rewardData[token].balance = rewardData[token].balance.sub(reward);

                IERC20(token).safeTransfer(_user, reward);

                emit RewardPaid(_user, token, reward);
            }
        }
        _updatePriceProvider();
    }

    /**
     * @notice Withdraw all lockings and earnings tokens where the unlock time has passed
     */
    function _cleanExpiredLocksAndEarnings(address user) internal {
        incentivesController.beforeLockUpdate(user);
        _updateReward(user);

        Balances storage bal = balances[user];
        uint256 earnAmount = _cleanWithdrawableEarnings(user, bal.earned);
        uint256 lockAmount = _cleanWithdrawableLocks(user, bal.locked);
        uint256 totalAmount = lockAmount.add(earnAmount);
        if (totalAmount == 0) {
            return;
        }

        bal.locked = bal.locked.sub(lockAmount);
        bal.earned = bal.earned.sub(earnAmount);
        bal.total = bal.total.sub(totalAmount);
        totalSupply = totalSupply.sub(totalAmount);
        lockedSupply = lockedSupply.sub(lockAmount);
        rdntToken.safeTransfer(user, earnAmount);
        stakingToken.safeTransfer(user, lockAmount);
        incentivesController.afterLockUpdate(user);
        emit Withdrawn(user, address(stakingToken), lockAmount, 0, 0);
        emit Withdrawn(user, address(rdntToken), earnAmount, 0, 0);
    }

    /**
     * @notice  Withdraw all lockings tokens where the unlock time has passed
     */
    function _cleanWithdrawableLocks(address user, uint256 totalLock)
        internal
        returns (uint256 lockAmount)
    {
        LockedBalance[] storage locks = userLocks[user];

        if (locks.length > 0) {
            uint256 length = locks.length;
            if (locks[length - 1].unlockTime <= block.timestamp) {
                lockAmount = totalLock;
                delete userLocks[user];

                _removeFromList(user);
            } else {
                for (uint256 i = 0; i < length; i++) {
                    if (locks[i].unlockTime > block.timestamp) break;
                    lockAmount = lockAmount.add(locks[i].amount);
                    delete locks[i];
                }
            }
        }
    }

    /**
     * @notice  Withdraw all earnings tokens where the unlock time has passed
     */
    function _cleanWithdrawableEarnings(address user, uint256 totalEarned)
        internal
        returns (uint256 earnAmount)
    {
        LockedBalance[] storage earnings = userEarnings[user];

        if (earnings.length > 0) {
            uint256 length = earnings.length;
            if (earnings[length - 1].unlockTime <= block.timestamp) {
                earnAmount = totalEarned;
                delete userEarnings[user];
            } else {
                for (uint256 i = 0; i < length; i++) {
                    if (earnings[i].unlockTime > block.timestamp) break;
                    earnAmount = earnAmount.add(earnings[i].amount);
                    delete earnings[i];
                }
            }
        }
    }

    function _updatePriceProvider() internal {
        priceProvider.update();
    }

    /********************** Lockers list ***********************/

    function _addToList(address user) internal {
        if (inserted[user] == false) {
            inserted[user] = true;
            indexOf[user] = userlist.length;
            userlist.push(user);
        }
    }

    function _removeFromList(address user) internal {
        if (inserted[user] == true) {
            delete inserted[user];

            uint256 index = indexOf[user];
            uint256 lastIndex = userlist.length - 1;
            address lastUser = userlist[lastIndex];

            indexOf[lastUser] = index;
            delete indexOf[user];

            userlist[index] = lastUser;
            userlist.pop();
        }
    }
}
