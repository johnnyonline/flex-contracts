// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: unclaimed_protocol_fees <= lender idle balance + total_debt.
///         This is what guarantees the Lender's report can never underflow, so reports
///         and atomic bad-debt liquidations can never brick
contract ProtocolFeesInvariant is BaseInvariant {

    function invariant_protocolFeesSolvency() external {
        assertLe(
            troveManager.unclaimed_protocol_fees(),
            borrowToken.balanceOf(address(lender)) + troveManager.total_debt(),
            "CRITICAL: unclaimed protocol fees exceed lender assets"
        );
    }

}
