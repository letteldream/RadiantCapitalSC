// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";

contract TokenVesting is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public rdnt;

    struct Vest {
        uint256 start;
        uint256 duration;
        uint256 total;
        uint256 claimed;
    }

    mapping(address => Vest) public vests;

    function initialize(
        address _rdnt
    ) public initializer {
        __Ownable_init();

        rdnt = _rdnt;
    }

    function addVest(address _claimer, uint256 _amount, uint256 _duration) external onlyOwner {
        IERC20(rdnt).safeTransferFrom(msg.sender, address(this), _amount);
        vests[_claimer].total = _amount;
        vests[_claimer].duration = _duration;
        vests[_claimer].start = block.timestamp;
        vests[_claimer].claimed = 0;
    }

    function claimable(address _claimer) external view returns (uint256) {
        Vest storage v = vests[_claimer];
        if(v.duration == 0) return 0;
        uint256 elapsedTime = block.timestamp.sub(v.start);
        if (elapsedTime > v.duration) elapsedTime = v.duration;
        uint256 claimable = v.total.mul(elapsedTime).div(v.duration);
        return claimable.sub(v.claimed);
    }

    function claim() external {
        Vest storage v = vests[msg.sender];
        if(v.duration == 0) return;
        uint256 elapsedTime = block.timestamp.sub(v.start);
        if (elapsedTime > v.duration) elapsedTime = v.duration;
        uint256 claimable = v.total.mul(elapsedTime).div(v.duration);
        if (claimable > v.claimed) {
            uint256 amount = claimable.sub(v.claimed);
            IERC20(rdnt).safeTransfer(msg.sender, amount);
            v.claimed = claimable;
        }
    }
}