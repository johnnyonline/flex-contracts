// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILender} from "../interfaces/ILender.sol";

/// @title StrategyAprOracle
/// @author Flex
/// @notice APR oracle for the Flex Lender strategy
contract StrategyAprOracle {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Oracle name
    string public constant name = "Flex Lender Strategy APR Oracle";

    /// @notice WAD constant
    uint256 private constant WAD = 1e18;

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the expected APR of a strategy post a debt change
    /// @dev APR = total_weighted_debt * WAD / ((totalAssets + delta) * borrowTokenPrecision)
    ///      Interest rates are stored in borrow token precision, so the result is scaled to WAD.
    ///      Reverts if _delta is negative and its absolute value exceeds totalAssets
    /// @param _strategy The strategy to get the APR for
    /// @param _delta The difference in debt allocated to the strategy
    /// @return The expected APR for the strategy in WAD (e.g., 1e16 = 1% APR)
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view returns (uint256) {
        ILender _lender = ILender(_strategy);

        uint256 _totalWeightedDebt = _lender.TROVE_MANAGER().total_weighted_debt();
        if (_totalWeightedDebt == 0) return 0;

        uint256 _totalAssets = uint256(int256(_lender.totalAssets()) + _delta);
        if (_totalAssets == 0) return 0;

        return _totalWeightedDebt * WAD / (_totalAssets * 10 ** IERC20Metadata(_lender.asset()).decimals());
    }

}
