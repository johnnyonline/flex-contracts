// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

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

    // A keeper settles a redemption-kicked auction via the standalone taker, which redeems the
    // received vault collateral for the underlying to pay
    function test_takeAuction(
        uint256 _userCollateral,
        uint256 _leverage
    ) public {
        _userCollateral = bound(_userCollateral, minCollateralFuzzAmount, maxCollateralFuzzAmount);
        _leverage = bound(_leverage, 2, maxLeverage);

        // The debt that will be sourced via redemption
        uint256 debtAmount = _userCollateral * (_leverage - 1) * priceOracle.get_price() / ORACLE_PRICE_SCALE;

        // Fund the lender, then push all of its idle liquidity into a redeemable trove
        mintAndDepositIntoLender(userLender, debtAmount);
        uint256 firstCollateral =
            (debtAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(anotherUserBorrower, firstCollateral, debtAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(borrowToken.balanceOf(address(lender)), 0, "lender should have no idle liquidity");

        // Trigger a redemption with a plain borrow at a higher rate, kicking an auction
        IDutchDesk dutchDesk = IDutchDesk(troveManager.dutch_desk());
        uint256 nonceBefore = dutchDesk.nonce();
        uint256 userTroveCollateral =
            (debtAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(userBorrower, userTroveCollateral, debtAmount, DEFAULT_ANNUAL_INTEREST_RATE * 2);
        assertEq(dutchDesk.nonce(), nonceBefore + 1, "auction not kicked");

        // A keeper takes the auction via the standalone taker
        address auction = dutchDesk.auction();
        vm.prank(operator);
        auctionTaker.takeAuction(auction, nonceBefore);

        // Verify the auction is fully settled
        assertEq(collateralToken.balanceOf(auction), 0, "E0");

        // Verify the redemption receiver got the proceeds in borrow tokens
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), debtAmount, 1e15, "E1"); // 0.1% tolerance

        // Verify the taker has no leftover tokens
        assertEq(collateralToken.balanceOf(address(auctionTaker)), 0, "E2");
        assertEq(borrowToken.balanceOf(address(auctionTaker)), 0, "E3");
    }

}
