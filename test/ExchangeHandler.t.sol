// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract ExchangeHandlerTests is Base {

    function setUp() public override {
        Base.setUp();

        vm.prank(management);
        exchangeHandler.accept_ownership();
    }

    function test_setup() public {
        assertEq(exchangeHandler.owner(), management, "E0");
        assertEq(exchangeHandler.pending_owner(), address(0), "E1");
        assertEq(exchangeHandler.route_index(), 2, "E2");
        assertNotEq(exchangeHandler.routes(0), address(0), "E3");
        assertNotEq(exchangeHandler.routes(1), address(0), "E4");
        assertEq(exchangeHandler.BORROW_TOKEN(), address(borrowToken), "E5");
        assertEq(exchangeHandler.COLLATERAL_TOKEN(), address(collateralToken), "E6");
    }

    function test_swap(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Airdrop collateral tokens to user
        airdrop(address(collateralToken), userBorrower, _amount);

        // Swap using route index 0 and send to userLender
        vm.startPrank(userBorrower);
        collateralToken.approve(address(exchangeHandler), _amount);
        uint256 _amountOut = exchangeHandler.swap(_amount, 0, userLender);
        vm.stopPrank();

        // Check balances
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E4");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E4");
        assertEq(collateralToken.balanceOf(userLender), 0, "E5");
        assertEq(borrowToken.balanceOf(userLender), _amountOut, "E6");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E7");
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E8");
    }

    function test_swap_zeroAmount(
        uint256 _index,
        address _receiver
    ) public {
        assertEq(exchangeHandler.swap(0, _index, _receiver), 0, "E0");
    }

    function test_swap_invalidRoute(
        uint256 _amount,
        uint256 _invalidIndex,
        address _receiver
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_invalidIndex > 1);

        vm.expectRevert("!route");
        exchangeHandler.swap(_amount, _invalidIndex, _receiver);
    }

    function test_transferOwnership(
        address _newOwner
    ) public {
        vm.prank(management);
        exchangeHandler.transfer_ownership(_newOwner);

        assertEq(exchangeHandler.owner(), management, "E0");
        assertEq(exchangeHandler.pending_owner(), _newOwner, "E1");

        vm.prank(_newOwner);
        exchangeHandler.accept_ownership();

        assertEq(exchangeHandler.owner(), _newOwner, "E2");
        assertEq(exchangeHandler.pending_owner(), address(0), "E3");
    }

    function test_transferOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != management);

        vm.expectRevert("!owner");
        vm.prank(_invalidCaller);
        exchangeHandler.transfer_ownership(_newOwner);
    }

    function test_acceptOwnership_invalidCaller(
        address _newOwner,
        address _invalidCaller
    ) public {
        vm.assume(_invalidCaller != _newOwner);

        vm.prank(management);
        exchangeHandler.transfer_ownership(_newOwner);

        vm.expectRevert("!pending_owner");
        vm.prank(_invalidCaller);
        exchangeHandler.accept_ownership();
    }

    function test_addRoute(
        address _newRoute
    ) public {
        vm.prank(management);
        exchangeHandler.add_route(_newRoute);

        assertEq(exchangeHandler.routes(2), _newRoute, "E0");
        assertEq(exchangeHandler.route_index(), 3, "E1");
    }

    function test_addRoute_invalidCaller(
        address _newRoute,
        address _invalidCaller
    ) public {
        vm.expectRevert("!owner");
        vm.prank(_invalidCaller);
        exchangeHandler.add_route(_newRoute);
    }

}
