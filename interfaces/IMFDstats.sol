// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

interface IMFDstats {
    struct AddTransferParam {
        address asset;
        uint256 amount;
        uint256 lpLockingRewardRatio;
        address operationExpenses;
        uint256 operationExpenseRatio;
    }

    function getTotal() external view returns (uint256);

    function getLastDayTotal() external view returns (uint256);

    function addTransfer(AddTransferParam memory param) external;
}
