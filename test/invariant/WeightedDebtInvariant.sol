// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: total_weighted_debt == sum(trove.debt * trove.annual_interest_rate)
contract TotalWeightedDebtEqSumTroveWeightedDebtInvariant is BaseInvariant {

    function invariant_totalWeightedDebtEqSumTroveWeightedDebt() external {
        uint256[] memory _ids = handler.getTroveIds();
        uint256 _sum = 0;

        for (uint256 i = 0; i < _ids.length; i++) {
            ITroveManager.Trove memory _trove = troveManager.troves(_ids[i]);
            _sum += _trove.debt * _trove.annual_interest_rate;
        }

        assertEq(troveManager.total_weighted_debt(), _sum, "CRITICAL: total_weighted_debt != sum(trove weighted debt)");
    }

}
