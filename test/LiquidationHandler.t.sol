// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract LiquidationHandlerTests is Base {

    IAuction public auction;

    function setUp() public override {
        Base.setUp();

        vm.prank(management);
        liquidationHandler.accept_ownership();

        auction = IAuction(liquidationHandler.AUCTION());
    }

    function test_setup() public {
        assertEq(liquidationHandler.owner(), management, "E0");
        assertEq(liquidationHandler.pending_owner(), address(0), "E1");
        assertEq(liquidationHandler.LENDER(), address(lender), "E2");
        assertEq(liquidationHandler.TROVE_MANAGER(), address(troveManager), "E3");
        assertTrue(liquidationHandler.AUCTION() != address(0), "E4");
        assertEq(liquidationHandler.PRICE_ORACLE(), address(priceOracle), "E5");
        assertEq(liquidationHandler.AUCTION_FACTORY(), auctionFactory, "E6");
        assertEq(liquidationHandler.BORROW_TOKEN(), address(borrowToken), "E7");
        assertEq(liquidationHandler.COLLATERAL_TOKEN(), address(collateralToken), "E8");
        assertEq(liquidationHandler.DUST_THRESHOLD(), liqHandlerDustThreshold, "E9");
        assertEq(liquidationHandler.MAX_AUCTION_AMOUNT(), liqHandlerMaxAuctionAmount, "E10");
        assertEq(liquidationHandler.STARTING_PRICE_BUFFER_PERCENTAGE(), 115 * 1e16, "E11");
        assertEq(liquidationHandler.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE(), 200 * 1e16, "E12");
        assertEq(liquidationHandler.MINIMUM_PRICE_BUFFER_PERCENTAGE(), 95 * 1e16, "E13");
        assertEq(liquidationHandler.MAX_GAS_PRICE_TO_TRIGGER(), 50e9, "E14");
        assertFalse(liquidationHandler.use_auction(), "E15");
        assertEq(liquidationHandler.keeper(), keeper, "E16");
        assertFalse(liquidationHandler.kick_trigger(), "E17");
    }

    function test_kickTrigger_collateralToSell(
        uint256 _amount
    ) public {
        _amount = bound(_amount, liquidationHandler.DUST_THRESHOLD() + 1, maxFuzzAmount);

        // Airdrop collateral to the auction contract
        airdrop(address(collateralToken), address(auction), _amount);

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E0");
    }

    function test_kickTrigger_notEnoughCollateralToSell(
        uint256 _amount
    ) public {
        _amount = bound(_amount, 0, liquidationHandler.DUST_THRESHOLD() - 1);

        // Airdrop collateral to the auction contract
        airdrop(address(collateralToken), address(auction), _amount);

        // Make sure kick trigger is false
        assertFalse(liquidationHandler.kick_trigger(), "E0");
    }

    function test_tendTrigger_collateralToSell_basefeeTooHigh(
        uint256 _amount
    ) public {
        test_kickTrigger_collateralToSell(_amount);

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E0");

        // Set basefee to too high
        vm.fee(50 * 1e10);

        // Make sure kick trigger is false
        assertFalse(liquidationHandler.kick_trigger(), "E1");
    }

    function test_kickTrigger_activeAuction(
        uint256 _amount
    ) public {
        _amount = bound(_amount, liquidationHandler.DUST_THRESHOLD() + 1, maxFuzzAmount);

        test_kickTrigger_collateralToSell(_amount);

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E0");

        // Kick it
        vm.prank(keeper);
        liquidationHandler.kick();

        assertTrue(auction.isActive(address(collateralToken)), "E1");
        assertTrue(auction.available(address(collateralToken)) > liquidationHandler.DUST_THRESHOLD(), "E2");

        // Make sure kick trigger is false
        assertFalse(liquidationHandler.kick_trigger(), "E3");

        // Advance time beyond auction length
        skip(auction.auctionLength() + 1);
        assertFalse(auction.isActive(address(collateralToken)), "E4");
        assertEq(auction.available(address(collateralToken)), 0, "E5");

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E6");
    }

    function test_kickTrigger_priceTooLow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, liquidationHandler.DUST_THRESHOLD() + 1, maxFuzzAmount);

        // Airdrop collateral to the auction contract
        airdrop(address(collateralToken), address(auction), _amount);

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E0");

        // Kick it
        vm.prank(keeper);
        liquidationHandler.kick();

        // Make sure kick trigger is false
        assertFalse(liquidationHandler.kick_trigger(), "E1");

        // Make sure starting price is set correctly
        assertEq(auction.startingPrice(), priceOracle.price() * _amount * 2 / 1e18 / 1e18, "E2");

        // Skip enough time such that price is too low
        // A lot of time needs to pass bc we're kicking with emergency buffer
        skip(4 hours);

        // Make sure auction price is lower than our min price
        assertLt(auction.price(address(collateralToken)), priceOracle.price() * liquidationHandler.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18, "E2");

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E3");

        // Make sure auction is not active
        assertFalse(auction.isActive(address(collateralToken)), "E4");
    }

    function test_kick_activeAuction(
        uint256 _amount
    ) public {
        _amount = bound(_amount, liquidationHandler.DUST_THRESHOLD() + 1, liquidationHandler.MAX_AUCTION_AMOUNT() / 2 - 1);

        // Airdrop collateral to the auction contract
        airdrop(address(collateralToken), address(auction), _amount);

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E0");

        // Kick it
        vm.prank(keeper);
        liquidationHandler.kick();

        assertTrue(auction.isActive(address(collateralToken)), "E1");
        assertEq(auction.available(address(collateralToken)), _amount, "E2");

        uint256 startingPriceBefore = auction.startingPrice();

        // Airdrop more collateral so that we can to kick again
        airdrop(address(collateralToken), address(auction), _amount, true);

        // Kick again, with new lot
        vm.prank(keeper);
        liquidationHandler.kick();

        assertTrue(auction.isActive(address(collateralToken)), "E3");
        assertEq(auction.available(address(collateralToken)), _amount * 2, "E4");
        assertApproxEqAbs(auction.startingPrice(), startingPriceBefore * 2, 1, "E5");
    }

    function test_kick_cappedByMaxAuctionAmount(
        uint256 _amount
    ) public {
        _amount = bound(_amount, liquidationHandler.MAX_AUCTION_AMOUNT(), maxFuzzAmount);

        // How much we expect to be left in the liq handler after kicking
        uint256 _expectedRemaining = _amount - liquidationHandler.MAX_AUCTION_AMOUNT();

        // Airdrop collateral to the auction contract
        airdrop(address(collateralToken), address(liquidationHandler), _amount);

        // Kick it
        vm.prank(keeper);
        liquidationHandler.kick();

        assertTrue(auction.isActive(address(collateralToken)), "E1");
        assertEq(auction.available(address(collateralToken)), liquidationHandler.MAX_AUCTION_AMOUNT(), "E2");
        assertEq(collateralToken.balanceOf(address(liquidationHandler)), _expectedRemaining, "E3");
    }

    function test_take_goesToLender(
        uint256 _amount
    ) public {
        _amount = bound(_amount, liquidationHandler.DUST_THRESHOLD() + 1, maxFuzzAmount);

        // Airdrop collateral to the auction contract
        airdrop(address(collateralToken), address(auction), _amount);

        // Make sure kick trigger is true
        assertTrue(liquidationHandler.kick_trigger(), "E0");

        // Kick it
        vm.prank(keeper);
        liquidationHandler.kick();

        // Airdrop borrow tokens to taker
        uint256 _amountNeeded = auction.getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);

        // Take it
        vm.startPrank(liquidator);
        borrowToken.approve(address(auction), _amountNeeded);
        auction.take(address(collateralToken));
        vm.stopPrank();

        assertEq(auction.available(address(collateralToken)), 0, "E1");
        assertEq(borrowToken.balanceOf(address(lender)), _amountNeeded, "E2");
    }

    function test_kick_notKeeper(
        address _notKeeper
    ) public {
        vm.assume(_notKeeper != keeper);

        vm.expectRevert("!keeper");
        vm.prank(_notKeeper);
        liquidationHandler.kick();
    }

    function test_toggleUseAuction() public {
        // Get initial state
        bool initialState = liquidationHandler.use_auction();

        // Toggle it
        vm.prank(management);
        liquidationHandler.toggle_use_auction();

        // Make sure it flipped
        assertEq(liquidationHandler.use_auction(), !initialState, "E0");
    }

    function test_toggleUseAuction_notOwner(
        address _notOwner
    ) public {
        vm.assume(_notOwner != management);

        vm.expectRevert("!owner");
        vm.prank(_notOwner);
        liquidationHandler.toggle_use_auction();
    }

    function test_setKeeper(
        address _newKeeper
    ) public {
        vm.prank(management);
        liquidationHandler.set_keeper(_newKeeper);

        assertEq(liquidationHandler.keeper(), _newKeeper, "E0");
    }

    function test_setKeeper_notOwner(
        address _notOwner,
        address _newKeeper
    ) public {
        vm.assume(_notOwner != management);

        vm.expectRevert("!owner");
        vm.prank(_notOwner);
        liquidationHandler.set_keeper(_newKeeper);
    }

}
