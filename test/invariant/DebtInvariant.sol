// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: total_debt >= sum(trove debts)
contract TotalDebtGeSumTroveDebtsInvariant is BaseInvariant {

    function invariant_totalDebtGeSumTroveDebts() external {
        uint256[] memory _ids = handler.getTroveIds();
        uint256 _totalDebt = troveManager.sync_total_debt();

        uint256 _sum = 0;
        for (uint256 i = 0; i < _ids.length; i++) {
            _sum += troveManager.get_trove_debt_after_interest(_ids[i]);
        }

        assertGe(_totalDebt, _sum, "CRITICAL: sum(trove debts) > total_debt");
    }

}
