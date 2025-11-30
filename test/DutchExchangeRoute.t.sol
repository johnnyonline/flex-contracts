// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract DutchExchangeRouteTests is Base {

    function setUp() public override {
        Base.setUp();

        vm.prank(management);
        dutchExchangeRoute.accept_ownership();
    }

    function test_setup() public {
        assertEq(dutchExchangeRoute.owner(), management, "E0");
        assertEq(dutchExchangeRoute.pending_owner(), address(0), "E1");
        assertEq(dutchExchangeRoute.EXCHANGE_HANDLER(), address(exchangeHandler), "E2");
        assertEq(dutchExchangeRoute.PRICE_ORACLE(), address(priceOracle), "E3");
        assertEq(dutchExchangeRoute.AUCTION_FACTORY(), address(auctionFactory), "E4");
        assertEq(dutchExchangeRoute.BORROW_TOKEN(), address(borrowToken), "E5");
        assertEq(dutchExchangeRoute.COLLATERAL_TOKEN(), address(collateralToken), "E6");
        assertEq(dutchExchangeRoute.DUST_THRESHOLD(), dustThreshold, "E7");
        assertEq(dutchExchangeRoute.MAX_AUCTION_AMOUNT(), maxAuctionAmount, "E8");
        assertEq(dutchExchangeRoute.MIN_AUCTION_AMOUNT(), minAuctionAmount, "E9");
        assertEq(dutchExchangeRoute.STARTING_PRICE_BUFFER_PERCENTAGE(), 1e18 + 15e16, "E10"); // 15%
        assertEq(dutchExchangeRoute.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE(), 1e18 + 100e16, "E11"); // 100%
        assertEq(dutchExchangeRoute.MINIMUM_PRICE_BUFFER_PERCENTAGE(), 1e18 - 5e16, "E12"); // 5%
        assertEq(dutchExchangeRoute.MAX_GAS_PRICE_TO_TRIGGER(), 50e9, "E13"); // 50 gwei
        assertEq(dutchExchangeRoute.MAX_AUCTIONS(), 20, "E14");
        assertEq(dutchExchangeRoute.keeper(), keeper, "E15");
        assertEq(dutchExchangeRoute.kick_trigger().length, 0, "E16");
        vm.expectRevert();
        dutchExchangeRoute.auctions(0);
    }

    function test_dutchExecute(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchExchangeRoute.MIN_AUCTION_AMOUNT(), dutchExchangeRoute.MAX_AUCTION_AMOUNT());

        // Airdrop collateral to the dutch route
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);

        // Execute as exchange handler
        vm.prank(address(exchangeHandler));
        uint256 _amountOut = dutchExchangeRoute.execute(_amount, userLender);

        // Should return 0 since not atomic
        assertEq(_amountOut, 0, "E0");

        // Should have created one auction
        address _auction = dutchExchangeRoute.auctions(0);
        assertTrue(_auction != address(0), "E1");

        // Auction should be active
        assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E2");

        // Auction should have the collateral
        assertEq(IAuction(_auction).available(address(collateralToken)), _amount, "E3");

        // Check starting price is set correctly (with 15% buffer)
        uint256 _expectedStartingPrice = _amount * priceOracle.price() / 1e18 * dutchExchangeRoute.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18;
        assertEq(IAuction(_auction).startingPrice(), _expectedStartingPrice, "E4");

        // Check minimum price is set correctly (with -5% buffer)
        uint256 _expectedMinimumPrice = priceOracle.price() * dutchExchangeRoute.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18;
        assertEq(IAuction(_auction).minimumPrice(), _expectedMinimumPrice, "E5");
    }

    function test_dutchExecute_belowMinAmount(
        uint256 _amount
    ) public {
        _amount = bound(_amount, 1, dutchExchangeRoute.MIN_AUCTION_AMOUNT() - 1);

        // Airdrop collateral to the dutch route
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);

        // Should revert
        vm.expectRevert("!min_auction_amount");
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);
    }

    function test_dutchExecute_aboveMaxAmount(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchExchangeRoute.MAX_AUCTION_AMOUNT() + 1, maxFuzzAmount);

        // Airdrop collateral to the dutch route
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);

        // Should revert
        vm.expectRevert("!max_auction_amount");
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);
    }

    function test_dutchExecute_invalidCaller(
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != address(exchangeHandler));

        // Should revert
        vm.expectRevert("!exchange_handler");
        vm.prank(_invalidCaller);
        dutchExchangeRoute.execute(0, userLender);
    }

    function test_dutchExecute_multipleAuctions_reusesWhenAvailable() public {
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();

        // First execution - creates auction 0
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        // Verify no collateral left in dutch route
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E1");

        // Second execution while first is active - creates auction 1
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction1 = dutchExchangeRoute.auctions(1);
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E2");
        assertNotEq(_auction0, _auction1, "E3");

        // Verify no collateral left in dutch route
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E4");

        // Take auction 0 to make it available for reuse
        uint256 _lenderBalanceBefore = borrowToken.balanceOf(userLender);
        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        // Verify receiver got the borrow tokens
        assertEq(borrowToken.balanceOf(userLender), _lenderBalanceBefore + _amountNeeded, "E5");

        // Verify auction 0 is now empty and not active
        assertEq(IAuction(_auction0).available(address(collateralToken)), 0, "E6");
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E7");

        // Third execution - should reuse auction 0 since it's now available
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        // Verify no collateral left in dutch route
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E8");

        // Should still only have 2 auctions total
        vm.expectRevert();
        dutchExchangeRoute.auctions(2);

        // Auction 0 should be active again
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E9");
    }

    function test_dutchExecute_exceedMaxAuctions() public {
        uint256 _maxAuctions = dutchExchangeRoute.MAX_AUCTIONS();
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();

        // Create MAX_AUCTIONS active auctions
        for (uint256 i = 0; i < _maxAuctions; i++) {
            airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
            vm.prank(address(exchangeHandler));
            dutchExchangeRoute.execute(_amount, userLender);

            // Verify auction was created
            address _auction = dutchExchangeRoute.auctions(i);
            assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E0");
        }

        // Try to create one more auction - should revert since we hit MAX_AUCTIONS limit
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.expectRevert("max_auctions");
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);
    }

    function test_dutchExecute_doesNotReuseAuctionWithPriceTooLow() public {
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();

        // First execution - creates auction 0
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        // Skip enough time so auction price is too low and auction becomes inactive
        skip(4 hours);

        // Auction should be inactive due to price too low
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E1");

        // But it should still have kickable collateral
        assertEq(IAuction(_auction0).kickable(address(collateralToken)), _amount, "E2");

        // Second execution should NOT reuse auction 0 since it has kickable collateral
        // It should create a new auction instead
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        // Should have created auction 1
        address _auction1 = dutchExchangeRoute.auctions(1);
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E3");
        assertNotEq(_auction0, _auction1, "E4");
    }

    function test_kickTrigger_priceTooLow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchExchangeRoute.MIN_AUCTION_AMOUNT(), dutchExchangeRoute.MAX_AUCTION_AMOUNT());

        // Create an auction
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);

        // Kick_trigger should be empty initially
        address[] memory _auctionsBefore = dutchExchangeRoute.kick_trigger();
        assertEq(_auctionsBefore.length, 0, "E0");

        // Skip time so price becomes too low
        skip(4 hours);

        // Auction should be inactive
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E1");

        // But should have kickable collateral
        assertEq(IAuction(_auction0).kickable(address(collateralToken)), _amount, "E2");

        // Now kick_trigger should include this auction
        address[] memory _auctionsAfter = dutchExchangeRoute.kick_trigger();
        assertEq(_auctionsAfter.length, 1, "E3");
        assertEq(_auctionsAfter[0], _auction0, "E4");
    }

    function test_kickTrigger_basefeeTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchExchangeRoute.MIN_AUCTION_AMOUNT(), dutchExchangeRoute.MAX_AUCTION_AMOUNT());

        // Create an auction and make price too low
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);

        // Skip time so price becomes too low
        skip(4 hours);

        // Verify auction needs to be kicked
        assertGt(IAuction(_auction0).kickable(address(collateralToken)), dutchExchangeRoute.DUST_THRESHOLD(), "E0");

        // Should be in kick_trigger list
        address[] memory _auctionsBefore = dutchExchangeRoute.kick_trigger();
        assertEq(_auctionsBefore.length, 1, "E1");

        // Set basefee too high
        vm.fee(dutchExchangeRoute.MAX_GAS_PRICE_TO_TRIGGER() + 1);

        // Now kick_trigger should return empty list due to high basefee
        address[] memory _auctionsAfter = dutchExchangeRoute.kick_trigger();
        assertEq(_auctionsAfter.length, 0, "E2");
    }

    function test_kickTrigger_multipleAuctions() public {
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();

        // Create 3 auctions
        for (uint256 i = 0; i < 3; i++) {
            airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
            vm.prank(address(exchangeHandler));
            dutchExchangeRoute.execute(_amount, userLender);
        }

        // Skip time so all prices become too low
        skip(4 hours);

        // All 3 auctions should be in kick_trigger list
        address[] memory _auctions = dutchExchangeRoute.kick_trigger();
        assertEq(_auctions.length, 3, "E0");
        assertEq(_auctions[0], dutchExchangeRoute.auctions(0), "E1");
        assertEq(_auctions[1], dutchExchangeRoute.auctions(1), "E2");
        assertEq(_auctions[2], dutchExchangeRoute.auctions(2), "E3");
    }

    function test_kickTrigger_ignoresDustAuctions(
        uint256 _dustAmount
    ) public {
        _dustAmount = bound(_dustAmount, 1, dutchExchangeRoute.DUST_THRESHOLD());

        // Create an auction through execute
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);

        // Take the full auction
        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        // Auction should not be active
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        // Someone externally adds dust and kicks it (malicious or accidental)
        airdrop(address(collateralToken), _auction0, _dustAmount);
        vm.prank(userBorrower);
        IAuction(_auction0).kick(address(collateralToken));

        // Auction should have kickable dust
        assertLe(IAuction(_auction0).kickable(address(collateralToken)), dutchExchangeRoute.DUST_THRESHOLD(), "E1");

        // kick_trigger should ignore this auction since it's below dust threshold
        address[] memory _auctions = dutchExchangeRoute.kick_trigger();
        assertEq(_auctions.length, 0, "E2");
    }

    function test_dutchExecute_reusesAuctionWithActiveDust() public {
        uint256 _dustAmount = dutchExchangeRoute.DUST_THRESHOLD();

        // Create auction 0
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);

        // Take most of auction 0, leaving dust
        uint256 _amountToTake = _amount - _dustAmount;
        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken), _amountToTake);
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken), _amountToTake, liquidator);
        vm.stopPrank();

        // Auction 0 should still be active but with dust amount
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");
        assertLe(IAuction(_auction0).available(address(collateralToken)), dutchExchangeRoute.DUST_THRESHOLD(), "E1");

        // Second execution SHOULD reuse auction 0 (dust is ignored)
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        // Should still only have 1 auction (reused auction 0)
        vm.expectRevert();
        dutchExchangeRoute.auctions(1);

        // Auction 0 should be active with new amount plus dust
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E2");
    }

    function test_dutchExecute_reusesAuctionWithKickableDust() public {
        uint256 _dustAmount = dutchExchangeRoute.DUST_THRESHOLD();

        // Create auction 0
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);

        // Take the auction fully
        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        // Auction should not be active
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        // Someone externally adds dust to the auction
        airdrop(address(collateralToken), _auction0, _dustAmount);

        // Auction should have kickable dust
        assertLe(IAuction(_auction0).kickable(address(collateralToken)), dutchExchangeRoute.DUST_THRESHOLD(), "E1");

        // Second execution SHOULD reuse auction 0 (dust is ignored)
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        // Should still only have 1 auction (reused auction 0)
        vm.expectRevert();
        dutchExchangeRoute.auctions(1);

        // Auction 0 should be active with new amount
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E2");
    }

    function test_kick(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchExchangeRoute.MIN_AUCTION_AMOUNT(), dutchExchangeRoute.MAX_AUCTION_AMOUNT());

        // Create an auction and make price too low
        airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
        vm.prank(address(exchangeHandler));
        dutchExchangeRoute.execute(_amount, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);

        // Skip time so price becomes too low
        skip(4 hours);

        // Get auctions to kick
        address[] memory _auctionsToKick = dutchExchangeRoute.kick_trigger();
        assertEq(_auctionsToKick.length, 1, "E0");

        // Kick as keeper
        vm.prank(keeper);
        dutchExchangeRoute.kick(_auctionsToKick);

        // Auction should be active again
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E1");

        // Check starting price is set with EMERGENCY buffer (100%)
        uint256 _expectedStartingPrice =
            _amount * priceOracle.price() / 1e18 * dutchExchangeRoute.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18;
        assertEq(IAuction(_auction0).startingPrice(), _expectedStartingPrice, "E2");

        // Check minimum price is set correctly
        uint256 _expectedMinimumPrice = priceOracle.price() * dutchExchangeRoute.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18;
        assertEq(IAuction(_auction0).minimumPrice(), _expectedMinimumPrice, "E3");
    }

    function test_kick_multipleAuctions() public {
        uint256 _amount = dutchExchangeRoute.MIN_AUCTION_AMOUNT();

        // Create 3 auctions
        for (uint256 i = 0; i < 3; i++) {
            airdrop(address(collateralToken), address(dutchExchangeRoute), _amount);
            vm.prank(address(exchangeHandler));
            dutchExchangeRoute.execute(_amount, userLender);
        }

        // Skip time so all prices become too low
        skip(4 hours);

        // Get all auctions to kick
        address[] memory _auctionsToKick = dutchExchangeRoute.kick_trigger();
        assertEq(_auctionsToKick.length, 3, "E0");

        // Kick all as keeper
        vm.prank(keeper);
        dutchExchangeRoute.kick(_auctionsToKick);

        // All should be active again
        for (uint256 i = 0; i < 3; i++) {
            address _auction = dutchExchangeRoute.auctions(i);
            assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E1");
        }
    }

    function test_kick_invalidCaller(
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != keeper);

        address[] memory _emptyArray = new address[](0);

        vm.expectRevert("!keeper");
        vm.prank(_invalidCaller);
        dutchExchangeRoute.kick(_emptyArray);
    }

    function test_setKeeper(
        address _newKeeper
    ) public {
        vm.prank(management);
        dutchExchangeRoute.set_keeper(_newKeeper);

        assertEq(dutchExchangeRoute.keeper(), _newKeeper, "E0");
    }

    function test_setKeeper_invalidCaller(
        address _notOwner,
        address _newKeeper
    ) public {
        vm.assume(_notOwner != management);

        vm.expectRevert("!owner");
        vm.prank(_notOwner);
        dutchExchangeRoute.set_keeper(_newKeeper);
    }

    function test_transferOwnership(
        address _newOwner
    ) public {
        vm.prank(management);
        dutchExchangeRoute.transfer_ownership(_newOwner);

        assertEq(dutchExchangeRoute.owner(), management, "E0");
        assertEq(dutchExchangeRoute.pending_owner(), _newOwner, "E1");

        vm.prank(_newOwner);
        dutchExchangeRoute.accept_ownership();

        assertEq(dutchExchangeRoute.owner(), _newOwner, "E2");
        assertEq(dutchExchangeRoute.pending_owner(), address(0), "E3");
    }

    function test_transferOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != management);

        vm.expectRevert("!owner");
        vm.prank(_invalidCaller);
        dutchExchangeRoute.transfer_ownership(_newOwner);
    }

    function test_acceptOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != _newOwner);

        vm.prank(management);
        dutchExchangeRoute.transfer_ownership(_newOwner);

        vm.expectRevert("!pending_owner");
        vm.prank(_invalidCaller);
        dutchExchangeRoute.accept_ownership();
    }

}
