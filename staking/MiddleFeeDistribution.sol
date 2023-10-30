// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;


import "../interfaces/IMultiFeeDistribution.sol";
import "../interfaces/IMintableToken.sol";

import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/IERC20Detailed.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";

/// @title Fee distributor inside 
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract MiddleFeeDistribution is IMiddleFeeDistribution, Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice RDNT token
    IMintableToken public rdntToken;

    /// @notice Fee distributor contract for lp locking
    IMultiFeeDistribution public lpFeeDistribution;

    /// @notice Fee distributor contract for earnings and RDNT lockings
    IMultiFeeDistribution public multiFeeDistribution;

    /// @notice Reward ratio for lp locking in bips
    uint256 public override lpLockingRewardRatio;

    /// @notice Reward ratio for operation expenses
    uint256 public override operationExpenseRatio;

    /// @notice Minters list
    mapping(address => bool) public minters;

    /// @notice Set minters immutable
    bool public mintersAreSet;

    /// @notice Operation Expense account
    address public override operationExpenses;

    /// @notice Admin address
    address public admin;

    // MFDStats address
    address internal _mfdStats;

    /// @notice Emitted when ERC20 token is recovered
    event Recovered(address token, uint256 amount);

    /// @notice Emitted when reward token is forwarded
    event ForwardReward(address token, uint256 amount);

    /// @notice Emitted when OpEx info is updated
    event SetOperationExpenses(address opEx, uint256 ratio);

    /**
    * @dev Throws if called by any account other than the admin or owner.
    */
    modifier onlyAdminOrOwner() {
        require(admin == _msgSender() || owner() == _msgSender(), 'caller is not the admin or owner');
        _;
    }

    function initialize(
        address _rdntToken,
        address mfdStats,
        IMultiFeeDistribution _lpFeeDistribution,
        IMultiFeeDistribution _multiFeeDistribution
    ) public initializer {
        __Ownable_init();

        rdntToken = IMintableToken(_rdntToken);
        _mfdStats = mfdStats;
        lpFeeDistribution = _lpFeeDistribution;
        multiFeeDistribution = _multiFeeDistribution;

        lpLockingRewardRatio = 5000;
        admin = msg.sender;

        IMintableToken(_rdntToken).setMinter(address(this));
    }

    function getMFDstatsAddress () external view override returns (address) {
        return _mfdStats;
    }

    function getRdntTokenAddress () external view override returns (address) {
        return address(rdntToken);
    }

    function getLPFeeDistributionAddress () external view override returns (address) {
        return address(lpFeeDistribution);
    }

    function getMultiFeeDistributionAddress () external view override returns (address) {
        return address(multiFeeDistribution);
    }

    /**
     * @notice Returns lock information of a user.
     * @dev It currently returns just MFD infos.
     */
    function lockedBalances(
        address user
    ) view external override returns (
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    ) {
        return multiFeeDistribution.lockedBalances(user);
    }

    /**
     * @notice Set minters who can call notify rewards to locking contracts
     */
    function setMinters(address[] memory _minters) external onlyAdminOrOwner {
        require(!mintersAreSet);
        for (uint i; i < _minters.length; i++) {
            minters[_minters[i]] = true;
        }
        mintersAreSet = true;
    }
    
    /**
     * @notice Set reward raitio for lp token locking
     */
    function setLpLockingRewardRatio(uint256 _lpLockingRewardRatio) external onlyAdminOrOwner {
        lpLockingRewardRatio = _lpLockingRewardRatio;
    }
    
    /**
     * @notice Set lp fee distribution contract
     */
    function setLPFeeDistribution(IMultiFeeDistribution _lpFeeDistribution) external onlyAdminOrOwner {
        lpFeeDistribution = _lpFeeDistribution;
    }
    
    /**
     * @notice Set operation expenses account
     */
    function setOperationExpenses(address _operationExpenses, uint256 _operationExpenseRatio) external onlyAdminOrOwner {
        operationExpenses = _operationExpenses;
        operationExpenseRatio = _operationExpenseRatio;
    }

    /**
     * @notice Add a new reward token to be distributed to stakers
     */
    function addReward(address _rewardsToken) external override onlyAdminOrOwner {
        multiFeeDistribution.addReward(_rewardsToken);
        lpFeeDistribution.addReward(_rewardsToken);
    }


    /**
     * @notice Mint new tokens
     * 
     * Minted tokens receive rewards normally but incur a 50% penalty when
     * withdrawn before LOCK_DURATION has passed.
     * 
     * @dev Rewards are splitted when it's reward notification, not earnings
     */
    function mint(address user, uint256 amount, bool withPenalty) external override {
        require(minters[msg.sender]);
        if (amount == 0) return;
        uint256 lpReward = amount.mul(lpLockingRewardRatio).div(1e4);
        if (lpReward > 0) {
            rdntToken.mint(address(lpFeeDistribution), lpReward);
        }
        rdntToken.mint(address(multiFeeDistribution), amount.sub(lpReward));
        if (user == address(this)) {
            if (lpReward > 0) {
                lpFeeDistribution.mint(address(lpFeeDistribution), lpReward, withPenalty);
            }
            multiFeeDistribution.mint(address(multiFeeDistribution), amount.sub(lpReward), withPenalty);
        } else {
            if (lpReward > 0) {
                lpFeeDistribution.mint(user, lpReward, withPenalty);
            }
            multiFeeDistribution.mint(user, amount.sub(lpReward), withPenalty);
        }
    }

    /**
     * @notice Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
     */
    function forwardReward(address[] memory _rewardTokens) external override {
        for (uint256 i = 0; i < _rewardTokens.length; i += 1) {
            uint256 total = IERC20(_rewardTokens[i]).balanceOf(address(this));

            if (operationExpenses != address(0) && operationExpenseRatio > 0) {
                uint256 opExAmount = total.mul(operationExpenseRatio).div(1e4);
                if (opExAmount > 0) {
                    IERC20(_rewardTokens[i]).safeTransfer(operationExpenses, opExAmount);
                }
                total = total.sub(opExAmount);
            }
            total = IERC20(_rewardTokens[i]).balanceOf(address(this));
            uint256 lpReward = total.mul(lpLockingRewardRatio).div(1e4);
            if (lpReward > 0) {
                IERC20(_rewardTokens[i]).safeTransfer(address(lpFeeDistribution), lpReward);
            }
            uint256 rdntReward = IERC20(_rewardTokens[i]).balanceOf(address(this));
            if (rdntReward > 0) {
                IERC20(_rewardTokens[i]).safeTransfer(address(multiFeeDistribution), rdntReward);
            }
        }
    }

    /**
     * @notice Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
