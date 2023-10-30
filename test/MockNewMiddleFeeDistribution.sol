// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../staking/MiddleFeeDistribution.sol";

contract MockNewMiddleFeeDistribution is MiddleFeeDistribution {
    function mockNewFunction () external pure returns (bool) {
        return true;
    }
}