// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/Ownable.sol";
import "../dependencies/openzeppelin/contracts/ERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";

/// @title Migration contract from V1 to V2
/// @author Radiant team
/// @dev All function calls are currently implemented without side effects
contract Migration is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    /// @notice V1 of RDNT
    ERC20 public tokenV1;

    /// @notice V2 of RDNT
    ERC20 public tokenV2;

    /// @notice Exchange rate in bips; if V1:V2 is 10:1 then, 10 * 1e4 
    uint256 public exchangeRate;


    /// @notice emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 exchangeRate);

    /// @notice emitted when migrate v1 token into v2
    event Migrate(address indexed user, uint256 amountV1, uint256 amountV2);

    /**
     * @notice constructor
     */
    constructor(ERC20 _tokenV1, ERC20 _tokenV2) Ownable() {
        tokenV1 = _tokenV1;
        tokenV2 = _tokenV2;

        exchangeRate = 1e4;
    }

    /**
     * @notice Withdraw ERC20 token
     */
    function setExchangeRate(uint256 _exchangeRate) external onlyOwner {
        exchangeRate = _exchangeRate;
        emit ExchangeRateUpdated(_exchangeRate);
    }

    /**
     * @notice Withdraw ERC20 token
     */
    function withdrawToken(ERC20 token, uint256 amount, address to) external onlyOwner {
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Migrate from V1 to V2
     * @param amount of V1 token
     */
    function exchange(uint256 amount) external {
        uint256 v1Decimals = tokenV1.decimals();
        uint256 v2Decimals = tokenV2.decimals();

        uint256 outAmount = amount.mul(1e4).div(exchangeRate).mul(10**v2Decimals).div(10**v1Decimals);
        tokenV1.safeTransferFrom(_msgSender(), address(this), amount);
        tokenV2.safeTransfer(_msgSender(), outAmount);

        emit Migrate(_msgSender(), amount, outAmount);
    }
}