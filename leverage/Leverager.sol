pragma solidity 0.7.6;
pragma abicoder v2;

// SPDX-License-Identifier: MIT

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/contracts/Ownable.sol";

import "../interfaces/ILendingPool.sol";

contract Leverager is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BORROW_RATIO_DECIMALS = 4;

    /// @notice Lending Pool address
    ILendingPool public lendingPool;

    uint256 public feePercent;
    address public treasury;

    constructor(ILendingPool _lendingPool, uint256 _feePercent, address _treasury) Ownable() {
        lendingPool = _lendingPool;
        // feePercent = 1000;
        feePercent = _feePercent;
        treasury = _treasury;
    }

    function setFeePercent(uint256 _feePercent) external onlyOwner {
        feePercent = _feePercent;
    }

    /**
     * @dev Returns the configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The configuration of the reserve
     **/
    function getConfiguration(address asset) external view returns (DataTypes.ReserveConfigurationMap memory) {
        return lendingPool.getConfiguration(asset);
    }

    /**
     * @dev Returns variable debt token address of asset
     * @param asset The address of the underlying asset of the reserve
     * @return varaiableDebtToken address of the asset
     **/
    function getVDebtToken(address asset) public view returns (address) {
        DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(asset);
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @dev Returns loan to value
     * @param asset The address of the underlying asset of the reserve
     * @return ltv of the asset
     **/
    function ltv(address asset) public view returns (uint256) {
        DataTypes.ReserveConfigurationMap memory conf =  lendingPool.getConfiguration(asset);
        return conf.data % (2 ** 16);
    }

    /**
     * @dev Loop the deposit and borrow of an asset
     * @param asset for loop
     * @param amount for the initial deposit
     * @param interestRateMode stable or variable borrow mode
     * @param borrowRatio Ratio of tokens to borrow
     * @param loopCount Repeat count for loop
     **/
    function loop(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint256 borrowRatio,
        uint256 loopCount
    ) external {
        uint16 referralCode = 0;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).safeApprove(address(lendingPool), type(uint256).max);
        IERC20(asset).safeApprove(treasury, type(uint256).max);

        uint256 fee = amount.mul(feePercent).div(1e4);
        IERC20(asset).safeTransfer(treasury, fee);
        amount = amount.sub(fee);

        lendingPool.deposit(asset, amount, msg.sender, referralCode);

        for (uint256 i = 0; i < loopCount; i += 1) {
            amount = amount.mul(borrowRatio).div(10 ** BORROW_RATIO_DECIMALS);
            lendingPool.borrow(asset, amount, interestRateMode, referralCode, msg.sender);

            fee = amount.mul(feePercent).div(1e4);
            IERC20(asset).safeTransfer(treasury, fee);
            lendingPool.deposit(asset, amount.sub(fee), msg.sender, referralCode);
        }
    }
}