// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract DutchDeskTests is Base {

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
        assertEq(dutchDesk.trove_manager(), address(troveManager), "E0");
        assertEq(dutchDesk.lender(), address(lender), "E1");
        assertEq(dutchDesk.price_oracle(), address(priceOracle), "E2");
        assertEq(dutchDesk.auction(), address(auction), "E3");
        assertEq(dutchDesk.collateral_token(), address(collateralToken), "E4");
        assertEq(dutchDesk.collateral_token_precision(), COLLATERAL_TOKEN_PRECISION, "E5");
        assertEq(dutchDesk.minimum_price_buffer_percentage(), minimumPriceBufferPercentage, "E6");
        assertEq(dutchDesk.starting_price_buffer_percentage(), startingPriceBufferPercentage, "E7");
        assertEq(dutchDesk.re_kick_starting_price_buffer_percentage(), reKickStartingPriceBufferPercentage, "E8");
        assertEq(dutchDesk.nonce(), 0, "E9");
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert("initialized");
        dutchDesk.initialize(
            IDutchDesk.InitializeParams({
                trove_manager: address(troveManager),
                lender: address(lender),
                price_oracle: address(priceOracle),
                auction: address(auction),
                borrow_token: address(borrowToken),
                collateral_token: address(collateralToken),
                minimum_price_buffer_percentage: minimumPriceBufferPercentage,
                starting_price_buffer_percentage: startingPriceBufferPercentage,
                re_kick_starting_price_buffer_percentage: reKickStartingPriceBufferPercentage
            })
        );
    }

    function test_kick(
        uint256 _amount,
        uint256 _maximumAmount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _maximumAmount = bound(_maximumAmount, 1, type(uint256).max);
        vm.assume(_receiver != address(0));

        // Collateral is transferred from troveManager via kick
        airdrop(address(collateralToken), address(troveManager), _amount);

        uint256 _nonceBefore = dutchDesk.nonce();

        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, _maximumAmount, _receiver);

        uint256 _auctionId = _nonceBefore;

        assertTrue(auction.is_active(_auctionId), "E0");
        assertEq(auction.get_available_amount(_auctionId), _amount, "E1");

        IAuction.AuctionInfo memory auctionInfo = auction.auctions(_auctionId);
        uint256 _expectedStartingPrice =
            _amount * priceOracle.get_price(false) * dutchDesk.starting_price_buffer_percentage() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(auctionInfo.starting_price, _expectedStartingPrice, "E2");

        uint256 _expectedMinimumPrice = priceOracle.get_price(false) * dutchDesk.minimum_price_buffer_percentage() / WAD;
        assertEq(auctionInfo.minimum_price, _expectedMinimumPrice, "E3");

        assertEq(auctionInfo.receiver, _receiver, "E4");
        assertEq(auctionInfo.surplus_receiver, address(lender), "E5");
        assertEq(dutchDesk.nonce(), _nonceBefore + 1, "E6");
        assertEq(auctionInfo.maximum_amount, _maximumAmount, "E7");
    }

    function test_kick_zeroAmount(
        address _receiver
    ) public {
        uint256 _nonceBefore = dutchDesk.nonce();

        vm.prank(address(troveManager));
        dutchDesk.kick(0, 0, _receiver);

        // Nothing should happen - nonce unchanged, no active auction
        assertEq(dutchDesk.nonce(), _nonceBefore, "E0");
        assertFalse(auction.is_active(_nonceBefore), "E1");
    }

    function test_multiple_kicks(
        uint256 _amount1,
        uint256 _amount2
    ) public {
        _amount1 = bound(_amount1, minFuzzAmount, maxFuzzAmount / 2);
        _amount2 = bound(_amount2, minFuzzAmount, maxFuzzAmount / 2);

        // First kick (redemption)
        airdrop(address(collateralToken), address(troveManager), _amount1);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount1, type(uint256).max, address(userLender));

        assertTrue(auction.is_active(0), "E0");
        assertEq(auction.get_available_amount(0), _amount1, "E1");
        assertEq(dutchDesk.nonce(), 1, "E2");

        // Second kick creates a new auction with nonce 1 (redemption)
        airdrop(address(collateralToken), address(troveManager), _amount2);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount2, type(uint256).max, address(userLender));

        assertTrue(auction.is_active(1), "E3");
        assertEq(auction.get_available_amount(1), _amount2, "E4");
        assertEq(dutchDesk.nonce(), 2, "E5");

        // First auction is still active
        assertTrue(auction.is_active(0), "E6");
    }

    function test_reKick(
        uint256 _amount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));

        // Kick a redemption auction
        airdrop(address(collateralToken), address(troveManager), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, type(uint256).max, _receiver);

        uint256 _auctionId = 0;
        assertTrue(auction.is_active(_auctionId), "E0");

        // Skip time until auction becomes inactive (price drops below minimum)
        skip(4 hours);

        assertFalse(auction.is_active(_auctionId), "E1");
        assertEq(auction.get_kickable_amount(_auctionId), _amount, "E2");

        // Re-kick the auction
        dutchDesk.re_kick(_auctionId);

        assertTrue(auction.is_active(_auctionId), "E3");
        assertEq(auction.get_available_amount(_auctionId), _amount, "E4");

        // Starting price should use re-kick buffer
        IAuction.AuctionInfo memory auctionInfo = auction.auctions(_auctionId);
        uint256 _expectedStartingPrice =
            _amount * priceOracle.get_price(false) * dutchDesk.re_kick_starting_price_buffer_percentage() / WAD / COLLATERAL_TOKEN_PRECISION;
        assertEq(auctionInfo.starting_price, _expectedStartingPrice, "E5");

        uint256 _expectedMinimumPrice = priceOracle.get_price(false) * dutchDesk.minimum_price_buffer_percentage() / WAD;
        assertEq(auctionInfo.minimum_price, _expectedMinimumPrice, "E6");
    }

    function test_reKick_auctionStillActive(
        uint256 _amount,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_receiver != address(0));

        // Kick a redemption auction
        airdrop(address(collateralToken), address(troveManager), _amount);
        vm.prank(address(troveManager));
        dutchDesk.kick(_amount, type(uint256).max, _receiver);

        assertTrue(auction.is_active(0), "E0");

        // Try to re-kick while auction is still active
        vm.expectRevert("active");
        dutchDesk.re_kick(0);
    }

}
