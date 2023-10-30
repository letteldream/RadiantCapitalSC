// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.7.6;
pragma abicoder v2;

interface IAaveOracle {
    function setAssetSources(
        address[] calldata assets,
        address[] calldata sources
    ) external;
}

interface IStableAndVariableTokensHelper {
    function setOracleBorrowRates(
        address[] calldata assets,
        uint256[] calldata rates,
        address oracle
    ) external;
}

interface ILendingPoolConfigurator {
    struct InitReserveInput {
        address aTokenImpl;
        address stableDebtTokenImpl;
        address variableDebtTokenImpl;
        uint8 underlyingAssetDecimals;
        address interestRateStrategyAddress;
        address underlyingAsset;
        address treasury;
        address incentivesController;
        uint256 allocPoint;
        string underlyingAssetName;
        string aTokenName;
        string aTokenSymbol;
        string variableDebtTokenName;
        string variableDebtTokenSymbol;
        string stableDebtTokenName;
        string stableDebtTokenSymbol;
        bytes params;
    }

    function batchInitReserve(InitReserveInput[] calldata input) external;
}

contract MockProtocolAdmin {
    IAaveOracle public immutable aaveOracle;
    IStableAndVariableTokensHelper
        public immutable stableAndVariableTokensHelper;
    ILendingPoolConfigurator public immutable lendingPoolConfigurator;

    constructor(
        address _aaveOracle,
        address _stableAndVariableTokensHelper,
        address _lendingPoolConfigurator
    ) {
        aaveOracle = IAaveOracle(_aaveOracle);
        stableAndVariableTokensHelper = IStableAndVariableTokensHelper(
            _stableAndVariableTokensHelper
        );
        lendingPoolConfigurator = ILendingPoolConfigurator(
            _lendingPoolConfigurator
        );
    }

    function setAssetSources(
        address[] calldata assets,
        address[] calldata sources
    ) external {
        aaveOracle.setAssetSources(assets, sources);
    }

    function setOracleBorrowRates(
        address[] calldata assets,
        uint256[] calldata rates,
        address oracle
    ) external {
        stableAndVariableTokensHelper.setOracleBorrowRates(
            assets,
            rates,
            oracle
        );
    }

    function batchInitReserve(
        ILendingPoolConfigurator.InitReserveInput[] calldata input
    ) external {
        lendingPoolConfigurator.batchInitReserve(input);
    }
}
