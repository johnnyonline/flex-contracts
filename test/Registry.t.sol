// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RegistryTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        assertEq(registry.VERSION(), "1.0.0", "E0");
        assertEq(registry.DADDY(), address(daddy), "E1");
        assertEq(registry.markets_count(), 0, "E2");
    }

    function test_endorse() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        assertEq(registry.markets_count(), 1, "E0");
        assertEq(registry.markets(0), address(troveManager), "E1");
        assertEq(uint256(registry.market_status(address(troveManager))), uint256(IRegistry.Status.endorsed), "E2");
        assertEq(registry.markets_count_for_pair(address(collateralToken), address(borrowToken)), 1, "E3");
        assertEq(registry.find_market_for_pair(address(collateralToken), address(borrowToken), 0), address(troveManager), "E4");
    }

    function test_endorse_notDaddy(
        address _notDaddy
    ) public {
        vm.assume(_notDaddy != address(daddy));

        vm.expectRevert("bad daddy");
        vm.prank(_notDaddy);
        registry.endorse(address(troveManager));
    }

    function test_endorse_notEmpty() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        vm.expectRevert();
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);
    }

    function test_endorse_unendorsed() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, true);

        vm.expectRevert();
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);
    }

    function test_unendorse() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, true);

        assertEq(uint256(registry.market_status(address(troveManager))), uint256(IRegistry.Status.unendorsed), "E0");
        assertEq(registry.markets_count(), 1, "E1"); // markets list is append-only
        assertEq(registry.markets(0), address(troveManager), "E2");
    }

    function test_unendorse_notDaddy(
        address _notDaddy
    ) public {
        vm.assume(_notDaddy != address(daddy));

        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        vm.expectRevert("bad daddy");
        vm.prank(_notDaddy);
        registry.unendorse(address(troveManager));
    }

    function test_unendorse_notEndorsed() public {
        vm.expectRevert();
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, true);
    }

    function test_unendorse_alreadyUnendorsed() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, true);

        vm.expectRevert();
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, true);
    }

    function test_marketsCountForPairSymmetry() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        // Should return same count regardless of order
        assertEq(
            registry.markets_count_for_pair(address(collateralToken), address(borrowToken)),
            registry.markets_count_for_pair(address(borrowToken), address(collateralToken)),
            "E0"
        );
    }

    function test_findMarketForPairSymmetry() public {
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        // Should return same market regardless of order
        assertEq(
            registry.find_market_for_pair(address(collateralToken), address(borrowToken), 0),
            registry.find_market_for_pair(address(borrowToken), address(collateralToken), 0),
            "E0"
        );
    }

    function test_getAllMarkets() public {
        // Empty before endorsing
        assertEq(registry.get_all_markets().length, 0, "E0");

        // Endorse
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        address[] memory _markets = registry.get_all_markets();
        assertEq(_markets.length, 1, "E1");
        assertEq(_markets[0], address(troveManager), "E2");
    }

    function test_getAllMarketsForPair() public {
        // Empty before endorsing
        assertEq(registry.get_all_markets_for_pair(address(collateralToken), address(borrowToken)).length, 0, "E0");

        // Endorse
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        address[] memory _markets = registry.get_all_markets_for_pair(address(collateralToken), address(borrowToken));
        assertEq(_markets.length, 1, "E1");
        assertEq(_markets[0], address(troveManager), "E2");

        // Symmetry
        address[] memory _marketsReversed = registry.get_all_markets_for_pair(address(borrowToken), address(collateralToken));
        assertEq(_marketsReversed.length, 1, "E3");
        assertEq(_marketsReversed[0], address(troveManager), "E4");
    }

}
