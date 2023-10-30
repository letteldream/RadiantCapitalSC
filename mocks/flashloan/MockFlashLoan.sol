// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

import '../../flashloan/base/FlashLoanReceiverBase.sol';

contract MockFlashLoan is FlashLoanReceiverBase {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public investor;

    constructor(ILendingPoolAddressesProvider provider)
        FlashLoanReceiverBase(provider)
    {}

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        for (uint256 i = 0; i < assets.length; i++) {
            IERC20 asset = IERC20(assets[i]);
            uint256 balance = asset.balanceOf(address(this));
            uint256 amountOwing = amounts[i].add(premiums[i]);

            if (balance < amountOwing) {
                asset.safeTransferFrom(
                    investor,
                    address(this),
                    amountOwing - balance
                );
            }

            asset.safeApprove(address(LENDING_POOL), amountOwing);
        }

        return true;
    }

    function flashLoanCall(
        address[] calldata assets,
        uint256[] calldata amounts
    ) public {
        uint256 length = assets.length;
        require(length == amounts.length);

        uint256[] memory modes = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            modes[i] = 0;
        }

        address receiverAddress = address(this);
        address onBehalfOf = address(this);
        bytes memory params = '';
        uint16 referralCode = 0;

        investor = msg.sender;

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
    }
}
