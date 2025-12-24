// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract DutchDeskTests is Base {

    function setUp() public override {
        Base.setUp();

        vm.prank(management);
        dutchDesk.accept_ownership();

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
        assertEq(dutchDesk.owner(), management, "E0");
        assertEq(dutchDesk.pending_owner(), address(0), "E1");
        assertEq(dutchDesk.TROVE_MANAGER(), address(troveManager), "E2");
        assertEq(dutchDesk.PRICE_ORACLE(), address(priceOracle), "E3");
        assertEq(dutchDesk.AUCTION(), address(auction), "E4");
        assertEq(dutchDesk.BORROW_TOKEN(), address(borrowToken), "E5");
        assertEq(dutchDesk.COLLATERAL_TOKEN(), address(collateralToken), "E6");
        assertEq(dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE(), 1e18 + 15e16, "E7"); // 115%
        assertEq(dutchDesk.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE(), 1e18 + 100e16, "E8"); // 200%
        assertEq(dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE(), 1e18 - 5e16, "E9"); // 95%
        assertEq(dutchDesk.keeper(), keeper, "E10");
        assertEq(dutchDesk.nonce(), 0, "E11");
    }

    function test_kick_liquidation(
        uint256 _amount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));

        // Collateral is transferred from troveManager via kick
        airdrop(address(collateralToken), address(troveManager), _amount);

        uint256 _nonceBefore = dutchDesk.nonce();

        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, _receiver, true);

        uint256 _auctionId = _nonceBefore; // nonce is auction ID, incremented after kick

        assertTrue(auction.is_active(_auctionId), "E0");
        assertEq(auction.get_available_amount(_auctionId), _amount, "E1");

        uint256 _expectedStartingPrice =
            _amount * priceOracle.get_price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(auction.starting_price(_auctionId), _expectedStartingPrice, "E2");

        uint256 _expectedMinimumPrice = priceOracle.get_price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(auction.minimum_price(_auctionId), _expectedMinimumPrice, "E3");

        assertEq(auction.receiver(_auctionId), _receiver, "E4");
        assertTrue(auction.is_liquidation(_auctionId), "E5");
        assertEq(dutchDesk.nonce(), _nonceBefore + 1, "E6");
        assertTrue(auction.is_ongoing_liquidation_auction(), "E7");
        assertEq(auction.liquidation_auctions(), 1, "E8");
    }

    function test_kick_redemption(
        uint256 _amount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));

        // Collateral is transferred from troveManager via kick
        airdrop(address(collateralToken), address(troveManager), _amount);

        uint256 _nonceBefore = dutchDesk.nonce();

        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, _receiver, false);

        uint256 _auctionId = _nonceBefore; // nonce is auction ID, incremented after kick

        assertTrue(auction.is_active(_auctionId), "E0");
        assertEq(auction.get_available_amount(_auctionId), _amount, "E1");

        uint256 _expectedStartingPrice =
            _amount * priceOracle.get_price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(auction.starting_price(_auctionId), _expectedStartingPrice, "E2");

        uint256 _expectedMinimumPrice = priceOracle.get_price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(auction.minimum_price(_auctionId), _expectedMinimumPrice, "E3");

        assertEq(auction.receiver(_auctionId), _receiver, "E4");
        assertFalse(auction.is_liquidation(_auctionId), "E5");
        assertEq(dutchDesk.nonce(), _nonceBefore + 1, "E6");
        assertFalse(auction.is_ongoing_liquidation_auction(), "E7");
        assertEq(auction.liquidation_auctions(), 0, "E8");
    }

    function test_kick_zeroAmount(
        address _receiver,
        bool _isLiquidation
    ) public {
        uint256 _nonceBefore = dutchDesk.nonce();

        vm.prank(address(troveManager));
        dutchDesk.kick(0, _receiver, _isLiquidation);

        // Nothing should happen - nonce unchanged, no active auction
        assertEq(dutchDesk.nonce(), _nonceBefore, "E0");
        assertFalse(auction.is_active(_nonceBefore), "E1");
    }

    function test_kick_multipleAuctions(
        uint256 _amount1,
        uint256 _amount2,
        address _receiver1,
        address _receiver2
    ) public {
        _amount1 = bound(_amount1, minFuzzAmount, maxFuzzAmount / 2);
        _amount2 = bound(_amount2, minFuzzAmount, maxFuzzAmount / 2);
        vm.assume(_receiver1 != address(0));
        vm.assume(_receiver2 != address(0));

        // First kick
        airdrop(address(collateralToken), address(troveManager), _amount1);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount1, _receiver1, true);

        assertTrue(auction.is_active(0), "E0");
        assertEq(auction.get_available_amount(0), _amount1, "E1");
        assertEq(dutchDesk.nonce(), 1, "E2");

        // Second kick creates a new auction with nonce 1
        airdrop(address(collateralToken), address(troveManager), _amount2);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount2, _receiver2, true);

        assertTrue(auction.is_active(1), "E3");
        assertEq(auction.get_available_amount(1), _amount2, "E4");
        assertEq(dutchDesk.nonce(), 2, "E5");

        // First auction is still active
        assertTrue(auction.is_active(0), "E6");
        assertEq(auction.liquidation_auctions(), 2, "E7");
    }

    function test_reKick(
        uint256 _amount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));

        // Kick an auction
        airdrop(address(collateralToken), address(troveManager), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, _receiver, true);

        uint256 _auctionId = 0;
        assertTrue(auction.is_active(_auctionId), "E0");

        // Skip time until auction becomes inactive (price drops below minimum)
        skip(4 hours);

        assertFalse(auction.is_active(_auctionId), "E1");
        assertEq(auction.get_kickable_amount(_auctionId), _amount, "E2");

        // Re-kick the auction
        vm.prank(keeper);
        dutchDesk.re_kick(_auctionId);

        assertTrue(auction.is_active(_auctionId), "E3");
        assertEq(auction.get_available_amount(_auctionId), _amount, "E4");

        // Starting price should use EMERGENCY buffer
        uint256 _expectedStartingPrice =
            _amount * priceOracle.get_price(false) / WAD * dutchDesk.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(auction.starting_price(_auctionId), _expectedStartingPrice, "E5");

        uint256 _expectedMinimumPrice = priceOracle.get_price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD;
        assertEq(auction.minimum_price(_auctionId), _expectedMinimumPrice, "E6");
    }

    function test_reKick_invalidCaller(
        uint256 _amount,
        address _receiver,
        address _invalidCaller
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));
        vm.assume(_invalidCaller != keeper);

        // Kick an auction
        airdrop(address(collateralToken), address(troveManager), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, _receiver, true);

        // Skip time until auction becomes inactive
        skip(4 hours);

        // Try to re-kick with invalid caller
        vm.expectRevert("!keeper");
        vm.prank(_invalidCaller);
        dutchDesk.re_kick(0);
    }

    function test_reKick_auctionStillActive(
        uint256 _amount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));

        // Kick an auction
        airdrop(address(collateralToken), address(troveManager), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, _receiver, true);

        assertTrue(auction.is_active(0), "E0");

        // Try to re-kick while auction is still active
        vm.expectRevert("active");
        vm.prank(keeper);
        dutchDesk.re_kick(0);
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
