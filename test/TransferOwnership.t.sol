// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract TransferOwnershipTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_transferOwnership(
        uint256 _amount,
        address _newOwner
    ) public returns (uint256) {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, userBorrower, "E0");
        assertEq(_trove.pending_owner, address(0), "E1");

        // Attempt to transfer ownership from a non-owner
        vm.prank(userLender);
        vm.expectRevert("!owner");
        troveManager.transfer_ownership(_troveId, userLender);

        // Transfer ownership
        vm.prank(userBorrower);
        troveManager.transfer_ownership(_troveId, _newOwner);

        // Check trove info again
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, userBorrower, "E2");
        assertEq(_trove.pending_owner, _newOwner, "E3");

        return _troveId;
    }

    function test_acceptOwnership(
        uint256 _amount,
        address _newOwner
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Start the ownership transfer process
        uint256 _troveId = test_transferOwnership(_amount, _newOwner);

        // Attempt to accept ownership from a non-pending owner
        vm.prank(userLender);
        vm.expectRevert("!pending_owner");
        troveManager.accept_ownership(_troveId);

        // Accept ownership
        vm.prank(_newOwner);
        troveManager.accept_ownership(_troveId);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, _newOwner, "E0");
        assertEq(_trove.pending_owner, address(0), "E1");
    }

    function test_forceTransferOwnership(
        uint256 _amount,
        address _newOwner
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, userBorrower, "E0");
        assertEq(_trove.pending_owner, address(0), "E1");

        // Attempt to force transfer ownership from a non-owner
        vm.prank(userLender);
        vm.expectRevert("!owner");
        troveManager.force_transfer_ownership(_troveId, userLender);

        // Transfer ownership
        vm.prank(userBorrower);
        troveManager.force_transfer_ownership(_troveId, _newOwner);

        // Check trove info again
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, _newOwner, "E2");
        assertEq(_trove.pending_owner, address(0), "E3");
    }

}
