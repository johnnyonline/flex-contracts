// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RepayCooldownTests is Base {

    function setUp() public override {
        // Deploy the market with a 30 minute repay cooldown
        repayCooldown = 30 minutes;

        Base.setUp();
    }

    /// @dev Fund the lender and open a trove at the target collateral ratio
    function _openTrove(
        uint256 _amount
    ) internal returns (uint256) {
        mintAndDepositIntoLender(userLender, _amount);
        uint256 _collateral = (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        return mintAndOpenTrove(userBorrower, _collateral, _amount, DEFAULT_ANNUAL_INTEREST_RATE);
    }

    function test_setup() public {
        assertEq(troveManager.repay_cooldown(), 30 minutes, "E0");
    }

    // Repaying is blocked until the cooldown after the open has passed
    function test_repay_cooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);
        uint256 _troveId = _openTrove(_amount);

        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), type(uint256).max);

        // Blocked through the last second of the cooldown
        skip(30 minutes);
        vm.expectRevert("!repay_cooldown");
        troveManager.repay(_troveId, _amount / 2);

        // One second later the repay works
        skip(1);
        troveManager.repay(_troveId, _amount / 2);
        vm.stopPrank();
    }

    // Closing is blocked until the cooldown after the open has passed
    function test_close_cooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        uint256 _troveId = _openTrove(_amount);

        // Airdrop generously so the close attempt isn't blocked by balance
        airdrop(address(borrowToken), userBorrower, _amount * 2);

        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), type(uint256).max);

        // Blocked through the last second of the cooldown
        skip(30 minutes);
        vm.expectRevert("!repay_cooldown");
        troveManager.close_trove(_troveId);

        // One second later the close works
        skip(1);
        troveManager.close_trove(_troveId);
        vm.stopPrank();

        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.closed), "E0");
    }

    // Borrowing more resets the cooldown
    function test_borrow_resetsCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        // Open with half the amount and collateral sized for the full amount, leaving borrow headroom
        mintAndDepositIntoLender(userLender, _amount);
        uint256 _collateral = (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateral, _amount / 2, DEFAULT_ANNUAL_INTEREST_RATE);

        // Borrow more after the open's cooldown
        skip(30 minutes + 1);
        vm.startPrank(userBorrower);
        troveManager.borrow(_troveId, _amount / 4, type(uint256).max, 0, 0);

        // The borrow restarted the cooldown
        borrowToken.approve(address(troveManager), type(uint256).max);
        vm.expectRevert("!repay_cooldown");
        troveManager.repay(_troveId, _amount / 4);

        // After another cooldown the repay works
        skip(30 minutes + 1);
        troveManager.repay(_troveId, _amount / 4);
        vm.stopPrank();
    }

    // Repaying does not reset the cooldown: consecutive repays work in the same block
    function test_repay_doesNotResetCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 4, maxFuzzAmount);
        uint256 _troveId = _openTrove(_amount);

        skip(30 minutes + 1);

        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), type(uint256).max);
        troveManager.repay(_troveId, _amount / 4);
        troveManager.repay(_troveId, _amount / 4);
        vm.stopPrank();
    }

    // A redemption against the trove does not reset the owner's cooldown, so it cannot be
    // used to grief the owner's exit
    function test_redemption_doesNotResetCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 3, maxFuzzAmount);
        uint256 _troveId = _openTrove(_amount);

        skip(30 minutes + 1);

        // Redeem against the trove
        vm.prank(address(lender));
        troveManager.redeem(_amount / 4, address(lender));

        // Airdrop generously so the close attempt isn't blocked by balance
        airdrop(address(borrowToken), userBorrower, _amount * 2);

        // The owner can still close immediately, in the same block as the redemption
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), type(uint256).max);
        troveManager.close_trove(_troveId);
        vm.stopPrank();

        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.closed), "E0");
    }

    // The factory rejects cooldowns above the maximum
    function test_deploy_cooldownTooLong_reverts() public {
        vm.expectRevert("!repay_cooldown");
        catFactory.deploy(
            ICatFactory.DeployParams({
                borrow_token: address(borrowToken),
                collateral_token: address(collateralToken),
                price_oracle: address(priceOracle),
                minimum_debt: minimumDebt * BPS,
                safe_collateral_ratio: safeCollateralRatio,
                minimum_collateral_ratio: minimumCollateralRatio,
                max_penalty_collateral_ratio: maxPenaltyCollateralRatio,
                min_liquidation_fee: minLiquidationFee,
                max_liquidation_fee: maxLiquidationFee,
                upfront_interest_period: upfrontInterestPeriod,
                interest_rate_adj_cooldown: interestRateAdjCooldown,
                repay_cooldown: 1 hours + 1,
                minimum_price_buffer_percentage: minimumPriceBufferPercentage,
                starting_price_buffer_percentage: startingPriceBufferPercentage,
                re_kick_starting_price_buffer_percentage: reKickStartingPriceBufferPercentage,
                step_duration: stepDuration,
                step_decay_rate: stepDecayRate,
                auction_length: auctionLength,
                salt: bytes32(uint256(777))
            })
        );
    }

}
