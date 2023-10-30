// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import './MockChainlinkAggregator.sol';

contract MockChainlinkAggregatorFactory {
    function createChainlinkAggregator() external returns (address) {
        MockChainlinkAggregator aggregator = new MockChainlinkAggregator();

        return address(aggregator);
    }
}
