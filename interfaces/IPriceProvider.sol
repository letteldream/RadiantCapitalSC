// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface IPriceProvider {
    function getTokenPrice() external view returns (uint256);
    function getTokenPriceUsd() external view returns (uint256);
    function getLpTokenPrice() external view returns (uint256);
    function getLpTokenPriceUsd() external view returns (uint256);
    function update() external;
}