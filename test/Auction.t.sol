// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract AuctionTests is Base {

    function setUp() public override {
        Base.setUp();

        // Adjust `maxFuzzAmount` to collateral token decimals
        uint256 _maxFuzzAmount = 1_000_000 ether;
        if (COLLATERAL_TOKEN_PRECISION < 1e18) maxFuzzAmount = _maxFuzzAmount / (1e18 / COLLATERAL_TOKEN_PRECISION);
        else maxFuzzAmount = _maxFuzzAmount;

        // Adjust `minFuzzAmount` to collateral token decimals
        uint256 _minFuzzAmount = 0.001 ether;
        if (COLLATERAL_TOKEN_PRECISION < 1e18) minFuzzAmount = _minFuzzAmount / (1e18 / COLLATERAL_TOKEN_PRECISION);
        else minFuzzAmount = _minFuzzAmount;
    }

    function test_setup() public {
        assertEq(auction.PAPI(), address(dutchDesk), "E0");
        assertEq(auction.BUY_TOKEN(), address(borrowToken), "E1");
        assertEq(auction.SELL_TOKEN(), address(collateralToken), "E2");
        assertEq(auction.STEP_DURATION(), 60, "E3");
        assertEq(auction.STEP_DECAY_RATE(), 50, "E4");
        assertEq(auction.AUCTION_LENGTH(), 1 days, "E4");
        assertEq(auction.liquidation_auctions(), 0, "E5");
    }

    function test_kick(
        uint256 _auctionId,
        uint256 _kickAmount,
        uint256 _startingPrice,
        uint256 _minimumPrice
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);
        _startingPrice = bound(_startingPrice, 1e18, 100e18);
        _minimumPrice = bound(_minimumPrice, 1e17, _startingPrice);

        // Airdrop collateral to dutchDesk (PAPI)
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);

        // Kick auction as dutchDesk
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, _startingPrice, _minimumPrice, userLender, false);

        // Check auction state
        assertTrue(auction.is_active(_auctionId), "E0");
        assertEq(auction.kick_timestamp(_auctionId), block.timestamp, "E1");
        assertEq(auction.initial_amount(_auctionId), _kickAmount, "E2");
        assertEq(auction.current_amount(_auctionId), _kickAmount, "E3");
        assertEq(auction.starting_price(_auctionId), _startingPrice, "E4");
        assertEq(auction.minimum_price(_auctionId), _minimumPrice, "E5");
        assertEq(auction.receiver(_auctionId), userLender, "E6");
        assertFalse(auction.is_liquidation(_auctionId), "E7");
        assertFalse(auction.is_ongoing_liquidation_auction(), "E8");
        assertEq(auction.liquidation_auctions(), 0, "E9");
        assertEq(collateralToken.balanceOf(address(auction)), _kickAmount, "E10");
    }

    function test_kick_liquidation(
        uint256 _auctionId,
        uint256 _kickAmount,
        uint256 _startingPrice,
        uint256 _minimumPrice
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);
        _startingPrice = bound(_startingPrice, 1e18, 100e18);
        _minimumPrice = bound(_minimumPrice, 1e17, _startingPrice);

        // Airdrop collateral to dutchDesk
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);

        // Kick liquidation auction
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, _startingPrice, _minimumPrice, userLender, true);

        // Check liquidation state
        assertTrue(auction.is_active(_auctionId), "E0");
        assertTrue(auction.is_liquidation(_auctionId), "E1");
        assertTrue(auction.is_ongoing_liquidation_auction(), "E2");
        assertEq(auction.liquidation_auctions(), 1, "E3");
    }

    function test_kick_notPapi(
        uint256 _auctionId,
        uint256 _kickAmount,
        uint256 _startingPrice,
        uint256 _minimumPrice
    ) public {
        vm.assume(_kickAmount > 0);
        vm.assume(_startingPrice > 0);
        vm.assume(_minimumPrice > 0);

        // Should revert when called by non-PAPI
        vm.prank(userBorrower);
        vm.expectRevert("!papi");
        auction.kick(_auctionId, _kickAmount, _startingPrice, _minimumPrice, userLender, false);
    }

    function test_kick_zeroAmount(
        uint256 _auctionId
    ) public {
        vm.prank(address(dutchDesk));
        vm.expectRevert("!kick_amount");
        auction.kick(_auctionId, 0, 1e18, 1e17, userLender, false);
    }

    function test_kick_zeroStartingPrice(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        vm.assume(_kickAmount > 0);

        vm.prank(address(dutchDesk));
        vm.expectRevert("!starting_price");
        auction.kick(_auctionId, _kickAmount, 0, 1e17, userLender, false);
    }

    function test_kick_zeroMinimumPrice(
        uint256 _auctionId,
        uint256 _kickAmount,
        uint256 _startingPrice
    ) public {
        vm.assume(_kickAmount > 0);
        vm.assume(_startingPrice > 0);

        vm.prank(address(dutchDesk));
        vm.expectRevert("!minimum_price");
        auction.kick(_auctionId, _kickAmount, _startingPrice, 0, userLender, false);
    }

    function test_kick_zeroReceiver(
        uint256 _auctionId,
        uint256 _kickAmount,
        uint256 _startingPrice,
        uint256 _minimumPrice
    ) public {
        vm.assume(_kickAmount > 0);
        vm.assume(_startingPrice > 0);
        vm.assume(_minimumPrice > 0);

        vm.prank(address(dutchDesk));
        vm.expectRevert("!receiver");
        auction.kick(_auctionId, _kickAmount, _startingPrice, _minimumPrice, address(0), false);
    }

    function test_kick_auctionAlreadyActive(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop enough for two kicks
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount * 2);

        // First kick succeeds
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Second kick on same ID should revert
        vm.prank(address(dutchDesk));
        vm.expectRevert("active");
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);
    }

    function test_reKick(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip past auction duration so it becomes inactive
        skip(auction.AUCTION_LENGTH() + 1);

        // Verify auction is inactive but has kickable amount
        assertFalse(auction.is_active(_auctionId), "E0");
        assertEq(auction.get_kickable_amount(_auctionId), _kickAmount, "E1");

        // Re-kick with new prices
        vm.prank(address(dutchDesk));
        auction.re_kick(_auctionId, 2e18, 2e17);

        // Verify auction is active again with updated prices
        assertTrue(auction.is_active(_auctionId), "E2");
        assertEq(auction.current_amount(_auctionId), _kickAmount, "E3");
        assertEq(auction.kick_timestamp(_auctionId), block.timestamp, "E4");
        assertEq(auction.starting_price(_auctionId), 2e18, "E5");
        assertEq(auction.minimum_price(_auctionId), 2e17, "E6");
    }

    function test_reKick_notPapi(
        uint256 _auctionId
    ) public {
        vm.prank(userBorrower);
        vm.expectRevert("!papi");
        auction.re_kick(_auctionId, 1e18, 1e17);
    }

    function test_reKick_auctionStillActive(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Try to re-kick while still active - should revert
        vm.prank(address(dutchDesk));
        vm.expectRevert("active");
        auction.re_kick(_auctionId, 2e18, 2e17);
    }

    function test_reKick_noAmountToKick(
        uint256 _auctionId
    ) public {
        // Try to re-kick auction that was never kicked
        vm.prank(address(dutchDesk));
        vm.expectRevert("!current_amount");
        auction.re_kick(_auctionId, 1e18, 1e17);
    }

    function test_reKick_zeroStartingPrice(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip past auction duration so it becomes inactive
        skip(auction.AUCTION_LENGTH() + 1);

        // Try to re-kick with zero starting price - should revert
        vm.prank(address(dutchDesk));
        vm.expectRevert("!starting_price");
        auction.re_kick(_auctionId, 0, 1e17);
    }

    function test_reKick_zeroMinimumPrice(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip past auction duration so it becomes inactive
        skip(auction.AUCTION_LENGTH() + 1);

        // Try to re-kick with zero minimum price - should revert
        vm.prank(address(dutchDesk));
        vm.expectRevert("!minimum_price");
        auction.re_kick(_auctionId, 1e18, 0);
    }

    function test_take(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip some time to let price decay
        skip(auction.STEP_DURATION() * 10);

        // Get needed amount and airdrop to liquidator
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp);
        airdrop(address(borrowToken), liquidator, _neededAmount);

        // Take auction
        vm.startPrank(liquidator);
        borrowToken.approve(address(auction), _neededAmount);
        auction.take(_auctionId, type(uint256).max, liquidator, "");
        vm.stopPrank();

        // Verify auction is complete
        assertFalse(auction.is_active(_auctionId), "E0");
        assertEq(auction.current_amount(_auctionId), 0, "E1");
        assertEq(auction.kick_timestamp(_auctionId), 0, "E2");

        // Verify token transfers
        assertEq(collateralToken.balanceOf(liquidator), _kickAmount, "E3");
        assertEq(borrowToken.balanceOf(userLender), _neededAmount, "E4");
    }

    function test_take_partialTake(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount * 2, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip some time
        skip(auction.STEP_DURATION() * 10);

        // Take only half
        uint256 _takeAmount = _kickAmount / 2;
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, _takeAmount, block.timestamp);
        airdrop(address(borrowToken), liquidator, _neededAmount);

        vm.startPrank(liquidator);
        borrowToken.approve(address(auction), _neededAmount);
        auction.take(_auctionId, _takeAmount, liquidator, "");
        vm.stopPrank();

        // Verify auction is still active with remaining amount
        assertTrue(auction.is_active(_auctionId), "E0");
        assertEq(auction.current_amount(_auctionId), _kickAmount - _takeAmount, "E1");
        assertEq(collateralToken.balanceOf(liquidator), _takeAmount, "E2");
    }

    function test_take_notActive(
        uint256 _auctionId
    ) public {
        // Try to take from non-existent auction
        vm.prank(liquidator);
        vm.expectRevert("!active");
        auction.take(_auctionId, type(uint256).max, liquidator, "");
    }

    function test_take_zeroNeededAmount(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Try to take 0 amount
        vm.prank(liquidator);
        vm.expectRevert("!needed_amount");
        auction.take(_auctionId, 0, liquidator, "");
    }

    function test_take_liquidationDecreasesCounter(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick as liquidation
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, true);

        // Verify liquidation counter incremented
        assertEq(auction.liquidation_auctions(), 1, "E0");
        assertTrue(auction.is_ongoing_liquidation_auction(), "E1");

        // Skip time and take
        skip(auction.STEP_DURATION() * 10);
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp);
        airdrop(address(borrowToken), liquidator, _neededAmount);

        vm.startPrank(liquidator);
        borrowToken.approve(address(auction), _neededAmount);
        auction.take(_auctionId, type(uint256).max, liquidator, "");
        vm.stopPrank();

        // Verify liquidation counter decremented
        assertEq(auction.liquidation_auctions(), 0, "E2");
        assertFalse(auction.is_ongoing_liquidation_auction(), "E3");
    }

    function test_priceDecay(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Get initial price
        uint256 _initialPrice = auction.get_price(_auctionId, block.timestamp);

        // Skip one step duration
        skip(auction.STEP_DURATION());

        // Verify price decayed by ~0.5%
        uint256 _priceAfterOneStep = auction.get_price(_auctionId, block.timestamp);
        assertLt(_priceAfterOneStep, _initialPrice, "E0");

        uint256 _expectedPrice = _initialPrice * (10000 - auction.STEP_DECAY_RATE()) / 10000;
        assertApproxEqRel(_priceAfterOneStep, _expectedPrice, 1e15, "E1");

        // Skip more steps
        skip(auction.STEP_DURATION() * 10);

        // Verify continued decay
        uint256 _priceAfterManySteps = auction.get_price(_auctionId, block.timestamp);
        assertLt(_priceAfterManySteps, _priceAfterOneStep, "E2");
    }

    function test_priceDecay_becomesInactiveAtMinimum(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Verify auction is active
        assertTrue(auction.is_active(_auctionId), "E0");

        // Skip past auction duration
        skip(auction.AUCTION_LENGTH() + 1);

        // Verify auction is inactive with 0 price
        assertFalse(auction.is_active(_auctionId), "E1");
        assertEq(auction.get_price(_auctionId, block.timestamp), 0, "E2");
        assertEq(auction.get_available_amount(_auctionId), 0, "E3");
        assertGt(auction.get_kickable_amount(_auctionId), 0, "E4");
    }

    function test_getAvailableAmount(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Before kick, available amount should be 0
        assertEq(auction.get_available_amount(_auctionId), 0, "E0");

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // After kick, available amount should equal kick amount
        assertEq(auction.get_available_amount(_auctionId), _kickAmount, "E1");

        // After expiration, available amount should be 0
        skip(auction.AUCTION_LENGTH() + 1);
        assertEq(auction.get_available_amount(_auctionId), 0, "E2");
    }

    function test_getKickableAmount(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Before kick, kickable amount should be 0
        assertEq(auction.get_kickable_amount(_auctionId), 0, "E0");

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // While active, kickable amount should be 0
        assertEq(auction.get_kickable_amount(_auctionId), 0, "E1");

        // After expiration, kickable amount should equal current amount
        skip(auction.AUCTION_LENGTH() + 1);
        assertEq(auction.get_kickable_amount(_auctionId), _kickAmount, "E2");
    }

    function test_getNeededAmount(
        uint256 _auctionId,
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount, maxFuzzAmount);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Get needed amount for full take
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, _kickAmount, block.timestamp);
        assertGt(_neededAmount, 0, "E0");

        // Partial take should need less
        uint256 _partialNeeded = auction.get_needed_amount(_auctionId, _kickAmount / 2, block.timestamp);
        assertLt(_partialNeeded, _neededAmount, "E1");

        // After price decay, needed amount should be less
        skip(auction.STEP_DURATION() * 10);
        uint256 _neededAmountLater = auction.get_needed_amount(_auctionId, _kickAmount, block.timestamp);
        assertLt(_neededAmountLater, _neededAmount, "E2");
    }

    function test_reentrancy_take(
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount * 2, maxFuzzAmount);
        uint256 _auctionId = 1;

        // Deploy malicious taker that tries to re-enter take()
        ReentrantTaker _maliciousTaker = new ReentrantTaker(address(auction), address(borrowToken), ReentrantTaker.AttackType.Take);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip some time to let price decay
        skip(auction.STEP_DURATION() * 10);

        // Get needed amount for partial take and airdrop to malicious taker
        uint256 _takeAmount = _kickAmount / 2;
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, _takeAmount, block.timestamp);
        airdrop(address(borrowToken), address(_maliciousTaker), _neededAmount * 2);

        // Set up the malicious taker
        _maliciousTaker.setAuctionId(_auctionId);
        _maliciousTaker.setTakeAmount(_takeAmount);

        // Attempt to take - should revert due to reentrancy protection
        vm.expectRevert();
        _maliciousTaker.executeTake(_auctionId, _takeAmount);
    }

    function test_reentrancy_kick(
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount * 2, maxFuzzAmount);
        uint256 _auctionId = 1;

        // Deploy malicious taker that tries to call kick() during callback
        ReentrantTaker _maliciousTaker = new ReentrantTaker(address(auction), address(borrowToken), ReentrantTaker.AttackType.Kick);

        // Airdrop collateral to dutchDesk and malicious taker
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        airdrop(address(collateralToken), address(_maliciousTaker), _kickAmount);

        // Kick auction
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip some time
        skip(auction.STEP_DURATION() * 10);

        // Get needed amount and airdrop to malicious taker
        uint256 _takeAmount = _kickAmount / 2;
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, _takeAmount, block.timestamp);
        airdrop(address(borrowToken), address(_maliciousTaker), _neededAmount);

        // Set up malicious taker to try to kick a new auction during callback
        _maliciousTaker.setAuctionId(2);
        _maliciousTaker.setTakeAmount(_takeAmount);

        // Attempt to take - should revert due to reentrancy protection
        vm.expectRevert();
        _maliciousTaker.executeTake(_auctionId, _takeAmount);
    }

    function test_reentrancy_reKick(
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount * 2, maxFuzzAmount);
        uint256 _auctionId = 1;

        // Deploy malicious taker that tries to call re_kick() during callback
        ReentrantTaker _maliciousTaker = new ReentrantTaker(address(auction), address(borrowToken), ReentrantTaker.AttackType.ReKick);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip some time
        skip(auction.STEP_DURATION() * 10);

        // Get needed amount and airdrop to malicious taker
        uint256 _takeAmount = _kickAmount / 2;
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, _takeAmount, block.timestamp);
        airdrop(address(borrowToken), address(_maliciousTaker), _neededAmount);

        // Set up malicious taker
        _maliciousTaker.setAuctionId(_auctionId);
        _maliciousTaker.setTakeAmount(_takeAmount);

        // Attempt to take - should revert due to reentrancy protection
        vm.expectRevert();
        _maliciousTaker.executeTake(_auctionId, _takeAmount);
    }

    function test_reentrancy_viewFunctions(
        uint256 _kickAmount
    ) public {
        _kickAmount = bound(_kickAmount, minFuzzAmount * 2, maxFuzzAmount);
        uint256 _auctionId = 1;

        // Deploy malicious taker that tries to call view functions during callback
        ReentrantTaker _maliciousTaker = new ReentrantTaker(address(auction), address(borrowToken), ReentrantTaker.AttackType.ViewFunctions);

        // Airdrop and kick
        airdrop(address(collateralToken), address(dutchDesk), _kickAmount);
        vm.prank(address(dutchDesk));
        auction.kick(_auctionId, _kickAmount, 1e18, 1e17, userLender, false);

        // Skip some time
        skip(auction.STEP_DURATION() * 10);

        // Get needed amount and airdrop to malicious taker
        uint256 _takeAmount = _kickAmount / 2;
        uint256 _neededAmount = auction.get_needed_amount(_auctionId, _takeAmount, block.timestamp);
        airdrop(address(borrowToken), address(_maliciousTaker), _neededAmount);

        // Set up malicious taker
        _maliciousTaker.setAuctionId(_auctionId);
        _maliciousTaker.setTakeAmount(_takeAmount);

        // Attempt to take - should revert due to reentrancy protection on view functions
        vm.expectRevert();
        _maliciousTaker.executeTake(_auctionId, _takeAmount);
    }

}

contract ReentrantTaker {

    enum AttackType {
        Take,
        Kick,
        ReKick,
        ViewFunctions
    }

    IAuction public auction;
    IERC20 public borrowToken;
    AttackType public attackType;
    uint256 public auctionId;
    uint256 public takeAmount;

    constructor(
        address _auction,
        address _borrowToken,
        AttackType _attackType
    ) {
        auction = IAuction(_auction);
        borrowToken = IERC20(_borrowToken);
        attackType = _attackType;
        borrowToken.approve(_auction, type(uint256).max);
    }

    function setAuctionId(
        uint256 _auctionId
    ) external {
        auctionId = _auctionId;
    }

    function setTakeAmount(
        uint256 _takeAmount
    ) external {
        takeAmount = _takeAmount;
    }

    function executeTake(
        uint256 _auctionId,
        uint256 _maxAmount
    ) external {
        // Pass non-empty data to trigger callback
        auction.take(_auctionId, _maxAmount, address(this), "attack");
    }

    function auctionTakeCallback(
        uint256,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external {
        // Try to re-enter based on attack type
        if (attackType == AttackType.Take) {
            auction.take(auctionId, takeAmount, address(this), "");
        } else if (attackType == AttackType.Kick) {
            auction.kick(auctionId, 1e18, 1e18, 1e17, address(this), false);
        } else if (attackType == AttackType.ReKick) {
            auction.re_kick(auctionId, 2e18, 2e17);
        } else if (attackType == AttackType.ViewFunctions) {
            // Try to call view functions - these should also be protected
            auction.get_available_amount(auctionId);
        }
    }

}
