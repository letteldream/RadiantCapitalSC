// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../dependencies/openzeppelin/contracts/IERC20.sol";
import "../dependencies/openzeppelin/contracts/Ownable.sol";

import "../interfaces/IStargateRouter.sol";
import "../interfaces/ILendingPool.sol";

/*
    Chain Ids
        Ethereum: 101
        BSC: 102
        Avalanche: 106
        Polygon: 109
        Arbitrum: 110
        Optimism: 111
        Fantom: 112
        Swimmer: 114
        DFK: 115
        Harmony: 116
        Moonbeam: 126

    Pool Ids
        Ethereum
            USDC: 1
            USDT: 2
            ETH: 13
        BSC
            USDT: 2
            BUSD: 5
        Avalanche
            USDC: 1
            USDT: 2
        Polygon
            USDC: 1
            USDT: 2
        Arbitrum
            USDC: 1
            USDT: 2
            ETH: 13
        Optimism
            USDC: 1
            ETH: 13
        Fantom
            USDC: 1
 */

contract StargateBorrow is Ownable {
    using SafeMath for uint256;

    /// @notice Stargate Router
    IStargateRouter public router;

    /// @notice Lending Pool address
    ILendingPool public lendingPool;

    /// @notice asset => poolId; at the moment, pool IDs for USDC and USDT are the same accross all chains
    mapping(address => uint256) public poolIdPerChain;

    /// @notice DAO wallet
    address public daoTreasury;

    uint256 public xChainBorrowFeePercent = 100;

    constructor(
        IStargateRouter _router,
        ILendingPool _lendingPool,
        address _treasury,
        uint256 _xChainBorrowFeePercent
    ) {
        router = _router;
        lendingPool = _lendingPool;
        daoTreasury = _treasury;
        xChainBorrowFeePercent = _xChainBorrowFeePercent;
    }

    /**
     * @notice Set DAO Treasury.
     */
    function setDAOTreasury(address _daoTreasury) external onlyOwner {
        // require(_daoTreasury != address(0));
        daoTreasury = _daoTreasury;
    }

    //Set Cross Chain Borrow Fee Percent
    function setXChainBorrowFeePercent (uint256 percent) external onlyOwner {
        xChainBorrowFeePercent = percent;
    }

    //Get Cross Chain Borrow Fee amount
    function getXChainBorrowFeeAmount (uint256 amount) public view returns(uint256){
        uint256 feeAmount = amount.mul(xChainBorrowFeePercent).div(1e4);
        return feeAmount;
    }
    
    // Set pool ids of assets
    function setPoolIDs(address[] memory assets, uint256[] memory poolIDs) external onlyOwner {
        for (uint256 i = 0; i < assets.length; i += 1) {
            poolIdPerChain[assets[i]] = poolIDs[i];
        }
    }

    // Call Router.sol method to get the value for swap()
    function quoteLayerZeroSwapFee(
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) external view returns (uint256, uint256) {
        return router.quoteLayerZeroFee(
            _dstChainId,
            _functionType,
            _toAddress,
            _transferAndCallPayload,
            _lzTxParams
        );
    }

    /**
     * @dev Loop the deposit and borrow of an asset
     * @param asset for loop
     * @param amount for the initial deposit
     * @param interestRateMode stable or variable borrow mode
     * @param dstChainId Destination chain id
     **/
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 dstChainId
    ) external payable {
        lendingPool.borrow(asset, amount, interestRateMode, 0, msg.sender);
        uint256 feeAmount = getXChainBorrowFeeAmount(amount);
        IERC20(asset).transfer(daoTreasury, feeAmount);
        amount = amount.sub(feeAmount);
        IERC20(asset).approve(address(router), amount);
        router.swap{value: msg.value}(
            dstChainId, // dest chain id
            poolIdPerChain[asset], // src chain pool id
            poolIdPerChain[asset], // dst chain pool id
            msg.sender, // receive address
            amount, // transfer amount
            amount.mul(99).div(100), // max slippage: 1%
            IStargateRouter.lzTxObj(0, 0, "0x"),
            abi.encodePacked(msg.sender),
            bytes("")
        );
    }
}