// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "../dependencies/openzeppelin/contracts/IERC20Detailed.sol";
import "../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";
import "../misc/interfaces/IAaveOracle.sol";
import "../dependencies/openzeppelin/contracts/SafeMath.sol";
import "../interfaces/IChainlinkAggregator.sol";

contract MFDstats is Initializable, OwnableUpgradeable {
    using SafeMath for uint256;

    address private _aaveOracle;

    struct MFDTransfer {
        uint256 timestamp;
        uint256 usdValue;
        uint256 lpUsdValue;
    }

    struct AssetAddresses {
        uint256 count;
        mapping(uint256 => address) assetAddress;
        mapping(uint256 => string) assetSymbol;
        mapping(address => uint256) indexOfAddress;
    }

    struct TrackPerAsset {
        address assetAddress;
        string assetSymbol;
        uint256 usdValue;
        uint256 lpUsdValue;
    }

    struct AddTransferParam {
        address asset;
        uint256 amount;
        uint256 lpLockingRewardRatio;
        address operationExpenses;
        uint256 operationExpenseRatio;
    }

    AssetAddresses private allAddresses;

    mapping(address => uint256) private _totalPerAsset;
    mapping(address => uint256) private _lpTotalPerAsset;
    mapping(address => MFDTransfer[]) private mfdTransfersPerAsset;

    uint256 public constant DAY_SECONDS = 86400;
    uint8 public constant DECIMALS = 18;

    event NewTransferAdded(address asset, uint256 usdValue, uint256 lpUsdValue);

    function initialize(address aaveOracle) public initializer {
        _aaveOracle = aaveOracle;
        __Ownable_init();
    }

    function addTransfer(AddTransferParam memory param) external {
        uint256 assetPrice = IAaveOracle(_aaveOracle).getAssetPrice(
            param.asset
        );
        address sourceOfAsset = IAaveOracle(_aaveOracle).getSourceOfAsset(
            param.asset
        );
        if (param.operationExpenses != address(0) && param.operationExpenseRatio > 0) {
            uint256 opExAmount = param.amount.mul(param.operationExpenseRatio).div(1e4);
            param.amount = param.amount.sub(opExAmount);
        }
        uint8 priceDecimal = IChainlinkAggregator(sourceOfAsset).decimals();
        uint8 assetDecimals = IERC20Detailed(param.asset).decimals();
        uint256 usdValue = assetPrice
            .mul(param.amount)
            .mul(10**DECIMALS)
            .div(10**priceDecimal)
            .div(10**assetDecimals);
        uint256 lpUsdValue = usdValue.mul(param.lpLockingRewardRatio).div(1e4);
        usdValue = usdValue.sub(lpUsdValue);

        uint256 index;

        if (allAddresses.indexOfAddress[param.asset] == 0) {
            allAddresses.count++;
            allAddresses.assetAddress[allAddresses.count] = param.asset;
            allAddresses.assetSymbol[allAddresses.count] = IERC20Detailed(
                param.asset
            ).symbol();
            allAddresses.indexOfAddress[param.asset] = allAddresses.count;
        }
        _totalPerAsset[param.asset] = _totalPerAsset[param.asset].add(usdValue);
        _lpTotalPerAsset[param.asset] = _lpTotalPerAsset[param.asset].add(
            lpUsdValue
        );

        for (uint256 i = 0; i < mfdTransfersPerAsset[param.asset].length; i++) {
            if (
                block.timestamp.sub(
                    mfdTransfersPerAsset[param.asset][i].timestamp
                ) <= DAY_SECONDS
            ) {
                index = i;
                break;
            }
        }

        for (
            uint256 i = index;
            i < mfdTransfersPerAsset[param.asset].length;
            i++
        ) {
            mfdTransfersPerAsset[param.asset][i - index] = mfdTransfersPerAsset[
                param.asset
            ][i];
        }

        for (uint256 i = 0; i < index; i++) {
            mfdTransfersPerAsset[param.asset].pop();
        }

        mfdTransfersPerAsset[param.asset].push(
            MFDTransfer(block.timestamp, usdValue, lpUsdValue)
        );

        emit NewTransferAdded(param.asset, usdValue, lpUsdValue);
    }

    function getTotal() external view returns (TrackPerAsset[] memory) {
        TrackPerAsset[] memory totalPerAsset = new TrackPerAsset[](
            allAddresses.count + 1
        );
        uint256 total;
        uint256 lpTotal;
        for (uint256 i = 1; i <= allAddresses.count; i++) {
            total = total.add(_totalPerAsset[allAddresses.assetAddress[i]]);
            lpTotal = lpTotal.add(
                _lpTotalPerAsset[allAddresses.assetAddress[i]]
            );

            totalPerAsset[i] = TrackPerAsset(
                allAddresses.assetAddress[i],
                allAddresses.assetSymbol[i],
                _totalPerAsset[allAddresses.assetAddress[i]],
                _lpTotalPerAsset[allAddresses.assetAddress[i]]
            );
        }
        totalPerAsset[0] = TrackPerAsset(address(0), "", total, lpTotal);
        return totalPerAsset;
    }

    function getLastDayTotal() external view returns (TrackPerAsset[] memory) {
        TrackPerAsset[] memory lastDayTotalPerAsset = new TrackPerAsset[](
            allAddresses.count + 1
        );
        uint256 lastdayTotal;
        uint256 lpLastDayTotal;

        for (uint256 i = 1; i <= allAddresses.count; i++) {
            uint256 assetLastDayTotal;
            uint256 lpAssetLastDayTotal;

            if (mfdTransfersPerAsset[allAddresses.assetAddress[i]].length > 0) {
                for (
                    uint256 j = mfdTransfersPerAsset[
                        allAddresses.assetAddress[i]
                    ].length.sub(1);
                    ;
                    j--
                ) {
                    if (
                        block.timestamp.sub(
                            mfdTransfersPerAsset[allAddresses.assetAddress[i]][
                                j
                            ].timestamp
                        ) <= DAY_SECONDS
                    ) {
                        assetLastDayTotal = assetLastDayTotal.add(
                            mfdTransfersPerAsset[allAddresses.assetAddress[i]][
                                j
                            ].usdValue
                        );
                        lpAssetLastDayTotal = lpAssetLastDayTotal.add(
                            mfdTransfersPerAsset[allAddresses.assetAddress[i]][
                                j
                            ].lpUsdValue
                        );
                    } else {
                        break;
                    }
                    if (j == 0) break;
                }
            }

            lastdayTotal = lastdayTotal.add(assetLastDayTotal);
            lpLastDayTotal = lpLastDayTotal.add(lpAssetLastDayTotal);
            lastDayTotalPerAsset[i] = TrackPerAsset(
                allAddresses.assetAddress[i],
                allAddresses.assetSymbol[i],
                assetLastDayTotal,
                lpAssetLastDayTotal
            );
        }

        lastDayTotalPerAsset[0] = TrackPerAsset(
            address(0),
            "",
            lastdayTotal,
            lpLastDayTotal
        );

        return lastDayTotalPerAsset;
    }
}
