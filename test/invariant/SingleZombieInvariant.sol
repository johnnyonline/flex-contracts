// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: at most one zombie trove with non-zero debt exists at a time
/// @dev The fuzzer is restricted to only call `openTrove` to maximize the chance of triggering
///      the double-zombie bug via the following redemption sequence:
///      1. User A opens trove (low rate) — drains lender liquidity
///      2. User B opens trove (higher rate) — lender is empty, so `_transfer_borrow_tokens` triggers
///         a redemption from trove A (lowest rate). Partial redemption leaves trove A below `min_debt` → zombie
///      3. User A opens another trove (even higher rate) — lender is empty again, `_redeem` checks the
///         zombie trove first but skips it (`msg.sender == trove.owner`), then redeems trove B instead.
///         If trove B is left below `min_debt`, it becomes a second zombie — violating the invariant
///
///      The buggy line in `_redeem` (trove_manager.vy):
///        `if msg.sender != trove.owner:`
///      This guard skips redemption of the caller's own zombie, but allows them to create a new zombie
///      from another trove, resulting in two zombies with non-zero debt at the same time
///
///      The handler uses a small fixed user set (3 addresses) and small debts (near `min_debt`) to increase
///      the probability of same-owner collisions and zombie-creating redemptions
contract SingleZombieInvariant is BaseInvariant {

    function setUp() public override {
        super.setUp();

        // Restrict fuzzer to only openTrove so it triggers the redemption sequence
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Handler.openTrove.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_atMostOneZombieWithDebt() external {
        uint256[] memory _ids = handler.getTroveIds();

        uint256 _zombieWithDebtCount = 0;
        for (uint256 i = 0; i < _ids.length; i++) {
            ITroveManager.Trove memory _trove = troveManager.troves(_ids[i]);
            if (_trove.status == ITroveManager.Status.zombie && _trove.debt > 0) _zombieWithDebtCount++;
        }

        assertLe(_zombieWithDebtCount, 1, "CRITICAL: more than one zombie trove with non-zero debt");
    }

}
