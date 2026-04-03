// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

interface IERC4626 {

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256);

}

contract AuctionTakerTests is Base {

    address public yvUSD = address(0x696d02Db93291651ED510704c9b286841d506987);

    uint256 public maxCollateralFuzzAmount;
    uint256 public minCollateralFuzzAmount;
    uint256 public maxLeverage;

    function setUp() public override {
        Base.setUp();

        // Deploy yvUSD/USDC market
        address _oracle = deployCode("yvusd_to_usdc_oracle");
        (address _troveManager,,,, address _lender) = catFactory.deploy(
            ICatFactory.DeployParams({
                borrow_token: address(borrowToken),
                collateral_token: yvUSD,
                price_oracle: _oracle,
                minimum_debt: minimumDebt,
                safe_collateral_ratio: safeCollateralRatio,
                minimum_collateral_ratio: minimumCollateralRatio,
                max_penalty_collateral_ratio: maxPenaltyCollateralRatio,
                min_liquidation_fee: minLiquidationFee,
                max_liquidation_fee: maxLiquidationFee,
                upfront_interest_period: upfrontInterestPeriod,
                interest_rate_adj_cooldown: interestRateAdjCooldown,
                minimum_price_buffer_percentage: minimumPriceBufferPercentage,
                starting_price_buffer_percentage: 1e18, // no buffer
                re_kick_starting_price_buffer_percentage: reKickStartingPriceBufferPercentage,
                step_duration: stepDuration,
                step_decay_rate: stepDecayRate,
                auction_length: auctionLength,
                salt: bytes32(uint256(69))
            })
        );

        // Override Base market with yvUSD/USDC market
        troveManager = ITroveManager(_troveManager);
        lender = ILender(_lender);
        priceOracle = IPriceOracle(_oracle);
        collateralToken = IERC20(yvUSD);

        // Recalculate constants for yvUSD market
        DEFAULT_ANNUAL_INTEREST_RATE = troveManager.min_annual_interest_rate() * 2;
        DEFAULT_TARGET_COLLATERAL_RATIO = troveManager.minimum_collateral_ratio() * 110 / 100;

        // Set fuzz bounds
        maxCollateralFuzzAmount = 10_000 * 1e6;
        minCollateralFuzzAmount = 600 * 1e6;
        maxLeverage = (minimumCollateralRatio / (minimumCollateralRatio - 100)) * 90 / 100;
    }

    function test_takeAuction(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        airdrop(address(collateralToken), userBorrower, _userCollateral);

        uint256 additionalCollateral = _userCollateral * (_leverage - 1);
        uint256 baseDebt = additionalCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE;
        uint256 flashLoanAmount = baseDebt;

        // Small buffer for Aave premium (no swap slippage since we deposit directly into vault)
        uint256 debtAmount = baseDebt + baseDebt / 1000; // 0.1% buffer

        // Fund the lender with enough for both troves
        mintAndDepositIntoLender(userLender, debtAmount);

        // Exhaust lender liquidity by opening a trove from another user
        uint256 firstCollateral =
            (debtAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(anotherUserBorrower, firstCollateral, debtAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Approve zapper to pull collateral
        vm.prank(userBorrower);
        collateralToken.approve(address(leverageZapper), _userCollateral);

        // Open leveraged trove with auction taker to take the kicked auction
        vm.prank(userBorrower);
        uint256 troveId = leverageZapper.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: userBorrower,
                trove_manager: address(troveManager),
                flash_loan_token: address(borrowToken),
                auction_taker: address(auctionTaker),
                owner_index: block.timestamp,
                flash_loan_amount: flashLoanAmount,
                collateral_amount: _userCollateral,
                debt_amount: debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: DEFAULT_ANNUAL_INTEREST_RATE * 2, // higher rate so we can redeem the first trove
                max_upfront_fee: type(uint256).max,
                min_borrow_out: 0,
                min_collateral_out: 0,
                collateral_swap: ILeverageZapper.SwapData({
                    router: yvUSD, data: abi.encodeWithSelector(IERC4626.deposit.selector, flashLoanAmount, address(leverageZapper))
                }),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        // Verify trove
        ITroveManager.Trove memory trove = troveManager.troves(troveId);
        assertEq(trove.owner, userBorrower, "E0");
        assertEq(uint256(trove.status), uint256(ITroveManager.Status.active), "E1");
        assertGt(trove.debt, 0, "E2");

        // Verify leverage: trove.collateral should be approximately _leverage * userCollateral
        assertApproxEqRel(trove.collateral, _userCollateral * _leverage, 1e16, "E3"); // 1% tolerance

        // Verify zapper has no leftover tokens
        assertEq(collateralToken.balanceOf(address(leverageZapper)), 0, "E4");
        assertEq(borrowToken.balanceOf(address(leverageZapper)), 0, "E5");

        // Verify auction taker has no leftover tokens
        assertEq(collateralToken.balanceOf(address(auctionTaker)), 0, "E6");
        assertEq(borrowToken.balanceOf(address(auctionTaker)), 0, "E7");

        // Verify swept leftovers to borrower
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E8");
        assertGt(borrowToken.balanceOf(userBorrower), 0, "E9");
    }

}
