// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

struct LockedBalance {
    uint256 amount;
    uint256 unlockTime;
}