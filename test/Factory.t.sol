// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract FactoryTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        // Cat Factory
        assertEq(catFactory.TROVE_MANAGER(), originalTroveManager, "E0");
        assertEq(catFactory.SORTED_TROVES(), originalSortedTroves, "E1");
        assertEq(catFactory.DUTCH_DESK(), originalDutchDesk, "E2");
        assertEq(catFactory.AUCTION(), originalAuction, "E3");
        assertEq(catFactory.LENDER_FACTORY(), address(lenderFactory), "E4");
        assertEq(catFactory.VERSION(), "1.0.0", "E5");

        // Lender Factory
        assertEq(lenderFactory.DADDY(), address(daddy), "E6");

        // Lender configuration
        assertEq(lender.keeper(), lenderFactory.KEEPER(), "E7");
        assertEq(lender.performanceFeeRecipient(), address(daddy), "E8");
        assertEq(lender.profitMaxUnlockTime(), 4 days, "E9");
    }

    // Deploy a wstETH/WETH market with a sub-token minimum debt of 0.1 WETH
    function test_deployMarket_smallMinDebt() public {
        address _weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address _wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

        // wstETH/WETH Morpho oracle
        address _oracle = deployCode("morpho_oracle", abi.encode(0xbD60A6770b27E084E8617335ddE769241B0e71D8, _weth, _wsteth));

        // Deploy the market
        (address _troveManagerAddress,,,, address _lender) = catFactory.deploy(
            ICatFactory.DeployParams({
                borrow_token: _weth,
                collateral_token: _wsteth,
                price_oracle: _oracle,
                minimum_debt: 1000, // 0.1 WETH
                safe_collateral_ratio: safeCollateralRatio,
                minimum_collateral_ratio: minimumCollateralRatio,
                max_penalty_collateral_ratio: maxPenaltyCollateralRatio,
                min_liquidation_fee: minLiquidationFee,
                max_liquidation_fee: maxLiquidationFee,
                upfront_interest_period: upfrontInterestPeriod,
                interest_rate_adj_cooldown: interestRateAdjCooldown,
                repay_cooldown: repayCooldown,
                minimum_price_buffer_percentage: minimumPriceBufferPercentage,
                starting_price_buffer_percentage: startingPriceBufferPercentage,
                re_kick_starting_price_buffer_percentage: reKickStartingPriceBufferPercentage,
                step_duration: stepDuration,
                step_decay_rate: stepDecayRate,
                auction_length: auctionLength,
                salt: bytes32(uint256(1234))
            })
        );
        ITroveManager _troveManager = ITroveManager(_troveManagerAddress);

        // The minimum debt is 0.1 WETH
        uint256 _minDebt = _troveManager.min_debt();
        assertEq(_minDebt, 0.1e18, "E0");

        // Lend 0.1 WETH
        airdrop(_weth, userLender, _minDebt);
        vm.startPrank(userLender);
        IERC20(_weth).approve(_lender, _minDebt);
        ILender(_lender).deposit(_minDebt, userLender);
        vm.stopPrank();

        // Calculate how much collateral is needed for the borrow amount
        uint256 _rate = _troveManager.min_annual_interest_rate() * 2;
        uint256 _targetRatio = _troveManager.minimum_collateral_ratio() * 110 / 100;
        uint256 _collateral = (_minDebt * _targetRatio / 1e18) * ORACLE_PRICE_SCALE / IPriceOracle(_troveManager.price_oracle()).get_price();
        airdrop(_wsteth, userBorrower, _collateral);

        vm.startPrank(userBorrower);
        IERC20(_wsteth).approve(_troveManagerAddress, _collateral);

        // Borrowing below the minimum debt reverts
        vm.expectRevert("!min_debt");
        _troveManager.open_trove(0, _collateral, _minDebt / 2, 0, 0, _rate, type(uint256).max, 0, 0);

        // Borrowing 0.1 WETH works
        uint256 _troveId = _troveManager.open_trove(0, _collateral, _minDebt, 0, 0, _rate, type(uint256).max, 0, 0);
        vm.stopPrank();

        // Check the trove
        ITroveManager.Trove memory _trove = _troveManager.troves(_troveId);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E1");
        assertGt(_trove.debt, _minDebt, "E2");
        assertEq(_trove.collateral, _collateral, "E3");
    }

}
