// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/IERC20.sol";

interface mockERC20 is IERC20 {
    function mint(uint256 amount) external;
}