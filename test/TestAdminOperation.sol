// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/Ownable.sol";

contract TestAdminOperation is Ownable {
    function test(uint256 _tesVal) external onlyOwner returns (uint256) {
        return 0x0000000000000000000000000000000000000000000000000000000000000054;
    }
}