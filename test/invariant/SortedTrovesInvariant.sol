// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./BaseInvariant.sol";

/// @notice Invariant: sorted list only contains ACTIVE troves and is ordered by interest rate
contract SortedTrovesRegistryInvariant is BaseInvariant {

    function invariant_sortedTrovesRegistry() external {
        uint256[] memory _ids = handler.getTroveIds();
        uint256 _activeCount = 0;

        for (uint256 i = 0; i < _ids.length; i++) {
            ITroveManager.Trove memory _trove = troveManager.troves(_ids[i]);
            bool _contains = sortedTroves.contains(_ids[i]);

            if (_trove.status == ITroveManager.Status.active) {
                _activeCount++;
                assertEq(_contains, true, "CRITICAL: active trove missing from sorted list");
            } else {
                assertEq(_contains, false, "CRITICAL: non-active trove in sorted list");
            }
        }

        uint256 _size = sortedTroves.size();
        assertEq(_size, _activeCount, "CRITICAL: sorted list size != active trove count");

        if (_size == 0) {
            assertEq(sortedTroves.first(), 0, "CRITICAL: empty list has first");
            assertEq(sortedTroves.last(), 0, "CRITICAL: empty list has last");
            return;
        }

        uint256 _current = sortedTroves.first();
        uint256 _prevRate = type(uint256).max;
        uint256 _visited = 0;

        while (_current != 0 && _visited < _size) {
            ITroveManager.Trove memory _trove = troveManager.troves(_current);
            assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "CRITICAL: sorted list contains non-active trove");

            uint256 _rate = _trove.annual_interest_rate;
            assertLe(_rate, _prevRate, "CRITICAL: sorted list out of order");
            _prevRate = _rate;

            _current = sortedTroves.next(_current);
            _visited++;
        }

        assertEq(_visited, _size, "CRITICAL: sorted list size mismatch");
        assertEq(_current, 0, "CRITICAL: sorted list does not terminate");
    }

}
