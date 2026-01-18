// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: zombie_trove_id is zero or points to a zombie trove not in the sorted list
contract ZombieTroveIdConsistencyInvariant is BaseInvariant {

    function invariant_zombieTroveIdConsistency() external {
        uint256 _zombieId = troveManager.zombie_trove_id();

        if (_zombieId == 0) {
            return;
        }

        ITroveManager.Trove memory _trove = troveManager.troves(_zombieId);

        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "CRITICAL: zombie_trove_id not zombie");
        assertEq(sortedTroves.contains(_zombieId), false, "CRITICAL: zombie_trove_id in sorted list");
        assertGt(_trove.debt, 0, "CRITICAL: zombie_trove_id has zero debt");
    }

}
