// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import '../dependencies/openzeppelin/contracts/ERC20.sol';
import '../interfaces/IMintableToken.sol';

contract MockStakingToken is IMintableToken, ERC20 {
    constructor() ERC20('MockStakingToken', 'MST') {}

    function mint(address _receiver, uint256 _amount)
        external
        override
        returns (bool)
    {
        _mint(_receiver, _amount);
        return true;
    }

    function burn(uint256 _amount) external override returns (bool) {
        _burn(msg.sender, _amount);
        return true;
    }

    function setMinter(address _minter) external override returns (bool) {
        return true;
    }
}
