// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../price/PriceProvider.sol";

contract MockNewPriceProvider is PriceProvider {
    function mockNewFunction () external pure returns (bool) {
        return true;
    }
}