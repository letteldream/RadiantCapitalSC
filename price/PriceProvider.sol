// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;

pragma experimental ABIEncoderV2;

import {IERC20} from "../dependencies/openzeppelin/contracts/IERC20.sol";
import {SafeERC20} from "../dependencies/openzeppelin/contracts/SafeERC20.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/upgradeability/Initializable.sol";
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';
import "../dependencies/uniswap/contracts/UniswapV2OracleLibrary.sol";
import "../dependencies/uniswap/contracts/UniswapV2Library.sol";

contract PriceProvider is Initializable {
    using FixedPoint for *;

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public rdntAddr;
    IUniswapV2Pair public lpToken;
    IChainlinkAggregator public baseTokenPriceInUsdProxyAggregator;

    uint256 public PERIOD;
    address public token0;
    address public token1;
    uint256    public price0CumulativeLast;
    uint256    public price1CumulativeLast;
    uint32  public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    function initialize(
        IUniswapV2Pair _lpToken,
        address _rdnt,
        IChainlinkAggregator _baseTokenPriceInUsdProxyAggregator,
        uint256 _twapPeriod
    ) public initializer {
        lpToken = _lpToken;
        rdntAddr = _rdnt;
        baseTokenPriceInUsdProxyAggregator = _baseTokenPriceInUsdProxyAggregator;
        PERIOD = _twapPeriod;
        token0 = lpToken.token0();
        token1 = lpToken.token1();
        price0CumulativeLast = lpToken.price0CumulativeLast();
        price1CumulativeLast = lpToken.price1CumulativeLast();
    }

    function decimals() public pure returns (uint256) {
        return 10**8;
    }

    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) =
            UniswapV2OracleLibrary.currentCumulativePrices(address(lpToken));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // ensure that at least one full period has passed since the last update
        // require(timeElapsed >= PERIOD, 'ExampleOracleSimple: PERIOD_NOT_ELAPSED');
        if(timeElapsed >= PERIOD) {
            // overflow is desired, casting never truncates
            // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
            price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
            price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

            price0CumulativeLast = price0Cumulative;
            price1CumulativeLast = price1Cumulative;
            blockTimestampLast = blockTimestamp;
        }
    }

    function getTwapTokenPrice() public view returns (uint amountOut) {
        uint256 amountIn = 1e18;
        uint256 decimalDiference = 1e10;
        amountOut = uint256(price0Average.mul(amountIn).decode144()).div(decimalDiference);
    }

    function getRawTokenPrice() public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1, ) = lpToken.getReserves();
        uint256 wethReserve = lpToken.token0() != address(rdntAddr)
            ? reserve0
            : reserve1;
        uint256 rdntReserve = lpToken.token0() == address(rdntAddr)
            ? reserve0
            : reserve1;
        uint256 decis = decimals();
        uint256 priceInEth = wethReserve.mul(decis).div(rdntReserve);
        return priceInEth;
    }

    function getTokenPrice() public view returns (uint256) {
        uint256 price = getTwapTokenPrice();
        if(price == 0) {
            price = getRawTokenPrice();
        }
        return price;
    }

    function getTokenPriceUsd() external view returns (uint256) {
        uint256 ethPrice = uint256(
            baseTokenPriceInUsdProxyAggregator.latestAnswer()
        );
        uint256 priceDecimals = baseTokenPriceInUsdProxyAggregator.decimals(); // 8 in most cases
        uint256 decis = decimals();

        uint256 rdntPriceInEth = getTokenPrice();
        uint256 rdntPriceInUsd = rdntPriceInEth.mul(ethPrice).div(decis);
        return rdntPriceInUsd;
    }

    function getLpTokenPrice() public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1, ) = lpToken.getReserves();
        uint256 wethReserve = lpToken.token0() != address(rdntAddr)
            ? reserve0
            : reserve1;
        uint256 rdntReserve = lpToken.token0() == address(rdntAddr)
            ? reserve0
            : reserve1;

        uint256 rdntPrice = getTokenPrice();

        uint256 rdntEthValue = rdntReserve.div(10**18).mul(rdntPrice);

        uint256 ethValue = wethReserve.mul(decimals()).div(10**18);

        uint256 totalValue = ethValue.add(rdntEthValue);

        uint256 lpTokenSupply = lpToken.totalSupply().div(
            10**lpToken.decimals()
        );

        uint256 lpTokenPrice = totalValue.div(lpTokenSupply);

        return lpTokenPrice;
    }

    function getLpTokenPriceUsd() external view returns (uint256) {
        uint256 ethPrice = uint256(
            baseTokenPriceInUsdProxyAggregator.latestAnswer()
        );
        uint256 priceDecimals = baseTokenPriceInUsdProxyAggregator.decimals(); // 8 in most cases
        uint256 decis = decimals();

        uint256 lpPrice = getLpTokenPrice();
        uint256 lpPriceUsd = lpPrice.mul(ethPrice).div(decis);
        return lpPriceUsd;
    }
}
