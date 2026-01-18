// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: collateral_balance == sum(trove collateral)
contract CollateralBalanceEqSumTroveCollateralInvariant is BaseInvariant {

    function invariant_collateralBalanceEqSumTroveCollateral() external {
        uint256[] memory _ids = handler.getTroveIds();
        uint256 _sum = 0;

        for (uint256 i = 0; i < _ids.length; i++) {
            ITroveManager.Trove memory _trove = troveManager.troves(_ids[i]);
            _sum += _trove.collateral;
        }

        assertEq(troveManager.collateral_balance(), _sum, "CRITICAL: collateral_balance != sum(trove collateral)");
    }

}
