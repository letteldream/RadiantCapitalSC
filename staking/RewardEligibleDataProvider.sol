// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../interfaces/ILendingPool.sol";
import "../interfaces/IMultiFeeDistribution.sol";
import "../interfaces/IChefIncentivesController.sol";
import "../interfaces/IPriceProvider.sol";
import "../interfaces/LockedBalance.sol";
import "../interfaces/uniswap/IUniswapV2Router02.sol";
import "../interfaces/uniswap/IUniswapV2Factory.sol";
import "../interfaces/uniswap/IUniswapV2Pair.sol";
import "../interfaces/IChainlinkAggregator.sol";

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/Ownable.sol";

/// @title Eligible Deposit Provider
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
///  One problem is this doesn't reflect lock expire or price volatility
contract RewardEligibleDataProvider is Ownable {
    using SafeMath for uint256;

    /********************** Common Info ***********************/

    /// @notice Address of Lending Pool
    ILendingPool public lendingPool;

    /// @notice Address of CIC
    IChefIncentivesController public chef;

    /// @notice Address of Middle fee distribution
    IMiddleFeeDistribution public middleFeeDistribution;

    /// @notice Price aggregator of market's base token price in USD
    IChainlinkAggregator public baseTokenPriceInUsdProxyAggregator;
    
    /// @notice RDNT + LP price provider
    IPriceProvider public priceProvider;

    /// @notice Required ratio of TVL to get reward; in bips
    uint256 public requiredEthRatio;

    /// @notice RDNT-ETH LP token
    address public lpToken;
    /********************** Eligible token info ***********************/

    /// @notice Array of eligibleTokens
    address[] public eligibleTokens;

    /// @notice Flag for eligibleTokens
    mapping(address => bool) public isEligibleToken;

    /// @notice Last eligible status of the user
    mapping(address => bool) public lastEligibleStatus;

    // Elgible deposits per rToken
    mapping(address => uint256) private elgibleDeposits;

    /// @notice User's deposits per rToken; rToken => user => amount
    mapping(address => mapping(address => uint256)) public userDeposits;

    /********************** Events ***********************/

    /// @notice Emitted when a new token is added
    event AddToken(address indexed token);

    /// @notice Emitted when required TVL ratio is updated
    event RequiredEthRatioUpdated(uint256 requiredEthRatio);

    /**
     * @param _lendingPool Address of lending pool.
     * @param _middleFeeDistribution MiddleFeeDistribution address.
     */
    constructor(
        ILendingPool _lendingPool,
        IMiddleFeeDistribution _middleFeeDistribution,
        IPriceProvider _priceProvider,
        IChainlinkAggregator _baseTokenPriceInUsdProxyAggregator
    ) Ownable() {
        lendingPool = _lendingPool;
        middleFeeDistribution = _middleFeeDistribution;
        priceProvider = _priceProvider;
        baseTokenPriceInUsdProxyAggregator = _baseTokenPriceInUsdProxyAggregator;
        requiredEthRatio = 2000;
    }

    /********************** Setters ***********************/

    /**
     * @notice Set CIC
     * @param _chef address.
     */
    function setChefIncentivesController(IChefIncentivesController _chef)
        external
        onlyOwner
    {
        chef = _chef;
    }

    /**
     * @notice Set LP token
     */
    function setLPToken(address _lpToken) external onlyOwner {
        require(lpToken == address(0));
        lpToken = _lpToken;
    }

    /**
     * @notice Sets required tvl ratio. Can only be called by the owner.
     * @param _requiredEthRatio Ratio in bips.
     */
    function setRequiredEthRatio(uint256 _requiredEthRatio) external onlyOwner {
        requiredEthRatio = _requiredEthRatio;
        emit RequiredEthRatioUpdated(_requiredEthRatio);
    }

    /********************** View functions ***********************/

    /**
     * @notice Returns reward eligible amount of the token
     */
    function rewardEligibleAmount(address token)
        external
        view
        returns (uint256)
    {
        return elgibleDeposits[token];
    }

    /**
     * @notice Returns locked RDNT and LP token value in eth
     */
    function lockedUsdValue(address user)
        public
        view
        returns (uint256)
    {
        IMultiFeeDistribution lpFeeDistribution = IMultiFeeDistribution(
            middleFeeDistribution.getLPFeeDistributionAddress()
        );
        IMultiFeeDistribution multiFeeDistribution = IMultiFeeDistribution(
            middleFeeDistribution.getMultiFeeDistributionAddress()
        );
        (, , uint256 lockedLP, ) = lpFeeDistribution.lockedBalances(user);
        (, , uint256 lockedRdnt, ) = multiFeeDistribution.lockedBalances(user);
        return _lockedUsdValue(lockedLP, lockedRdnt);
    }

    /**
     * @notice Returns eth value required to be locked
     * @return required eth value.
     */
    function requiredUsdValue(address user)
        public
        view
        returns (uint256 required)
    {
        (uint256 totalCollateralETH, , , , , ) = lendingPool.getUserAccountData(
            user
        );
        required = totalCollateralETH.mul(requiredEthRatio).div(1e4);
    }

    /**
     * @notice Returns if the user is eligible to receive rewards
     */
    function isEligibleForRewards(address _user)
        public
        view
        returns (bool isEligible)
    {
        uint256 lockedValue = lockedUsdValue(_user);
        uint256 requiredValue = requiredUsdValue(_user);
        return requiredValue > 0 && lockedValue >= requiredValue;
    }

    /**
     * @notice Returns locked RDNT and LP token value in eth
     * @dev This doesn't handle the TVL update
     */
    function lastEligibleTime(address user)
        external
        view
        returns (uint256 lastEligibleTimestamp)
    {
        uint256 requiredValue = requiredUsdValue(user);

        IMultiFeeDistribution lpFeeDistribution = IMultiFeeDistribution(
            middleFeeDistribution.getLPFeeDistributionAddress()
        );
        IMultiFeeDistribution multiFeeDistribution = IMultiFeeDistribution(
            middleFeeDistribution.getMultiFeeDistributionAddress()
        );
        LockedBalance[] memory lpLockData = lpFeeDistribution.lockInfo(user);
        LockedBalance[] memory rndtLockData = multiFeeDistribution.lockInfo(
            user
        );

        uint256 lockedLP;
        uint256 lockedRdnt;
        uint256 i = lpLockData.length;
        uint256 j = rndtLockData.length;
        while (true) {
            if (i == 0 && j == 0) {
                return 0;
            }
            if (i == 0) {
                j = j - 1;
                lastEligibleTimestamp = rndtLockData[j].unlockTime;
                lockedRdnt = lockedRdnt + rndtLockData[j].amount;
            } else if (j == 0) {
                i = i - 1;
                lastEligibleTimestamp = lpLockData[i].unlockTime;
                lockedLP = lockedLP + lpLockData[i].amount;
            } else if (lpLockData[i - 1].unlockTime < rndtLockData[j - 1].unlockTime) {
                j = j - 1;
                lastEligibleTimestamp = rndtLockData[j].unlockTime;
                lockedRdnt = lockedRdnt + rndtLockData[j].amount;
            } else {
                i = i - 1;
                lastEligibleTimestamp = lpLockData[i].unlockTime;
                lockedLP = lockedLP + lpLockData[i].amount;
            }

            if (_lockedUsdValue(lockedLP, lockedRdnt) >= requiredValue) {
                break;
            }
        }

        if (lastEligibleTimestamp > block.timestamp) {
            lastEligibleTimestamp = block.timestamp;
        }
    }

    /********************** Operate functions ***********************/

    /**
     * @notice Add tokens to track for eligibility
     * @param token to track.
     */
    function addToken(address token) external onlyOwner {
        eligibleTokens.push(token);
        isEligibleToken[token] = true;

        emit AddToken(token);
    }

    /**
     * @notice Refresh token amount for eligibility
     */
    function refresh(
        address token,
        address user,
        uint256 balance
    ) external {
        require(msg.sender == address(chef), "Can only be called by CIC");
        if (user == address(0)) {
            return;
        }
        bool lastEligible = lastEligibleStatus[user];
        bool currentEligble = isEligibleForRewards(user);

        if (!lastEligible && !currentEligble) {
            if (isEligibleToken[token]) {
                userDeposits[token][user] = balance;
            }
            return;
        }
        if (lastEligible && currentEligble) {
            if (isEligibleToken[token]) {
                elgibleDeposits[token] = elgibleDeposits[token]
                    .add(balance)
                    .sub(userDeposits[token][user]);
                userDeposits[token][user] = balance;
            }
            return;
        }
        if (lastEligible && !currentEligble) {
            for (uint256 i = 0; i < eligibleTokens.length; i += 1) {
                elgibleDeposits[eligibleTokens[i]] = elgibleDeposits[
                    eligibleTokens[i]
                ].sub(userDeposits[eligibleTokens[i]][user]);
            }
            if (isEligibleToken[token]) {
                userDeposits[token][user] = balance;
            }
        }
        if (!lastEligible && currentEligble) {
            if (isEligibleToken[token]) {
                userDeposits[token][user] = balance;
            }
            for (uint256 i = 0; i < eligibleTokens.length; i += 1) {
                elgibleDeposits[eligibleTokens[i]] = elgibleDeposits[
                    eligibleTokens[i]
                ].add(userDeposits[eligibleTokens[i]][user]);
            }
        }

        lastEligibleStatus[user] = currentEligble;
    }

    /********************** Internal functions ***********************/

    /**
     * @notice Returns locked RDNT and LP token value in eth
     */
    function _lockedUsdValue(uint256 lockedLP, uint256 lockedRdnt)
        internal
        view
        returns (uint256)
    {

        uint256 rdntPrice = priceProvider.getTokenPriceUsd();
        uint256 lpPrice = priceProvider.getLpTokenPriceUsd();

        uint256 userRdntValueUsd = lockedRdnt.mul(rdntPrice).div(10**18);
        uint256 userLpValueUsd = lockedLP.mul(lpPrice).div(10**18);

        uint256 usdLockedVal = userRdntValueUsd.add(userLpValueUsd);
        return usdLockedVal;
    }
}
