// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/IERC20.sol";

contract MockIncentivesController {
  function beforeLockUpdate(address user) external {}

  function afterLockUpdate(address user) external {}

  function addPool(address _token, uint256 _allocPoint) external {}

  function claim(address _user, address[] calldata _tokens) external {}
}