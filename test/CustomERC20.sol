// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/ERC20.sol";

contract CustomERC20 is ERC20 {
  constructor(uint256 amount) ERC20("Custom", "Custom") {
    _mint(msg.sender, amount);
  }

  function setMinter(address minter) external returns (bool) {
  }

  function mint(address receiver, uint256 amount) external returns (bool) {
    _mint(receiver, amount);
  }

  function burn(uint256 amount) external returns (bool) {
    _burn(msg.sender, amount);
  }
}