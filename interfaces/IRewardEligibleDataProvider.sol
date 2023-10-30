// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

interface IRewardEligibleDataProvider {
    function refresh(
        address token,
        address user,
        uint256 balance
    ) external;

    function requiredEthValue(address user)
        external
        view
        returns (uint256 required);

    function isEligibleForRewards(address _user)
        external
        view
        returns (bool isEligible);

    function lastEligibleTime(address user)
        external
        view
        returns (uint256 lastEligibleTimestamp);

    function lockedUsdValue(address user)
        external
        view
        returns (uint256);

    function lastEligibleStatus(address user)
        external
        view
        returns (bool);
}
