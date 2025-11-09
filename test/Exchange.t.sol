// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract ExchangeTests is Base {

    function setUp() public override {
        Base.setUp();

        vm.prank(management);
        exchange.accept_ownership();
    }

    function test_setup() public {
        assertEq(exchange.owner(), management, "E0");
        assertEq(exchange.pending_owner(), address(0), "E1");
        assertEq(exchange.route_index(), 1, "E2");
        assertNotEq(exchange.routes(0), address(0), "E3");
        assertEq(exchange.BORROW_TOKEN(), address(borrowToken), "E4");
        assertEq(exchange.COLLATERAL_TOKEN(), address(collateralToken), "E5");
    }

    function test_swap(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Airdrop collateral tokens to user
        airdrop(address(collateralToken), userBorrower, _amount);

        // Swap using route index 0 and send to userLender
        vm.startPrank(userBorrower);
        collateralToken.approve(address(exchange), _amount);
        uint256 _amountOut = exchange.swap(_amount, 0, userLender);
        vm.stopPrank();

        // Check balances
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E4");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E4");
        assertEq(collateralToken.balanceOf(userLender), 0, "E5");
        assertEq(borrowToken.balanceOf(userLender), _amountOut, "E6");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E7");
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E8");
    }

    function test_swap_zeroAmount(
        uint256 _index,
        address _receiver
    ) public {
        assertEq(exchange.swap(0, _index, _receiver), 0, "E0");
    }

    function test_swap_invalidRoute(
        uint256 _amount,
        uint256 _invalidIndex,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_invalidIndex > 0);

        vm.expectRevert("!route");
        exchange.swap(_amount, _invalidIndex, _receiver);
    }

    function test_transferOwnership(
        address _newOwner
    ) public {
        vm.prank(management);
        exchange.transfer_ownership(_newOwner);

        assertEq(exchange.owner(), management, "E0");
        assertEq(exchange.pending_owner(), _newOwner, "E1");

        vm.prank(_newOwner);
        exchange.accept_ownership();

        assertEq(exchange.owner(), _newOwner, "E2");
        assertEq(exchange.pending_owner(), address(0), "E3");
    }

    function test_transferOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != management);

        vm.expectRevert("!owner");
        vm.prank(_invalidCaller);
        exchange.transfer_ownership(_newOwner);
    }

    function test_acceptOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != _newOwner);

        vm.prank(management);
        exchange.transfer_ownership(_newOwner);

        vm.expectRevert("!pending_owner");
        vm.prank(_invalidCaller);
        exchange.accept_ownership();
    }

    function test_addRoute(
        address _newRoute
    ) public {
        vm.prank(management);
        exchange.add_route(_newRoute);

        assertEq(exchange.routes(1), _newRoute, "E0");
        assertEq(exchange.route_index(), 2, "E1");
    }

    function test_addRoute_invalidCaller(
        address _newRoute,
        address _invalidCaller
    ) public {
        vm.expectRevert("!owner");
        vm.prank(_invalidCaller);
        exchange.add_route(_newRoute);
    }

}
