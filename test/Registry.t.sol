// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RegistryTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        assertEq(registry.VERSION(), "1.0.0", "E0");
        assertEq(registry.daddy(), deployerAddress, "E1");
        assertEq(registry.pending_daddy(), address(0), "E2");
        assertEq(registry.markets_count(), 0, "E3");
    }

    function test_transferOwnership(
        address _newDaddy
    ) public {
        vm.assume(_newDaddy != address(0));

        vm.prank(deployerAddress);
        registry.transfer_ownership(_newDaddy);

        assertEq(registry.pending_daddy(), _newDaddy, "E0");
        assertEq(registry.daddy(), deployerAddress, "E1");
    }

    function test_transferOwnership_notDaddy(
        address _notDaddy
    ) public {
        vm.assume(_notDaddy != deployerAddress);

        vm.expectRevert("bad daddy");
        vm.prank(_notDaddy);
        registry.transfer_ownership(address(1));
    }

    function test_acceptOwnership(
        address _newDaddy
    ) public {
        vm.assume(_newDaddy != address(0));

        vm.prank(deployerAddress);
        registry.transfer_ownership(_newDaddy);

        vm.prank(_newDaddy);
        registry.accept_ownership();

        assertEq(registry.daddy(), _newDaddy, "E0");
        assertEq(registry.pending_daddy(), address(0), "E1");
    }

    function test_acceptOwnership_notPendingDaddy(
        address _newDaddy,
        address _notPendingDaddy
    ) public {
        vm.assume(_newDaddy != address(0));
        vm.assume(_notPendingDaddy != _newDaddy);

        vm.prank(deployerAddress);
        registry.transfer_ownership(_newDaddy);

        vm.expectRevert("!pending_daddy");
        vm.prank(_notPendingDaddy);
        registry.accept_ownership();
    }

    function test_endorse() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        assertEq(registry.markets_count(), 1, "E0");
        assertEq(registry.markets(0), address(troveManager), "E1");
        assertEq(uint256(registry.market_status(address(troveManager))), uint256(IRegistry.Status.endorsed), "E2");
        assertEq(registry.markets_count_for_pair(address(collateralToken), address(borrowToken)), 1, "E3");
        assertEq(registry.find_market_for_pair(address(collateralToken), address(borrowToken), 0), address(troveManager), "E4");
    }

    function test_endorse_notDaddy(
        address _notDaddy
    ) public {
        vm.assume(_notDaddy != deployerAddress);

        vm.expectRevert("bad daddy");
        vm.prank(_notDaddy);
        registry.endorse(address(troveManager));
    }

    function test_endorse_notEmpty() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        vm.expectRevert("!empty");
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));
    }

    function test_endorse_unendorsed() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        vm.prank(deployerAddress);
        registry.unendorse(address(troveManager));

        vm.expectRevert("!empty");
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));
    }

    function test_unendorse() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        vm.prank(deployerAddress);
        registry.unendorse(address(troveManager));

        assertEq(uint256(registry.market_status(address(troveManager))), uint256(IRegistry.Status.unendorsed), "E0");
        assertEq(registry.markets_count(), 1, "E1"); // markets list is append-only
        assertEq(registry.markets(0), address(troveManager), "E2");
    }

    function test_unendorse_notDaddy(
        address _notDaddy
    ) public {
        vm.assume(_notDaddy != deployerAddress);

        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        vm.expectRevert("bad daddy");
        vm.prank(_notDaddy);
        registry.unendorse(address(troveManager));
    }

    function test_unendorse_notEndorsed() public {
        vm.expectRevert("!ENDORSED");
        vm.prank(deployerAddress);
        registry.unendorse(address(troveManager));
    }

    function test_unendorse_alreadyUnendorsed() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        vm.prank(deployerAddress);
        registry.unendorse(address(troveManager));

        vm.expectRevert("!ENDORSED");
        vm.prank(deployerAddress);
        registry.unendorse(address(troveManager));
    }

    function test_marketsCountForPairSymmetry() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        // Should return same count regardless of order
        assertEq(
            registry.markets_count_for_pair(address(collateralToken), address(borrowToken)),
            registry.markets_count_for_pair(address(borrowToken), address(collateralToken)),
            "E0"
        );
    }

    function test_findMarketForPairSymmetry() public {
        vm.prank(deployerAddress);
        registry.endorse(address(troveManager));

        // Should return same market regardless of order
        assertEq(
            registry.find_market_for_pair(address(collateralToken), address(borrowToken), 0),
            registry.find_market_for_pair(address(borrowToken), address(collateralToken), 0),
            "E0"
        );
    }

}
