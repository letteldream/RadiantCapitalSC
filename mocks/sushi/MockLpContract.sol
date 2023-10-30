// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../../dependencies/openzeppelin/contracts/ERC20.sol";
import "../../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../../dependencies/uniswap/contracts/UQ112x112.sol";

/**
 * @title Mock Contract for Sushi LP token
 * @notice Anyone can mint lp tokens
 * @dev In every mint, it is decreasing reserve0 and increasing reserve1 to simulate price changes
 * @author gmspacex
 */
contract MockLpContract is ERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224;


    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    address private rdntToken;
    address public token0;
    address public token1;

    constructor(
        string memory name,
        string memory symbol,
        address _rdntToken,
        address _weth,
        uint112[] memory _startBalances
    ) ERC20(name, symbol) {
        reserve0 = _startBalances[0]; //10**decimals() * 100_000;
        reserve1 = _startBalances[1]; //10**decimals() * 100_000;
        rdntToken = _rdntToken;
        token0 = _rdntToken;
        token1 = _weth;
    }

    function mintSize() public returns (uint256) {
        return 1000000;
    }

    /**
     * @notice External function to mint lp tokens
     * @dev Anyone can mint lp tokens
     */
    function mint() external {
        _mint(msg.sender, mintSize() *10**decimals());
        // simulate price changes
        increasePrice();
    }

    function decreasePrice() public {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint balance0 = uint256(reserve0).mul(10).div(9);
        uint balance1 = uint256(reserve1).mul(9).div(10);
        _update(balance0, balance1, _reserve0, _reserve1);
    }

    function increasePrice() public {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint balance0 = uint256(reserve0).mul(9).div(10);
        uint balance1 = uint256(reserve1).mul(10).div(9);
        _update(balance0, balance1, _reserve0, _reserve1);
    }

    /**
     * @notice External view function that returns amount of reserves
     * @return _reserve0
     * @return _reserve1
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

     function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
    }
}
