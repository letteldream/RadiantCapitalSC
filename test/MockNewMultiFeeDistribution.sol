// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../staking/MultiFeeDistribution.sol";

contract MockNewMultiFeeDistribution is MultiFeeDistribution {
    function mockNewFunction () external pure returns (bool) {
        return true;
    }
}