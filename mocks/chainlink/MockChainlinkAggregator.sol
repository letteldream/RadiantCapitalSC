// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import '../../interfaces/IChainlinkAggregator.sol';

contract MockChainlinkAggregator is IChainlinkAggregator {
    int256 public s_answer;

    function setLatestAnswer(int256 answer) public {
        s_answer = answer;
    }

    function latestAnswer() public view override returns (int256) {
        return s_answer;
    }

    function latestTimestamp() external view override returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external view override returns (uint256) {
        return 0;
    }

    function getAnswer(uint256 roundId)
        external
        view
        override
        returns (int256)
    {
        return 0;
    }

    function getTimestamp(uint256 roundId)
        external
        view
        override
        returns (uint256)
    {
        return 0;
    }

    function decimals() external view override returns (uint8) {
        return 8;
    }

    function description() external view override returns (string memory) {
        return '';
    }

    function version() external view override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {}

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {}
}
