import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

import { ether, uint256Max } from '../helper';
import { MockToken } from '../types/MockToken';

const fs = require('fs');

const deployAave: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, ethers } = hre;
  const { deploy } = deployments;
  const [deployer, treasury] = await ethers.getSigners();

  const MARKET_ID = 'ShyftAave';
  const PROVIDER_ID = '1';
  const ORACLE_BASE_CURRENCY = '0x0000000000000000000000000000000000000000'; // USD
  const ORACLE_BASE_CURRENCY_UNIT = '100000000'; // 10**8

  ////////////////////////////
  const deployContract = async (
    contractName: string,
    opts: any,
    args?: any[]
  ) => {
    const deployResult = await deploy(contractName, {
      from: deployer.address,
      args,
      log: true,
      ...opts,
    });
    const contract = await ethers.getContractAt(
      opts.contract ?? contractName,
      deployResult.address
    );
    console.log(`${contractName}: ${contract.address}`);
    return contract;
  };

  // Deploy LendingPoolAddressesProviderRegistry
  const lendingPoolAddressesProviderRegistry = await deployContract(
    'LendingPoolAddressesProviderRegistry',
    {}
  );

  // Deploy LendingPoolAddressesProvider
  const lendingPoolAddressesProvider = await deployContract(
    'LendingPoolAddressesProvider',
    {},
    [MARKET_ID]
  );

  // Set the provider at the Registry
  await (
    await lendingPoolAddressesProviderRegistry.registerAddressesProvider(
      lendingPoolAddressesProvider.address,
      PROVIDER_ID
    )
  ).wait();

  // Set pool admins
  await (
    await lendingPoolAddressesProvider.setPoolAdmin(deployer.address)
  ).wait();
  await (
    await lendingPoolAddressesProvider.setEmergencyAdmin(deployer.address)
  ).wait();

  // Set treasury
  await (
    await lendingPoolAddressesProvider.setLiquidationFeeTo(treasury.address)
  ).wait();

  // Deploy libraries used by lending pool implementation, ReserveLogic
  const reserveLogic = await deployContract('ReserveLogic', {});

  // Deploy libraries used by lending pool implementation, GenericLogic
  const genericLogic = await deployContract('GenericLogic', {});

  // Deploy libraries used by lending pool implementation, ValidationLogic
  const validationLogic = await deployContract('ValidationLogic', {
    libraries: {
      GenericLogic: genericLogic.address,
    },
  });

  // Deploy LendingPool implementation
  const lendingPoolImpl = await deployContract('LendingPool', {
    libraries: {
      ValidationLogic: validationLogic.address,
      ReserveLogic: reserveLogic.address,
    },
  });

  //   Initialize LendingPool implementation
  await (
    await lendingPoolImpl.initialize(lendingPoolAddressesProvider.address)
  ).wait();

  // Setting the LendingPool implementation at the LendingPoolAddressesProvider
  await (
    await lendingPoolAddressesProvider.setLendingPoolImpl(
      lendingPoolImpl.address
    )
  ).wait();

  // LendingPool (InitializableImmutableAdminUpgradeabilityProxy)
  const lendingPoolProxy: any = lendingPoolImpl.attach(
    await lendingPoolAddressesProvider.getLendingPool()
  );
  console.log('LendingPoolProxy: ', lendingPoolProxy.address);

  // Deploy LendingPoolConfigurator implementation
  const lendingPoolConfiguratorImpl = await deployContract(
    'LendingPoolConfigurator',
    {}
  );

  // Setting the LendingPool implementation at the LendingPoolAddressesProvider
  await (
    await lendingPoolAddressesProvider.setLendingPoolConfiguratorImpl(
      lendingPoolConfiguratorImpl.address
    )
  ).wait();

  // LendingPoolConfigurator (InitializableImmutableAdminUpgradeabilityProxy)
  const lendingPoolConfiguratorProxy = lendingPoolConfiguratorImpl.attach(
    await lendingPoolAddressesProvider.getLendingPoolConfigurator()
  );
  console.log(
    'LendingPoolConfiguratorProxy: ',
    lendingPoolConfiguratorProxy.address
  );

  // Deploy deployment helpers
  // contracts/deployments/StableAndVariableTokensHelper
  const stableAndVariableTokensHelper = await deployContract(
    'StableAndVariableTokensHelper',
    {},
    [lendingPoolProxy.address, lendingPoolAddressesProvider.address]
  );

  // Deploy deployment helpers
  // contracts/deployments/ATokensAndRatesHelper
  const aTokensAndRatesHelper = await deployContract(
    'ATokensAndRatesHelper',
    {},
    [
      lendingPoolProxy.address,
      lendingPoolAddressesProvider.address,
      lendingPoolConfiguratorProxy.address,
    ]
  );

  // Deploy implementation AToken
  // contracts/protocol/tokenization/AToken
  const aToken = await deployContract('AaveAToken', { contract: 'AToken' });

  // Deploy generic StableDebtToken
  // contracts/protocol/tokenization/StableDebtToken
  const stableDebtToken = await deployContract('StableDebtToken', {});

  // Deploy generic VariableDebtToken
  // contracts/protocol/tokenization/VariableDebtToken
  const variableDebtToken = await deployContract('VariableDebtToken', {});

  // Deploy contracts/misc/AaveOracle
  const aaveOracle = await deployContract('AaveOracle', {}, [
    [], // assetAddresses
    [], // chainlinkAggregators
    '0x0000000000000000000000000000000000000000',
    ORACLE_BASE_CURRENCY,
    ORACLE_BASE_CURRENCY_UNIT,
  ]);

  // Setting the AaveOracle at the LendingPoolAddressesProvider
  // Register the proxy price provider on the addressesProvider
  await (
    await lendingPoolAddressesProvider.setPriceOracle(aaveOracle.address)
  ).wait();

  // Deploy contracts/mocks/oracle/LendingRateOracle
  const lendingRateOracle = await deployContract('LendingRateOracle', {});

  // Setting the LendingRateOracle at the LendingPoolAddressesProvider
  // Register the proxy price provider on the addressesProvider
  await (
    await lendingPoolAddressesProvider.setLendingRateOracle(
      lendingRateOracle.address
    )
  ).wait();

  // setInitialMarketRatesInRatesOracleByHelper
  // Set helper as owner
  await (
    await lendingRateOracle.transferOwnership(
      stableAndVariableTokensHelper.address
    )
  ).wait();

  await (
    await stableAndVariableTokensHelper.setOracleBorrowRates(
      [], // assetAddresses
      [], // borrowRates
      lendingRateOracle.address
    )
  ).wait();

  // Set back ownership
  await (
    await stableAndVariableTokensHelper.setOracleOwnership(
      lendingRateOracle.address,
      deployer.address
    )
  ).wait();

  // Deploy mock staking token
  const stakingToken = await deployContract('MockStakingToken', {}, []);

  // Deploy underlying token
  const aTokenDeployResult = await deploy('AMockToken', {
    contract: 'MockToken',
    from: deployer.address,
    args: [ether(2000)],
    log: true,
  });
  const underlyingToken = <MockToken>(
    await ethers.getContractAt('MockToken', aTokenDeployResult.address)
  );

  // Deploy ChainlinkAggregatorFactory
  const chainlinkAggregatorFactory = await deployContract(
    'MockChainlinkAggregatorFactory',
    {}
  );

  // Deploy ChainlinkAggregator
  const chainlinkAggregator = await deployContract(
    'MockChainlinkAggregator',
    {}
  );
  await (await chainlinkAggregator.setLatestAnswer('100000000000')).wait();

  // Deploy LPContract
  const mockLpContract = await deployContract('MockLpContract', {}, [
    'Mock LP',
    'MLP',
    stakingToken.address,
    stakingToken.address,
    [ethers.utils.parseEther('1000000'), ethers.utils.parseEther('300')],
  ]);
  await (await mockLpContract.mint()).wait();

  // Deploy PriceProvider
  const priceProvider = await deploy('PriceProvider', {
    from: deployer.address,
    args: [],
    log: true,
    proxy: {
      proxyContract: 'OpenZeppelinTransparentProxy',
      execute: {
        methodName: 'initialize',
        args: [
          mockLpContract.address,
          stakingToken.address,
          chainlinkAggregator.address,
          1800,
        ],
      },
    },
  });

  // Deploy MFDstats
  const mfdstats = await deployContract('MFDstats', {}, []);

  // Deploy fee distribution
  const lpFeeDistributionDeployResult = await deploy('LPFeeDistribution', {
    contract: 'MultiFeeDistribution',
    from: deployer.address,
    args: [],
    log: true,
    proxy: {
      proxyContract: 'OpenZeppelinTransparentProxy',
      execute: {
        methodName: 'initialize',
        args: [
          ethers.constants.AddressZero,
          stakingToken.address,
          ethers.constants.AddressZero,
          priceProvider.address,
          60,
          30,
          86400,
        ],
      },
    },
  });
  const lpFeeDistribution = await ethers.getContractAt(
    'MultiFeeDistribution',
    lpFeeDistributionDeployResult.address
  );

  const multiFeeDistributionDeployResult = await deploy(
    'MultiFeeDistribution',
    {
      contract: 'MultiFeeDistribution',
      from: deployer.address,
      args: [],
      log: true,
      proxy: {
        proxyContract: 'OpenZeppelinTransparentProxy',
        execute: {
          methodName: 'initialize',
          args: [
            stakingToken.address,
            stakingToken.address,
            mfdstats.address,
            priceProvider.address,
            60,
            30,
            86400,
          ],
        },
      },
    }
  );
  const multiFeeDistribution = await ethers.getContractAt(
    'MultiFeeDistribution',
    multiFeeDistributionDeployResult.address
  );

  const middleFeeDistributionDeployResult = await deploy(
    'MiddleFeeDistribution',
    {
      from: deployer.address,
      args: [],
      log: true,
      proxy: {
        proxyContract: 'OpenZeppelinTransparentProxy',
        execute: {
          methodName: 'initialize',
          args: [
            stakingToken.address,
            mfdstats.address,
            lpFeeDistribution.address,
            multiFeeDistribution.address,
          ],
        },
      },
    }
  );
  const middleFeeDistribution = await ethers.getContractAt(
    'MiddleFeeDistribution',
    middleFeeDistributionDeployResult.address
  );

  // Deploy RewardEligibleDataProvider
  const rewardEligibleDataProvider = await deployContract(
    'RewardEligibleDataProvider',
    {},
    [
      lendingPoolProxy.address,
      middleFeeDistribution.address,
      priceProvider.address,
      ethers.constants.AddressZero,
    ]
  );

  // Deploy ChefIncentivesController
  const chefIncentivesController = await deploy('ChefIncentivesController', {
    from: deployer.address,
    args: [],
    log: true,
    proxy: {
      proxyContract: 'OpenZeppelinTransparentProxy',
      execute: {
        methodName: 'initialize',
        args: [
          lendingPoolConfiguratorProxy.address,
          rewardEligibleDataProvider.address,
          middleFeeDistribution.address,
          1,
        ],
      },
    },
  });

  (
    await rewardEligibleDataProvider.setChefIncentivesController(
      chefIncentivesController.address
    )
  ).wait();

  // Deploy contracts/staking/MerkleDistributor
  const merkleDistributor = await deployContract('MerkleDistributor', {}, [
    middleFeeDistribution.address,
    '200000000000000000000000000',
  ]);

  // set minters on fee distribution contracts
  await (
    await lpFeeDistribution.setMinters([
      middleFeeDistribution.address,
      chefIncentivesController.address,
    ])
  ).wait();
  await (
    await multiFeeDistribution.setMinters([
      middleFeeDistribution.address,
      chefIncentivesController.address,
    ])
  ).wait();
  await (
    await middleFeeDistribution.setMinters([
      chefIncentivesController.address,
      merkleDistributor.address,
    ])
  ).wait();
  await (
    await middleFeeDistribution.transferOwnership(
      lendingPoolConfiguratorProxy.address
    )
  ).wait();

  // Deploy DefaultReserveInterestRateStrategy
  const defaultReserveInterestRateStrategy = await deployContract(
    'DefaultReserveInterestRateStrategy',
    {},
    [
      lendingPoolAddressesProvider.address,
      '900000000000000000000000000',
      '0',
      '40000000000000000000000000',
      '600000000000000000000000000',
      '20000000000000000000000000',
      '600000000000000000000000000',
    ]
  );

  // Deploy FlashLoan
  const flashLoan = await deployContract('MockFlashLoan', {}, [
    lendingPoolAddressesProvider.address,
  ]);

  // Deploy MockProtocolAdmin
  const protocolAdmin = await deployContract('MockProtocolAdmin', {}, [
    aaveOracle.address,
    stableAndVariableTokensHelper.address,
    lendingPoolConfiguratorProxy.address,
  ]);

  await (await aaveOracle.transferOwnership(protocolAdmin.address)).wait();
  await (
    await stableAndVariableTokensHelper.transferOwnership(protocolAdmin.address)
  ).wait();
  await (
    await lendingPoolAddressesProvider.setPoolAdmin(protocolAdmin.address)
  ).wait();

  await await protocolAdmin.setAssetSources(
    [underlyingToken.address],
    [chainlinkAggregator.address]
  );

  await (
    await protocolAdmin.batchInitReserve([
      {
        aTokenImpl: aToken.address,
        stableDebtTokenImpl: stableDebtToken.address,
        variableDebtTokenImpl: variableDebtToken.address,
        underlyingAssetDecimals: 8,
        interestRateStrategyAddress: defaultReserveInterestRateStrategy.address,
        underlyingAsset: underlyingToken.address,
        treasury: middleFeeDistribution.address,
        incentivesController: chefIncentivesController.address,
        allocPoint: 100,
        underlyingAssetName: await underlyingToken.name(),
        aTokenName: 'Shyft Aave interest bearing token',
        aTokenSymbol: 'SAToken',
        variableDebtTokenName: 'Shyft Aave interest bearing token',
        variableDebtTokenSymbol: 'SAToken',
        stableDebtTokenName: 'Shyft Aave interest bearing token',
        stableDebtTokenSymbol: 'SAToken',
        params: '0x10',
      },
    ])
  ).wait();

  // Deposit pool
  await (
    await underlyingToken.mint(
      deployer.address,
      ethers.utils.parseEther('1000')
    )
  ).wait();
  await (
    await underlyingToken.approve(
      lendingPoolProxy.address,
      ethers.utils.parseEther('1000')
    )
  ).wait();

  await (
    await lendingPoolProxy.deposit(
      underlyingToken.address,
      ethers.utils.parseEther('1000'),
      deployer.address,
      0
    )
  ).wait();

  // Deposit pool
  await (
    await underlyingToken.mint(
      deployer.address,
      ethers.utils.parseEther('1000')
    )
  ).wait();
  await (
    await underlyingToken.approve(
      lendingPoolProxy.address,
      ethers.utils.parseEther('1000')
    )
  ).wait();

  await (
    await lendingPoolProxy.deposit(
      underlyingToken.address,
      ethers.utils.parseEther('1000'),
      deployer.address,
      0
    )
  ).wait();

  // Flashloan
  await (
    await underlyingToken.mint(
      flashLoan.address,
      ethers.utils.parseEther('1000')
    )
  ).wait();

  console.log(
    'BeforeFlashLoan: ',
    (await underlyingToken.balanceOf(flashLoan.address)).toString()
  );

  await await flashLoan.flashLoanCall(
    [underlyingToken.address],
    [ethers.utils.parseEther('1000')]
  );

  console.log(
    'AfterFlashLoan: ',
    (await underlyingToken.balanceOf(flashLoan.address)).toString()
  );
};

export default deployAave;
deployAave.tags = ['Aave'];
deployAave.dependencies = [];
