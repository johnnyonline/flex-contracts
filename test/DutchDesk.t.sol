// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract DutchDeskTests is Base {

    IAuction public liquidationAuction;

    function setUp() public override {
        Base.setUp();

        vm.prank(management);
        dutchDesk.accept_ownership();

        liquidationAuction = IAuction(dutchDesk.LIQUIDATION_AUCTION());

        // Adjust `maxFuzzAmount` to collateral token decimals
        uint256 _maxFuzzAmount = 1_000_000 ether;
        if (COLLATERAL_TOKEN_PRECISION < 1e18) maxFuzzAmount = _maxFuzzAmount / (1e18 / COLLATERAL_TOKEN_PRECISION);
        else maxFuzzAmount = _maxFuzzAmount;
    }

    function test_setup() public {
        assertEq(dutchDesk.owner(), management, "E0");
        assertEq(dutchDesk.pending_owner(), address(0), "E1");
        assertEq(dutchDesk.TROVE_MANAGER(), address(troveManager), "E2");
        assertEq(dutchDesk.PRICE_ORACLE(), address(priceOracle), "E3");
        assertEq(dutchDesk.AUCTION_FACTORY(), auctionFactory, "E4");
        assertEq(dutchDesk.BORROW_TOKEN(), address(borrowToken), "E5");
        assertEq(dutchDesk.COLLATERAL_TOKEN(), address(collateralToken), "E6");
        assertEq(dutchDesk.DUST_THRESHOLD(), dustThreshold, "E7");
        assertEq(dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE(), 1e18 + 15e16, "E8"); // 115%
        assertEq(dutchDesk.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE(), 1e18 + 100e16, "E9"); // 200%
        assertEq(dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE(), 1e18 - 5e16, "E10"); // 95%
        assertEq(dutchDesk.MAX_GAS_PRICE_TO_TRIGGER(), 50e9, "E11"); // 50 gwei
        assertEq(dutchDesk.MAX_AUCTIONS(), 20, "E12");
        assertEq(dutchDesk.keeper(), keeper, "E13");
        assertNotEq(dutchDesk.LIQUIDATION_AUCTION(), address(0), "E14");
        assertEq(liquidationAuction.receiver(), address(lender), "E15");
        assertEq(liquidationAuction.want(), address(borrowToken), "E16");
        assertEq(liquidationAuction.getAllEnabledAuctions()[0], address(collateralToken), "E17");
        assertEq(dutchDesk.emergency_kick_trigger(false).length, 0, "E18");
        assertEq(dutchDesk.emergency_kick_trigger(true).length, 0, "E19");
        vm.expectRevert();
        dutchDesk.auctions(0);
    }

    function test_kick_liquidation(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);

        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        assertTrue(liquidationAuction.isActive(address(collateralToken)), "E0");
        assertEq(liquidationAuction.available(address(collateralToken)), _amount, "E1");

        uint256 _expectedStartingPrice =
            _amount * priceOracle.price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(liquidationAuction.startingPrice(), _expectedStartingPrice, "E2");

        uint256 _expectedMinimumPrice = priceOracle.price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(liquidationAuction.minimumPrice(), _expectedMinimumPrice, "E3");

        assertEq(liquidationAuction.receiver(), address(lender), "E4");
    }

    function test_kick_liquidation_zeroAmount() public {
        vm.prank(address(troveManager));
        dutchDesk.kick(0, address(0), false);

        assertFalse(liquidationAuction.isActive(address(collateralToken)), "E0");
    }

    function test_kick_liquidation_activeAuction(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount / 2);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        assertTrue(liquidationAuction.isActive(address(collateralToken)), "E0");
        assertEq(liquidationAuction.available(address(collateralToken)), _amount, "E1");

        uint256 _startingPriceBefore = liquidationAuction.startingPrice();

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        assertTrue(liquidationAuction.isActive(address(collateralToken)), "E2");
        assertEq(liquidationAuction.available(address(collateralToken)), _amount * 2, "E3");
        assertApproxEqAbs(liquidationAuction.startingPrice(), _startingPriceBefore * 2, 1, "E4");
    }

    function test_take_liquidation_goesToLender(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);

        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        uint256 _amountNeeded = liquidationAuction.getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);

        vm.startPrank(liquidator);
        borrowToken.approve(address(liquidationAuction), _amountNeeded);
        liquidationAuction.take(address(collateralToken));
        vm.stopPrank();

        assertEq(liquidationAuction.available(address(collateralToken)), 0, "E0");
        assertEq(borrowToken.balanceOf(address(lender)), _amountNeeded, "E1");
    }

    function test_kick_redemption(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);

        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction = dutchDesk.auctions(0);
        assertTrue(_auction != address(0), "E0");
        assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E1");
        assertEq(IAuction(_auction).available(address(collateralToken)), _amount, "E2");

        uint256 _expectedStartingPrice =
            _amount * priceOracle.price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(IAuction(_auction).startingPrice(), _expectedStartingPrice, "E3");

        uint256 _expectedMinimumPrice = priceOracle.price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(IAuction(_auction).minimumPrice(), _expectedMinimumPrice, "E4");

        assertEq(IAuction(_auction).receiver(), userLender, "E5");
    }

    function test_kick_redemption_multipleAuctions_reusesWhenAvailable() public {
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E1");

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction1 = dutchDesk.auctions(1);
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E2");
        assertNotEq(_auction0, _auction1, "E3");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E4");

        uint256 _lenderBalanceBefore = borrowToken.balanceOf(userLender);
        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        assertEq(borrowToken.balanceOf(userLender), _lenderBalanceBefore + _amountNeeded, "E5");
        assertEq(IAuction(_auction0).available(address(collateralToken)), 0, "E6");
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E7");

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E8");

        vm.expectRevert();
        dutchDesk.auctions(2);

        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E9");
    }

    function test_kick_redemption_exceedMaxAuctions() public {
        uint256 _maxAuctions = dutchDesk.MAX_AUCTIONS();
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;

        for (uint256 i = 0; i < _maxAuctions; i++) {
            airdrop(address(collateralToken), address(dutchDesk), _amount);
            vm.prank(address(troveManager));
            dutchDesk.kick(_amount, userLender, true);

            address _auction = dutchDesk.auctions(i);
            assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E0");
        }

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.expectRevert("max_auctions");
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        // Settle one auction and verify we can kick again
        address _auctionToSettle = dutchDesk.auctions(0);
        uint256 _amountNeeded = IAuction(_auctionToSettle).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auctionToSettle, _amountNeeded);
        IAuction(_auctionToSettle).take(address(collateralToken), _amount, liquidator);
        vm.stopPrank();

        // Now we should be able to kick again
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);
        assertTrue(IAuction(_auctionToSettle).isActive(address(collateralToken)), "E1");
    }

    function test_kick_redemption_doesNotReuseAuctionWithPriceTooLow() public {
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        skip(4 hours);

        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E1");
        assertEq(IAuction(_auction0).kickable(address(collateralToken)), _amount, "E2");

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction1 = dutchDesk.auctions(1);
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E3");
        assertNotEq(_auction0, _auction1, "E4");
    }

    function test_kick_redemption_createsNewAuctionWithActiveDust() public {
        uint256 _dustAmount = dutchDesk.DUST_THRESHOLD();
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + COLLATERAL_TOKEN_PRECISION;

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);

        uint256 _amountToTake = _amount - _dustAmount;
        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken), _amountToTake);
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken), _amountToTake, liquidator);
        vm.stopPrank();

        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");
        assertLe(IAuction(_auction0).available(address(collateralToken)), dutchDesk.DUST_THRESHOLD(), "E1");

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        // Even with dust remaining, a new auction should be created since the first is still active
        address _auction1 = dutchDesk.auctions(1);
        assertNotEq(_auction0, _auction1, "E2");
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E3");
    }

    function test_kick_redemption_reusesAuctionWithKickableDust() public {
        uint256 _dustAmount = dutchDesk.DUST_THRESHOLD();
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);

        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        airdrop(address(collateralToken), _auction0, _dustAmount);

        assertLe(IAuction(_auction0).kickable(address(collateralToken)), dutchDesk.DUST_THRESHOLD(), "E1");

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        vm.expectRevert();
        dutchDesk.auctions(1);

        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E2");
    }

    function test_emergencyKickTrigger_liquidation_priceTooLow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        address[] memory _auctionsBefore = dutchDesk.emergency_kick_trigger(false);
        assertEq(_auctionsBefore.length, 0, "E0");

        skip(4 hours);

        assertFalse(liquidationAuction.isActive(address(collateralToken)), "E1");
        assertEq(liquidationAuction.kickable(address(collateralToken)), _amount, "E2");

        address[] memory _auctionsAfter = dutchDesk.emergency_kick_trigger(false);
        assertEq(_auctionsAfter.length, 1, "E3");
        assertEq(_auctionsAfter[0], address(liquidationAuction), "E4");
    }

    function test_emergencyKickTrigger_redemption_priceTooLow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);

        address[] memory _auctionsBefore = dutchDesk.emergency_kick_trigger(true);
        assertEq(_auctionsBefore.length, 0, "E0");

        skip(4 hours);

        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E1");
        assertEq(IAuction(_auction0).kickable(address(collateralToken)), _amount, "E2");

        address[] memory _auctionsAfter = dutchDesk.emergency_kick_trigger(true);
        assertEq(_auctionsAfter.length, 1, "E3");
        assertEq(_auctionsAfter[0], _auction0, "E4");
    }

    function test_emergencyKickTrigger_basefeeTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        skip(4 hours);

        assertGt(liquidationAuction.kickable(address(collateralToken)), dutchDesk.DUST_THRESHOLD(), "E0");

        address[] memory _auctionsBefore = dutchDesk.emergency_kick_trigger(false);
        assertEq(_auctionsBefore.length, 1, "E1");

        vm.fee(dutchDesk.MAX_GAS_PRICE_TO_TRIGGER() + 1);

        address[] memory _auctionsAfter = dutchDesk.emergency_kick_trigger(false);
        assertEq(_auctionsAfter.length, 0, "E2");
    }

    function test_emergencyKickTrigger_multipleRedemptionAuctions() public {
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;

        for (uint256 i = 0; i < 3; i++) {
            airdrop(address(collateralToken), address(dutchDesk), _amount);
            vm.prank(address(troveManager));
            dutchDesk.kick(_amount, userLender, true);
        }

        skip(4 hours);

        address[] memory _auctions = dutchDesk.emergency_kick_trigger(true);
        assertEq(_auctions.length, 3, "E0");
        assertEq(_auctions[0], dutchDesk.auctions(0), "E1");
        assertEq(_auctions[1], dutchDesk.auctions(1), "E2");
        assertEq(_auctions[2], dutchDesk.auctions(2), "E3");
    }

    function test_emergencyKickTrigger_ignoresDustAuctions(
        uint256 _dustAmount
    ) public {
        _dustAmount = bound(_dustAmount, 1, dutchDesk.DUST_THRESHOLD());

        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;
        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);

        uint256 _amountNeeded = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        airdrop(address(collateralToken), _auction0, _dustAmount);
        vm.prank(address(dutchDesk));
        IAuction(_auction0).kick(address(collateralToken));

        assertLe(IAuction(_auction0).kickable(address(collateralToken)), dutchDesk.DUST_THRESHOLD(), "E1");

        address[] memory _auctions = dutchDesk.emergency_kick_trigger(true);
        assertEq(_auctions.length, 0, "E2");
    }

    function test_emergencyKick_liquidation(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, address(0), false);

        skip(4 hours);

        address[] memory _auctionsToKick = dutchDesk.emergency_kick_trigger(false);
        assertEq(_auctionsToKick.length, 1, "E0");

        vm.prank(keeper);
        dutchDesk.emergency_kick(_auctionsToKick);

        assertTrue(liquidationAuction.isActive(address(collateralToken)), "E1");

        uint256 _expectedStartingPrice =
            _amount * priceOracle.price(false) / WAD * dutchDesk.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(liquidationAuction.startingPrice(), _expectedStartingPrice, "E2");

        uint256 _expectedMinimumPrice = priceOracle.price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(liquidationAuction.minimumPrice(), _expectedMinimumPrice, "E3");
    }

    function test_emergencyKick_redemption(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);

        skip(4 hours);

        address[] memory _auctionsToKick = dutchDesk.emergency_kick_trigger(true);
        assertEq(_auctionsToKick.length, 1, "E0");

        vm.prank(keeper);
        dutchDesk.emergency_kick(_auctionsToKick);

        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E1");

        uint256 _expectedStartingPrice =
            _amount * priceOracle.price(false) / WAD * dutchDesk.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(IAuction(_auction0).startingPrice(), _expectedStartingPrice, "E2");

        uint256 _expectedMinimumPrice = priceOracle.price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(IAuction(_auction0).minimumPrice(), _expectedMinimumPrice, "E3");
    }

    function test_emergencyKick_multipleRedemptionAuctions() public {
        uint256 _amount = dutchDesk.DUST_THRESHOLD() + 1;

        for (uint256 i = 0; i < 3; i++) {
            airdrop(address(collateralToken), address(dutchDesk), _amount);
            vm.prank(address(troveManager));
            dutchDesk.kick(_amount, userLender, true);
        }

        skip(4 hours);

        address[] memory _auctionsToKick = dutchDesk.emergency_kick_trigger(true);
        assertEq(_auctionsToKick.length, 3, "E0");

        vm.prank(keeper);
        dutchDesk.emergency_kick(_auctionsToKick);

        for (uint256 i = 0; i < 3; i++) {
            address _auction = dutchDesk.auctions(i);
            assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E1");
        }
    }

    function test_emergencyKick_invalidCaller(
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != keeper);

        address[] memory _emptyArray = new address[](0);

        vm.expectRevert("!keeper");
        vm.prank(_invalidCaller);
        dutchDesk.emergency_kick(_emptyArray);
    }

    function test_emergencyKick_notKickable(
        uint256 _amount
    ) public {
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _auction0 = dutchDesk.auctions(0);

        // Auction is active but not kickable (no time has passed, price hasn't dropped)
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");
        assertEq(IAuction(_auction0).kickable(address(collateralToken)), 0, "E1");

        // Try to emergency kick an auction that isn't kickable
        address[] memory _auctionsToKick = new address[](1);
        _auctionsToKick[0] = _auction0;

        vm.expectRevert("!kickable");
        vm.prank(keeper);
        dutchDesk.emergency_kick(_auctionsToKick);
    }

    function test_kick_invalidCaller(
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != address(troveManager) && _invalidCaller != address(dutchDesk));

        vm.expectRevert("!trove_manager");
        vm.prank(_invalidCaller);
        dutchDesk.kick(0, userLender, false);
    }

    function test_auctionKick_onlyDutchDesk(
        address _invalidCaller,
        uint256 _amount
    ) public {
        vm.assume(_invalidCaller != address(dutchDesk));
        _amount = bound(_amount, dutchDesk.DUST_THRESHOLD() + 1, maxFuzzAmount);

        // 1. Test LIQUIDATION_AUCTION can only be kicked by dutchDesk
        IAuction _liquidationAuction = IAuction(dutchDesk.LIQUIDATION_AUCTION());
        airdrop(address(collateralToken), address(_liquidationAuction), _amount);
        vm.expectRevert("!governance");
        vm.prank(_invalidCaller);
        _liquidationAuction.kick(address(collateralToken));

        // 2. Test redemption auction can only be kicked by dutchDesk
        // First create a redemption auction
        airdrop(address(collateralToken), address(dutchDesk), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, userLender, true);

        address _redemptionAuction = dutchDesk.auctions(0);
        assertTrue(_redemptionAuction != address(0), "E1");

        // Take the redemption auction so we can try to kick it again
        uint256 _amountNeeded = IAuction(_redemptionAuction).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_redemptionAuction, _amountNeeded);
        IAuction(_redemptionAuction).take(address(collateralToken), _amount, liquidator);
        vm.stopPrank();

        // Try to kick redemption auction directly - should fail
        vm.expectRevert("!governance");
        vm.prank(_invalidCaller);
        IAuction(_redemptionAuction).kick(address(collateralToken));
    }

    function test_setKeeper(
        address _newKeeper
    ) public {
        vm.prank(management);
        dutchDesk.set_keeper(_newKeeper);

        assertEq(dutchDesk.keeper(), _newKeeper, "E0");
    }

    function test_setKeeper_invalidCaller(
        address _notOwner,
        address _newKeeper
    ) public {
        vm.assume(_notOwner != management);

        vm.expectRevert("!owner");
        vm.prank(_notOwner);
        dutchDesk.set_keeper(_newKeeper);
    }

    function test_transferOwnership(
        address _newOwner
    ) public {
        vm.prank(management);
        dutchDesk.transfer_ownership(_newOwner);

        assertEq(dutchDesk.owner(), management, "E0");
        assertEq(dutchDesk.pending_owner(), _newOwner, "E1");

        vm.prank(_newOwner);
        dutchDesk.accept_ownership();

        assertEq(dutchDesk.owner(), _newOwner, "E2");
        assertEq(dutchDesk.pending_owner(), address(0), "E3");
    }

    function test_transferOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != management);

        vm.expectRevert("!owner");
        vm.prank(_invalidCaller);
        dutchDesk.transfer_ownership(_newOwner);
    }

    function test_acceptOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != _newOwner);

        vm.prank(management);
        dutchDesk.transfer_ownership(_newOwner);

        vm.expectRevert("!pending_owner");
        vm.prank(_invalidCaller);
        dutchDesk.accept_ownership();
    }

}
